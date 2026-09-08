import 'dart:async';
import 'dart:convert';

import 'package:path/path.dart' as p;

import '../../../core/cancellation.dart';
import '../domain/language_server.dart';

final class LanguageSession {
  LanguageSession(this.spec, this.connection);
  final LanguageServerSpec spec;
  final LanguageConnection connection;
  Map<String, dynamic> capabilities = {};
  final documents = <String, LanguageDocument>{};
  StreamSubscription<Map<String, dynamic>>? subscription;
  bool ready = false;
  String? error;
  bool contains(String workspace, String path) =>
      p.equals(workspace, spec.workspace) &&
      p.isWithin(spec.root, path) &&
      !spec.excludedRoots.any(
        (root) =>
            p.isWithin(spec.root, root) &&
            (p.equals(root, path) || p.isWithin(root, path)),
      ) &&
      p.extension(path).toLowerCase() ==
          (spec.language == 'dart' ? '.dart' : '.py');
}

final class LanguageService {
  LanguageService(this.servers);
  final LanguageServers servers;
  final _changed = StreamController<void>.broadcast();
  Stream<void> get changes => _changed.stream;
  final sessions = <String, LanguageSession>{};
  final _problems = <String, List<LanguageProblem>>{};
  final _problemBytes = <String, int>{};
  final _limitedProblems = <String>{};
  bool get diagnosticsLimited => _limitedProblems.isNotEmpty;
  List<LanguageProblem> get problems =>
      _problems.values.expand((v) => v).take(2000).toList();
  List<LanguageDocument> _documents = const [];
  bool _closed = false;
  final _workspaceEpochs = <String, int>{};
  bool starting = false;
  int generation = 0;
  String? message;
  int _nextCompletion = 0;
  final _completions =
      <
        int,
        ({
          LanguageSession session,
          LanguageDocument doc,
          Map<String, Object?> item,
        })
      >{};

  void _removeProblem(String key) {
    _problems.remove(key);
    _problemBytes.remove(key);
    _limitedProblems.remove(key);
  }

  void _removeServerProblems(String id) {
    for (final key
        in _problems.keys.where((key) => key.startsWith('$id:')).toList()) {
      _removeProblem(key);
    }
  }

  Future<void> start(LanguageServerSpec spec) async {
    if (_closed || starting) {
      throw const LanguageFailure(
        'Language server startup is already in progress.',
      );
    }
    if (!sessions.containsKey(spec.id) && sessions.length >= 4) {
      throw const LanguageFailure(
        'Stop a language server before starting more (limit: 4).',
      );
    }
    starting = true;
    generation++;
    final epoch = _workspaceEpochs[spec.workspace] ?? 0;
    _changed.add(null);
    try {
      await stop(spec.id);
      final connection = await servers.start(spec);
      if (_closed || epoch != (_workspaceEpochs[spec.workspace] ?? 0)) {
        await connection.close();
        return;
      }
      final session = LanguageSession(spec, connection);
      sessions[spec.id] = session;
      session.subscription = connection.notifications.listen(
        (event) => _notification(session, event),
      );
      final result = await connection.request('initialize', {
        'processId': null,
        'clientInfo': {'name': 'Tabryo', 'version': '0.1.0'},
        'rootUri': Uri.directory(spec.root).toString(),
        'workspaceFolders': [
          {
            'uri': Uri.directory(spec.root).toString(),
            'name': p.basename(spec.root),
          },
        ],
        'capabilities': {
          'general': {
            'positionEncodings': ['utf-16'],
          },
          'workspace': {
            // Unsolicited requests receive an explicit applied:false response.
            // Completion imports in this document use additionalTextEdits.
            'applyEdit': true,
            'configuration': false,
            'workspaceEdit': {
              'documentChanges': true,
              'resourceOperations': <String>[],
            },
          },
          'textDocument': {
            'synchronization': {'dynamicRegistration': false, 'didSave': true},
            'publishDiagnostics': {'versionSupport': true},
            'completion': {
              'completionItem': {
                'snippetSupport': true,
                'documentationFormat': ['plaintext'],
                'resolveSupport': {
                  'properties': [
                    'documentation',
                    'detail',
                    'additionalTextEdits',
                  ],
                },
              },
            },
            'hover': {
              'contentFormat': ['plaintext'],
            },
            'signatureHelp': {
              'signatureInformation': {
                'documentationFormat': ['plaintext'],
                'parameterInformation': {'labelOffsetSupport': true},
              },
            },
            'documentSymbol': {'hierarchicalDocumentSymbolSupport': true},
            'codeAction': {
              'codeActionLiteralSupport': {
                'codeActionKind': {
                  'valueSet': [
                    'quickfix',
                    'refactor',
                    'refactor.extract',
                    'refactor.inline',
                    'refactor.rewrite',
                    'source.organizeImports',
                  ],
                },
              },
              'dataSupport': true,
              'resolveSupport': {
                'properties': ['edit'],
              },
            },
            'rename': {'prepareSupport': false},
          },
        },
        'initializationOptions': spec.kind == LanguageServerKind.dart
            ? {
                'onlyAnalyzeProjectsWithOpenFiles': true,
                'suggestFromUnimportedLibraries': true,
              }
            : <String, Object?>{},
      });
      if (_closed || sessions[spec.id] != session) return;
      if (result is! Map || result['capabilities'] is! Map) {
        throw const LanguageFailure('Language server initialization failed.');
      }
      session.capabilities = Map<String, dynamic>.from(
        result['capabilities'] as Map,
      );
      if ((session.capabilities['positionEncoding'] ?? 'utf-16') != 'utf-16') {
        throw const LanguageFailure(
          'Language server does not support UTF-16 positions.',
        );
      }
      connection.notify('initialized', {});
      if (spec.kind == LanguageServerKind.pyright) {
        connection.notify('workspace/didChangeConfiguration', {
          'settings': {
            'python': {
              'pythonPath': spec.python,
              'analysis': {
                'typeCheckingMode': 'basic',
                'diagnosticMode': 'openFilesOnly',
                'autoSearchPaths': true,
              },
            },
            'pyright': {'disableOrganizeImports': true},
          },
        });
      }
      session.ready = true;
      message = '${spec.kind.name} connected for ${p.basename(spec.root)}.';
      synchronize(_documents);
    } catch (error) {
      await stop(spec.id);
      message = '$error';
      rethrow;
    } finally {
      starting = false;
      if (!_closed) _changed.add(null);
    }
  }

  void synchronize(List<LanguageDocument> documents) {
    if (_closed) return;
    _documents = List.of(documents);
    var changed = false;
    for (final session in sessions.values.where((s) => s.ready)) {
      try {
        final wanted = {
          for (final doc in documents)
            if (session.contains(doc.workspace, doc.path)) doc.path: doc,
        };
        for (final path in session.documents.keys.toList()) {
          if (!wanted.containsKey(path)) {
            changed = true;
            session.connection.notify('textDocument/didClose', {
              'textDocument': {'uri': Uri.file(path).toString()},
            });
            session.documents.remove(path);
            _removeProblem('${session.spec.id}:$path');
          }
        }
        for (final doc in wanted.values) {
          final previous = session.documents[doc.path];
          final uri = Uri.file(doc.path).toString();
          if (previous == null) {
            changed = true;
            session.connection.notify('textDocument/didOpen', {
              'textDocument': {
                'uri': uri,
                'languageId': session.spec.language,
                'version': doc.version,
                'text': doc.text,
              },
            });
          } else if (previous.version != doc.version) {
            changed = true;
            final sync = session.capabilities['textDocumentSync'];
            final kind = sync is Map ? sync['change'] : sync;
            session.connection.notify('textDocument/didChange', {
              'textDocument': {'uri': uri, 'version': doc.version},
              'contentChanges': [
                {
                  if (kind == 2)
                    'range': {
                      'start': {'line': 0, 'character': 0},
                      'end': languagePosition(
                        previous.text,
                        previous.text.length,
                      ),
                    },
                  'text': doc.text,
                },
              ],
            });
            _removeProblem('${session.spec.id}:${doc.path}');
          }
          session.documents[doc.path] = doc;
        }
      } catch (_) {
        changed = true;
        session.ready = false;
        session.error =
            'Document synchronization failed. Restart this language server.';
        _removeServerProblems(session.spec.id);
        unawaited(session.connection.close());
      }
    }
    if (changed) _changed.add(null);
  }

  void _notification(LanguageSession session, Map<String, dynamic> event) {
    if (_closed || sessions[session.spec.id] != session) return;
    final params = event['params'];
    if (event['method'] == 'tabryo/disconnected') {
      session.ready = false;
      session.error = params is Map
          ? '${params['message']}'
          : 'Language server stopped.';
      _removeServerProblems(session.spec.id);
      _changed.add(null);
      return;
    }
    if (event['method'] != 'textDocument/publishDiagnostics' ||
        params is! Map ||
        params['uri'] is! String ||
        params['diagnostics'] is! List) {
      return;
    }
    try {
      final uri = Uri.parse(params['uri'] as String);
      if (uri.scheme != 'file' || uri.hasQuery || uri.hasFragment) return;
      final path = p.normalize(uri.toFilePath());
      if (!session.contains(session.spec.workspace, path)) return;
      final doc = session.documents[path];
      final version = params['version'];
      if (doc != null && version != null && version != doc.version) return;
      final key = '${session.spec.id}:$path';
      if (!_problems.containsKey(key) && _problems.length >= 100) {
        if (_limitedProblems.add('file limit')) _changed.add(null);
        return;
      }
      _limitedProblems.remove(key);
      var retained = 0;
      final otherBytes = _problemBytes.entries
          .where((e) => e.key != key)
          .fold<int>(0, (sum, e) => sum + e.value);
      final otherCount = _problems.entries
          .where((e) => e.key != key)
          .fold<int>(0, (sum, e) => sum + e.value.length);
      final accepted = <LanguageProblem>[];
      for (final item in (params['diagnostics'] as List).take(200)) {
        if (item is! Map ||
            item['message'] is! String ||
            item['range'] is! Map) {
          continue;
        }
        final range = item['range'] as Map;
        if (range['start'] is! Map || range['end'] is! Map) continue;
        bool validPosition(Map value) =>
            value['line'] is int &&
            value['character'] is int &&
            (value['line'] as int) >= 0 &&
            (value['character'] as int) >= 0;
        if (!validPosition(range['start'] as Map) ||
            !validPosition(range['end'] as Map) ||
            (item['severity'] != null &&
                (item['severity'] is! int ||
                    (item['severity'] as int) < 1 ||
                    (item['severity'] as int) > 4))) {
          continue;
        }
        if (doc != null) {
          try {
            languageOffset(doc.text, range['start'] as Map);
            languageOffset(doc.text, range['end'] as Map);
          } on LanguageFailure {
            continue;
          }
        }
        final size = utf8.encode(jsonEncode(item)).length;
        if (retained + size > 64 * 1024 ||
            otherBytes + retained + size > 2 * 1024 * 1024 ||
            otherCount + accepted.length >= 2000) {
          _limitedProblems.add(key);
          break;
        }
        retained += size;
        accepted.add(
          LanguageProblem(
            server: session.spec.id,
            workspace: session.spec.workspace,
            path: path,
            diagnostic: Map<String, dynamic>.from(item),
            version: version is int ? version : null,
          ),
        );
      }
      _problems[key] = accepted;
      _problemBytes[key] = retained;
      if ((params['diagnostics'] as List).length > 200) {
        _limitedProblems.add(key);
      }
      _changed.add(null);
    } on FormatException {
      return;
    } on UnsupportedError {
      return;
    }
  }

  LanguageSession? sessionFor(LanguageDocument doc, {bool lint = false}) =>
      sessions.values
          .where(
            (s) =>
                s.ready &&
                s.contains(doc.workspace, doc.path) &&
                (lint
                    ? s.spec.kind != LanguageServerKind.pyright
                    : s.spec.kind != LanguageServerKind.ruff),
          )
          .firstOrNull;

  Future<Object?> request(
    LanguageDocument doc,
    String method,
    Map<String, Object?> params, {
    Cancellation? cancellation,
    bool lint = false,
  }) async {
    if (method == 'completionItem/resolve') {
      final entry = _completions[params['ticket']];
      if (entry == null ||
          entry.doc.workspace != doc.workspace ||
          entry.doc.path != doc.path ||
          (entry.doc.version != doc.version &&
              (doc.version != entry.doc.version + 1 ||
                  acceptedCompletionText(entry.doc.text, entry.item) !=
                      doc.text)) ||
          sessions[entry.session.spec.id] != entry.session ||
          !entry.session.ready) {
        throw const Cancelled();
      }
      final provider = entry.session.capabilities['completionProvider'];
      final resolved = provider is Map && provider['resolveProvider'] == true
          ? await entry.session.connection.request(
              method,
              entry.item,
              cancellation: cancellation,
            )
          : entry.item;
      cancellation?.check();
      if (!entry.session.ready ||
          sessions[entry.session.spec.id] != entry.session ||
          !completionVersionMatches(
            entry.doc,
            entry.session.documents[doc.path],
            entry.item,
          )) {
        throw const Cancelled();
      }
      if (resolved is! Map) {
        throw const LanguageFailure('Invalid resolved completion.');
      }
      return checkedCompletion(
        entry.doc.text,
        Map<String, Object?>.from(resolved),
      );
    }
    final session = sessionFor(doc, lint: lint);
    if (session == null) return null;
    final capability = switch (method) {
      'textDocument/completion' => 'completionProvider',
      'textDocument/hover' => 'hoverProvider',
      'textDocument/signatureHelp' => 'signatureHelpProvider',
      'textDocument/definition' => 'definitionProvider',
      'textDocument/references' => 'referencesProvider',
      'textDocument/documentSymbol' => 'documentSymbolProvider',
      'textDocument/rename' => 'renameProvider',
      'textDocument/codeAction' => 'codeActionProvider',
      'codeAction/resolve' => 'codeActionProvider',
      'textDocument/formatting' => 'documentFormattingProvider',
      _ => throw const LanguageFailure('Unsupported language operation.'),
    };
    if (session.capabilities[capability] == null ||
        session.capabilities[capability] == false) {
      return null;
    }
    if (method == 'codeAction/resolve') {
      final provider = session.capabilities[capability];
      if (provider is! Map || provider['resolveProvider'] != true) {
        return params;
      }
    }
    final result = await session.connection.request(method, {
      ...params,
      if (method != 'codeAction/resolve')
        'textDocument': {'uri': Uri.file(doc.path).toString()},
    }, cancellation: cancellation);
    if (!session.ready ||
        sessions[session.spec.id] != session ||
        session.documents[doc.path]?.version != doc.version) {
      throw const Cancelled();
    }
    if (method == 'textDocument/completion') {
      _completions.removeWhere(
        (_, entry) =>
            entry.doc.path == doc.path && entry.doc.workspace == doc.workspace,
      );
      final values = result is List
          ? result
          : (result is Map ? result['items'] : null);
      final items = <Map<String, Object?>>[];
      for (final raw in (values is List ? values : []).take(200)) {
        if (raw is! Map || raw['label'] is! String) continue;
        final item = Map<String, Object?>.from(raw);
        final ticket = ++_nextCompletion;
        while (_completions.length >= 800) {
          _completions.remove(_completions.keys.first);
        }
        _completions[ticket] = (session: session, doc: doc, item: item);
        items.add({...checkedCompletion(doc.text, item), 'ticket': ticket});
      }
      return {
        'isIncomplete': result is Map && result['isIncomplete'] == true,
        'items': items,
      };
    }
    return result;
  }

  Future<void> stop(String id) async {
    final session = sessions.remove(id);
    if (session == null) return;
    _completions.removeWhere((_, entry) => identical(entry.session, session));
    generation++;
    final wasReady = session.ready;
    session.ready = false;
    _removeServerProblems(id);
    await session.subscription?.cancel();
    if (wasReady) {
      try {
        await session.connection
            .request('shutdown', {})
            .timeout(const Duration(milliseconds: 800));
        session.connection.notify('exit', {});
      } catch (_) {
        /* A stopped server is still reaped by its transport. */
      }
    }
    await session.connection.close();
    if (!_closed) _changed.add(null);
  }

  Future<void> closeWorkspace(String root) async {
    _workspaceEpochs[root] = (_workspaceEpochs[root] ?? 0) + 1;
    for (final session in sessions.values.toList()) {
      if (p.equals(session.spec.workspace, root)) await stop(session.spec.id);
    }
  }

  Future<void> close() async {
    _closed = true;
    for (final id in sessions.keys.toList()) {
      await stop(id);
    }
    await _changed.close();
  }
}
