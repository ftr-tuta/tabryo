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
import 'package:tabryo/features/tasks/application/shared_tasks.dart';
import 'package:tabryo/features/tasks/domain/project_task.dart';
import 'package:tabryo/features/tasks/infrastructure/local_task_files.dart';
import 'package:tabryo/features/tasks/infrastructure/native_test_results.dart';
import 'package:tabryo/features/tasks/infrastructure/native_coverage.dart';
import 'package:tabryo/features/tasks/presentation/tasks_panel.dart';
import 'package:tabryo/features/tasks/presentation/tasks_view_model.dart';
import 'package:tabryo/features/workspaces/presentation/workbench_view_model.dart';

import 'editor_test.dart' show MemoryDocuments;
import 'projects_test.dart' show installedProjectTools;
import 'workbench_test.dart'
    show MemoryHost, MemoryLauncher, MemoryFiles, NoGit, MemoryPreferences;

final class MemoryTaskFiles implements TaskFiles {
  int discarded = 0;
  int configurationReads = 0;
  TaskConfiguration configuration = const TaskConfiguration('', []);
  Completer<void>? validation;
  Completer<TestResults>? reading;
  @override
  Future<TaskConfiguration> readConfiguration(
    DevelopmentProject project,
  ) async {
    configurationReads++;
    return configuration;
  }

  @override
  Future<CoverageResults> readCoverage(
    TaskReport report,
    DevelopmentProject project,
  ) async => const CoverageResults([]);
  @override
  Future<TaskReport> createReport({
    required bool python,
    bool coverage = false,
    bool dartCoverage = false,
  }) async => TaskReport(
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
  ) async => await reading?.future ?? const TestResults([], complete: true);
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
    'shared tasks validate portable paths names fields and bounded arguments',
    () {
      final source = jsonEncode({
        'version': 1,
        'tasks': [
          {
            'name': 'Selective tests',
            'kind': 'test',
            'target': 'test/test_ação.py',
            'filter': 'happy',
            'coverage': true,
          },
          {
            'name': 'Script',
            'kind': 'run',
            'target': 'main.py',
            'arguments': ['a & b', r'$HOME'],
          },
        ],
      });
      final parsed = SharedTasks.parse(source);
      expect(parsed.source, source);
      expect(parsed.tasks.first.coverage, isTrue);
      expect(parsed.tasks.last.arguments, ['a & b', r'$HOME']);
      for (final task in [
        {'name': 'x', 'kind': 'test', 'target': '../outside.py'},
        {'name': 'x', 'kind': 'test', 'target': r'C:\outside.py'},
        {'name': 'x', 'kind': 'test', 'target': '/outside.py'},
        {'name': 'x', 'kind': 'run', 'coverage': true},
        {'name': 'x', 'kind': 'test', 'command': 'whoami'},
        {
          'name': 'x',
          'kind': 'run',
          'environment': {'TOKEN': 'secret'},
        },
        {
          'name': 'x',
          'kind': 'test',
          'arguments': ['--junitxml=escape'],
        },
      ]) {
        expect(
          () => SharedTasks.parse(
            jsonEncode({
              'version': 1,
              'tasks': [task],
            }),
          ),
          throwsFormatException,
        );
      }
      expect(
        () => SharedTasks.parse(
          jsonEncode({
            'version': 1,
            'tasks': [
              {'name': 'duplicate', 'kind': 'test'},
              {'name': 'duplicate', 'kind': 'test'},
            ],
          }),
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'shared configuration changed after review prevents execution',
    () async {
      final file = File(p.join(root, '.tabryo', 'project.json'));
      await file.parent.create();
      await file.writeAsString(SharedTasks.example(project));
      final taskFiles = LocalTaskFiles();
      final tasks = TasksViewModel(taskFiles, windows: Platform.isWindows);
      final tools = ToolchainSelection({
        ProjectTool.python: Platform.resolvedExecutable,
      });
      final projects = ProjectsViewModel(LocalProjectEnvironment())
        ..selections[project.id] = tools;
      final host = MemoryHost(), git = NoGit();
      final model = WorkbenchViewModel(
        host: host,
        launcher: MemoryLauncher(),
        files: MemoryFiles(),
        gitReader: git,
        gitMutator: git,
        preferencesStore: MemoryPreferences(),
        projects: projects,
        tasks: tasks,
      );
      addTearDown(model.disposeAsync);
      await model.openWorkspace(root);
      final config = await taskFiles.readConfiguration(project);
      final task = await tasks.prepare(
        project,
        tools,
        ProjectTaskKind.analyze,
        configuration: config,
      );
      await file.writeAsString('${config.source}\n');
      await expectLater(model.runTask(task), throwsA(isA<ProjectFailure>()));
      expect(host.specs, isEmpty);
      await tasks.discard(task);
      await expectLater(
        tasks.prepare(
          project,
          tools,
          ProjectTaskKind.test,
          configuration: config,
        ),
        throwsA(isA<ProjectFailure>()),
      );
      final fresh = await taskFiles.readConfiguration(project);
      final allowed = await tasks.prepare(
        project,
        tools,
        ProjectTaskKind.analyze,
        configuration: fresh,
      );
      await model.runTask(allowed);
      expect(host.specs, hasLength(1));
      await model.stopTask(allowed);
    },
  );

  test('coverage merges native line hits and rejects inconsistent incomplete or escaping reports', () {
    final report = NativeCoverage.parse(
      'SF:lib/example.dart\nDA:1,2\nDA:2,0\nLF:2\nLH:1\nend_of_record\n'
      'SF:lib/example.dart\nDA:2,3\nend_of_record\n'
      'SF:../outside.dart\nDA:1,1\nend_of_record\n',
      project,
    );
    expect(report.total, 2);
    expect(report.covered, 2);
    expect(report.excludedFiles, 1);
    expect(report.files.single.lines, {1: 2, 2: 3});
    for (final source in [
      '',
      'SF:lib/a.dart\nDA:1,1\n',
      'SF:lib/a.dart\nDA:1,1\nLF:2\nend_of_record\n',
      'SF:lib/a.dart\nDA:1,-1\nend_of_record\n',
      'SF:lib/a.dart\nDA:1,0\nDA:1,1\nend_of_record\n',
    ]) {
      expect(
        () => NativeCoverage.parse(source, project),
        throwsFormatException,
      );
    }
  });

  test('requested coverage failure is visible and removes only owned native outputs', () async {
    final files = LocalTaskFiles();
    final tasks = TasksViewModel(files, windows: Platform.isWindows);
    addTearDown(tasks.disposeAsync);
    final tools = ToolchainSelection({
      ProjectTool.python: Platform.resolvedExecutable,
    });
    final task = await tasks.prepare(
      project,
      tools,
      ProjectTaskKind.test,
      coverage: true,
    );
    await File(
      task.report!.path,
    ).writeAsString('<testsuite tests="1"><testcase name="pass"/></testsuite>');
    await File(task.report!.auxiliaryPaths.single)
        .writeAsString('native coverage data');
    tasks.started(task, 1);
    await tasks.finished(task, 0);
    expect(task.results!.cases.single.outcome, TestOutcome.passed);
    expect(task.status, TaskStatus.failed);
    expect(task.coverageError, contains('Coverage unavailable'));
    expect(await Directory(task.report!.directory).exists(), isFalse);
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
    'concurrent starts in different projects keep the four-task limit',
    () async {
      final projects = ProjectsViewModel(LocalProjectEnvironment());
      final tasks = TasksViewModel(
        MemoryTaskFiles(),
        windows: Platform.isWindows,
      );
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
      );
      addTearDown(model.disposeAsync);
      await model.openWorkspace(root);
      final tools = ToolchainSelection({
        ProjectTool.python: Platform.resolvedExecutable,
      });
      final pending = <ProjectTask>[];
      for (var index = 0; index < 5; index++) {
        final child = await Directory(p.join(root, 'project$index')).create();
        final project = DevelopmentProject(
          workspace: root,
          directory: child.path,
          name: 'project$index',
          kind: ProjectKind.python,
        );
        projects.selections[project.id] = tools;
        final task = await tasks.prepare(
          project,
          tools,
          ProjectTaskKind.analyze,
        );
        if (index < 3) {
          await model.runTask(task);
        } else {
          pending.add(task);
        }
      }
      Future<Object?> start(ProjectTask task) async {
        try {
          await model.runTask(task);
          return null;
        } catch (error) {
          return error;
        }
      }

      final outcomes = await Future.wait(pending.map(start));
      expect(outcomes.whereType<ProjectFailure>(), hasLength(1));
      expect(host.specs, hasLength(4));
      expect(
        tasks.runs.where((t) => t.status == TaskStatus.running),
        hasLength(4),
      );
      for (final task in pending) {
        await tasks.discard(task);
      }
    },
  );

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

  test(
    'a zero exit remains pending until its report has been validated',
    () async {
      final files = MemoryTaskFiles()..reading = Completer<TestResults>();
      final model = TasksViewModel(files, windows: Platform.isWindows);
      addTearDown(model.disposeAsync);
      final task = await model.prepare(
        project,
        ToolchainSelection({ProjectTool.python: Platform.resolvedExecutable}),
        ProjectTaskKind.test,
      );
      model.started(task, 1);
      final finishing = model.finished(task, 0);
      expect(task.status, TaskStatus.running);
      files.reading!.complete(const TestResults([], complete: false));
      await finishing;
      expect(task.status, TaskStatus.failed);
      expect(files.discarded, 1);
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
      await tester.ensureVisible(find.text('Review task'));
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

  testWidgets(
    'shared task loading is explicit and coverage rows navigate to source',
    (tester) async {
      final files = MemoryTaskFiles()
        ..configuration = SharedTasks.parse(
          '{"version":1,"tasks":[{"name":"Team tests","kind":"test"}]}',
        );
      final tasks = TasksViewModel(files, windows: Platform.isWindows);
      final tools = ToolchainSelection({
        ProjectTool.python: Platform.resolvedExecutable,
      });
      var starts = 0;
      TestCaseResult? opened;
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
                onOpen: (_, result) async {
                  opened = result;
                },
              ),
            ),
          ),
        ),
      );
      expect(files.configurationReads, 0);
      expect(starts, 0);
      await tester.ensureVisible(
        find.text('Shared tasks · .tabryo/project.json'),
      );
      await tester.tap(find.text('Shared tasks · .tabryo/project.json'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Load shared tasks'));
      await tester.tap(find.text('Load shared tasks'));
      await tester.pumpAndSettle();
      expect(find.text('Team tests'), findsOneWidget);
      expect(starts, 0);
      await tester.ensureVisible(find.text('Review shared task'));
      await tester.tap(find.text('Review shared task'));
      await tester.pumpAndSettle();
      expect(find.text('Review project task'), findsOneWidget);
      expect(starts, 0);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      final task = await tasks.prepare(project, tools, ProjectTaskKind.analyze);
      task.coverage = CoverageResults([
        CoverageFileResult(p.join(root, 'example.py'), {2: 1, 3: 0}),
      ]);
      tasks.started(task, 1);
      await tasks.finished(task, 0);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.textContaining('Line coverage: 1/2'));
      expect(find.textContaining('50.0%'), findsOneWidget);
      await tester.ensureVisible(find.text('example.py'));
      await tester.tap(find.text('example.py'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Line 3 · 0 hits'));
      await tester.pumpAndSettle();
      expect(opened!.line, 3);
      expect(opened!.path, p.join(root, 'example.py'));
      expect(tester.takeException(), isNull);
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
      coverage: true,
    );
    final passed = await Process.run(
      selected.command.spec.executable,
      selected.command.spec.arguments,
      workingDirectory: root,
      environment: selected.command.spec.environment,
    );
    model.started(selected, 2);
    await model.finished(selected, passed.exitCode);
    expect(selected.status, TaskStatus.passed);
    expect(selected.results!.cases.single.name, 'test_pass');
    expect(selected.coverage!.total, greaterThan(0));
    expect(selected.coverage!.covered, greaterThan(0));
    expect(await File(p.join(root, '.coverage')).exists(), isFalse);
    expect(await Directory(selected.report!.directory).exists(), isFalse);
  }, skip: Platform.environment['TABRYO_TEST_TASKS'] != '1');

  test(
    'installed Dart coverage runs selective native tests and produces navigable line hits',
    () async {
      final tools = await installedProjectTools(root);
      await File(p.join(root, 'pubspec.yaml')).writeAsString(
        'name: coverage_example\nenvironment:\n  sdk: ^3.13.2\ndev_dependencies:\n  test: ^1.25.0\n  coverage: 1.15.1\n',
      );
      final source = File(p.join(root, 'lib', 'example.dart'));
      await source.parent.create();
      await source.writeAsString('int answer() => 42;\n');
      final file = File(p.join(root, 'test', 'example_test.dart'));
      await file.parent.create();
      await file.writeAsString(
        "import 'package:test/test.dart';\nimport 'package:coverage_example/example.dart';\nvoid main() { test('selected', () => expect(answer(), 42)); test('not selected', () => fail('should not run')); }\n",
      );
      final setup = await Process.run(tools[ProjectTool.dart]!, [
        'pub',
        'get',
      ], workingDirectory: root).timeout(const Duration(seconds: 60));
      expect(setup.exitCode, 0, reason: '${setup.stdout}\n${setup.stderr}');
      final dartProject = DevelopmentProject(
        workspace: root,
        directory: root,
        name: 'coverage_example',
        kind: ProjectKind.dart,
      );
      final model = TasksViewModel(
        LocalTaskFiles(),
        windows: Platform.isWindows,
      );
      addTearDown(model.disposeAsync);
      final task = await model.prepare(
        dartProject,
        tools,
        ProjectTaskKind.test,
        target: file.path,
        filter: 'selected',
        coverage: true,
      );
      // The filter is literal substring matching; give the unwanted case a distinct name.
      await file.writeAsString(
        (await file.readAsString()).replaceFirst(
          "'not selected'",
          "'unwanted'",
        ),
      );
      final spec = task.command.spec;
      final result = await Process.run(
        spec.executable,
        spec.arguments,
        workingDirectory: root,
        environment: spec.environment,
      ).timeout(const Duration(seconds: 60));
      model.started(task, 1);
      await model.finished(task, result.exitCode);
      expect(
        task.status,
        TaskStatus.passed,
        reason:
            '${task.error}\n${task.coverageError}\n${result.stdout}\n${result.stderr}',
      );
      expect(task.results!.cases.single.name, 'selected');
      expect(task.coverage!.files.single.path, source.path);
      expect(task.coverage!.covered, greaterThan(0));
      expect(await Directory(task.report!.directory).exists(), isFalse);
    },
    skip: Platform.environment['TABRYO_TEST_TASKS'] != '1',
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
