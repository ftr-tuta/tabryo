import 'dart:io';
import 'dart:ffi';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ffi/ffi.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:tabryo/core/preview_cache.dart';
import 'package:tabryo/features/editor/infrastructure/local_document_files.dart';
import 'package:tabryo/features/editor/presentation/editor_view_model.dart';
import 'package:tabryo/features/mcp_studio/application/mcp_studio.dart';
import 'package:tabryo/features/mcp_studio/infrastructure/local_studio_storage.dart';
import 'package:tabryo/features/mcp_studio/presentation/mcp_studio_view_model.dart';
import 'package:tabryo/features/files/infrastructure/local_workspace_files.dart';
import 'package:tabryo/features/git/infrastructure/local_git.dart';
import 'package:tabryo/features/preferences/infrastructure/local_preferences.dart';
import 'package:tabryo/features/terminals/domain/terminal_ports.dart';
import 'package:tabryo/features/terminals/infrastructure/native_terminal.dart';
import 'package:tabryo/features/terminals/presentation/terminal_session.dart';
import 'package:tabryo/features/workspaces/domain/workspace.dart';
import 'package:tabryo/features/workspaces/presentation/workbench_view_model.dart';
import 'package:tabryo/main.dart';

final class CountingHost implements PtyHost {
  int starts = 0;
  @override
  PtyProcess start(LaunchSpec spec) {
    starts++;
    return NativePtyHost().start(spec);
  }
}

// A local interactive fixture, never an authenticated or paid Codex invocation.
final class InteractiveLauncher implements CodexLauncher {
  LaunchSpec _launch(String root, String mode) => LaunchSpec(
    executable: Platform.isWindows
        ? '${Platform.environment['SystemRoot']}\\System32\\WindowsPowerShell\\v1.0\\powershell.exe'
        : '/bin/sh',
    workingDirectory: root,
    arguments: Platform.isWindows
        ? [
            '-NoLogo',
            '-NoProfile',
            '-Command',
            r'''[Console]::InputEncoding=[Text.UTF8Encoding]::new();[Console]::OutputEncoding=[Text.UTF8Encoding]::new();[Console]::WriteLine($env:TABRYO_TEST_MODE);while(($line=[Console]::ReadLine()) -ne $null){[Console]::WriteLine('ECHO:'+ $line);if($line -eq 'exit'){break}}''',
          ]
        : [
            '-c',
            r'''printf '%s\n' "$TABRYO_TEST_MODE"; while IFS= read -r line; do printf 'ECHO:%s\n' "$line"; [ "$line" = exit ] && break; done''',
          ],
    environment: {'TABRYO_TEST_MODE': mode},
  );
  @override
  LaunchSpec shell(String directory) => _launch(directory, 'SHELL_READY');
  @override
  LaunchSpec codex(String directory, {bool resume = false}) =>
      _launch(directory, resume ? 'RESUME_READY' : 'CODEX_FIXTURE_READY');
}

String terminalText(TerminalSession session) => [
  for (var i = 0; i < session.terminal.buffer.lines.length; i++)
    session.terminal.buffer.lines[i].getText(),
].join('\n');

Future<void> until(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  for (var attempt = 0; attempt < timeout.inMilliseconds ~/ 100; attempt++) {
    if (condition()) return;
    await tester.pump(const Duration(milliseconds: 100));
  }
  fail(
    'The desktop operation did not complete within ${timeout.inSeconds} seconds.',
  );
}

void requestNativeWindowClose() {
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
  final post = user32
      .lookupFunction<
        Int32 Function(IntPtr, Uint32, IntPtr, IntPtr),
        int Function(int, int, int, int)
      >('PostMessageW');
  final title = 'Tabryo'.toNativeUtf16();
  final processId = calloc<Uint32>();
  try {
    var window = 0;
    while ((window = find(0, window, nullptr, title)) != 0) {
      owner(window, processId);
      if (processId.value == pid) {
        expect(post(window, 0x0010 /* WM_CLOSE */, 0, 0), isNot(0));
        return;
      }
    }
    fail('The current test process has no Tabryo window.');
  } finally {
    calloc.free(title);
    calloc.free(processId);
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // The Flutter desktop driver requires debug/profile. A compiled Release
  // test entrypoint still runs the same native integration_test cases; use its
  // aggregate result as the process exit status when launched directly.
  if (kReleaseMode) {
    binding.allTestsPassed.future.then((passed) => exit(passed ? 0 : 1));
  }
  testWidgets('desktop gestures, Unicode paste, splits, and real Git PTY commands', (
    tester,
  ) async {
    final temporary = await Directory.systemTemp.createTemp('tabryo-desktop-');
    final root = await Directory(
      p.join(temporary.path, 'workspace ação & test'),
    ).create();
    final cache = PreviewCache();
    final config = await File(p.join(temporary.path, 'gitconfig'))
        .writeAsString('');
    final environment = {
      'GIT_CONFIG_NOSYSTEM': '1',
      'GIT_CONFIG_GLOBAL': config.path,
      'GIT_AUTHOR_NAME': 'Desktop Test',
      'GIT_AUTHOR_EMAIL': 'desktop@example.invalid',
      'GIT_COMMITTER_NAME': 'Desktop Test',
      'GIT_COMMITTER_EMAIL': 'desktop@example.invalid',
    };
    final executable = findExecutable(['git.exe', 'git'])!;
    Future<ProcessResult> fixtureGit(List<String> args) => Process.run(
      executable,
      args,
      workingDirectory: root.path,
      environment: environment,
    );
    expect((await fixtureGit(['init', '-b', 'main'])).exitCode, 0);
    final remote = p.join(temporary.path, 'remote.git');
    expect((await fixtureGit(['init', '--bare', remote])).exitCode, 0);
    expect((await fixtureGit(['remote', 'add', 'origin', remote])).exitCode, 0);
    final git = LocalGit(
      executable: executable,
      cache: cache,
      environment: environment,
    );
    final host = CountingHost();
    final model = WorkbenchViewModel(
      host: host,
      launcher: InteractiveLauncher(),
      files: LocalWorkspaceFiles(cache),
      gitReader: git,
      gitMutator: git,
      preferencesStore: LocalPreferencesStore(
        File(p.join(temporary.path, 'preferences.json')),
      ),
    );
    addTearDown(() async {
      await model.shutdown();
      await temporary.delete(recursive: true);
    });
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: TabryoApp(createViewModel: () => model),
      ),
    );
    await tester.pumpAndSettle();
    expect(host.starts, 0);
    debugPrint(
      'App RSS (${kReleaseMode ? "Release with integration binding" : "Debug"}), empty: ${ProcessInfo.currentRss ~/ (1024 * 1024)} MiB',
    );
    await tester.tap(find.widgetWithText(TextButton, 'Open workspace'));
    await tester.pumpAndSettle();
    // The integration binding uses the real IME. TestTextInput's synthetic
    // client -1 only works in Debug, so deliver to the actual text client.
    tester
        .state<EditableTextState>(find.byType(EditableText))
        .updateEditingValue(TextEditingValue(text: root.path));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    await until(tester, () => model.workspace != null && !model.loading);
    expect(host.starts, 0);
    await tester.tap(find.widgetWithText(TextButton, 'Shell'));
    await until(
      tester,
      () =>
          model.activeSession != null &&
          terminalText(model.activeSession!).contains('SHELL_READY'),
    );
    final shell = model.activeSession!;
    debugPrint(
      'App RSS, one fixture terminal: ${ProcessInfo.currentRss ~/ (1024 * 1024)} MiB',
    );
    await Clipboard.setData(
      const ClipboardData(text: 'ação 🌱\nsecond line\n'),
    );
    await tester.tap(find.byTooltip('Paste (Ctrl+Shift+V)'));
    await tester.pumpAndSettle();
    expect(find.text('Paste multiple lines?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Paste'));
    await until(tester, () => terminalText(shell).contains('ECHO:second line'));
    expect(terminalText(shell), contains('ação 🌱'));
    await model.openTerminal(codex: true, resume: true);
    await until(
      tester,
      () => terminalText(model.activeSession!).contains('RESUME_READY'),
    );
    await model.openTerminal(split: SplitDirection.horizontal);
    await model.openTerminal(split: SplitDirection.vertical);
    await until(
      tester,
      () =>
          model.sessions.values.every((s) => terminalText(s).contains('READY')),
    );
    expect(host.starts, 4);
    debugPrint(
      'App RSS, four fixture terminals: ${ProcessInfo.currentRss ~/ (1024 * 1024)} MiB; child processes excluded',
    );
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(milliseconds: 100));
    final rendered =
        await (boundary.currentContext!.findRenderObject()
                as RenderRepaintBoundary)
            .toImage();
    final png = await rendered.toByteData(format: ui.ImageByteFormat.png);
    if (Platform.environment['TABRYO_SCREENSHOT'] case final String path) {
      await File(path).writeAsBytes(png!.buffer.asUint8List());
    }
    rendered.dispose();
    await File(p.join(root.path, 'notes.txt'))
        .writeAsString('Desktop commit\n');
    await model.selectSidebar(SidebarPage.changes);
    await model.stage(model.changes.single);
    await model.runGitCommand(
      (repo) => git.commit(repo, 'Desktop integration commit'),
      'Commit',
    );
    final commit = model.activeSession!;
    await until(tester, () => commit.status == SessionStatus.exited);
    expect(commit.exitCode, 0, reason: terminalText(commit));
    expect(
      (await git.history(await git.repository(root.path))).single.subject,
      'Desktop integration commit',
    );
    // Explicit refspec belongs only to disposable fixture setup; product push uses configured upstreams.
    expect(
      (await fixtureGit(['config', 'branch.main.remote', 'origin'])).exitCode,
      0,
    );
    expect(
      (await fixtureGit(['config', 'branch.main.merge', 'refs/heads/main']))
          .exitCode,
      0,
    );
    await model.runGitCommand(
      (repo) => git.remoteCommand(repo, 'push', 'origin'),
      'Push',
    );
    final push = model.activeSession!;
    await until(tester, () => push.status == SessionStatus.exited);
    expect(push.exitCode, 0, reason: terminalText(push));
    expect(
      (await fixtureGit(['--git-dir', remote, 'rev-parse', 'main'])).stdout,
      (await fixtureGit(['rev-parse', 'HEAD'])).stdout,
    );
    await model.shutdown();
    await tester.pumpWidget(const SizedBox.shrink());
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets(
    'desktop editor protects changes and Studio launches a reviewed command',
    (tester) async {
      final temporary = await Directory.systemTemp.createTemp(
        'tabryo-desktop-editor-',
      );
      final root = await temporary.resolveSymbolicLinks();
      final file = await File(p.join(root, 'notes.txt'))
          .writeAsString('Original\n');
      final cache = PreviewCache();
      final git = LocalGit(
        executable: findExecutable(['git.exe', 'git'])!,
        cache: cache,
      );
      final editor = EditorViewModel(LocalDocumentFiles(cache));
      final studio = McpStudioViewModel(McpStudio(LocalStudioStorage()));
      final host = CountingHost();
      final model = WorkbenchViewModel(
        host: host,
        launcher: InteractiveLauncher(),
        files: LocalWorkspaceFiles(cache),
        gitReader: git,
        gitMutator: git,
        preferencesStore: LocalPreferencesStore(
          File(p.join(root, 'preferences.json')),
        ),
        editor: editor,
        studio: studio,
      );
      addTearDown(() async {
        await model.shutdown();
        await temporary.delete(recursive: true);
      });
      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: TabryoApp(createViewModel: () => model),
        ),
      );
      await model.openWorkspace(root);
      await model.openFile(file.path);
      await tester.pumpAndSettle();
      tester
          .state<EditableTextState>(find.byType(EditableText))
          .updateEditingValue(
            const TextEditingValue(
              text: 'Unsaved ação\n',
              selection: TextSelection.collapsed(offset: 4),
            ),
          );
      await tester.pumpAndSettle();
      if (Platform.isWindows) {
        requestNativeWindowClose();
        await until(
          tester,
          () => find.text('Unsaved changes').evaluate().isNotEmpty,
        );
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(editor.active!.controller.text, 'Unsaved ação\n');
        expect(host.starts, 0);
      }
      await File(file.path).writeAsString('External\n');
      await tester.tap(find.byTooltip('Save document (Ctrl+S)'));
      await until(tester, () => editor.active!.error != null);
      expect(editor.active!.controller.text, 'Unsaved ação\n');
      expect(await file.readAsString(), 'External\n');
      await tester.tap(find.byTooltip('MCP Studio'));
      await tester.pumpAndSettle();
      tester
          .state<EditableTextState>(
            find.descendant(
              of: find.widgetWithText(TextField, 'Project name'),
              matching: find.byType(EditableText),
            ),
          )
          .updateEditingValue(const TextEditingValue(text: 'greeting_demo'));
      await tester.tap(find.text('Review project'));
      await until(tester, () => studio.preview != null);
      await tester.pumpAndSettle();
      final studioScroll = find
          .descendant(
            of: find.byKey(const ValueKey('studio-content')),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.text('Create reviewed project'),
        200,
        scrollable: studioScroll,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create reviewed project'));
      await until(tester, () => studio.selected != null && !studio.busy);
      await tester.pumpAndSettle();
      expect(host.starts, 0);
      await tester.ensureVisible(find.text('Open source in editor'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open source in editor'));
      await until(
        tester,
        () =>
            model.workspace?.root == studio.selected!.path &&
            editor.active != null,
      );
      await tester.pumpAndSettle();
      expect(editor.buffers.first.controller.text, 'Unsaved ação\n');
      expect(editor.active!.path, endsWith(p.join('lib', 'server.dart')));
      if (Platform.environment['TABRYO_SCREENSHOT'] case final String path) {
        final rendered =
            await (boundary.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final png = await rendered.toByteData(format: ui.ImageByteFormat.png);
        await File(path).writeAsBytes(png!.buffer.asUint8List());
        rendered.dispose();
      }
      await tester.tap(find.byTooltip('MCP Studio'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byTooltip('Review Install dependencies'),
        200,
        scrollable: studioScroll,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Review Install dependencies'));
      await until(
        tester,
        () => find.text('Run in terminal').evaluate().isNotEmpty,
      );
      expect(host.starts, 0);
      await tester.tap(find.text('Run in terminal'));
      await until(tester, () => model.activeSession != null);
      final command = model.activeSession!;
      await until(
        tester,
        () => command.status == SessionStatus.exited,
        timeout: const Duration(minutes: 2),
      );
      expect(command.exitCode, 0, reason: terminalText(command));
      expect(host.starts, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
