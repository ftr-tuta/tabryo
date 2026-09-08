import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';
import 'package:webview_win_floating/webview_win_floating.dart';

import '../domain/document_files.dart';
import '../domain/editor_assets.dart';
import 'editor_view_model.dart';

final editorRoutes = RouteObserver<ModalRoute<dynamic>>();

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
  bool _sending = false;
  bool _sendAgain = false;
  String? _comparison;
  EditorBuffer? _comparisonDocument;
  String? _error;
  Timer? _loadTimeout;
  int _request = 0;
  final _documents = <EditorBuffer, _WebDocument>{};
  final _pending = <int, Completer<void>>{};
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
    try {
      final page = await model.openWebEditor();
      if (!mounted) return;
      _page = page;
      final browser = WinWebViewController(
        params: WindowsWebViewControllerCreationParams(
          userDataFolder: page.profileDirectory,
        ),
      );
      _browser = browser;
      await browser.setVisibility(false);
      await browser.setJavaScriptMode(JavaScriptMode.unrestricted);
      await browser.setNavigationDelegate(
        WinNavigationDelegate(
          onNavigationRequest: (request) =>
              request.isMainFrame &&
                  Uri.tryParse(request.url)?.replace(fragment: '') ==
                      page.uri.replace(fragment: '')
              ? NavigationDecision.navigate
              : NavigationDecision.prevent,
          onHttpError: (_) => _fail(),
          onWebResourceError: (_) => _fail(),
        ),
      );
      await browser.addJavaScriptChannel(
        'TabryoEditor',
        onMessageReceived: (event) => _receive(event.message),
      );
      if (!mounted) {
        return;
      }
      setState(() {});
      _loadTimeout?.cancel();
      _loadTimeout = Timer(const Duration(seconds: 20), () {
        if (!_ready) _fail();
      });
      await browser.loadRequest(page.uri);
    } catch (_) {
      _fail();
    }
  }

  void _fail() {
    if (!mounted) return;
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
    await browser?.dispose();
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
    _covered = false;
    _schedule();
  }

  void _schedule() {
    if (_scheduled || !mounted) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted) unawaited(_sync());
    });
    WidgetsBinding.instance.ensureVisualUpdate();
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
    if (!_ready) return;
    if (_sending) {
      _sendAgain = true;
      return;
    }
    _sending = true;
    try {
      _documents.removeWhere((buffer, _) => !model.buffers.contains(buffer));
      final documents = <Map<String, Object?>>[];
      for (final buffer in model.buffers) {
        final doc = _documents.putIfAbsent(
          buffer,
          () => _WebDocument('document-${++_request}', buffer.controller.text),
        );
        if (doc.text != buffer.controller.text) {
          doc.text = buffer.controller.text;
          doc.generation++;
          doc.sequence = 0;
        }
        documents.add({
          'id': doc.id,
          'generation': doc.generation,
          'text': doc.text,
          // Nested workspaces may open the same file with different buffers.
          'uri': Uri.file(buffer.path)
              .replace(queryParameters: {'tabryo': doc.id})
              .toString(),
          'language': switch (p.extension(buffer.path).toLowerCase()) {
            '.dart' => 'dart',
            '.py' => 'python',
            '.yaml' || '.yml' => 'yaml',
            '.md' => 'markdown',
            '.toml' || '.ini' => 'ini',
            '.json' => 'json',
            _ => 'plaintext',
          },
          'readOnly': buffer.saving,
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
      await _browser?.setVisibility(visible);
      if (visible && !_presented) {
        await _browser?.requestFocus();
        await _send({'type': 'command', 'command': 'focus'});
      }
      _presented = visible;
    } catch (_) {
      _fail();
    } finally {
      _sending = false;
      if (_sendAgain) {
        _sendAgain = false;
        _schedule();
      }
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
      if (type == 'rejected') {
        model.rejectInput(buffer);
        return;
      }
      if (type == 'save') {
        unawaited(model.save(buffer));
        return;
      }
      if (!['change', 'selection', 'state', 'flushed'].contains(type) ||
          value['generation'] != doc.generation ||
          value['sequence'] is! int ||
          (value['sequence'] as int) < doc.sequence ||
          value['text'] is! String) {
        return;
      }
      final text = value['text'] as String;
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
      model.applyWebEdit(
        buffer,
        text,
        start,
        end,
        value['canUndo'] == true,
        value['canRedo'] == true,
      );
      if (type == 'flushed') _pending.remove(value['request'])?.complete();
    } on FormatException {
      /* Untrusted malformed browser messages are ignored. */
      return;
    }
  }

  Future<void> _flush(EditorBuffer buffer) async {
    if (!_ready) throw const DocumentFailure('The code editor is not ready.');
    if (!_documents.containsKey(buffer)) await _sync();
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
    if (_ready) {
      unawaited(
        _send({'type': 'command', 'command': command})
            .catchError((_) => _fail()),
      );
    }
  }

  @override
  void dispose() {
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
}
