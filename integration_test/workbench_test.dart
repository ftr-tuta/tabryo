import 'dart:io';
import 'dart:ffi';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ffi/ffi.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:tabryo/core/preview_cache.dart';
import 'package:tabryo/features/debugger/application/debug_service.dart';
import 'package:tabryo/features/debugger/domain/debug_session.dart';
import 'package:tabryo/features/debugger/infrastructure/dap_connection.dart';
import 'package:tabryo/features/debugger/presentation/debug_panel.dart';
import 'package:tabryo/features/editor/infrastructure/local_document_files.dart';
import 'package:tabryo/features/editor/presentation/editor_view_model.dart';
import 'package:tabryo/features/mcp_studio/application/mcp_studio.dart';
import 'package:tabryo/features/mcp_studio/infrastructure/local_studio_storage.dart';
import 'package:tabryo/features/mcp_studio/presentation/mcp_studio_view_model.dart';
import 'package:tabryo/features/files/infrastructure/local_workspace_files.dart';
import 'package:tabryo/features/files/domain/workspace_files.dart';
import 'package:tabryo/core/cancellation.dart';
import 'package:tabryo/features/git/infrastructure/local_git.dart';
import 'package:tabryo/features/preferences/infrastructure/local_preferences.dart';
import 'package:tabryo/features/projects/infrastructure/local_project_environment.dart';
import 'package:tabryo/features/projects/presentation/projects_view_model.dart';
import 'package:tabryo/features/projects/domain/project.dart';
import 'package:tabryo/features/tasks/domain/project_task.dart';
import 'package:tabryo/features/tasks/infrastructure/local_task_files.dart';
import 'package:tabryo/features/tasks/presentation/tasks_view_model.dart';
import 'package:tabryo/features/tasks/presentation/tasks_panel.dart';
import 'package:tabryo/features/terminals/domain/terminal_ports.dart';
import 'package:tabryo/features/terminals/infrastructure/native_terminal.dart';
import 'package:tabryo/features/terminals/infrastructure/local_text_clipboard.dart';
import 'package:tabryo/features/terminals/presentation/terminal_session.dart';
import 'package:tabryo/features/workspaces/domain/workspace.dart';
import 'package:tabryo/features/workspaces/presentation/workbench_view_model.dart';
import 'package:tabryo/features/workspaces/presentation/window_coordinator.dart';
import 'package:tabryo/features/preferences/domain/preferences.dart';
import 'package:tabryo/features/terminals/presentation/terminal_pane_view.dart';
import 'package:tabryo/features/debugger/presentation/devtools_pane.dart';
import 'package:webview_win_floating/webview_win_floating.dart';
import 'package:multiview_desktop/multiview_desktop.dart';
import 'package:tabryo/main.dart';

import 'editor_test.dart' show controlKey, expectWeb, focusTestWindow;

final class WindowEvents extends WindowObserver {
  final events = <String>[];
  @override
  void onWindowEvent(int viewId, String eventName) {
    events.add('$viewId:$eventName');
    if (events.length > 100) events.removeAt(0);
  }
}

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
  // Exercise the production gesture path for native input. The live tester's
  // inspection dispatcher assumes every event still has a registered RenderView,
  // which is false during native view removal and runMultiApp root replacement.
  binding.shouldPropagateDevicePointerEvents = true;
  // The Flutter desktop driver requires debug/profile. A compiled Release
  // test entrypoint still runs the same native integration_test cases; use its
  // aggregate result as the process exit status when launched directly.
  if (kReleaseMode) {
    binding.allTestsPassed.future.then((passed) => exit(passed ? 0 : 1));
  }
  testWidgets(
    'reviewed Flutter tests report native results and task stop closes its process',
    (tester) async {
      final temporary = await Directory.systemTemp.createTemp(
        'native-project-tests-',
      );
      final directory = await Directory(p.join(temporary.path, 'ação & tests'))
          .create();
      final root = await directory.resolveSymbolicLinks();
      await File(p.join(root, 'pubspec.yaml')).writeAsString(
        'name: native_tests\nenvironment:\n  sdk: ^3.13.2\ndev_dependencies:\n  flutter_test:\n    sdk: flutter\n',
      );
      final testFile = File(p.join(root, 'test', 'example_test.dart'));
      await testFile.parent.create();
      await testFile.writeAsString(
        "import 'package:flutter_test/flutter_test.dart';\nimport 'package:native_tests/example.dart';\nvoid main() { test('ação passes', () { expect(answer(), 42); }); test('failure is visible', () { expect(1, 2); }); }\n",
      );
      final sourceFile = File(p.join(root, 'lib', 'example.dart'));
      await sourceFile.parent.create();
      await sourceFile.writeAsString('int answer() => 42;\n');
      final environment = LocalProjectEnvironment();
      final project = DevelopmentProject(
        workspace: root,
        directory: root,
        name: 'native_tests',
        kind: ProjectKind.flutter,
      );
      final hints = await environment.toolchains(project);
      final flutter = hints.candidates[ProjectTool.flutter]!.first.path;
      final tools = ToolchainSelection({
        ProjectTool.flutter: flutter,
        ProjectTool.dart: p.join(
          flutter,
          'bin',
          'cache',
          'dart-sdk',
          'bin',
          Platform.isWindows ? 'dart.exe' : 'dart',
        ),
      });
      final setup = await Process.run(
        p.join(flutter, 'bin', Platform.isWindows ? 'flutter.bat' : 'flutter'),
        ['pub', 'get', '--offline'],
        workingDirectory: root,
      ).timeout(const Duration(seconds: 60));
      expect(setup.exitCode, 0, reason: '${setup.stdout}\n${setup.stderr}');
      final cache = PreviewCache();
      final git = LocalGit(
        executable: findExecutable(['git.exe', 'git'])!,
        cache: cache,
      );
      final projects = ProjectsViewModel(environment)
        ..selections[project.id] = tools;
      final tasks = TasksViewModel(
        LocalTaskFiles(),
        windows: Platform.isWindows,
      );
      final host = CountingHost();
      final editor = EditorViewModel(LocalDocumentFiles(cache));
      final debugger = DebugService(LocalDebugAdapters());
      final model = WorkbenchViewModel(
        host: host,
        launcher: InteractiveLauncher(),
        files: LocalWorkspaceFiles(cache),
        gitReader: git,
        gitMutator: git,
        preferencesStore: LocalPreferencesStore(
          File(p.join(temporary.path, 'preferences.json')),
        ),
        projects: projects,
        tasks: tasks,
        editor: editor,
        debugger: debugger,
      );
      addTearDown(() async {
        await model.disposeAsync();
        await temporary.delete(recursive: true);
      });
      await model.openWorkspace(root);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: TasksPanel(
                model: tasks,
                project: project,
                projects: [project],
                selection: tools,
                onRun: model.runTask,
                onStop: model.stopTask,
                onTerminal: model.showTaskTerminal,
                onOpen: model.openTestResult,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Discover test files'));
      await until(tester, () => !tasks.scanning);
      expect(tasks.discoveries[project.id]!.paths, [testFile.path]);
      expect(host.starts, 0);
      await tester.ensureVisible(find.text('Review task'));
      await tester.tap(find.text('Review task'));
      await until(
        tester,
        () => find.text('Run reviewed task').evaluate().isNotEmpty,
      );
      expect(host.starts, 0);
      await tester.tap(find.text('Run reviewed task'));
      await until(tester, () => tasks.runs.isNotEmpty);
      final task = tasks.runs.single;
      await until(
        tester,
        () => task.results != null,
        timeout: const Duration(seconds: 60),
      );
      await model.sessions[task.sessionId]!.finished;
      expect(
        task.status,
        TaskStatus.failed,
        reason: terminalText(model.sessions[task.sessionId]!),
      );
      expect(task.results!.complete, isTrue);
      expect(
        task.results!.cases.map((t) => t.outcome),
        containsAll([TestOutcome.passed, TestOutcome.failed]),
      );
      expect(task.results!.cases.first.path, testFile.path);
      final selected = await tasks.prepare(
        project,
        tools,
        ProjectTaskKind.test,
        target: testFile.path,
        filter: 'ação passes',
        coverage: true,
      );
      await model.runTask(selected);
      await until(
        tester,
        () => selected.results != null,
        timeout: const Duration(seconds: 60),
      );
      await model.sessions[selected.sessionId]!.finished;
      expect(
        selected.status,
        TaskStatus.passed,
        reason:
            '${selected.error}\n${terminalText(model.sessions[selected.sessionId]!)}',
      );
      expect(selected.results!.cases.single.name, 'ação passes');
      expect(selected.coverageError, isNull);
      expect(selected.coverage!.files.single.path, sourceFile.path);
      expect(selected.coverage!.covered, greaterThan(0));
      await model.openTestResult(selected, selected.results!.cases.single);
      expect(editor.active!.path, testFile.path);
      final matches = await model.files.search(
        root,
        const WorkspaceSearchQuery('answer()'),
        Cancellation(),
      );
      final match = matches.matches.firstWhere(
        (m) => m.path == sourceFile.path,
      );
      await model.openSearchResult(root, match);
      expect(editor.active!.path, sourceFile.path);
      expect(editor.active!.controller.selection.start, 4);
      editor.active!.controller.text =
          '// local unsaved edit\nint answer() => 43;\n';
      await model.openSearchResult(root, match);
      expect(model.message, contains('changed since the search'));
      expect(editor.active!.controller.text, contains('local unsaved edit'));
      await editor.save(editor.active!);
      expect(await Directory(selected.report!.directory).exists(), isFalse);
      final dartProject = DevelopmentProject(
        workspace: root,
        directory: root,
        name: 'script',
        kind: ProjectKind.dart,
      );
      projects.selections[dartProject.id] = tools;
      final entry = File(p.join(root, 'wait.dart'));
      await entry.writeAsString(
        "import 'dart:async'; void main() { print('WAIT_READY'); Timer.periodic(const Duration(seconds:1), (_) {}); }",
      );
      final running = await tasks.prepare(
        dartProject,
        tools,
        ProjectTaskKind.run,
        target: entry.path,
      );
      await model.runTask(running);
      await until(
        tester,
        () =>
            terminalText(model.sessions[running.sessionId]!)
                .contains('WAIT_READY'),
      );
      await model.stopTask(running);
      expect(running.status, TaskStatus.cancelled);
      expect(model.sessions[running.sessionId]!.status, SessionStatus.exited);
      final debugSource = await File(p.join(root, 'main.dart')).writeAsString(
        'void main() {\n  var answer = 41;\n  print(answer + 1);\n}\n',
      );
      // Release bindings do not install the keyboard test transport by default.
      // Register before the field attaches so enterText reaches its connection.
      tester.testTextInput.register();
      addTearDown(tester.testTextInput.unregister);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: DebugPanel(
                service: debugger,
                project: dartProject,
                tools: tools,
                onStart: model.startDebugger,
                onStop: debugger.stop,
                onControl: model.controlDebugger,
                onSource: model.openDebugSource,
              ),
            ),
          ),
        ),
      );
      await tester.enterText(
        find.widgetWithText(
          TextField,
          'Breakpoint lines in this file (for example 5, 12)',
        ),
        '3',
      );
      expect(
        tester
            .widget<TextField>(
              find.widgetWithText(
                TextField,
                'Breakpoint lines in this file (for example 5, 12)',
              ),
            )
            .controller!
            .text,
        '3',
      );
      await tester.ensureVisible(find.text('Review run / debug'));
      await tester.tap(find.text('Review run / debug'));
      await tester.pumpAndSettle();
      expect(debugger.active, isFalse);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(debugger.active, isFalse);
      await tester.tap(find.text('Review run / debug'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start reviewed session'));
      await until(tester, () {
        if (debugger.error != null) fail(debugger.error!);
        return debugger.status == DebugStatus.paused &&
            debugger.scopes.isNotEmpty;
      });
      // A paused debugger retains the same project command reservation.
      final conflicting = await tasks.prepare(
        dartProject,
        tools,
        ProjectTaskKind.run,
        target: entry.path,
      );
      await expectLater(
        model.runTask(conflicting),
        throwsA(isA<ProjectFailure>()),
      );
      await tester.pump();
      expect(find.text('main.dart: 3 verified'), findsOneWidget);
      await tester.ensureVisible(find.byTooltip('Open stack source').first);
      await tester.tap(find.byTooltip('Open stack source').first);
      await until(tester, () => editor.active?.path == debugSource.path);
      expect(editor.active!.controller.selection.start, greaterThan(0));
      await tester.ensureVisible(find.text('Stop debugger'));
      await tester.tap(find.text('Stop debugger'));
      await until(tester, () => !debugger.active);
      expect(debugger.status, DebugStatus.terminated);
      tester.testTextInput.unregister();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
  testWidgets(
    'project creation reviews the native Flutter command and publishes its result',
    (tester) async {
      final temporary = await Directory.systemTemp.createTemp(
        'tabryo-project-ui-',
      );
      final directory = await Directory(
        p.join(temporary.path, 'workspace ação & test'),
      ).create();
      final root = await directory.resolveSymbolicLinks();
      await File(p.join(root, 'pubspec.yaml'))
          .writeAsString('name: workspace_app\nflutter:\n');
      final cache = PreviewCache();
      final git = LocalGit(
        executable: findExecutable(['git.exe', 'git'])!,
        cache: cache,
      );
      final host = CountingHost();
      final projects = ProjectsViewModel(LocalProjectEnvironment());
      final model = WorkbenchViewModel(
        host: host,
        launcher: InteractiveLauncher(),
        files: LocalWorkspaceFiles(cache),
        gitReader: git,
        gitMutator: git,
        preferencesStore: LocalPreferencesStore(
          File(p.join(temporary.path, 'preferences.json')),
        ),
        projects: projects,
      );
      addTearDown(() async {
        await model.shutdown();
        await temporary.delete(recursive: true);
      });
      await tester.pumpWidget(TabryoApp(createViewModel: () => model));
      await model.openWorkspace(root);
      await tester.pumpAndSettle();
      expect(host.starts, 0);
      await tester.tap(find.byTooltip('Projects and toolchains'));
      await until(tester, () => !projects.scanning && !projects.selecting);
      await tester.pumpAndSettle();
      expect(host.starts, 0);
      await tester.tap(find.text('Create project'));
      await tester.pumpAndSettle();
      final nameField = find.descendant(
        of: find.widgetWithText(TextFormField, 'New project name'),
        matching: find.byType(EditableText),
      );
      tester
          .state<EditableTextState>(nameField)
          .updateEditingValue(const TextEditingValue(text: 'sample_app'));
      await tester.tap(find.text('Preview creation'));
      await until(
        tester,
        () => find.text('Run reviewed creation').evaluate().isNotEmpty,
      );
      await tester.pumpAndSettle();
      expect(host.starts, 0);
      expect(await Directory(p.join(root, 'sample_app')).exists(), isFalse);
      expect(find.textContaining('--no-pub'), findsOneWidget);
      await tester.tap(find.text('Run reviewed creation'));
      await until(tester, () => model.activeSession != null);
      final session = model.activeSession!;
      await until(
        tester,
        () => session.status == SessionStatus.exited,
        timeout: const Duration(seconds: 60),
      );
      await session.finished;
      await tester.pumpAndSettle();
      expect(session.exitCode, 0, reason: terminalText(session));
      expect(session.message, isNull);
      expect(host.starts, 1);
      expect(
        await File(p.join(root, 'sample_app', 'lib', 'main.dart')).exists(),
        isTrue,
      );
      expect(
        await directory
            .list()
            .where((v) => p.basename(v.path).startsWith('.tabryo-create-'))
            .isEmpty,
        isTrue,
      );
      expect(find.text('Run reviewed creation'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
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
      clipboard: LocalTextClipboard(),
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
      final nativeWindows = WindowCoordinator();
      runMultiApp(
        home: (_, _) => RepaintBoundary(
          key: boundary,
          child: TabryoApp(
            createViewModel: () => model,
            windows: nativeWindows,
          ),
        ),
        config: MultiAppConfig(
          observers: [nativeWindows],
          generalParams: const MultiPlatformParams(enableDynamicAnchor: false),
        ),
      );
      await until(tester, () => nativeWindows.primary != null);
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

  testWidgets(
    'shared windows move execution and local preview without restarting services',
    (tester) async {
      final temporary = await Directory.systemTemp.createTemp(
        'tabryo-windows-',
      );
      final root = await temporary.resolveSymbolicLinks();
      final cache = PreviewCache();
      final git = LocalGit(
        executable: findExecutable(['git.exe', 'git'])!,
        cache: cache,
      );
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
        editor: EditorViewModel(LocalDocumentFiles(cache)),
        devToolsProfileDirectory: p.join(root, 'webview'),
      );
      final windows = WindowCoordinator();
      final windowEvents = WindowEvents();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requests = <String>[];
      server.listen((request) async {
        requests.add(request.uri.path);
        request.response.headers.contentType = ContentType.html;
        request.response.write(
          '<!doctype html><html><body style="background:#abc"><input id="value" value="initial"><script>window.presentationMarker=41</script></body></html>',
        );
        await request.response.close();
      });
      addTearDown(() async {
        await model.shutdown();
        await server.close(force: true);
        try {
          await temporary.delete(recursive: true);
        } on FileSystemException {
          /* Native profile still closing. */
        }
      });
      runMultiApp(
        home: (_, _) =>
            TabryoApp(createViewModel: () => model, windows: windows),
        config: MultiAppConfig(
          observers: [windows, windowEvents],
          generalParams: const MultiPlatformParams(enableDynamicAnchor: false),
        ),
      );
      await until(tester, () => windows.primary != null);
      await model.openWorkspace(root);
      await model.openTerminal();
      await until(
        tester,
        () => terminalText(model.activeSession!).contains('SHELL_READY'),
      );
      final session = model.activeSession!;
      await tester.pump();
      final terminalState = tester.state(find.byType(TerminalPaneView));
      await tester.tap(find.text('Open execution in window'));
      await until(tester, () => windows.detached.length == 1);
      final execution = windows.detached.single;
      await until(
        tester,
        () => find.byType(TerminalPaneView).evaluate().length == 1,
      );
      expect(
        identical(tester.state(find.byType(TerminalPaneView)), terminalState),
        isTrue,
      );
      expect(host.starts, 1);
      final id = execution.window!;
      await windows.detach(execution);
      expect(execution.window, id);
      final window = MultiViewDesktop.fromId(id);
      await window.setPosition(const Offset(-8000, -8000));
      await windows.recoverPosition(execution);
      expect((await window.getBounds()).left, greaterThan(-8000));
      await window.minimize();
      await tester.pump(const Duration(milliseconds: 500));
      expect(
        await window.isMinimized(),
        isTrue,
        reason: '${windowEvents.events}',
      );
      await until(tester, () => execution.minimized);
      session.terminal.textInput('still running\r');
      await until(
        tester,
        () => terminalText(session).contains('ECHO:still running'),
      );
      await windows.focus(execution);
      await window.closeWindow();
      await until(tester, () => execution.window == null);
      await tester.pump();
      await until(
        tester,
        () => !binding.renderViews.any((view) => view.flutterView.viewId == id),
      );
      // The OS can drain pointer events after the Flutter view has been removed.
      binding.handlePointerEvent(
        PointerAddedEvent(
          viewId: id,
          device: 9001,
          kind: ui.PointerDeviceKind.mouse,
        ),
      );
      binding.handlePointerEvent(
        PointerRemovedEvent(
          viewId: id,
          device: 9001,
          kind: ui.PointerDeviceKind.mouse,
        ),
      );
      expect(
        identical(tester.state(find.byType(TerminalPaneView)), terminalState),
        isTrue,
      );
      expect(host.starts, 1);

      await tester.tap(find.text('Web preview'));
      await tester.pumpAndSettle();
      // Deliver through the actual client, also when Release disables the
      // synthetic test input client -1. Native clipboard input is tested below.
      tester
          .state<EditableTextState>(find.byType(EditableText))
          .updateEditingValue(
            TextEditingValue(text: 'http://127.0.0.1:${server.port}/'),
          );
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Open'))
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Open'));
      await until(
        tester,
        () => find.byType(WinWebViewWidget).evaluate().isNotEmpty,
      );
      final browser = tester
          .widget<WinWebViewWidget>(find.byType(WinWebViewWidget))
          .controller;
      await until(
        tester,
        () => tester
            .state<DevToolsPaneState>(find.byType(DevToolsPane))
            .surfaceVisible,
      );
      await browser.runJavaScript('window.presentationMarker=42');
      await tester.tap(find.byTooltip('Open in window'));
      await until(
        tester,
        () => windows.detached.any(
          (entry) => entry.category == ToolWindow.preview,
        ),
      );
      final preview = windows.detached.singleWhere(
        (entry) => entry.category == ToolWindow.preview,
      );
      await tester.pump();
      expect(
        identical(
          tester
              .widget<WinWebViewWidget>(find.byType(WinWebViewWidget))
              .controller,
          browser,
        ),
        isTrue,
      );
      expect(
        await browser.runJavaScriptReturningResult('window.presentationMarker'),
        42,
      );
      final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
      addTearDown(
        () => Clipboard.setData(ClipboardData(text: clipboard?.text ?? '')),
      );
      if (Platform.isWindows) focusTestWindow();
      await windows.focus(preview);
      await browser.requestFocus();
      await browser.runJavaScript('document.getElementById("value").select()');
      await Clipboard.setData(const ClipboardData(text: 'ação preserved'));
      if (Platform.isWindows) {
        controlKey(0x56);
      } else {
        final focused = await Process.run('xdotool', [
          'getwindowfocus',
          'getwindowpid',
        ]);
        expect('${focused.stdout}'.trim(), '$pid');
        expect((await Process.run('xdotool', ['key', 'ctrl+v'])).exitCode, 0);
      }
      await expectWeb(
        tester,
        browser,
        'document.getElementById("value").value === "ação preserved"',
        true,
      );
      await expectWeb(
        tester,
        browser,
        'typeof window.TabryoEditor === "undefined" && typeof window.tabryoBridge === "undefined"',
        true,
      );
      model.previewPreferences(
        model.preferences.copyWith(theme: AppTheme.dark),
      );
      await tester.pumpAndSettle();
      expect(
        Theme.of(tester.element(find.text(preview.title))).brightness,
        Brightness.dark,
      );
      expect(
        await browser.runJavaScriptReturningResult(
          'document.getElementById("value").value === "ação preserved"',
        ),
        isTrue,
        reason:
            'Preview input after theme: ${await browser.runJavaScriptReturningResult('document.getElementById("value").value')}',
      );
      expect(
        await browser.runJavaScriptReturningResult(
          'getComputedStyle(document.body).backgroundColor === "rgb(170, 187, 204)"',
        ),
        isTrue,
      );
      final returning = windows.reattach(preview);
      await until(tester, () => preview.window == null);
      await tester.pump(const Duration(milliseconds: 300));
      await returning;
      expect(
        await browser.runJavaScriptReturningResult('window.presentationMarker'),
        42,
      );
      expect(requests.where((path) => path == '/'), hasLength(1));
      expect(host.starts, 1);
      expect(model.sessions[session.id], same(session));
      expect(tester.takeException(), isNull);
      debugPrint(
        'Shared windows: ${host.starts} PTY; one preserved browser; one Flutter engine; '
        'display scales ${binding.platformDispatcher.views.map((view) => view.devicePixelRatio).toList()}; '
        'RSS ${ProcessInfo.currentRss ~/ (1024 * 1024)} MiB',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
