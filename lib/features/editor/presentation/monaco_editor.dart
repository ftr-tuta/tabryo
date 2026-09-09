import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';
import 'package:webview_win_floating/webview_win_floating.dart';

import '../domain/document_files.dart';
import '../domain/editor_assets.dart';
import 'editor_view_model.dart';
import '../../../core/cancellation.dart';
import '../../../core/web_surface_routes.dart';
import '../../language/domain/language_server.dart';
export '../../../core/web_surface_routes.dart' show editorRoutes;

final class EditorShortcutIntent extends Intent {
  const EditorShortcutIntent(this.command);
  final String command;
}

/// One web surface holds all models, so activity switches keep native undo state.
final class MonacoEditor extends StatefulWidget {
  const MonacoEditor({required this.model, required this.visible, super.key});
  final EditorViewModel model;
  final bool visible;
  @override
  State<MonacoEditor> createState() => MonacoEditorState();
}

final class MonacoEditorState extends State<MonacoEditor> with RouteAware {
  WinWebViewController? _browser;
  EditorPage? _page;
  ModalRoute<dynamic>? _route;
  bool _covered = false;
  bool _ready = false;
  bool _presented = false;
  bool _scheduled = false;
  int _syncRevision = 0;
  Future<void>? _synchronizing;
  String? _comparison;
  EditorBuffer? _comparisonDocument;
  String? _error;
  Timer? _loadTimeout;
  int _opening = 0;
  int _request = 0;
  final _documents = <EditorBuffer, _WebDocument>{};
  final _pending = <int, Completer<void>>{};
  final _languageRequests = <int, Cancellation>{};
  final _languageActions =
      <
        int,
        ({
          EditorBuffer buffer,
          int version,
          int revision,
          int authority,
          Map action,
        })
      >{};
  int _nextAction = 0;
  bool _reviewingLanguage = false;
  bool _promptingRename = false;
  final _commands = <({String command, EditorBuffer? buffer})>[];
  EditorViewModel get model => widget.model;
  bool get ready => _ready;
  bool get surfaceVisible =>
      _ready && _presented && widget.visible && !_covered;

  @override
  void initState() {
    super.initState();
    model.addListener(_schedule);
    model.synchronize = _flush;
    model.webCommand = _command;
    unawaited(_open());
  }

  Future<void> _open() async {
    final attempt = ++_opening;
    bool current() => mounted && attempt == _opening;
    _loadTimeout?.cancel();
    // Cover assets and native controller creation as well as page loading.
    _loadTimeout = Timer(const Duration(seconds: 20), () {
      if (current() && !_ready) _fail();
    });
    try {
      final page = await model.openWebEditor();
      if (!current()) return;
      _page = page;
      final browser = WinWebViewController(
        params: WindowsWebViewControllerCreationParams(
          userDataFolder: page.profileDirectory,
          profileName: 'TabryoEditor',
        ),
      );
      _browser = browser;
      await browser.setVisibility(false);
      if (!current()) return;
      await browser.setJavaScriptMode(JavaScriptMode.unrestricted);
      if (!current()) return;
      await browser.setNavigationDelegate(
        WinNavigationDelegate(
          onNavigationRequest: (request) =>
              request.isMainFrame &&
                  Uri.tryParse(request.url)?.replace(fragment: '') ==
                      page.uri.replace(fragment: '')
              ? NavigationDecision.navigate
              : NavigationDecision.prevent,
          onHttpError: (_) {
            if (current()) _fail();
          },
          onWebResourceError: (_) {
            if (current()) _fail();
          },
        ),
      );
      if (!current()) return;
      await browser.addJavaScriptChannel(
        'TabryoEditor',
        onMessageReceived: (event) {
          if (current()) _receive(event.message);
        },
      );
      if (!current()) {
        return;
      }
      setState(() {});
      await browser.loadRequest(page.uri);
    } catch (_) {
      if (current()) _fail();
    }
  }

  void _fail() {
    if (!mounted) return;
    _opening++;
    for (final cancellation in _languageRequests.values) {
      cancellation.cancel();
    }
    _languageRequests.clear();
    _languageActions.clear();
    _commands.clear();
    _loadTimeout?.cancel();
    setState(() {
      _ready = false;
      _presented = false;
      _error = 'The code editor could not load. Your document buffers are preserved.';
    });
    unawaited(_browser?.setVisibility(false));
  }

  Future<void> _retry() async {
    final browser = _browser;
    setState(() {
      _browser = null;
      _error = null;
      _ready = false;
      _presented = false;
      _documents.clear();
      _comparison = null;
      _comparisonDocument = null;
    });
    await WidgetsBinding.instance.endOfFrame;
    try {
      await browser?.dispose().timeout(const Duration(seconds: 5));
    } catch (_) {
      // Disposal still completes if native initialization eventually returns.
      // A stopped native surface must not prevent a new connection attempt.
      if (!mounted) return;
    }
    if (mounted) await _open();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (_route != route) {
      editorRoutes.unsubscribe(this);
      _route = route;
      if (route != null) editorRoutes.subscribe(this, route);
    }
    _schedule();
  }

  @override
  void didUpdateWidget(MonacoEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    _schedule();
  }

  @override
  void didPushNext() {
    _covered = true;
    _presented = false;
    unawaited(_browser?.setVisibility(false));
  }

  @override
  void didPopNext() {
    // Native surfaces must wait for the covering route's reverse transition
    // and focus restoration, not just Navigator.pop's early notification.
    unawaited(
      editorRoutes.settled.then((_) {
        if (!mounted) return;
        _covered = _route?.isCurrent != true;
        _schedule();
      }),
    );
  }

  void _schedule() {
    _syncRevision++;
    // Retire the old generation synchronously. A browser state packet already
    // in flight must not overwrite a host edit before the next Flutter frame.
    for (final entry in _documents.entries) {
      _captureHostText(entry.key, entry.value);
    }
    if (_scheduled || !mounted) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted) unawaited(_sync());
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _captureHostText(EditorBuffer buffer, _WebDocument doc) {
    if (doc.text == buffer.controller.text) return;
    doc.expectedSequence ??= doc.sequence;
    doc.text = buffer.controller.text;
    doc.generation++;
    doc.sequence = 0;
  }

  Future<void> _send(Map<String, Object?> packet) async {
    if (!_ready || _page == null || _browser == null) {
      throw const DocumentFailure('The code editor is not connected.');
    }
    await _browser!.runJavaScript(
      'window.tabryoReceive(${jsonEncode({'token': _page!.token, ...packet})})',
    );
  }

  Future<void> _sync() async {
    while (_synchronizing != null) {
      await _synchronizing;
    }
    if (!_ready) return;
    final operation = _syncDocuments();
    _synchronizing = operation;
    try {
      await operation;
    } finally {
      _synchronizing = null;
    }
  }

  Future<void> _syncDocuments() async {
    final revision = _syncRevision;
    try {
      _languageActions.removeWhere(
        (_, action) =>
            !model.buffers.contains(action.buffer) ||
            action.revision != model.languageRevision ||
            action.authority != model.language?.generation,
      );
      _documents.removeWhere((buffer, _) => !model.buffers.contains(buffer));
      final documents = <Map<String, Object?>>[];
      for (final buffer in model.buffers) {
        final doc = _documents.putIfAbsent(
          buffer,
          () => _WebDocument('document-${++_request}', buffer.controller.text),
        );
        _captureHostText(buffer, doc);
        documents.add({
          'id': doc.id,
          'generation': doc.generation,
          if (doc.expectedSequence != null)
            'expectedSequence': doc.expectedSequence,
          'text': doc.text,
          'start': buffer.controller.selection.baseOffset.clamp(
            0,
            doc.text.length,
          ),
          'end': buffer.controller.selection.extentOffset.clamp(
            0,
            doc.text.length,
          ),
          // Nested workspaces may open the same file with different buffers.
          'uri': Uri.file(buffer.path)
              .replace(queryParameters: {'tabryo': doc.id})
              .toString(),
          'language': switch (p.extension(buffer.path).toLowerCase()) {
            '.dart' => 'dart',
            '.py' => 'python',
            '.c' ||
            '.cc' ||
            '.cpp' ||
            '.cxx' ||
            '.h' ||
            '.hh' ||
            '.hpp' ||
            '.hxx' ||
            '.inl' => 'cpp',
            '.cs' => 'csharp',
            '.uproject' || '.uplugin' => 'json',
            '.yaml' || '.yml' => 'yaml',
            '.md' => 'markdown',
            '.toml' || '.ini' => 'ini',
            '.json' => 'json',
            _ => 'plaintext',
          },
          'sourceUri': Uri.file(buffer.path).toString(),
          'languageEnabled':
              model.language?.sessions.values.any(
                (s) => s.ready && s.contains(buffer.root, buffer.path),
              ) ??
              false,
          'diagnostics': [
            for (final problem
                in model.language?.problems ?? <LanguageProblem>[])
              if (p.equals(problem.workspace, buffer.root) &&
                  p.equals(problem.path, buffer.path))
                problem.diagnostic,
          ],
          'readOnly': buffer.saving || buffer.readOnly,
          'newline': buffer.baseline.newline,
          'bom': buffer.baseline.bom,
        });
      }
      await _send({
        'type': 'sync',
        'documents': documents,
        'active': _documents[model.active]?.id,
        'dark': Theme.of(context).brightness == Brightness.dark,
      });
      if (_comparison != model.active?.diskText ||
          _comparisonDocument != model.active) {
        _comparisonDocument = model.active;
        _comparison = model.active?.diskText;
        await _send(
          _comparison == null
              ? {'type': 'command', 'command': 'closeDiff'}
              : {'type': 'compare', 'text': _comparison},
        );
      }
      final visible = _ready && widget.visible && !_covered;
      if (visible != _presented) await _browser?.setVisibility(visible);
      if (visible && !_presented) {
        await _browser?.requestFocus();
        await _send({'type': 'command', 'command': 'focus'});
      }
      _presented = visible;
      if (visible && !_covered) {
        while (_commands.isNotEmpty) {
          // A save, tab change or host edit may finish while this snapshot is
          // crossing the bridge. Deliver the next snapshot before its command.
          if (revision != _syncRevision) return;
          final queued = _commands.removeAt(0);
          if (!identical(queued.buffer, model.active)) continue;
          final command = queued.command;
          await _send({
            'type': 'command',
            'command': command,
            if (command == 'reveal')
              'start': model.active?.controller.selection.extentOffset,
          });
        }
      }
    } catch (_) {
      _fail();
    }
  }

  void _receive(String raw) {
    if (!mounted || raw.length > 4 * 1024 * 1024) return;
    try {
      final value = jsonDecode(raw);
      if (value is! Map<String, dynamic> || value['token'] != _page?.token) {
        return;
      }
      final type = value['type'];
      if (type == 'ready') {
        _loadTimeout?.cancel();
        setState(() {
          _ready = true;
          _error = null;
        });
        _schedule();
        return;
      }
      if (type == 'failed') {
        _fail();
        return;
      }
      if (type == 'workbench') {
        final command = value['command'];
        if (command is String &&
            ['palette', 'open', 'nextTab', 'previousTab'].contains(command)) {
          Actions.maybeInvoke(context, EditorShortcutIntent(command));
        }
        return;
      }
      final entry = _documents.entries
          .where((entry) => entry.value.id == value['id'])
          .firstOrNull;
      if (entry == null || !model.buffers.contains(entry.key)) return;
      final buffer = entry.key;
      final doc = entry.value;
      if (type == 'languageCancel') {
        _languageRequests[value['request']]?.cancel();
        return;
      }
      if (type == 'language') {
        if (value['request'] is int &&
            value['method'] is String &&
            value['params'] is Map &&
            value['generation'] == doc.generation &&
            value['sequence'] == doc.sequence &&
            _languageRequests.length < 32) {
          unawaited(
            _languageRequest(
              buffer,
              value['request'] as int,
              value['method'] as String,
              Map<String, Object?>.from(value['params'] as Map),
            ),
          );
        }
        return;
      }
      if (type == 'languageReview') {
        final action = _languageActions.remove(value['action']);
        if (action != null && identical(action.buffer, buffer)) {
          unawaited(
            _resolveLanguageAction(
              buffer,
              action.version,
              action.action,
              action.revision,
              action.authority,
            ),
          );
        }
        return;
      }
      if (type == 'languageRename' && value['position'] is Map) {
        unawaited(_promptRename(buffer, value['position'] as Map));
        return;
      }
      if (type == 'languageNavigate') {
        if (value['uri'] is String && value['position'] is Map) {
          unawaited(
            model
                .navigateLanguage(
                  buffer,
                  value['uri'] as String,
                  value['position'] as Map,
                )
                .catchError((Object error) => _languageError(error)),
          );
        }
        return;
      }
      if (type == 'rejected') {
        model.rejectInput(buffer);
        return;
      }
      if (type == 'save') {
        unawaited(model.save(buffer));
        return;
      }
      if (![
            'change',
            'selection',
            'state',
            'flushed',
            'superseded',
          ].contains(type) ||
          value['generation'] != doc.generation ||
          value['sequence'] is! int ||
          (value['sequence'] as int) < doc.sequence ||
          value['text'] is! String) {
        return;
      }
      final text = value['text'] as String;
      if (buffer.readOnly && text != buffer.controller.text) {
        doc.generation++;
        doc.sequence = 0;
        _schedule();
        return;
      }
      if (utf8.encode(text.replaceAll('\n', buffer.baseline.newline)).length +
                  (buffer.baseline.bom ? 3 : 0) >
              DocumentFiles.byteLimit ||
          text.contains('\u0000') ||
          text.contains('\r')) {
        model.rejectInput(buffer);
        doc.generation++;
        doc.sequence = 0;
        _schedule();
        return;
      }
      final start = value['start'];
      final end = value['end'];
      if (start is! int ||
          end is! int ||
          start < 0 ||
          end < 0 ||
          start > text.length ||
          end > text.length) {
        return;
      }
      doc.text = text;
      doc.sequence = value['sequence'] as int;
      doc.expectedSequence = null;
      model.applyWebEdit(
        buffer,
        text,
        start,
        end,
        value['canUndo'] == true,
        value['canRedo'] == true,
      );
      if (type == 'superseded') model.replacementSuperseded(buffer);
      if (type == 'flushed') _pending.remove(value['request'])?.complete();
    } on FormatException {
      /* Untrusted malformed browser messages are ignored. */
      return;
    }
  }

  void _languageError(Object error) {
    if (mounted && error is! Cancelled) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  Future<void> _promptRename(EditorBuffer buffer, Map position) async {
    if (_promptingRename || _reviewingLanguage) return;
    _promptingRename = true;
    final version = buffer.version;
    final revision = model.languageRevision;
    final authority = model.language?.generation ?? 0;
    try {
      languageOffset(buffer.controller.text, position);
      var name = '';
      final chosen = await showDialog<String>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, update) => AlertDialog(
            title: const Text('Rename symbol'),
            content: SizedBox(
              width: 400,
              child: TextField(
                autofocus: true,
                decoration: const InputDecoration(labelText: 'New symbol name'),
                onChanged: (value) => update(() => name = value.trim()),
                onSubmitted: (_) {
                  if (name.isNotEmpty) Navigator.pop(context, name);
                },
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: name.isEmpty
                    ? null
                    : () => Navigator.pop(context, name),
                child: const Text('Review rename'),
              ),
            ],
          ),
        ),
      );
      if (chosen == null || !mounted) return;
      if (version != buffer.version ||
          revision != model.languageRevision ||
          authority != model.language?.generation) {
        throw const Cancelled();
      }
      final result = await model.languageRequest(
        buffer,
        'textDocument/rename',
        {'position': Map<String, Object?>.from(position), 'newName': chosen},
      );
      if (result is Map && mounted) {
        await _reviewLanguageEdit(buffer, version, result, revision, authority);
      }
    } catch (error) {
      _languageError(error);
    } finally {
      _promptingRename = false;
    }
  }

  Future<void> _reviewLanguageEdit(
    EditorBuffer buffer,
    int version,
    Map edit,
    int revision,
    int authority,
  ) async {
    if (_reviewingLanguage || !mounted) return;
    _reviewingLanguage = true;
    try {
      if (authority != model.language?.generation) throw const Cancelled();
      final changes = await model.prepareLanguageEdit(
        buffer,
        edit,
        version: version,
        revision: revision,
      );
      if (!mounted) return;
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Review proposed edits'),
          content: SizedBox(
            width: 850,
            height: 420,
            child: ListView(
              children: [
                const Text(
                  'Apply to unsaved editor buffers. Save each document to write it to disk. Expand every file to compare the complete text.',
                ),
                for (final change in changes)
                  ExpansionTile(
                    title: Text(change.buffer.path),
                    children: [
                      const Text('Before'),
                      SelectableText(change.before),
                      const Divider(),
                      const Text('After'),
                      SelectableText(change.after),
                    ],
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Apply unsaved edits'),
            ),
          ],
        ),
      );
      if (accepted == true && mounted) {
        if (authority != model.language?.generation) throw const Cancelled();
        await model.applyReviewedLanguageEdit(changes);
      }
    } catch (error) {
      _languageError(error);
    } finally {
      _reviewingLanguage = false;
    }
  }

  Future<void> _resolveLanguageAction(
    EditorBuffer buffer,
    int version,
    Map action,
    int revision,
    int authority,
  ) async {
    try {
      if (buffer.version != version ||
          revision != model.languageRevision ||
          authority != model.language?.generation) {
        throw const Cancelled();
      }
      final resolved = action['edit'] is Map
          ? action
          : await model.languageRequest(
              buffer,
              'codeAction/resolve',
              Map<String, Object?>.from(action),
              lint: true,
            );
      if (resolved is! Map ||
          resolved['edit'] is! Map ||
          resolved['command'] != null) {
        throw const LanguageFailure(
          'This action needs a server command that is not supported by the editor review.',
        );
      }
      await _reviewLanguageEdit(
        buffer,
        version,
        resolved['edit'] as Map,
        revision,
        authority,
      );
    } catch (error) {
      _languageError(error);
    }
  }

  Future<void> _languageRequest(
    EditorBuffer buffer,
    int request,
    String method,
    Map<String, Object?> params,
  ) async {
    if (_languageRequests.containsKey(request)) return;
    final cancellation = Cancellation();
    _languageRequests[request] = cancellation;
    final opening = _opening;
    final version = buffer.version;
    final revision = model.languageRevision;
    final authority = model.language?.generation ?? 0;
    Object? result;
    try {
      if (params['position'] case final Map position) {
        languageOffset(buffer.controller.text, position);
      }
      if (method == 'textDocument/codeAction') {
        params['context'] = {
          'diagnostics': [
            for (final problem
                in model.language?.problems ?? <LanguageProblem>[])
              if (problem.workspace == buffer.root &&
                  problem.path == buffer.path &&
                  !problem.server.startsWith('pyright:'))
                problem.diagnostic,
          ],
          'only': ['quickfix', 'refactor', 'source.organizeImports'],
        };
      }
      result = await model.languageRequest(
        buffer,
        method,
        params,
        cancellation: cancellation,
        lint: method == 'textDocument/codeAction',
      );
      if (!mounted || opening != _opening || cancellation.isCancelled) return;
      if (method == 'textDocument/rename' && result is Map) {
        await _reviewLanguageEdit(buffer, version, result, revision, authority);
        result = null;
      } else if (method == 'textDocument/codeAction') {
        _languageActions.clear();
        final actions = <Map<String, Object?>>[];
        for (final item in (result is List ? result : []).take(20)) {
          if (item is! Map ||
              (item['edit'] is! Map && item['data'] == null) ||
              item['title'] is! String ||
              item['disabled'] != null) {
            continue;
          }
          while (_languageActions.length >= 20) {
            _languageActions.remove(_languageActions.keys.first);
          }
          final id = ++_nextAction;
          _languageActions[id] = (
            buffer: buffer,
            version: version,
            revision: revision,
            authority: authority,
            action: item,
          );
          actions.add({'id': id, 'title': item['title'], 'kind': item['kind']});
        }
        result = actions;
      } else if (method == 'textDocument/references' &&
          result is List &&
          result.isNotEmpty) {
        final selected = await showDialog<Map>(
          context: context,
          builder: (context) => SimpleDialog(
            title: const Text('Project references'),
            children: [
              for (final location in (result as List).take(200))
                if (location is Map &&
                    location['uri'] is String &&
                    location['range'] is Map)
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(context, location),
                    child: Text(
                      '${location['uri']} · ${((location['range'] as Map)['start'] as Map)['line'] + 1}',
                    ),
                  ),
            ],
          ),
        );
        if (selected != null && mounted) {
          await model.navigateLanguage(
            buffer,
            selected['uri'] as String,
            (selected['range'] as Map)['start'] as Map,
          );
        }
        result = null;
      }
    } catch (error) {
      _languageError(error);
      result = null;
    } finally {
      if (identical(_languageRequests[request], cancellation)) {
        _languageRequests.remove(request);
      }
      if (mounted && _ready && opening == _opening) {
        try {
          await _send({
            'type': 'languageResult',
            'request': request,
            'result': result,
          });
        } catch (_) {
          /* Reconnection owns the next provider request. */
        }
      }
    }
  }

  Future<void> _flush(EditorBuffer buffer) async {
    if (!_ready) throw const DocumentFailure('The code editor is not ready.');
    // A save must acknowledge pending host replacements before it reads back
    // the browser, otherwise a queued format/reload can revert to old text.
    await _sync();
    final doc = _documents[buffer];
    if (doc == null) {
      throw const DocumentFailure('The document is not connected.');
    }
    final request = ++_request;
    final completion = Completer<void>();
    _pending[request] = completion;
    try {
      await _send({'type': 'flush', 'id': doc.id, 'request': request});
      await completion.future.timeout(const Duration(seconds: 5));
    } finally {
      _pending.remove(request);
    }
  }

  void _command(String command) {
    if (!_ready) return;
    if (command == 'extractVariable' || command == 'extractMethod') {
      unawaited(
        _extract(
          command == 'extractVariable'
              ? DartRefactor.extractVariable
              : DartRefactor.extractMethod,
        ),
      );
      return;
    }
    if (_commands.length >= 32) {
      _languageError(
        const LanguageFailure('Wait for the pending editor actions to finish.'),
      );
      return;
    }
    _commands.add((command: command, buffer: model.active));
    _schedule();
  }

  Future<void> _extract(DartRefactor kind) async {
    final buffer = model.active;
    if (_promptingRename ||
        _reviewingLanguage ||
        buffer == null ||
        buffer.readOnly) {
      return;
    }
    _promptingRename = true;
    try {
      if (!await model.synchronizeBuffer(buffer)) throw const Cancelled();
      final version = buffer.version;
      final revision = model.languageRevision;
      final authority = model.language?.generation ?? 0;
      final selection = buffer.controller.selection;
      if (!selection.isValid || selection.isCollapsed) {
        throw const LanguageFailure(
          'Select the expression or statements to extract.',
        );
      }
      if (!mounted) return;
      var name = '';
      final chosen = await showDialog<String>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, update) => AlertDialog(
            title: Text(
              kind == DartRefactor.extractVariable
                  ? 'Extract Dart variable'
                  : 'Extract Dart method / getter',
            ),
            content: TextField(
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Extracted symbol name',
              ),
              onChanged: (value) => update(() => name = value.trim()),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: name.isEmpty
                    ? null
                    : () => Navigator.pop(context, name),
                child: const Text('Review extraction'),
              ),
            ],
          ),
        ),
      );
      if (chosen == null || !mounted) return;
      if (buffer.version != version ||
          model.languageRevision != revision ||
          model.language?.generation != authority) {
        throw const Cancelled();
      }
      model.synchronizeLanguage();
      final edit = await model.language!.refactor(
        model.languageDocument(buffer),
        kind,
        chosen,
        selection.start,
        selection.end,
      );
      await _reviewLanguageEdit(buffer, version, edit, revision, authority);
    } catch (error) {
      _languageError(error);
    } finally {
      _promptingRename = false;
    }
  }

  @override
  void dispose() {
    _opening++;
    _loadTimeout?.cancel();
    editorRoutes.unsubscribe(this);
    model.removeListener(_schedule);
    model.synchronize = null;
    model.webCommand = null;
    for (final pending in _pending.values) {
      pending.completeError(
        const DocumentFailure('The code editor was closed.'),
      );
    }
    _pending.clear();
    for (final cancellation in _languageRequests.values) {
      cancellation.cancel();
    }
    _languageActions.clear();
    unawaited(_browser?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      if (_browser != null)
        Positioned.fill(child: WinWebViewWidget(controller: _browser!)),
      if (!_ready)
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error ?? 'Loading code editor…'),
              if (_error != null)
                TextButton(
                  onPressed: _retry,
                  child: const Text('Reconnect editor'),
                ),
            ],
          ),
        ),
    ],
  );
}

final class _WebDocument {
  _WebDocument(this.id, this.text);
  final String id;
  String text;
  int generation = 1;
  int sequence = 0;
  int? expectedSequence;
}
