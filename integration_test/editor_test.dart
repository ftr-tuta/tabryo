import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:tabryo/core/preview_cache.dart';
import 'package:tabryo/features/editor/infrastructure/bundled_editor_assets.dart';
import 'package:tabryo/features/editor/infrastructure/local_document_files.dart';
import 'package:tabryo/features/editor/infrastructure/local_dart_formatter.dart';
import 'package:tabryo/features/editor/presentation/editor_pane.dart';
import 'package:tabryo/features/editor/presentation/editor_view_model.dart';
import 'package:tabryo/features/editor/presentation/monaco_editor.dart';
import 'package:tabryo/features/language/application/language_service.dart';
import 'package:tabryo/features/language/domain/language_server.dart';
import 'package:tabryo/features/language/infrastructure/lsp_connection.dart';
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

void focusTestWindow() {
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
  try {
    var window = 0;
    while ((window = find(0, window, nullptr, nullptr)) != 0) {
      owner(window, process);
      if (process.value != pid) continue;
      show(window, 9);
      if (foreground(window) != 0) return;
      final activeThread = owner(active(), process);
      final attached = attach(current(), activeThread, 1) != 0;
      try {
        if (foreground(window) != 0) return;
      } finally {
        if (attached) attach(current(), activeThread, 0);
      }
    }
    fail('The native test window could not receive keyboard focus.');
  } finally {
    calloc.free(process);
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
  Object expected,
) async {
  Object? value;
  for (var attempt = 0; attempt < 50; attempt++) {
    value = await browser.runJavaScriptReturningResult(expression);
    if (value == expected) return;
    await tester.pump(const Duration(milliseconds: 100));
  }
  final details = await browser.runJavaScriptReturningResult("""
    JSON.stringify({focus: document.activeElement?.className,
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
        language: LanguageService(LocalLanguageServers()),
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
      addTearDown(visible.dispose);
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [editorRoutes],
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: visible,
              builder: (_, value, _) =>
                  EditorPane(model: editor, visible: value),
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
      await until(tester, () => state.surfaceVisible);
      debugPrint(
        'Native editor: surface ready; checking keyboard and clipboard',
      );
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
      editor.undoBuffer(buffer);
      await until(tester, () => buffer.controller.text != edited);
      editor.redoBuffer(buffer);
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
        "TabryoEditor.postMessage(JSON.stringify({token:'wrong',type:'failed'})); location.href='https://example.invalid/';",
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
        window.savedEditorPost = TabryoEditor.postMessage;
        TabryoEditor.postMessage = function(raw) {
          const type = JSON.parse(raw).type;
          if (type !== 'change' && type !== 'selection') window.savedEditorPost.call(TabryoEditor, raw);
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
        'TabryoEditor.postMessage = window.savedEditorPost; delete window.savedEditorPost;',
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
}
