import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tabryo/core/cancellation.dart';
import 'package:tabryo/features/editor/presentation/editor_view_model.dart';
import 'package:tabryo/features/projects/domain/project.dart';
import 'package:tabryo/features/projects/infrastructure/local_project_environment.dart';
import 'package:tabryo/features/projects/presentation/projects_view_model.dart';
import 'package:tabryo/features/tasks/application/project_tasks.dart';
import 'package:tabryo/features/tasks/domain/project_task.dart';
import 'package:tabryo/features/tasks/infrastructure/local_task_files.dart';
import 'package:tabryo/features/tasks/infrastructure/native_test_results.dart';
import 'package:tabryo/features/tasks/presentation/tasks_panel.dart';
import 'package:tabryo/features/tasks/presentation/tasks_view_model.dart';
import 'package:tabryo/features/workspaces/presentation/workbench_view_model.dart';

import 'editor_test.dart' show MemoryDocuments;
import 'projects_test.dart' show installedProjectTools;
import 'workbench_test.dart'
    show MemoryHost, MemoryLauncher, MemoryFiles, NoGit, MemoryPreferences;

final class MemoryTaskFiles implements TaskFiles {
  int discarded = 0;
  Completer<void>? validation;
  @override
  Future<TaskReport> createReport({required bool python}) async => TaskReport(
    Directory.systemTemp.path,
    p.join(Directory.systemTemp.path, 'results.xml'),
    python,
  );
  @override
  Future<void> discardReport(TaskReport report) async {
    discarded++;
  }

  @override
  Future<void> validateTarget(DevelopmentProject project, String target) async {
    await validation?.future;
  }

  @override
  Future<TestFileDiscovery> discover(
    DevelopmentProject project,
    List<String> excludedRoots,
    Cancellation cancellation,
  ) async => const TestFileDiscovery([]);
  @override
  Future<TestResults> readReport(
    TaskReport report,
    DevelopmentProject project,
  ) async => const TestResults([], complete: true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late String root;
  late DevelopmentProject project;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('project-tests-');
    root = await directory.resolveSymbolicLinks();
    project = DevelopmentProject(
      workspace: root,
      directory: root,
      name: 'example',
      kind: ProjectKind.python,
    );
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test('discovery excludes dependencies and nested projects and never imports tests', () async {
    for (final path in [
      'test_one.py',
      'nested/test_two.py',
      '.venv/test_ignored.py',
      'child/test_ignored.py',
      'normal.py',
    ]) {
      final file = File(p.join(root, path));
      await file.parent.create(recursive: true);
      await file.writeAsString('raise RuntimeError("must not import")');
    }
    final files = LocalTaskFiles();
    final result = await files.discover(project, [
      p.join(root, 'child'),
    ], Cancellation());
    expect(
      result.paths,
      unorderedEquals([
        p.join(root, 'test_one.py'),
        p.join(root, 'nested', 'test_two.py'),
      ]),
    );
    expect(result.limited, isFalse);
    await expectLater(
      files.validateTarget(project, p.join(root, '..', 'outside.py')),
      throwsA(anything),
    );
    final cancelled = Cancellation()..cancel();
    await expectLater(
      files.discover(project, [], cancelled),
      throwsA(isA<Cancelled>()),
    );
  });

  test('native reports preserve late Dart failures and reject incomplete or hostile reports', () {
    final events = [
      {'type': 'start', 'protocolVersion': '0.1.1'},
      {
        'type': 'suite',
        'suite': {'id': 1, 'path': p.join(root, 'test_one.dart')},
      },
      {
        'type': 'testStart',
        'test': {'id': 2, 'name': 'ação 🌱', 'suiteID': 1, 'line': 7},
      },
      {
        'type': 'testDone',
        'testID': 2,
        'result': 'success',
        'hidden': true,
        'skipped': false,
      },
      {
        'type': 'error',
        'testID': 2,
        'error': 'late failure',
        'stackTrace': 'trace',
      },
      {'type': 'done', 'success': false},
    ];
    String encoded(Iterable<Map> values) => values.map(jsonEncode).join('\n');
    final result = NativeTestResults.parse(
      encoded(events),
      project,
      python: false,
    );
    expect(result.complete, isTrue);
    expect(result.cases.single.outcome, TestOutcome.failed);
    expect(result.cases.single.line, 7);
    expect(result.cases.single.details, contains('late failure'));
    expect(
      NativeTestResults.parse(
        encoded(events.take(5)),
        project,
        python: false,
      ).complete,
      isFalse,
    );
    final junit = NativeTestResults.parse(
      '<testsuites><testsuite tests="2"><testcase name="a" file="test_one.py" line="3"/><testcase name="b" file="../outside.py"><skipped/></testcase></testsuite></testsuites>',
      project,
      python: true,
    );
    expect(junit.complete, isTrue);
    expect(junit.cases.first.line, 4);
    expect(junit.cases.last.path, isNull);
    expect(junit.cases.last.outcome, TestOutcome.skipped);
    expect(
      () => NativeTestResults.parse(
        '<!DOCTYPE x [<!ENTITY a SYSTEM "file:///secret">]><testsuite tests="0"/>',
        project,
        python: true,
      ),
      throwsFormatException,
    );
    expect(
      NativeTestResults.parse(
        '<testsuite tests="1"/>',
        project,
        python: true,
      ).complete,
      isFalse,
    );
  });

  test(
    'runner configuration uses the selected SDK and keeps arguments literal',
    () {
      final tools = ToolchainSelection({
        ProjectTool.python: p.join(root, 'python.exe'),
      });
      final report = TaskReport(root, p.join(root, 'results.xml'), true);
      final planner = ProjectTasks(windows: true);
      final test = planner.prepare(
        project,
        tools,
        ProjectTaskKind.test,
        target: p.join(root, 'test a.py'),
        filter: 'one or two',
        report: report,
      );
      expect(
        test.command.spec.arguments,
        containsAllInOrder([
          '-m',
          'pytest',
          '--color=no',
          '-o',
          'junit_family=xunit1',
          '--junitxml',
          report.path,
          '-k',
          'one or two',
          p.join(root, 'test a.py'),
        ]),
      );
      final run = planner.prepare(
        project,
        tools,
        ProjectTaskKind.run,
        target: p.join(root, 'main.py'),
        arguments: ['hello & goodbye', r'$value', 'ação 🌱'],
      );
      expect(run.command.spec.arguments.last, 'ação 🌱');
      expect(
        () => planner.prepare(project, tools, ProjectTaskKind.build),
        throwsA(isA<ProjectFailure>()),
      );
      expect(
        () => planner.prepare(project, tools, ProjectTaskKind.test),
        throwsA(isA<ProjectFailure>()),
      );
    },
  );

  test('task execution refuses dirty buffers, serializes project commands and marks cancellation', () async {
    final environment = LocalProjectEnvironment();
    final projects = ProjectsViewModel(environment);
    final files = LocalTaskFiles();
    final tasks = TasksViewModel(files, windows: Platform.isWindows);
    final tools = ToolchainSelection({
      ProjectTool.python: Platform.resolvedExecutable,
    });
    projects.selections[project.id] = tools;
    final documents = MemoryDocuments();
    final editor = EditorViewModel(documents);
    final host = MemoryHost();
    final git = NoGit();
    final model = WorkbenchViewModel(
      host: host,
      launcher: MemoryLauncher(),
      files: MemoryFiles(),
      gitReader: git,
      gitMutator: git,
      preferencesStore: MemoryPreferences(),
      projects: projects,
      tasks: tasks,
      editor: editor,
    );
    addTearDown(model.disposeAsync);
    await model.openWorkspace(root);
    final target = p.join(root, 'main.py');
    await File(target).writeAsString('print(1)');
    await editor.open(root, target);
    editor.active!.controller.text = 'changed';
    final task = await tasks.prepare(
      project,
      tools,
      ProjectTaskKind.run,
      target: target,
    );
    expect(host.specs, isEmpty);
    await expectLater(model.runTask(task), throwsA(isA<ProjectFailure>()));
    expect(host.specs, isEmpty);
    await editor.save(editor.active!);
    await model.runTask(task);
    expect(task.status, TaskStatus.running);
    expect(host.specs, hasLength(1));
    final second = await tasks.prepare(
      project,
      tools,
      ProjectTaskKind.run,
      target: target,
    );
    await expectLater(model.runTask(second), throwsA(isA<ProjectFailure>()));
    await tasks.discard(second);
    await model.closeSession(task.sessionId!);
    expect(task.status, TaskStatus.cancelled);
    expect(host.processes.single.closes, 1);
    await expectLater(model.runTask(task), throwsA(isA<ProjectFailure>()));
    final stale = await tasks.prepare(
      project,
      tools,
      ProjectTaskKind.run,
      target: target,
    );
    projects.selections[project.id] = tools.withPath(
      ProjectTool.python,
      p.join(root, 'other.exe'),
    );
    await expectLater(model.runTask(stale), throwsA(isA<ProjectFailure>()));
    await tasks.discard(stale);
  });

  test(
    'missing reports cannot pass and cleanup preserves unexpected files',
    () async {
      final files = LocalTaskFiles();
      final model = TasksViewModel(files, windows: Platform.isWindows);
      addTearDown(model.disposeAsync);
      final tools = ToolchainSelection({
        ProjectTool.python: Platform.resolvedExecutable,
      });
      final missing = await model.prepare(project, tools, ProjectTaskKind.test);
      model.started(missing, 1);
      await model.finished(missing, 0);
      expect(missing.status, TaskStatus.failed);
      expect(missing.error, contains('no readable report'));
      expect(await Directory(missing.report!.directory).exists(), isFalse);
      final changed = await files.createReport(python: true);
      final extra = File(p.join(changed.directory, 'unexpected.txt'));
      await extra.writeAsString('retain');
      addTearDown(() async {
        await extra.delete();
        await files.discardReport(changed);
      });
      await expectLater(
        files.discardReport(changed),
        throwsA(isA<FileSystemException>()),
      );
      expect(await extra.readAsString(), 'retain');
      final failed = await model.prepare(project, tools, ProjectTaskKind.test);
      await File(failed.report!.path).writeAsString(
        '<testsuite tests="1"><testcase name="failed"><failure>error</failure></testcase></testsuite>',
      );
      model.started(failed, 2);
      await model.finished(failed, 0);
      expect(failed.status, TaskStatus.failed);
    },
  );

  test('closing during task preparation discards in-flight reports and caps concurrent reviews', () async {
    final files = MemoryTaskFiles()..validation = Completer<void>();
    final model = TasksViewModel(files, windows: Platform.isWindows);
    final tools = ToolchainSelection({
      ProjectTool.python: Platform.resolvedExecutable,
    });
    final waiting = List.generate(
      4,
      (_) => model.prepare(
        project,
        tools,
        ProjectTaskKind.test,
        target: p.join(root, 'test.py'),
      ),
    );
    final failures = waiting
        .map((value) => expectLater(value, throwsA(isA<ProjectFailure>())))
        .toList();
    await expectLater(
      model.prepare(project, tools, ProjectTaskKind.test),
      throwsA(isA<ProjectFailure>()),
    );
    await model.disposeAsync();
    files.validation!.complete();
    await Future.wait(failures);
    expect(files.discarded, 4);
    expect(model.runs, isEmpty);
  });

  testWidgets(
    'task review cancellation executes nothing and discards its report',
    (tester) async {
      final files = MemoryTaskFiles();
      final tasks = TasksViewModel(files, windows: Platform.isWindows);
      final tools = ToolchainSelection({
        ProjectTool.python: Platform.resolvedExecutable,
      });
      var starts = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: TasksPanel(
                model: tasks,
                project: project,
                projects: [project],
                selection: tools,
                onRun: (_) async {
                  starts++;
                },
                onStop: (_) async {},
                onTerminal: (_) {},
                onOpen: (_, _) async {},
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Review task'));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(find.text('Review project task'), findsOneWidget);
      expect(starts, 0);
      await tester.tap(find.text('Cancel'));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(starts, 0);
      expect(tasks.runs, isEmpty);
      expect(files.discarded, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tasks.disposeAsync();
    },
  );

  test('installed pytest runs a file selection and reports passes failures and skips with source locations', () async {
    final tools = await installedProjectTools(root);
    expect(tools[ProjectTool.python], isNotNull);
    await File(p.join(root, 'test_example.py')).writeAsString(
      'import pytest\ndef test_pass():\n    assert 1 == 1\ndef test_fail():\n    assert 1 == 2\n@pytest.mark.skip(reason="example")\ndef test_skip():\n    pass\n',
    );
    await File(p.join(root, 'test_other.py'))
        .writeAsString('raise RuntimeError("unselected file was imported")');
    final model = TasksViewModel(LocalTaskFiles(), windows: Platform.isWindows);
    addTearDown(model.disposeAsync);
    final task = await model.prepare(
      project,
      tools,
      ProjectTaskKind.test,
      target: p.join(root, 'test_example.py'),
    );
    final spec = task.command.spec;
    final result = await Process.run(
      spec.executable,
      spec.arguments,
      workingDirectory: root,
      environment: spec.environment,
    ).timeout(const Duration(seconds: 30));
    expect(result.exitCode, 1, reason: '${result.stdout}\n${result.stderr}');
    model.started(task, 1);
    await model.finished(task, result.exitCode);
    expect(task.status, TaskStatus.failed);
    expect(task.results!.complete, isTrue);
    expect(
      task.results!.cases.map((v) => v.outcome),
      containsAll([
        TestOutcome.passed,
        TestOutcome.failed,
        TestOutcome.skipped,
      ]),
    );
    expect(
      task.results!.cases.every(
        (v) => v.path == p.join(root, 'test_example.py'),
      ),
      isTrue,
    );
    expect(await Directory(task.report!.directory).exists(), isFalse);
    final selected = await model.prepare(
      project,
      tools,
      ProjectTaskKind.test,
      target: p.join(root, 'test_example.py'),
      filter: 'test_pass',
    );
    final passed = await Process.run(
      selected.command.spec.executable,
      selected.command.spec.arguments,
      workingDirectory: root,
    );
    model.started(selected, 2);
    await model.finished(selected, passed.exitCode);
    expect(selected.status, TaskStatus.passed);
    expect(selected.results!.cases.single.name, 'test_pass');
  }, skip: Platform.environment['TABRYO_TEST_TASKS'] != '1');
}
