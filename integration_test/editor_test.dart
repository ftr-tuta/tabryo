import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';
import 'package:path/path.dart' as p;
import 'package:tabryo/core/preview_cache.dart';
import 'package:tabryo/features/debugger/application/debug_service.dart';
import 'package:tabryo/features/debugger/domain/debug_session.dart';
import 'package:tabryo/features/debugger/infrastructure/dap_connection.dart';
import 'package:tabryo/features/debugger/presentation/devtools_pane.dart';
import 'package:tabryo/features/projects/domain/project.dart';
import 'package:tabryo/features/editor/infrastructure/bundled_editor_assets.dart';
import 'package:tabryo/features/editor/infrastructure/local_document_files.dart';
import 'package:tabryo/features/editor/infrastructure/local_dart_formatter.dart';
import 'package:tabryo/features/editor/presentation/editor_pane.dart';
import 'package:tabryo/features/editor/presentation/editor_view_model.dart';
import 'package:tabryo/features/editor/presentation/monaco_editor.dart';
import 'package:tabryo/features/git/domain/git_ports.dart';
import 'package:tabryo/features/git/infrastructure/local_git.dart';
import 'package:tabryo/features/git/presentation/git_review_view_model.dart';
import 'package:tabryo/features/preferences/domain/appearance.dart';
import 'package:tabryo/features/preferences/presentation/workbench_theme.dart';
import 'package:tabryo/features/editor_context/application/editor_context_service.dart';
import 'package:tabryo/features/editor_context/infrastructure/local_editor_context.dart';
import 'package:tabryo/features/language/application/language_service.dart';
import 'package:tabryo/features/language/domain/language_server.dart';
import 'package:tabryo/features/language/infrastructure/lsp_connection.dart';
import 'package:tabryo/features/language/infrastructure/local_language_sources.dart';
import 'package:webview_win_floating/webview_win_floating.dart';

void controlKey(int key) {
  final user32 = DynamicLibrary.open('user32.dll');
  final foreground = user32.lookupFunction<IntPtr Function(), int Function()>(
    'GetForegroundWindow',
  );
  final owner = user32
      .lookupFunction<
        Uint32 Function(IntPtr, Pointer<Uint32>),
        int Function(int, Pointer<Uint32>)
      >('GetWindowThreadProcessId');
  final send = user32
      .lookupFunction<
        Uint32 Function(Uint32, Pointer<Uint8>, Int32),
        int Function(int, Pointer<Uint8>, int)
      >('SendInput');
  final process = calloc<Uint32>();
  final inputs = calloc<Uint8>(
    4 * 40,
  ); // INPUT ABI on the supported Windows x64 host.
  try {
    owner(foreground(), process);
    expect(process.value, pid, reason: 'Never type into another process.');
    final data = inputs.asTypedList(4 * 40).buffer.asByteData();
    for (final (index, event) in [
      (0x11, 0),
      (key, 0),
      (key, 2),
      (0x11, 2),
    ].indexed) {
      data.setUint32(index * 40, 1, Endian.little);
      data.setUint16(index * 40 + 8, event.$1, Endian.little);
      data.setUint32(index * 40 + 12, event.$2, Endian.little);
    }
    expect(send(4, inputs, 40), 4);
  } finally {
    calloc.free(inputs);
    calloc.free(process);
  }
}

int focusTestWindow({bool ownedMainOnly = false}) {
  final user32 = DynamicLibrary.open('user32.dll');
  final find = user32
      .lookupFunction<
        IntPtr Function(IntPtr, IntPtr, Pointer<Utf16>, Pointer<Utf16>),
        int Function(int, int, Pointer<Utf16>, Pointer<Utf16>)
      >('FindWindowExW');
  final owner = user32
      .lookupFunction<
        Uint32 Function(IntPtr, Pointer<Uint32>),
        int Function(int, Pointer<Uint32>)
      >('GetWindowThreadProcessId');
  final show = user32
      .lookupFunction<Int32 Function(IntPtr, Int32), int Function(int, int)>(
        'ShowWindow',
      );
  final foreground = user32
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
        'SetForegroundWindow',
      );
  final current = DynamicLibrary.open('kernel32.dll')
      .lookupFunction<Uint32 Function(), int Function()>('GetCurrentThreadId');
  final active = user32.lookupFunction<IntPtr Function(), int Function()>(
    'GetForegroundWindow',
  );
  final attach = user32
      .lookupFunction<
        Int32 Function(Uint32, Uint32, Int32),
        int Function(int, int, int)
      >('AttachThreadInput');
  final process = calloc<Uint32>();
  final className = calloc<Uint16>(256);
  final getClass = user32
      .lookupFunction<
        Int32 Function(IntPtr, Pointer<Uint16>, Int32),
        int Function(int, Pointer<Uint16>, int)
      >('GetClassNameW');
  try {
    var window = 0;
    while ((window = find(0, window, nullptr, nullptr)) != 0) {
      owner(window, process);
      if (process.value != pid) continue;
      if (ownedMainOnly) {
        final length = getClass(window, className, 256);
        if (String.fromCharCodes(className.asTypedList(length)) ==
            'FLUTTER_RUNNER_WIN32_WINDOW') {
          return window;
        }
        continue;
      }
      show(window, 9);
      if (foreground(window) != 0) return window;
      final activeThread = owner(active(), process);
      final attached = attach(current(), activeThread, 1) != 0;
      try {
        if (foreground(window) != 0) return window;
      } finally {
        if (attached) attach(current(), activeThread, 0);
      }
    }
    fail('The owned native test window was unavailable.');
  } finally {
    calloc.free(process);
    calloc.free(className);
  }
}

Future<void> clickNativeSurface(WidgetTester tester, Offset position) async {
  final point = tester.getTopLeft(find.byType(WinWebViewWidget)) + position;
  final ratio = tester.view.devicePixelRatio;
  if (Platform.isWindows) {
    final window = focusTestWindow(ownedMainOnly: true);
    final user32 = DynamicLibrary.open('user32.dll');
    final childAt = user32
        .lookupFunction<
          IntPtr Function(IntPtr, Int64, Uint32),
          int Function(int, int, int)
        >('ChildWindowFromPointEx');
    final map = user32
        .lookupFunction<
          Int32 Function(IntPtr, IntPtr, Pointer<Int32>, Uint32),
          int Function(int, int, Pointer<Int32>, int)
        >('MapWindowPoints');
    final ancestor = user32
        .lookupFunction<
          IntPtr Function(IntPtr, Uint32),
          int Function(int, int)
        >('GetAncestor');
    final send = user32
        .lookupFunction<
          Int32 Function(IntPtr, Uint32, UintPtr, IntPtr),
          int Function(int, int, int, int)
        >('PostMessageW');
    final coordinates = calloc<Int32>(2);
    try {
      coordinates[0] = (point.dx * ratio).round();
      coordinates[1] = (point.dy * ratio).round();
      var target = window;
      for (var depth = 0; depth < 16; depth++) {
        final child = childAt(
          target,
          (coordinates[1] << 32) | (coordinates[0] & 0xffffffff),
          7,
        );
        if (child == 0 || child == target) break;
        map(target, child, coordinates, 1);
        target = child;
      }
      expect(
        target,
        isNot(window),
        reason: 'The native browser must be visible at the requested point.',
      );
      expect(ancestor(target, 2), window);
      final at = ((coordinates[1] & 0xffff) << 16) | (coordinates[0] & 0xffff);
      expect(send(target, 0x0200, 0, at), 1);
      expect(send(target, 0x0201, 1, at), 1);
      expect(send(target, 0x0202, 0, at), 1);
      await tester.pump(const Duration(milliseconds: 100));
    } finally {
      calloc.free(coordinates);
    }
  } else {
    final windows = await Process.run('xdotool', [
      'search',
      '--onlyvisible',
      '--pid',
      '$pid',
    ]);
    expect(windows.exitCode, 0);
    final window = '${windows.stdout}'.trim().split('\n').first;
    final clicked = await Process.run('xdotool', [
      'windowfocus',
      '--sync',
      window,
      'mousemove',
      '--window',
      window,
      '${(point.dx * ratio).round()}',
      '${(point.dy * ratio).round()}',
      'click',
      '1',
    ]);
    expect(clicked.exitCode, 0);
  }
}

Future<void> until(WidgetTester tester, bool Function() condition) async {
  for (var attempt = 0; attempt < 300; attempt++) {
    if (condition()) return;
    await tester.pump(const Duration(milliseconds: 100));
  }
  fail('Native editor did not reach the expected state.');
}

Future<void> expectWeb(
  WidgetTester tester,
  WinWebViewController browser,
  String expression,
  Object expected, {
  int attempts = 50,
}) async {
  Object? value;
  for (var attempt = 0; attempt < attempts; attempt++) {
    value = await browser.runJavaScriptReturningResult(expression);
    if (value == expected) return;
    await tester.pump(const Duration(milliseconds: 100));
  }
  final details = await browser.runJavaScriptReturningResult("""
    JSON.stringify({focus: document.activeElement?.className,
      page: document.body?.innerText.slice(0, 1000).replace(/https?:[^ ]+/g, '[endpoint]'),
      ready: document.readyState,
      compiler: new URL(location.href).searchParams.get('compiler'),
      webgl: !!document.createElement('canvas').getContext('webgl2'),
      fonts: document.fonts.status,
      languages: navigator.languages,
      bootstrapErrors: window.tabryoDevToolsErrors ?? [],
      assets: performance.getEntriesByType('resource').slice(-20).map(e => new URL(e.name).pathname),
      devTools: document.querySelector('flutter-view') ? {
        children: [...document.querySelector('flutter-view').children].map(e => e.tagName),
        shadow: [...(document.querySelector('flt-glass-pane')?.shadowRoot?.children ?? [])].map(e => e.tagName),
        labels: [...document.querySelectorAll('flt-semantics-host [aria-label]')].map(e => e.getAttribute('aria-label').replace(/https?:[^ ]+/g, '[endpoint]')).slice(0, 40),
        semantics: document.querySelector('flt-semantics-host')?.childElementCount,
        viewport: [innerWidth, innerHeight],
        canvases: [...(document.querySelector('flt-glass-pane')?.shadowRoot?.querySelectorAll('canvas') ?? [])].map(e => [e.width, e.height]),
        clicks: window.devToolsClicks ?? [],
      } : null,
      suggestions: [...document.querySelectorAll('.suggest-widget')].map(e => ({display: getComputedStyle(e).display, text: e.textContent.slice(0, 100)})),
      errors: window.editorFailures ?? []})
  """);
  expect(value, expected, reason: '$expression\n$details');
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Use the same native test cases in the compiled Release application, where
  // GTK/WebKit stderr is observable without the debug service test transport.
  if (kReleaseMode) {
    binding.allTestsPassed.future.then((passed) => exit(passed ? 0 : 1));
  }
  testWidgets(
    'native Monaco edits Unicode, preserves undo and safely saves across dialogs',
    (tester) async {
      debugPrint('Native editor: preparing the filesystem fixture');
      final directory = await Directory.systemTemp.createTemp('tabryo-editor-');
      final root = await directory.resolveSymbolicLinks();
      final nested = await Directory(p.join(root, 'nested project')).create();
      final file = File(p.join(nested.path, 'ação example.dart'));
      await file.writeAsBytes([
        0xef,
        0xbb,
        0xbf,
        ...utf8.encode('void main() {}\r\n'),
      ]);
      final editor = EditorViewModel(
        LocalDocumentFiles(PreviewCache()),
        formatter: LocalDartFormatter(),
        contextSharing: EditorContextService(LocalEditorContext()),
        language: LanguageService(LocalLanguageServers()),
        languageSources: LocalLanguageSources(
          LocalDocumentFiles(PreviewCache()),
        ),
        webAssets: BundledEditorAssets(
          load: (name) async =>
              (await rootBundle.load(name)).buffer.asUint8List(),
          list: () async =>
              (await AssetManifest.loadFromAssetBundle(rootBundle))
                  .listAssets(),
          profileDirectory: p.join(root, 'webview'),
        ),
      );
      addTearDown(() async {
        await editor.disposeAsync();
        // WebView2 can release its profile asynchronously after disposal.
        // The OS owns this disposable temporary directory if handles remain open.
        try {
          await directory.delete(recursive: true);
        } on FileSystemException {
          /* Native profile still closing. */
        }
      });
      editor.selectWorkspace(root);
      await editor.open(root, file.path);
      debugPrint(
        'Native editor: fixture ready; mounting the workbench surface',
      );
      final visible = ValueNotifier(true);
      final reviewing = ValueNotifier(false);
      final brightness = ValueNotifier(Brightness.light);
      final git = LocalGit(executable: 'git', cache: PreviewCache());
      final review = GitReviewViewModel(git, git, git)
        ..diff = const GitFileDiff(
          'review.dart',
          GitContent(
            GitContentKind.text,
            'original',
            text: 'beforeReview();\n',
          ),
          GitContent(GitContentKind.text, 'modified', text: 'afterReview();\n'),
        );
      addTearDown(visible.dispose);
      addTearDown(reviewing.dispose);
      addTearDown(brightness.dispose);
      addTearDown(review.dispose);
      await tester.pumpWidget(
        ListenableBuilder(
          listenable: Listenable.merge([visible, reviewing, brightness]),
          builder: (_, _) => MaterialApp(
            theme: workbenchTheme(
              const Appearance(preset: ThemePreset.violet),
              brightness.value,
            ),
            navigatorObservers: [editorRoutes],
            home: Scaffold(
              body: EditorPane(
                model: editor,
                visible: visible.value,
                review: reviewing.value ? review : null,
              ),
            ),
          ),
        ),
      );
      debugPrint('Native editor: first Flutter frame rendered');
      await until(
        tester,
        () => find.byType(WinWebViewWidget).evaluate().isNotEmpty,
      );
      final state = tester.state<MonacoEditorState>(find.byType(MonacoEditor));
      debugPrint('Native editor: waiting for the embedded surface');
      final browser = tester
          .widget<WinWebViewWidget>(find.byType(WinWebViewWidget))
          .controller;
      try {
        await until(tester, () => state.surfaceVisible);
      } catch (_) {
        // Keep the readiness requirement while identifying which native
        // startup stage failed on an isolated desktop runner.
        try {
          final details = await browser
              .runJavaScriptReturningResult('''
            JSON.stringify({document: document.readyState,
              channel: typeof window.tabryoBridge,
              origin: location.origin,
              receiver: typeof window.tabryoReceive,
              failures: window.editorFailures ?? []})
          ''')
              .timeout(const Duration(seconds: 3));
          debugPrint('Native editor startup: $details');
        } catch (_) {
          debugPrint('Native editor startup: the WebView did not respond.');
        }
        rethrow;
      }
      debugPrint(
        'Native editor: surface ready; checking keyboard and clipboard',
      );
      final surfaceSize = tester.getSize(find.byType(WinWebViewWidget));
      final pixelRatio = tester.view.devicePixelRatio;
      await expectWeb(
        tester,
        browser,
        'Math.abs(innerWidth * devicePixelRatio - ${surfaceSize.width * pixelRatio}) <= 3 && '
        'Math.abs(innerHeight * devicePixelRatio - ${surfaceSize.height * pixelRatio}) <= 3',
        true,
      );
      if (Platform.environment['GDK_SCALE'] == '2') {
        expect(pixelRatio, 2);
      }
      if (Platform.isWindows) {
        focusTestWindow();
      } else {
        final windows = await Process.run('xdotool', [
          'search',
          '--onlyvisible',
          '--pid',
          '$pid',
        ]);
        expect(windows.exitCode, 0);
        final window = '${windows.stdout}'.trim().split('\n').first;
        expect(
          (await Process.run('xdotool', [
            'windowfocus',
            '--sync',
            window,
          ])).exitCode,
          0,
        );
      }
      await browser.requestFocus();
      await tester.pump(const Duration(milliseconds: 100));
      final previousClipboard = await Clipboard.getData(Clipboard.kTextPlain);
      addTearDown(
        () => Clipboard.setData(
          ClipboardData(text: previousClipboard?.text ?? ''),
        ),
      );
      await Clipboard.setData(const ClipboardData(text: '// ação 🌱\n'));
      if (Platform.isWindows) {
        controlKey(0x56); // Ctrl+V reaches the actual WebView2 input surface.
      } else {
        final focus = await Process.run('xdotool', [
          'getwindowfocus',
          'getwindowpid',
        ]);
        expect('${focus.stdout}'.trim(), '$pid');
        expect((await Process.run('xdotool', ['key', 'ctrl+v'])).exitCode, 0);
      }
      await until(
        tester,
        () => editor.active!.controller.text.contains('ação 🌱'),
      );
      final buffer = editor.active!;
      debugPrint(
        'Native editor: Unicode input received; checking save and history',
      );
      final edited = buffer.controller.text;
      expect(buffer.webCanUndo, isTrue);
      if (Platform.isWindows) {
        controlKey(0x53);
      } else {
        expect((await Process.run('xdotool', ['key', 'ctrl+s'])).exitCode, 0);
      }
      await until(tester, () {
        if (buffer.error != null) fail(buffer.error!);
        return !buffer.dirty && !buffer.saving;
      });
      expect(buffer.error, isNull);
      final saved = await file.readAsBytes();
      expect(saved.take(3), [0xef, 0xbb, 0xbf]);
      expect(
        utf8.decode(saved.skip(3).toList()),
        edited.replaceAll('\n', '\r\n'),
      );
      final selectionBeforeReview = buffer.controller.selection;
      reviewing.value = true;
      brightness.value = Brightness.dark;
      await tester.pump();
      final background = workbenchTheme(
        const Appearance(preset: ThemePreset.violet),
        Brightness.dark,
      ).colorScheme.surface.toARGB32();
      await expectWeb(
        tester,
        browser,
        "getComputedStyle(document.body).backgroundColor === 'rgb(${(background >> 16) & 255}, ${(background >> 8) & 255}, ${background & 255})'",
        true,
      );
      await expectWeb(
        tester,
        browser,
        "document.querySelector('.monaco-diff-editor')?.textContent.includes('afterReview') ?? false",
        true,
      );
      expect(
        tester.state<MonacoEditorState>(find.byType(MonacoEditor)),
        same(state),
      );
      expect(
        tester
            .widget<WinWebViewWidget>(find.byType(WinWebViewWidget))
            .controller,
        same(browser),
      );
      expect(buffer.controller.text, edited);
      reviewing.value = false;
      await tester.pump();
      await expectWeb(
        tester,
        browser,
        "document.querySelector('.view-lines')?.textContent.includes('ação') ?? false",
        true,
      );
      expect(buffer.controller.selection, selectionBeforeReview);
      editor.undoBuffer(buffer);
      await until(tester, () => buffer.controller.text != edited);
      editor.redoBuffer(buffer);
      await until(tester, () => buffer.controller.text == edited);
      debugPrint(
        'Native editor: composing text defers synchronization until commit',
      );
      await browser.runJavaScript("""
        (() => {
          const input = document.querySelector('textarea');
          input.focus();
          input.dispatchEvent(new CompositionEvent('compositionstart', {bubbles: true, data: ''}));
          input.dispatchEvent(new CompositionEvent('compositionupdate', {bubbles: true, data: '日本語'}));
        })();
      """);
      await expectWeb(
        tester,
        browser,
        "document.querySelector('.view-lines')?.textContent.includes('日本語') ?? false",
        true,
      );
      expect(buffer.controller.text, edited);
      var flushedComposition = false;
      final compositionFlush = editor.synchronizeBuffer(buffer).then((value) {
        flushedComposition = value;
        return value;
      });
      await tester.pump(const Duration(milliseconds: 100));
      expect(flushedComposition, isFalse);
      await browser.runJavaScript(
        "document.querySelector('textarea').dispatchEvent(new CompositionEvent('compositionend', {bubbles: true, data: '日本語'}));",
      );
      expect(await compositionFlush, isTrue);
      expect(buffer.controller.text, contains('日本語'));
      editor.undoBuffer(buffer);
      await until(tester, () => buffer.controller.text == edited);
      await browser.runJavaScript("""
        (() => {
          const input = document.querySelector('textarea');
          input.focus();
          input.dispatchEvent(new CompositionEvent('compositionstart', {bubbles: true, data: ''}));
          input.dispatchEvent(new CompositionEvent('compositionupdate', {bubbles: true, data: '字'}));
        })();
      """);
      await expectWeb(
        tester,
        browser,
        "document.querySelector('.view-lines')?.textContent.includes('字') ?? false",
        true,
      );
      buffer.controller.text = 'replacement during composition';
      editor.select(buffer);
      await tester.pump(const Duration(milliseconds: 100));
      await browser.runJavaScript(
        "document.querySelector('textarea').dispatchEvent(new CompositionEvent('compositionend', {bubbles: true, data: '字'}));",
      );
      await until(tester, () => buffer.reviewRequired);
      expect(buffer.controller.text, contains('字'));
      expect(buffer.controller.text, isNot('replacement during composition'));
      expect(await editor.save(buffer), isFalse);
      editor.keepLocalEdits(buffer);
      editor.undoBuffer(buffer);
      await until(tester, () => buffer.controller.text == edited);
      debugPrint('Native editor: reviewing an MCP excerpt and replacement');
      await tester.tap(find.byTooltip('Document actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Editor context for Codex / MCP'));
      await tester.pumpAndSettle();
      expect(state.surfaceVisible, isFalse);
      await tester.tap(find.text('Share the whole document'));
      await tester.tap(find.text('Review editor context'));
      await until(
        tester,
        () => find.text('Publish reviewed context').evaluate().isNotEmpty,
      );
      expect(editor.contextSharing!.connection, isNull);
      await tester.tap(find.text('Publish reviewed context'));
      await until(tester, () => editor.contextSharing!.connection != null);
      final grant = editor.contextSharing!.connection!;
      final client = HttpClient()..findProxy = (_) => 'DIRECT';
      try {
        final request = await client.postUrl(grant.endpoint);
        request.headers.contentType = ContentType.json;
        request.headers.set('Authorization', 'Bearer ${grant.token}');
        request.write(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': 1,
            'method': 'tools/call',
            'params': {
              'name': 'propose_replacement',
              'arguments': {
                'client_id': 'native-review',
                'snapshot_id': editor.contextSharing!.snapshot!.id,
                'text': '// MCP proposal\n$edited',
              },
            },
          }),
        );
        final response = await request.close();
        expect(response.statusCode, 200);
        expect(
          await response.transform(utf8.decoder).join(),
          contains('pending'),
        );
      } finally {
        client.close(force: true);
      }
      await until(
        tester,
        () => find.text('Review replacement').evaluate().isNotEmpty,
      );
      await tester.ensureVisible(find.text('Review replacement'));
      await tester.tap(find.text('Review replacement'));
      await until(
        tester,
        () => find.text('Apply unsaved replacement').evaluate().isNotEmpty,
      );
      expect(buffer.controller.text, edited);
      await tester.tap(find.text('Apply unsaved replacement'));
      await until(
        tester,
        () => buffer.controller.text.startsWith('// MCP proposal'),
      );
      expect(await file.readAsBytes(), saved);
      await tester.ensureVisible(find.text('Revoke editor context'));
      await tester.tap(find.text('Revoke editor context'));
      await until(tester, () => editor.contextSharing!.connection == null);
      await tester.tap(find.text('Close'));
      await until(tester, () => state.surfaceVisible);
      await expectWeb(
        tester,
        browser,
        "document.querySelector('.view-lines')?.textContent.replaceAll('\\u00a0', ' ').includes('MCP proposal') ?? false",
        true,
      );
      editor.undoBuffer(buffer);
      await until(tester, () => buffer.controller.text == edited);
      visible.value = false;
      await until(tester, () => !state.surfaceVisible);
      visible.value = true;
      await until(tester, () => state.surfaceVisible);
      await browser.runJavaScript(
        "document.querySelector('textarea').focus(); document.execCommand('insertText', false, '// local\\n');",
      );
      await until(tester, () => buffer.dirty);
      final close = confirmDocumentClose(
        tester.element(find.byType(EditorPane)),
        editor,
        [buffer],
      );
      await until(
        tester,
        () => find.text('Unsaved changes').evaluate().isNotEmpty,
      );
      expect(state.surfaceVisible, isFalse);
      await tester.tap(find.text('Cancel'));
      expect(await close, isFalse);
      await until(tester, () => state.surfaceVisible);
      await file.writeAsString('External edit\r\n');
      expect(await editor.save(buffer), isFalse);
      expect(buffer.controller.text, contains('// local'));
      expect(await file.readAsString(), 'External edit\r\n');
      await editor.compare(buffer);
      await tester.pumpAndSettle();
      await expectWeb(
        tester,
        browser,
        "document.querySelectorAll('.monaco-diff-editor').length",
        1,
      );
      editor.closeComparison(buffer);
      await tester.pumpAndSettle();
      await expectWeb(
        tester,
        browser,
        "document.querySelectorAll('.monaco-diff-editor').length",
        0,
      );
      await expectWeb(
        tester,
        browser,
        "performance.getEntriesByType('resource').some(x => x.name.endsWith('/editor.worker.js'))",
        true,
      );
      // One physical file can belong to two authorized, nested workspace roots.
      final nestedRoot = await nested.resolveSymbolicLinks();
      debugPrint(
        'Native editor: diff verified; checking workspace isolation and navigation',
      );
      editor.selectWorkspace(nestedRoot);
      await editor.open(nestedRoot, file.path);
      await expectWeb(
        tester,
        browser,
        "document.querySelector('.view-lines')?.innerText.includes('External')",
        true,
      );
      expect(editor.active, isNot(same(buffer)));
      editor.selectWorkspace(root);
      await expectWeb(
        tester,
        browser,
        "document.querySelector('.view-lines')?.innerText.includes('local')",
        true,
      );
      expect(buffer.controller.text, contains('ação 🌱'));
      await browser.runJavaScript(
        "window.tabryoBridge.postMessage(JSON.stringify({token:'wrong',type:'failed'})); location.href='https://example.invalid/';",
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(state.ready, isTrue);
      await expectWeb(tester, browser, "location.protocol === 'http:'", true);
      final retained = buffer.controller.text;
      debugPrint('Native editor: navigation denied; checking reconnect');
      await browser.runJavaScript(
        "setTimeout(() => { throw new Error('Fixture editor failure'); }, 0)",
      );
      await until(tester, () => !state.ready);
      expect(buffer.controller.text, retained);
      await until(
        tester,
        () => find.text('Reconnect editor').evaluate().isNotEmpty,
      );
      await tester.tap(find.text('Reconnect editor'));
      debugPrint('Native editor: reconnect requested');
      await until(tester, () => state.surfaceVisible);
      debugPrint('Native editor: reconnected surface ready');
      final reconnected = tester
          .widget<WinWebViewWidget>(find.byType(WinWebViewWidget))
          .controller;
      await expectWeb(
        tester,
        reconnected,
        "document.querySelector('.view-lines')?.innerText.includes('local')",
        true,
      );
      expect(await editor.synchronizeBuffer(buffer), isTrue);
      expect(buffer.controller.text, retained);
      if (Platform.isWindows) focusTestWindow();
      await reconnected.requestFocus();
      await tester.pump(const Duration(milliseconds: 100));
      await Clipboard.setData(ClipboardData(text: 'x' * (512 * 1024 + 1)));
      debugPrint('Native editor: testing oversized clipboard input');
      if (Platform.isWindows) {
        controlKey(0x56);
      } else {
        final focus = await Process.run('xdotool', [
          'getwindowfocus',
          'getwindowpid',
        ]);
        expect('${focus.stdout}'.trim(), '$pid');
        expect((await Process.run('xdotool', ['key', 'ctrl+v'])).exitCode, 0);
      }
      await until(tester, () => buffer.error?.contains('512 KiB') == true);
      expect(state.ready, isTrue);
      expect(await editor.synchronizeBuffer(buffer), isTrue);
      expect(buffer.controller.text, retained);
      expect(tester.takeException(), isNull);
      debugPrint(
        'Native editor: oversized input rejected; testing concurrent replacement',
      );
      // Deliberately delay input notifications to exercise the native bridge's
      // version boundary, while allowing the replacement response through.
      await reconnected.runJavaScript("""
        window.savedEditorPost = window.tabryoBridge.postMessage;
        window.tabryoBridge.postMessage = function(raw) {
          const type = JSON.parse(raw).type;
          if (type !== 'change' && type !== 'selection') window.savedEditorPost.call(window.tabryoBridge, raw);
        };
        document.querySelector('textarea').focus();
        document.execCommand('insertText', false, '// queued local input\\n');
      """);
      expect(buffer.controller.text, retained);
      buffer.controller.text = 'replacement from disk';
      editor.select(buffer);
      await until(tester, () => buffer.reviewRequired);
      expect(buffer.controller.text, contains('// queued local input'));
      expect(buffer.controller.text, isNot('replacement from disk'));
      expect(await editor.save(buffer), isFalse);
      await reconnected.runJavaScript(
        'window.tabryoBridge.postMessage = window.savedEditorPost; delete window.savedEditorPost;',
      );
      editor.keepLocalEdits(buffer);
      expect(buffer.reviewRequired, isFalse);
      debugPrint('Native editor: checking Dart format on save and undo');
      // Admit a BOM/CRLF baseline after the earlier external-conflict scenario.
      await file.writeAsBytes([
        0xef,
        0xbb,
        0xbf,
        ...utf8.encode('void main() {}\r\n'),
      ]);
      expect(await editor.reload(buffer), isTrue);
      expect(await editor.synchronizeBuffer(buffer), isTrue);
      final config = File('.dart_tool/package_config.json').absolute;
      final packages =
          (jsonDecode(await config.readAsString()) as Map)['packages'] as List;
      final flutter = packages.cast<Map>().firstWhere(
        (v) => v['name'] == 'flutter',
      );
      final sdkRoot = p.dirname(
        p.dirname(
          config.uri.resolve(flutter['rootUri'] as String).toFilePath(),
        ),
      );
      editor.dartFormatters = {
        root: p.join(
          sdkRoot,
          'bin',
          'cache',
          'dart-sdk',
          'bin',
          Platform.isWindows ? 'dart.exe' : 'dart',
        ),
      };
      const unformatted = 'void main(){print("ação 🌱");}\n';
      final selection = unformatted.indexOf('ação');
      buffer.controller.value = TextEditingValue(
        text: unformatted,
        selection: TextSelection(
          baseOffset: selection,
          extentOffset: selection + 4,
        ),
      );
      editor.select(buffer);
      expect(await editor.synchronizeBuffer(buffer), isTrue);
      expect(await editor.save(buffer), isTrue, reason: buffer.error);
      final formatted = buffer.controller.text;
      expect(formatted, contains('  print('));
      expect(
        formatted.substring(
          buffer.controller.selection.start,
          buffer.controller.selection.end,
        ),
        'ação',
      );
      final bytes = await file.readAsBytes();
      expect(bytes.take(3), [0xef, 0xbb, 0xbf]);
      expect(
        utf8.decode(bytes.skip(3).toList()),
        formatted.replaceAll('\n', '\r\n'),
      );
      editor.undoBuffer(buffer);
      await until(tester, () => buffer.controller.text == unformatted);
      expect(buffer.dirty, isTrue);
      editor.redoBuffer(buffer);
      await until(tester, () => buffer.controller.text == formatted);
      expect(buffer.dirty, isFalse);
      debugPrint('Native editor: qualifying Dart language intelligence');
      await reconnected.runJavaScript("""
        window.editorFailures = [];
        for (const type of ['error', 'unhandledrejection']) window.addEventListener(type, event => {
          if (window.editorFailures.length < 5) window.editorFailures.push(String(event.message ?? event.reason));
        });
      """);
      await editor.language!.start(
        LanguageServerSpec(
          kind: LanguageServerKind.dart,
          workspace: root,
          root: root,
          executable: editor.dartFormatters[root]!,
        ),
      );
      const source =
          'int value = 1;\nvoid main(){ print(value); missingName(); }\n';
      buffer.controller.value = TextEditingValue(
        text: source,
        selection: TextSelection.collapsed(offset: source.indexOf('value') + 2),
      );
      expect(await editor.synchronizeBuffer(buffer), isTrue);
      await until(
        tester,
        () => editor.language!.problems.any(
          (p) => '${p.diagnostic['message']}'.contains('missingName'),
        ),
      );
      await expectWeb(
        tester,
        reconnected,
        "document.querySelectorAll('.squiggly-error').length > 0",
        true,
      );
      // IntegrationTest leaves native text input active. Register the Flutter
      // keyboard stub before this dialog attaches, so enterText uses its real
      // client ID in Release too (the -1 test client is accepted only in Debug).
      tester.testTextInput.register();
      addTearDown(tester.testTextInput.unregister);
      await tester.tap(find.byTooltip('Document actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rename symbol'));
      await tester.pumpAndSettle();
      await until(
        tester,
        () => find
            .widgetWithText(TextField, 'New symbol name')
            .evaluate()
            .isNotEmpty,
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'New symbol name'),
        'count',
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<EditableText>(find.byType(EditableText)).controller.text,
        'count',
      );
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Review rename'),
            )
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.text('Review rename'));
      await until(
        tester,
        () => find.text('Review proposed edits').evaluate().isNotEmpty,
      );
      expect(state.surfaceVisible, isFalse);
      await tester.tap(find.text('Apply unsaved edits'));
      await until(
        tester,
        () => buffer.controller.text.contains('print(count)'),
      );
      expect(buffer.dirty, isTrue);
      expect(await file.readAsString(), isNot(contains('count')));
      await until(tester, () => state.surfaceVisible);
      const extractionSource = 'void main() { print(40 + 2); }\n';
      buffer.controller.value = TextEditingValue(
        text: extractionSource,
        selection: TextSelection(
          baseOffset: extractionSource.indexOf('40 + 2'),
          extentOffset: extractionSource.indexOf('40 + 2') + 6,
        ),
      );
      expect(await editor.synchronizeBuffer(buffer), isTrue);
      await tester.tap(find.byTooltip('Document actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Extract Dart method / getter'));
      await until(
        tester,
        () => find
            .widgetWithText(TextField, 'Extracted symbol name')
            .evaluate()
            .isNotEmpty,
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Extracted symbol name'),
        'calculate',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Review extraction'));
      await until(
        tester,
        () => find.text('Review proposed edits').evaluate().isNotEmpty,
      );
      expect(buffer.controller.text, extractionSource);
      await tester.tap(find.text('Apply unsaved edits'));
      await tester.pumpAndSettle();
      await until(
        tester,
        () => buffer.controller.text.contains('get calculate => 40 + 2'),
      );
      expect(buffer.controller.text, contains('print(calculate)'));
      expect(await file.readAsString(), isNot(contains('calculate')));
      await until(tester, () => state.surfaceVisible);
      editor.undoBuffer(buffer);
      await until(tester, () => buffer.controller.text == extractionSource);
      tester.testTextInput.unregister();
      debugPrint('Native editor: rename review applied; checking completion');
      await until(tester, () => state.surfaceVisible);
      const completionSource =
          'void main() { final value = "ação"; value.toStr; }\n';
      buffer.controller.value = TextEditingValue(
        text: completionSource,
        selection: TextSelection.collapsed(
          offset: completionSource.indexOf('toStr') + 5,
        ),
      );
      expect(await editor.synchronizeBuffer(buffer), isTrue);
      expect(buffer.controller.text, completionSource);
      expect(
        buffer.controller.selection.extentOffset,
        completionSource.indexOf('toStr') + 5,
      );
      await tester.tap(find.byTooltip('Document actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Complete code'));
      await tester.pumpAndSettle();
      await expectWeb(
        tester,
        reconnected,
        "document.querySelector('.suggest-widget')?.innerText.includes('toString') ?? false",
        true,
      );
      const importSource = 'void main() { Ran; }\n';
      buffer.controller.value = TextEditingValue(
        text: importSource,
        selection: TextSelection.collapsed(
          offset: importSource.indexOf('Ran') + 3,
        ),
      );
      expect(await editor.synchronizeBuffer(buffer), isTrue);
      editor.webCommand?.call('completion');
      await expectWeb(
        tester,
        reconnected,
        "[...document.querySelectorAll('.suggest-widget .monaco-list-row')].some(e => e.querySelector('.label-name')?.textContent === 'Random')",
        true,
      );
      await reconnected.runJavaScript("""
        (() => {
          const row = [...document.querySelectorAll('.suggest-widget .monaco-list-row')].find(e => e.querySelector('.label-name')?.textContent === 'Random');
          row.dispatchEvent(new MouseEvent('mousedown', {bubbles:true, button:0}));
          row.dispatchEvent(new MouseEvent('mouseup', {bubbles:true, button:0}));
          row.dispatchEvent(new MouseEvent('dblclick', {bubbles:true, button:0}));
        })();
      """);
      await expectWeb(
        tester,
        reconnected,
        "document.querySelector('.view-lines')?.innerText.includes('dart:math') ?? false",
        true,
      );
      expect(
        buffer.controller.text,
        contains("import 'dart:math';"),
        reason: buffer.error,
      );
      expect(buffer.controller.text, contains('Random'));
      expect(await file.readAsString(), isNot(contains("import 'dart:math';")));
      final sourcePath = p.join(
        p.dirname(p.dirname(editor.dartFormatters[root]!)),
        'lib',
        'math',
        'random.dart',
      );
      await editor.navigateLanguage(buffer, Uri.file(sourcePath).toString(), {
        'line': 0,
        'character': 0,
      });
      await until(tester, () => editor.active!.readOnly);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Dependency source · Read only'),
        findsOneWidget,
      );
      expect(await editor.save(editor.active!), isFalse);
      editor.select(buffer);
      buffer.controller.text = 'void main(){print("ação 🌱");}\n';
      debugPrint(
        'Native editor: completion rendered; checking language format on save',
      );
      expect(await editor.save(buffer), isTrue, reason: buffer.error);
      expect(buffer.controller.text, contains('  print('));
      await editor.language!.closeWorkspace(root);
      debugPrint(
        'Native editor: language server stopped; checking surface disposal',
      );
      await expectWeb(
        tester,
        reconnected,
        "document.querySelectorAll('.squiggly-error').length",
        0,
      );
      if (Platform.isLinux) {
        // Removing an absent channel must not add a tombstone that prevents
        // the remaining channels from being disposed when the surface closes.
        await reconnected.removeScriptChannelByName('AlreadyRemoved');
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  testWidgets(
    'local DevTools loads in its own surface and obeys dialog visibility',
    (tester) async {
      final directory = await Directory.systemTemp.createTemp(
        'tabryo_devtools_',
      );
      final root = await directory.resolveSymbolicLinks();
      final source = await File(p.join(root, 'main.dart')).writeAsString(
        "import 'dart:async';\nvoid main() { Timer.periodic(const Duration(seconds: 1), (_) {}); }\n",
      );
      final config = File(
        p.join(Directory.current.path, '.dart_tool', 'package_config.json'),
      );
      final packages =
          (jsonDecode(await config.readAsString()) as Map)['packages'] as List;
      final flutter = packages.cast<Map>().firstWhere(
        (v) => v['name'] == 'flutter',
      );
      final sdk = p.dirname(
        p.dirname(
          config.uri.resolve(flutter['rootUri'] as String).toFilePath(),
        ),
      );
      final service = DebugService(LocalDebugAdapters());
      addTearDown(() async {
        await service.dispose();
        try {
          await directory.delete(recursive: true);
        } on FileSystemException {
          // A native WebView2 profile can finish closing after the widget.
        }
      });
      await service.start(
        DebugConfiguration(
          project: DevelopmentProject(
            workspace: root,
            directory: root,
            name: 'DevTools',
            kind: ProjectKind.dart,
          ),
          tools: ToolchainSelection({
            ProjectTool.dart: p.join(
              sdk,
              'bin',
              'cache',
              'dart-sdk',
              'bin',
              Platform.isWindows ? 'dart.exe' : 'dart',
            ),
          }),
          program: source.path,
        ),
      );
      await until(tester, () => service.vmService != null);
      await service.openDevTools(external: false);
      expect(service.devToolsUri, isNotNull);
      final visible = ValueNotifier(true);
      addTearDown(visible.dispose);
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [editorRoutes],
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: visible,
              builder: (_, value, _) => DevToolsPane(
                uri: service.devToolsUri!,
                profileDirectory: p.join(root, 'webview'),
                visible: value,
              ),
            ),
          ),
        ),
      );
      await until(
        tester,
        () =>
            find.byType(DevToolsPane).evaluate().isNotEmpty &&
            tester
                .state<DevToolsPaneState>(find.byType(DevToolsPane))
                .surfaceVisible,
      );
      final state = tester.state<DevToolsPaneState>(find.byType(DevToolsPane));
      final browser = tester
          .widget<WinWebViewWidget>(find.byType(WinWebViewWidget))
          .controller;
      await expectWeb(
        tester,
        browser,
        "(() => { try { return navigator.languages.length > 0 && navigator.languages.every(tag => !!new Intl.Locale(tag)); } catch (_) { return false; } })()",
        true,
      );
      await expectWeb(
        tester,
        browser,
        "document.querySelector('flt-glass-pane') != null",
        true,
        attempts: 300,
      );
      await expectWeb(
        tester,
        browser,
        "typeof window.tabryoReceive === 'undefined' && typeof window.TabryoEditor === 'undefined'",
        true,
      );
      await browser.runJavaScript(
        "document.querySelector('flt-semantics-placeholder')?.click();",
      );
      await expectWeb(
        tester,
        browser,
        "(document.querySelector('flt-glass-pane')?.shadowRoot?.querySelector('canvas')?.width ?? 0) > 0",
        true,
        attempts: 300,
      );
      await browser.requestFocus();
      await tester.pump(const Duration(seconds: 1));
      await browser.runJavaScript("""
        window.devToolsClicks = [];
        document.addEventListener('pointerdown', e => window.devToolsClicks.push({x: e.clientX, y: e.clientY, trusted: e.isTrusted, target: e.target.tagName}), true);
        window.editorFailures = [];
        window.addEventListener('error', e => window.editorFailures.push(e.message));
      """);
      await expectWeb(
        tester,
        browser,
        "[...document.querySelectorAll('flt-semantics-host [role=tab]')].some(e => (e.getAttribute('aria-label') ?? e.textContent).includes('Debugger'))",
        true,
        attempts: 300,
      );
      final tabBounds = jsonDecode(
        await browser.runJavaScriptReturningResult("""
        (() => {
          const tab = [...document.querySelectorAll('flt-semantics-host [role=tab]')].find(e => (e.getAttribute('aria-label') ?? e.textContent).includes('Debugger'));
          const r = tab.getBoundingClientRect();
          return [(r.x + r.width / 2) / innerWidth, (r.y + r.height / 2) / innerHeight];
        })()
      """) as String,
      ) as List;
      // WebKit CSS pixels and Flutter logical pixels can have different scale
      // factors. Map through the actual surface, then let native input convert
      // that logical point to device pixels exactly once.
      final surface = tester.getSize(find.byType(WinWebViewWidget));
      await clickNativeSurface(
        tester,
        Offset(
          (tabBounds[0] as num).toDouble() * surface.width,
          (tabBounds[1] as num).toDouble() * surface.height,
        ),
      );
      await expectWeb(
        tester,
        browser,
        'window.devToolsClicks.length > 0',
        true,
        attempts: 300,
      );
      await expectWeb(
        tester,
        browser,
        "location.href.includes('debugger')",
        true,
        attempts: 300,
      );
      final route = showDialog<void>(
        context: tester.element(find.byType(DevToolsPane)),
        builder: (context) => AlertDialog(
          title: const Text('DevTools visibility'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Return to tools'),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(state.surfaceVisible, isFalse);
      await tester.tap(find.text('Return to tools'));
      await tester.pumpAndSettle();
      await route;
      await until(tester, () => state.surfaceVisible);
      await browser.runJavaScript(
        "location.href = 'https://example.invalid/';",
      );
      await expectWeb(
        tester,
        browser,
        'location.origin === ${jsonEncode(service.devToolsUri!.origin)}',
        true,
      );
      visible.value = false;
      await tester.pumpAndSettle();
      expect(state.surfaceVisible, isFalse);
      await browser.runJavaScript(
        "localStorage.setItem('tabryo-profile-check', 'owned')",
      );
      final isolated = WinWebViewController(
        params: WindowsWebViewControllerCreationParams(
          userDataFolder: p.join(root, 'other-web-profile'),
          profileName: 'OtherWebProfile',
        ),
      );
      try {
        await isolated.setVisibility(false);
        await isolated.setJavaScriptMode(JavaScriptMode.unrestricted);
        var loaded = false;
        await isolated.setNavigationDelegate(
          WinNavigationDelegate(onPageFinished: (_) => loaded = true),
        );
        await isolated.loadRequest(
          service.devToolsUri!.resolve('/favicon.png'),
        );
        await until(tester, () => loaded);
        await expectWeb(
          tester,
          isolated,
          "localStorage.getItem('tabryo-profile-check') === null",
          true,
        );
        await expectWeb(
          tester,
          browser,
          "localStorage.getItem('tabryo-profile-check') === 'owned'",
          true,
        );
      } finally {
        await isolated.dispose();
        await browser.runJavaScript(
          "localStorage.removeItem('tabryo-profile-check')",
        );
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await service.stop();
      expect(service.devToolsUri, isNull);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
