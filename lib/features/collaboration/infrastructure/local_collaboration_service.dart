import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../application/collaboration_broker.dart';
import '../domain/collaboration.dart';
import 'collaboration_tools.dart';
import 'managed_codex_session.dart';
import 'sqlite_collaboration_store.dart';

/// Start-Process passes one command-line string to the Windows child parser.
/// Preserve TOML quotes, spaces and trailing backslashes in Codex overrides.
String windowsCollaborationArguments(List<String> arguments) => arguments
    .map((argument) {
      final result = StringBuffer('"');
      var backslashes = 0;
      for (final character in argument.split('')) {
        if (character == r'\') {
          backslashes++;
          continue;
        }
        result.write(
          r'\' * (character == '"' ? backslashes * 2 + 1 : backslashes),
        );
        result.write(character);
        backslashes = 0;
      }
      result.write(r'\' * (backslashes * 2));
      result.write('"');
      return result.toString();
    })
    .join(' ');

/// Authenticated local HTTP control plane and stateless Streamable HTTP MCP.
/// Only this process owns the SQLite connection and the Codex children.
final class LocalCollaborationService {
  LocalCollaborationService._(
    this.directory,
    this.store,
    this._lock,
    this._server,
    this.codexExecutable,
    this.gitExecutable,
    this.sessionEnvironment,
    this.sessionArguments,
  ) : broker = CollaborationBroker(store);
  final Directory directory;
  final SqliteCollaborationStore store;
  final CollaborationBroker broker;
  final RandomAccessFile _lock;
  final HttpServer _server;
  final String codexExecutable;
  final String gitExecutable;
  final Map<String, String>? sessionEnvironment;
  final List<String> sessionArguments;
  final controllerToken = collaborationToken();
  final _starting = <String>{};
  final _errors = <String, String>{};
  final _closed = Completer<void>();
  Timer? _timer;
  bool _stopping = false;
  bool _ticking = false;
  int _requests = 0;
  Future<void> get done => _closed.future;
  Uri get endpoint => Uri.parse('http://127.0.0.1:${_server.port}');

  static Future<LocalCollaborationService> start({
    required Directory directory,
    required String codexExecutable,
    required String gitExecutable,
    Map<String, String>? sessionEnvironment,
    List<String> sessionArguments = const [],
    bool restore = true,
  }) async {
    await directory.create(recursive: true);
    final lock = await File(p.join(directory.path, 'service.lock'))
        .open(mode: FileMode.append);
    try {
      await lock.lock(FileLock.exclusive);
    } catch (_) {
      await lock.close();
      throw const CollaborationFailure(
        'The collaboration service is already running.',
      );
    }
    SqliteCollaborationStore? store;
    HttpServer? server;
    try {
      store = SqliteCollaborationStore(
        p.join(directory.path, 'collaboration.sqlite'),
      );
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.idleTimeout = const Duration(seconds: 30);
      final service = LocalCollaborationService._(
        directory,
        store,
        lock,
        server,
        codexExecutable,
        gitExecutable,
        sessionEnvironment,
        sessionArguments,
      );
      server.listen((request) => unawaited(service._handle(request)));
      final metadata = File(p.join(directory.path, 'service.json'));
      final temporary = File('${metadata.path}.tmp');
      await temporary.writeAsString(
        jsonEncode({
          'endpoint': '${service.endpoint}',
          'token': service.controllerToken,
          'pid': pid,
          'version': 1,
        }),
        flush: true,
      );
      await temporary.rename(metadata.path);
      service._timer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => unawaited(service._tick()),
      );
      if (restore) {
        for (final participant in store.participants().where(
          (row) => row['state'] == 'active',
        )) {
          unawaited(service._restore(participant['id'] as String));
        }
      }
      return service;
    } catch (_) {
      await server?.close(force: true);
      store?.close();
      await lock.close();
      rethrow;
    }
  }

  Future<void> _restore(String id) async {
    try {
      await connectParticipant(id);
    } catch (_) {
      /* Shown in snapshot. */
      return;
    }
  }

  ManagedCodexSession? session(String id) {
    final current = broker.sessions[id];
    return current is ManagedCodexSession ? current : null;
  }

  Future<void> connectParticipant(String id) async {
    if (_stopping || !_starting.add(id)) {
      throw const CollaborationFailure(
        'The participant is already connecting or the service is stopping.',
      );
    }
    try {
      final participant = store.participant(id);
      if (participant['state'] == 'completed') {
        throw const CollaborationFailure(
          'Completed participants cannot restart. Enroll a new participant.',
        );
      }
      final previous = session(id);
      if (previous?.connection.connected == true) {
        previous!.pauseDelivery(false);
        store.updateParticipant(id, {'state': 'active'});
        _errors.remove(id);
        return;
      }
      broker.sessions.remove(id);
      await previous?.close();
      final token = store.rotateToken(id);
      final managed = await ManagedCodexSession.start(
        participant: participant,
        executable: codexExecutable,
        mcpEndpoint: endpoint.resolve('/mcp'),
        mcpToken: token,
        onThread: (thread) => store.updateParticipant(id, {'thread': thread}),
        environment: sessionEnvironment,
        extraArguments: sessionArguments,
      );
      if (_stopping) {
        await managed.close();
        return;
      }
      broker.sessions[id] = managed;
      store.updateParticipant(id, {'state': 'active'});
      _errors.remove(id);
    } catch (_) {
      _errors[id] = 'Codex could not connect. Check the installed CLI, login, trusted project configuration and terminal. No uncertain input was retried.';
      rethrow;
    } finally {
      _starting.remove(id);
    }
  }

  Future<void> _tick() async {
    if (_stopping || _ticking) return;
    _ticking = true;
    try {
      await broker.pump();
      for (final entry in broker.sessions.entries.toList()) {
        if (_stopping) break;
        try {
          await entry.value.status();
        } catch (_) {
          _errors[entry.key] = 'Session disconnected. Reconnect to reconcile pending deliveries.';
        }
      }
    } catch (_) {
      for (final id in broker.sessions.keys) {
        _errors[id] = 'Delivery reconciliation is pending. No uncertain message was retried.';
      }
    } finally {
      _ticking = false;
    }
  }

  bool _equals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  Future<void> _handle(HttpRequest request) async {
    var admitted = false;
    try {
      final origin = request.headers.value('origin');
      if ((origin != null && origin != '$endpoint') ||
          request.headers.value('host') != endpoint.authority) {
        request.response.statusCode = HttpStatus.forbidden;
        return;
      }
      final auth = request.headers.value('authorization') ?? '';
      if (!auth.startsWith('Bearer ')) {
        request.response.statusCode = HttpStatus.unauthorized;
        return;
      }
      final token = auth.substring(7);
      final control = request.uri.path == '/control';
      final participant = control ? null : store.authenticate(token);
      if ((control && !_equals(token, controllerToken)) ||
          (!control && participant == null)) {
        request.response.statusCode = HttpStatus.unauthorized;
        return;
      }
      if (request.uri.path != '/control' && request.uri.path != '/mcp') {
        request.response.statusCode = HttpStatus.notFound;
        return;
      }
      if (request.method != 'POST') {
        request.response.statusCode = HttpStatus.methodNotAllowed;
        return;
      }
      if (_stopping || _requests >= 24) {
        request.response.statusCode = HttpStatus.serviceUnavailable;
        return;
      }
      _requests++;
      admitted = true;
      final bytes = <int>[];
      await for (final chunk in request.timeout(const Duration(seconds: 15))) {
        if (bytes.length + chunk.length > 128 * 1024) {
          request.response.statusCode = HttpStatus.requestEntityTooLarge;
          return;
        }
        bytes.addAll(chunk);
      }
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) throw const FormatException();
      final body = Map<String, Object?>.from(decoded);
      request.response.headers.contentType = ContentType.json;
      request.response.headers.set('Cache-Control', 'no-store');
      if (control) {
        try {
          final result = await controlCall(
            requiredText(body, 'operation', max: 80),
            Map<String, Object?>.from((body['arguments'] as Map?) ?? {}),
          );
          request.response.write(jsonEncode({'result': result}));
        } on CollaborationFailure catch (error) {
          request.response.write(jsonEncode({'error': error.message}));
        } catch (_) {
          request.response.write(
            jsonEncode({
              'error':
                  'The operation failed. Check session status before retrying.',
            }),
          );
        }
      } else {
        if (!body.containsKey('id')) {
          request.response.statusCode = HttpStatus.accepted;
          return;
        }
        final id = body['id'];
        try {
          final result = await _mcp(participant!, body);
          request.response.write(
            jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result}),
          );
        } on CollaborationFailure catch (error) {
          request.response.write(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': id,
              'error': {'code': -32602, 'message': error.message},
            }),
          );
        } catch (_) {
          request.response.write(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': id,
              'error': {
                'code': -32603,
                'message': 'Collaboration operation failed; retain your client_id before retrying.',
              },
            }),
          );
        }
      }
    } catch (_) {
      request.response.statusCode = HttpStatus.badRequest;
    } finally {
      if (admitted) _requests--;
      await request.response.close();
    }
  }

  Future<Json> _mcp(Json participant, Json body) async {
    final parameters = Map<String, Object?>.from(
      (body['params'] as Map?) ?? {},
    );
    switch (body['method']) {
      case 'initialize':
        final requested = parameters['protocolVersion'];
        return {
          'protocolVersion':
              {
                '2024-11-05',
                '2025-03-26',
                '2025-06-18',
                '2025-11-25',
              }.contains(requested)
              ? requested
              : '2025-06-18',
          'capabilities': {'tools': <String, Object?>{}},
          'serverInfo': {'name': 'tabryo_collaboration', 'version': '0.1.0'},
          'instructions': 'Share context only within this group and the user-authorized objective. Persisted receipts are not model acknowledgements.',
        };
      case 'ping':
        return {};
      case 'tools/list':
        return {'tools': collaborationTools};
      case 'tools/call':
        final name = requiredText(parameters, 'name', max: 80);
        final args = Map<String, Object?>.from(
          (parameters['arguments'] as Map?) ?? {},
        );
        try {
          final value = await toolCall(participant, name, args);
          return {
            'content': [
              {'type': 'text', 'text': jsonEncode(value)},
            ],
            'isError': false,
          };
        } on CollaborationFailure catch (error) {
          return {
            'content': [
              {'type': 'text', 'text': error.message},
            ],
            'isError': true,
          };
        }
      default:
        throw const CollaborationFailure('Unknown MCP method.');
    }
  }

  Future<Object?> toolCall(Json participant, String name, Json args) async {
    validateToolArguments(name, args);
    final group = participant['group_id'] as String;
    final id = participant['id'] as String;
    return switch (name) {
      'participants' => {
        'self': id,
        'participants': store.participants(group: group),
      },
      'messages' => store.messages(group, after: (args['after'] as int?) ?? 0),
      'send' => store.send(id, args),
      'acknowledge' => store.acknowledge(id, args['id'] as int),
      'publish_checkpoint' => store.checkpoint(id, {
        ...args,
        'source': await gitState(participant['root'] as String),
      }),
      'checkpoints' => store.checkpoints(
        group,
        author: args['author'] as String?,
        after: (args['after'] as int?) ?? 0,
      ),
      'checkpoint_detail' => store.checkpointDetail(group, args['id'] as int),
      _ => throw const CollaborationFailure('Unknown tool.'),
    };
  }

  Future<String?> _git(String root, List<String> args) async {
    try {
      final result = await Process.run(gitExecutable, [
        '-C',
        root,
        ...args,
      ]).timeout(const Duration(seconds: 10));
      return result.exitCode == 0 ? (result.stdout as String).trim() : null;
    } catch (_) {
      return null;
    }
  }

  Future<Json> gitState(String root) async {
    final head = await _git(root, ['rev-parse', 'HEAD']);
    final branch = await _git(root, ['branch', '--show-current']);
    final status = await _git(root, [
      'status',
      '--porcelain=v1',
      '--untracked-files=normal',
    ]);
    return {
      'root': root,
      'commit': head,
      'branch': branch,
      'local_changes': status?.isNotEmpty,
      'changes': status
          ?.split('\n')
          .where((s) => s.isNotEmpty)
          .take(200)
          .toList(),
      'changes_truncated': status != null && status.split('\n').length > 200,
      'captured_at': DateTime.now().toUtc().toIso8601String(),
      'validation_provenance': 'reported by participant',
    };
  }

  Future<Json> controlCall(String operation, Json args) async {
    switch (operation) {
      case 'snapshot':
        final group = args['group'] as String?;
        return {
          'capabilities': ['editor_context'],
          'groups': store.groups(),
          'participants': store
              .participants(group: group)
              .map(
                (row) => {
                  ...row,
                  if (session(row['id'] as String) case final managed?)
                    ...managed.snapshot,
                  'connecting': _starting.contains(row['id']),
                  'error':
                      _errors[row['id']] ??
                      session(row['id'] as String)?.lastError,
                },
              )
              .toList(),
          'messages': group == null
              ? <Json>[]
              : store.messages(group, after: (args['after'] as int?) ?? 0),
          'checkpoints': group == null
              ? <Json>[]
              : store.checkpoints(
                  group,
                  after: (args['checkpoint_after'] as int?) ?? 0,
                ),
        };
      case 'create_group':
        return store.createGroup(requiredText(args, 'name', max: 120));
      case 'send_editor_context':
        final id = requiredText(args, 'participant', max: 128);
        final participant = store.participant(id);
        final root = requiredText(args, 'workspace');
        final path = requiredText(args, 'path');
        if (participant['state'] != 'active' ||
            participant['thread'] != requiredText(args, 'thread', max: 128) ||
            !p.equals(participant['root'] as String, root) ||
            !p.isWithin(root, path)) {
          throw const CollaborationFailure(
            'The selected Codex session or editor workspace changed. Select it again.',
          );
        }
        // Only the authenticated native control plane can create this kind.
        // Persist before forwarding, using the same durable retry identity.
        final message = store.send(id, {
          'recipient': id,
          'client_id': requiredText(args, 'client_id', max: 128),
          'kind': 'editor_context',
          'summary': requiredText(args, 'text', max: 24000),
        });
        unawaited(broker.pumpParticipant(id));
        return {'id': message['id'], 'status': message['status']};
      case 'add_participant':
        final inputRoot = requiredText(args, 'root');
        if (!p.isAbsolute(inputRoot)) {
          throw const CollaborationFailure('Select an absolute project path.');
        }
        final root = await Directory(inputRoot).resolveSymbolicLinks();
        final common = await _git(root, [
          'rev-parse',
          '--path-format=absolute',
          '--git-common-dir',
        ]);
        var repository = common == null
            ? root
            : await Directory(common).resolveSymbolicLinks();
        if (Platform.isWindows) repository = repository.toLowerCase();
        final row = store.addParticipant({
          ...args,
          'root': root,
          'repository': repository,
        });
        return {...row}..remove('token');
      case 'connect':
        await connectParticipant(requiredText(args, 'id', max: 128));
        return {};
      case 'pause':
      case 'disconnect':
      case 'complete':
        final id = requiredText(args, 'id', max: 128);
        if (_starting.contains(id)) {
          throw const CollaborationFailure(
            'Wait for this participant to finish connecting.',
          );
        }
        if (store.participant(id)['state'] == 'completed') {
          if (operation == 'complete') return {};
          throw const CollaborationFailure(
            'Completed participants stay retired.',
          );
        }
        store.updateParticipant(id, {
          'state': operation == 'pause' ? 'paused' : 'disconnected',
        });
        final managed = session(id);
        managed?.pauseDelivery(true);
        if (operation == 'pause') {
          await managed?.interrupt();
        } else {
          await managed?.close();
          broker.sessions.remove(id);
          if (operation == 'complete') {
            store.updateParticipant(id, {'state': 'completed'});
          }
        }
        return {};
      case 'auto_wake':
        store.updateParticipant(requiredText(args, 'id', max: 128), {
          'auto_wake': args['enabled'] == true ? 1 : 0,
        });
        return {};
      case 'launch':
        final managed = session(requiredText(args, 'id', max: 128));
        if (managed == null || !managed.connection.connected) {
          throw const CollaborationFailure('Connect the participant first.');
        }
        return managed.launch;
      case 'external_terminal':
        final managed = session(requiredText(args, 'id', max: 128));
        if (managed == null || !managed.connection.connected) {
          throw const CollaborationFailure('Connect the participant first.');
        }
        if (!Platform.isWindows) {
          throw const CollaborationFailure(
            'External collaboration terminals are currently supported on Windows.',
          );
        }
        String literal(String value) => "'${value.replaceAll("'", "''")}'";
        final launch = managed.launch;
        // Every argument comes from our own endpoint/UUID/options. PowerShell
        // literals also quote executable and cwd; no peer text enters a shell.
        final arguments = windowsCollaborationArguments(
          (launch['arguments'] as List).cast<String>(),
        );
        final result = await Process.run(
          '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}\\System32\\WindowsPowerShell\\v1.0\\powershell.exe',
          [
            '-NoProfile',
            '-NonInteractive',
            '-Command',
            'Start-Process -FilePath ${literal(codexExecutable)} -WorkingDirectory ${literal(managed.participant['root'] as String)} -ArgumentList ${literal(arguments)} -WindowStyle Normal',
          ],
          environment: Map<String, String>.from(launch['environment'] as Map),
        );
        if (result.exitCode != 0) {
          throw const CollaborationFailure(
            'Could not open an external terminal. Use Open in Tabryo.',
          );
        }
        return {};
      case 'respond':
        final managed = session(requiredText(args, 'participant', max: 128));
        if (managed == null) {
          throw const CollaborationFailure('Participant disconnected.');
        }
        managed.respond(
          requiredText(args, 'request', max: 128),
          Map<String, Object?>.from(args['response'] as Map),
        );
        return {};
      case 'approval_detail':
        final managed = session(requiredText(args, 'participant', max: 128));
        if (managed == null) {
          throw const CollaborationFailure('Participant disconnected.');
        }
        return managed.approvalDetail(requiredText(args, 'request', max: 128));
      case 'checkpoint_detail':
        return store.checkpointDetail(
          requiredText(args, 'group', max: 128),
          args['id'] as int,
        );
      case 'stop':
        Timer(const Duration(milliseconds: 100), () => unawaited(close()));
        return {'stopping': true};
      default:
        throw const CollaborationFailure('Unknown control operation.');
    }
  }

  Future<void> _closeSessions() async {
    try {
      await broker.close();
    } catch (_) {
      // The process exits after done; its Windows job closes any remaining
      // owned children even if an individual transport could not close cleanly.
      return;
    }
  }

  Future<void> close() async {
    if (_stopping) return done;
    _stopping = true;
    _timer?.cancel();
    await _closeSessions();
    while (_starting.isNotEmpty || _ticking || _requests > 0) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await _server.close(force: true);
    store.close();
    final metadata = File(p.join(directory.path, 'service.json'));
    if (await metadata.exists()) await metadata.delete();
    await _lock.close();
    _closed.complete();
  }
}
