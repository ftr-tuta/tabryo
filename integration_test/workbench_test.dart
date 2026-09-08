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
        "import 'package:flutter_test/flutter_test.dart';\nvoid main() { test('ação passes', () { expect(1, 1); }); test('failure is visible', () { expect(1, 2); }); }\n",
      );
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
      await model.openTestResult(selected, selected.results!.cases.single);
      expect(editor.active!.path, testFile.path);
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
