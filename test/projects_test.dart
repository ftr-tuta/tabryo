import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tabryo/core/cancellation.dart';
import 'package:tabryo/features/editor/domain/document_formatter.dart';
import 'package:tabryo/features/editor/presentation/editor_view_model.dart';
import 'package:tabryo/features/preferences/domain/preferences.dart';
import 'package:tabryo/features/projects/domain/project.dart';
import 'package:tabryo/features/projects/application/project_setup.dart';
import 'package:tabryo/features/projects/infrastructure/local_project_environment.dart';
import 'package:tabryo/features/projects/presentation/projects_screen.dart';
import 'package:tabryo/features/projects/presentation/projects_view_model.dart';
import 'package:tabryo/features/projects/presentation/project_setup_panel.dart';
import 'package:tabryo/features/workspaces/presentation/workbench_view_model.dart';

import 'editor_test.dart' show MemoryDocuments;
import 'workbench_test.dart'
    show MemoryHost, MemoryLauncher, MemoryFiles, NoGit, MemoryPreferences;

Future<ToolchainSelection> installedProjectTools(String root) async {
  final config = File('.dart_tool/package_config.json').absolute;
  final packages =
      (jsonDecode(await config.readAsString()) as Map)['packages'] as List;
  final flutterPackage = packages.cast<Map>().firstWhere(
    (v) => v['name'] == 'flutter',
  );
  final flutter = p.dirname(
    p.dirname(
      config.uri.resolve(flutterPackage['rootUri'] as String).toFilePath(),
    ),
  );
  final project = DevelopmentProject(
    workspace: root,
    directory: root,
    name: 'example',
    kind: ProjectKind.python,
  );
  final hints = await LocalProjectEnvironment().toolchains(project);
  return ToolchainSelection({
    ProjectTool.dart: p.join(
      flutter,
      'bin',
      'cache',
      'dart-sdk',
      'bin',
      Platform.isWindows ? 'dart.exe' : 'dart',
    ),
    ProjectTool.flutter: flutter,
    for (final tool in [ProjectTool.python, ProjectTool.uv, ProjectTool.poetry])
      tool:
          ?Platform.environment['TABRYO_TEST_${tool.name.toUpperCase()}'] ??
          hints.candidates[tool]?.firstOrNull?.path,
  });
}

Future<void> runSetupCommand(ProjectCommand command) async {
  final spec = command.spec;
  final variables = {...Platform.environment}
    ..removeWhere((name, _) => spec.unsetEnvironment.contains(name));
  final process = await Process.start(
    spec.executable,
    spec.arguments,
    workingDirectory: spec.workingDirectory,
    environment: {...variables, ...spec.environment},
    includeParentEnvironment: false,
  );
  final output = process.stdout.transform(utf8.decoder).join();
  final errors = process.stderr.transform(utf8.decoder).join();
  try {
    final result = await process.exitCode.timeout(const Duration(seconds: 60));
    expect(result, 0, reason: '${await output}\n${await errors}');
  } finally {
    process.kill();
    await process.exitCode;
  }
}

final class RecordingFormatter implements DocumentFormatter {
  final calls = <({String executable, String root})>[];
  @override
  Future<FormattedDocument> format({
    required String executable,
    required String root,
    required String path,
    required String text,
    required int start,
    required int end,
  }) async {
    calls.add((executable: executable, root: root));
    return FormattedDocument(text, start, end);
  }

  @override
  void close() {}
}

final class PendingProjects implements ProjectEnvironment {
  final reads = <String, Completer<ProjectDiscovery>>{};
  @override
  bool get windows => Platform.isWindows;
  @override
  Future<ProjectDiscovery> discover(String root, Cancellation cancellation) =>
      (reads[root] = Completer<ProjectDiscovery>()).future;
  @override
  Future<ToolchainHints> toolchains(DevelopmentProject project) async =>
      const ToolchainHints({});
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory temporary;
  late String root;
  Future<File> file(String name, [String content = '']) async {
    final file = File(p.join(root, name));
    await file.parent.create(recursive: true);
    return file.writeAsString(content);
  }

  Future<String> executable(String name) async {
    final path = (await file(name)).path;
    if (!Platform.isWindows) {
      expect((await Process.run('chmod', ['+x', path])).exitCode, 0);
    }
    return path;
  }

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('development-projects-');
    root = await temporary.resolveSymbolicLinks();
  });
  tearDown(() async {
    await temporary.delete(recursive: true);
  });

  test(
    'official Dart creation publishes only a successful new destination',
    () async {
      final environment = LocalProjectEnvironment();
      final setup = ProjectSetup(environment);
      final tools = await installedProjectTools(root);
      final preview = await setup.prepareCreation(
        root,
        'example_cli',
        ProjectKind.dart,
        tools,
      );
      expect(await Directory(preview.target.destination).exists(), isFalse);
      await runSetupCommand(preview.command);
      await environment.finishCreation(preview, publish: true);
      expect(
        await File(p.join(root, 'example_cli', 'pubspec.yaml')).exists(),
        isTrue,
      );
      expect(await Directory(preview.target.staging).exists(), isFalse);
      await expectLater(
        setup.prepareCreation(root, 'example_cli', ProjectKind.dart, tools),
        throwsA(isA<ProjectFailure>()),
      );
      final cancelled = await setup.prepareCreation(
        root,
        'cancelled',
        ProjectKind.dart,
        tools,
      );
      await environment.finishCreation(cancelled, publish: false);
      expect(await Directory(cancelled.target.staging).exists(), isFalse);
      final racing = await setup.prepareCreation(
        root,
        'racing',
        ProjectKind.dart,
        tools,
      );
      await File(p.join(racing.target.source, 'pubspec.yaml'))
          .create(recursive: true);
      await file('racing/existing.txt', 'keep');
      await expectLater(
        environment.finishCreation(racing, publish: true),
        throwsA(isA<ProjectFailure>()),
      );
      expect(
        await File(p.join(root, 'racing', 'existing.txt')).readAsString(),
        'keep',
      );
      expect(await Directory(racing.target.source).exists(), isTrue);
    },
  );

  test(
    'native Flutter and Python setup use the selected tools and project environments',
    () async {
      final environment = LocalProjectEnvironment();
      final setup = ProjectSetup(environment);
      final tools = await installedProjectTools(root);
      for (final tool in [
        ProjectTool.python,
        ProjectTool.uv,
        ProjectTool.poetry,
      ]) {
        expect(
          tools[tool],
          isNotNull,
          reason: 'The native setup gate requires ${tool.name}.',
        );
      }
      final flutter = await setup.prepareCreation(
        root,
        'mobile_app',
        ProjectKind.flutter,
        tools,
      );
      await runSetupCommand(flutter.command);
      await environment.finishCreation(flutter, publish: true);
      expect(
        await File(p.join(flutter.target.destination, 'lib', 'main.dart'))
            .exists(),
        isTrue,
      );
      final python = await setup.prepareCreation(
        root,
        'python_app',
        ProjectKind.python,
        tools,
      );
      await runSetupCommand(python.command);
      await environment.finishCreation(python, publish: true);
      final pythonProject = (await environment.discover(
        root,
        Cancellation(),
      )).projects.singleWhere((v) => v.directory == python.target.destination);
      final commands = setup.commands(pythonProject, tools);
      final create = commands.firstWhere((v) => v.createsEnvironment);
      await environment.validateCommand(pythonProject, create);
      await runSetupCommand(create);
      await expectLater(
        environment.validateCommand(pythonProject, create),
        throwsA(isA<ProjectFailure>()),
      );
      final sync = commands.firstWhere(
        (v) => v.title == 'Sync uv dependencies',
      );
      await environment.validateCommand(pythonProject, sync);
      await runSetupCommand(sync);
      expect(
        await File(p.join(pythonProject.directory, 'uv.lock')).exists(),
        isTrue,
      );
      await file(
        'poetry_project/pyproject.toml',
        '[tool.poetry]\nname = "poetry-project"\nversion = "0.1.0"\npackage-mode = false\n[tool.poetry.dependencies]\npython = "^3.12"\n',
      );
      final poetryProject = (await environment.discover(
        root,
        Cancellation(),
      )).projects.singleWhere((v) => v.directory.endsWith('poetry_project'));
      final poetryCommands = setup.commands(poetryProject, tools);
      await environment.validateCommand(poetryProject, poetryCommands.first);
      await runSetupCommand(poetryCommands.first);
      final install = poetryCommands.singleWhere(
        (v) => v.title == 'Install Poetry dependencies',
      );
      await environment.validateCommand(poetryProject, install);
      await runSetupCommand(install);
      expect(
        await File(p.join(poetryProject.directory, '.venv', 'pyvenv.cfg'))
            .exists(),
        isTrue,
      );
      expect(
        await File(p.join(poetryProject.directory, 'poetry.lock')).exists(),
        isTrue,
      );
      await file('poetry_project/requirements.txt');
      final pipProject = (await environment.discover(
        root,
        Cancellation(),
      )).projects.singleWhere((v) => v.directory == poetryProject.directory);
      final pip = setup
          .commands(pipProject, tools, pythonManager: PythonManager.pip)
          .singleWhere((v) => v.title == 'Install Python requirements');
      await environment.validateCommand(pipProject, pip);
      await runSetupCommand(pip);
    },
    skip: Platform.environment['TABRYO_TEST_PROJECT_SETUP'] != '1',
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test('setup refuses dirty buffers, serializes commands and cleans process ownership', () async {
    await file('pubspec.yaml', 'name: example\n');
    final dart = await executable(Platform.isWindows ? 'dart.exe' : 'dart');
    final projects = ProjectsViewModel(
      LocalProjectEnvironment(environment: {}),
    );
    await projects.scan(root);
    final documents = EditorViewModel(MemoryDocuments())..selectWorkspace(root);
    await documents.open(root, p.join(root, 'main.dart'));
    documents.active!.controller.text = 'unsaved';
    final host = MemoryHost();
    final git = NoGit();
    final model = WorkbenchViewModel(
      host: host,
      launcher: MemoryLauncher(),
      files: MemoryFiles(),
      gitReader: git,
      gitMutator: git,
      preferencesStore: MemoryPreferences(),
      editor: documents,
      projects: projects,
    );
    await model.openWorkspace(root);
    final project = projects.selected!;
    final command = projects.setup
        .commands(project, ToolchainSelection({ProjectTool.dart: dart}))
        .single;
    await expectLater(
      model.runProjectCommand(project, command),
      throwsA(isA<ProjectFailure>()),
    );
    expect(host.specs, isEmpty);
    await documents.save(documents.active!);
    await model.runProjectCommand(project, command);
    await expectLater(
      model.runProjectCommand(project, command),
      throwsA(isA<ProjectFailure>()),
    );
    expect(host.specs, hasLength(1));
    await model.closeSession(model.sessions.keys.single);
    await model.runProjectCommand(project, command);
    expect(host.specs, hasLength(2));
    await model.shutdown();
    expect(host.processes.every((v) => v.ended), isTrue);
  });

  test('official MCP draft follows the selected Flutter SDK without starting a command', () async {
    await file(
      'pubspec.yaml',
      'name: example\ndependencies:\n  flutter:\n    sdk: flutter\n',
    );
    final sdk = p.join(root, 'sdk');
    await executable(
      p.join('sdk', 'bin', Platform.isWindows ? 'flutter.bat' : 'flutter'),
    );
    final dart = await executable(
      p.join(
        'sdk',
        'bin',
        'cache',
        'dart-sdk',
        'bin',
        Platform.isWindows ? 'dart.exe' : 'dart',
      ),
    );
    final projects = ProjectsViewModel(
      LocalProjectEnvironment(environment: {}),
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
    );
    addTearDown(model.shutdown);
    await model.openWorkspace(root);
    await projects.scan(root);
    final project = projects.selected!;
    projects.selections[project.id] = ToolchainSelection({
      ProjectTool.flutter: sdk,
    });
    final draft = await model.dartFlutterMcpDraft();
    expect(draft.command, dart);
    expect(draft.arguments, [
      'mcp-server',
      '--dart-sdk',
      p.dirname(p.dirname(dart)),
      '--flutter-sdk',
      sdk,
    ]);
    expect(draft.workingDirectory, root);
    expect(host.specs, isEmpty);
    projects.selections[project.id] = ToolchainSelection();
    await expectLater(
      model.dartFlutterMcpDraft(),
      throwsA(isA<ProjectFailure>()),
    );
    expect(host.specs, isEmpty);
  });

  testWidgets('setup shows its exact command and cancellation starts nothing', (
    tester,
  ) async {
    final environment = PendingProjects();
    final model = ProjectsViewModel(environment);
    final project = DevelopmentProject(
      workspace: root,
      directory: root,
      name: 'example',
      kind: ProjectKind.dart,
    );
    model.selected = project;
    model.selections[project.id] = ToolchainSelection({
      ProjectTool.dart: p.join(root, 'dart.exe'),
    });
    final commands = <ProjectCommand>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProjectSetupPanel(
            model: model,
            project: project,
            onRun: (_, command) async {
              commands.add(command);
            },
          ),
        ),
      ),
    );
    await tester.tap(find.text('Review and run'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Arguments: ["pub","get"]'), findsOneWidget);
    expect(commands, isEmpty);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(commands, isEmpty);
    await tester.tap(find.text('Review and run'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Run reviewed command'));
    await tester.pumpAndSettle();
    expect(commands, hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
    await model.disposeAsync();
  });

  test('discovers mixed nested projects with bounded manifests and no tool execution', () async {
    await file('pubspec.yaml', 'name: tools\nenvironment:\n  sdk: ^3.13.0\n');
    await file('pyproject.toml', '[project]\nname = "api"\n');
    await file(
      'app/pubspec.yaml',
      'name: mobile\ndependencies:\n  flutter:\n    sdk: flutter\n',
    );
    await file('backend/pyproject.toml', '[tool.poetry]\nname = "backend"\n');
    await file('backend/poetry.lock');
    await file('backend/.python-version', '3.12.10\n');
    await file('legacy/requirements.txt', 'django\n');
    await file(
      'legacy/setup.py',
      'raise RuntimeError("must never execute during discovery")',
    );
    await file('broken/pubspec.yaml', '[broken');
    await file('broken/requirements.txt', '');
    await file('node_modules/hidden/pubspec.yaml', 'name: ignored');
    await file('.venv/site-packages/pyproject.toml');
    final environment = LocalProjectEnvironment(environment: {});
    final result = await environment.discover(root, Cancellation());
    expect(result.projects, hasLength(6));
    expect(result.projects.where((v) => v.directory == root), hasLength(2));
    expect(result.projects.map((v) => v.id).toSet(), hasLength(6));
    expect(
      result.projects.singleWhere((v) => v.directory.endsWith('broken')).kind,
      ProjectKind.python,
    );
    expect(
      result.projects.singleWhere((v) => v.name == 'mobile').kind,
      ProjectKind.flutter,
    );
    expect(
      result.projects
          .singleWhere((v) => v.directory.endsWith('backend'))
          .manager,
      PythonManager.poetry,
    );
    expect(
      result.projects
          .singleWhere((v) => v.directory.endsWith('legacy'))
          .manager,
      PythonManager.pip,
    );
    expect(result.warnings, hasLength(1));
    expect(result.limited, isFalse);
    final bounded = await LocalProjectEnvironment(
      environment: {},
      directoryLimit: 1,
    ).discover(root, Cancellation());
    expect(bounded.limited, isTrue);
    await expectLater(
      environment.discover(root, Cancellation()..cancel()),
      throwsA(isA<Cancelled>()),
    );
  });

  test('mixed project pairs cannot exceed the discovery limit', () async {
    await file('pubspec.yaml', 'name: root_project\n');
    for (var index = 0; index < 32; index++) {
      await file('project_$index/pubspec.yaml', 'name: project_$index\n');
      await file('project_$index/requirements.txt');
    }
    final result = await LocalProjectEnvironment(environment: {})
        .discover(root, Cancellation());
    expect(result.projects, hasLength(64));
    expect(result.limited, isTrue);
  });

  test(
    'toolchain hints retain venv identity, FVM and pinned pyenv versions',
    () async {
      await file('pubspec.yaml', 'name: app\nflutter:\n');
      await file('.fvmrc', '[]');
      final flutter = p.join(root, '.fvm', 'flutter_sdk');
      await executable(
        p.join(
          '.fvm',
          'flutter_sdk',
          'bin',
          Platform.isWindows ? 'flutter.bat' : 'flutter',
        ),
      );
      final dart = await executable(
        p.join(
          '.fvm',
          'flutter_sdk',
          'bin',
          'cache',
          'dart-sdk',
          'bin',
          Platform.isWindows ? 'dart.exe' : 'dart',
        ),
      );
      final python = await executable(
        p.join(
          '.venv',
          Platform.isWindows ? 'Scripts' : 'bin',
          Platform.isWindows ? 'python.exe' : 'python',
        ),
      );
      await file('.python-version', '3.12.10');
      final pyenvPython = await executable(
        Platform.isWindows
            ? p.join('pyenv', 'versions', '3.12.10', 'python.exe')
            : p.join('pyenv', 'versions', '3.12.10', 'bin', 'python'),
      );
      final environment = LocalProjectEnvironment(
        environment: {'PYENV_ROOT': p.join(root, 'pyenv')},
      );
      final project = (await environment.discover(
        root,
        Cancellation(),
      )).projects.first;
      final hints = await environment.toolchains(project);
      expect(hints.candidates[ProjectTool.flutter]!.first.path, flutter);
      expect(hints.candidates[ProjectTool.dart]!.first.path, dart);
      expect(hints.candidates[ProjectTool.python]!.first.path, python);
      expect(
        hints.candidates[ProjectTool.python]!.map((v) => v.path),
        contains(pyenvPython),
      );
      final model = ProjectsViewModel(environment);
      await model.scan(root);
      await model.select(
        model.discovery.projects.firstWhere(
          (v) => v.kind == ProjectKind.flutter,
        ),
      );
      final choice = await model.apply(
        model.selected!,
        ToolchainSelection({ProjectTool.flutter: flutter}),
      );
      expect(choice![ProjectTool.dart], dart);
      final prefs = Preferences(
        rememberPreferences: true,
        projectToolchains: {model.selected!.id: choice},
      );
      expect(
        Preferences.fromJson(prefs.toJson())
            .projectToolchains[model.selected!.id]![ProjectTool.flutter],
        flutter,
      );
      expect(
        Preferences.fromJson(
          prefs.copyWith(rememberPreferences: false).toJson(),
        ).projectToolchains,
        isEmpty,
      );
      expect(
        (await model.apply(model.selected!, ToolchainSelection()))!.paths,
        isEmpty,
      );
      await model.disposeAsync();
    },
  );

  test('late discovery cannot replace another workspace selection', () async {
    final environment = PendingProjects();
    final model = ProjectsViewModel(environment);
    final first = model.scan('first');
    final second = model.scan('second');
    final current = DevelopmentProject(
      workspace: 'second',
      directory: 'second',
      name: 'current',
      kind: ProjectKind.dart,
    );
    environment.reads['second']!.complete(ProjectDiscovery([current]));
    await second;
    environment.reads['first']!.complete(const ProjectDiscovery([]));
    await first;
    expect(model.workspace, 'second');
    expect(model.selected, current);
    await model.disposeAsync();
  });

  test('Dart formatting uses the closest selected project inside the authorized workspace', () async {
    final formatter = RecordingFormatter();
    final model = EditorViewModel(MemoryDocuments(), formatter: formatter)
      ..selectWorkspace(root);
    final nested = p.join(root, 'app');
    model.dartFormatters = {root: 'root-sdk', nested: 'app-sdk'};
    await model.open(root, p.join(nested, 'main.dart'));
    model.active!.controller.text = 'app edits';
    expect(await model.save(model.active!), isTrue);
    expect(formatter.calls.last, (executable: 'app-sdk', root: nested));
    await model.open(root, p.join(root, 'script.dart'));
    model.active!.controller.text = 'root edits';
    expect(await model.save(model.active!), isTrue);
    expect(formatter.calls.last, (executable: 'root-sdk', root: root));
    model.dartFormatters = {root: 'root-sdk', nested: ''};
    await model.open(root, p.join(nested, 'no_format.dart'));
    model.active!.controller.text = 'formatting explicitly disabled';
    expect(await model.save(model.active!), isTrue);
    expect(formatter.calls, hasLength(2));
    model.dartFormatters = {root: 'root-sdk'};
    model.selectWorkspace(nested);
    await model.open(nested, p.join(nested, 'separate.dart'));
    model.active!.controller.text = 'separate workspace';
    expect(await model.save(model.active!), isTrue);
    expect(formatter.calls, hasLength(2));
    await model.disposeAsync();
  });

  testWidgets(
    'project choices are explicit and scoped to the selected project',
    (tester) async {
      final model = ProjectsViewModel(
        LocalProjectEnvironment(environment: {'PATH': root}),
      );
      final dart = (await tester.runAsync(() async {
        await file('pubspec.yaml', 'name: example\n');
        final dart = await executable(Platform.isWindows ? 'dart.exe' : 'dart');
        await model.scan(root);
        return dart;
      }))!;
      final applied = <ToolchainSelection>[];
      Future<void>? applying;
      await tester.pumpWidget(
        MaterialApp(
          home: ProjectsScreen(
            model: model,
            onApply: (project, selection) => applying = () async {
              applied.add((await model.apply(project, selection))!);
            }(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(applied, isEmpty);
      expect(model.selections, isEmpty);
      await tester.tap(find.widgetWithText(ActionChip, 'PATH'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, dart), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.text('Apply toolchains'));
        await applying!.timeout(const Duration(seconds: 5));
      });
      await tester.pumpAndSettle();
      expect(applied.single[ProjectTool.dart], dart);
      await tester.pumpWidget(const SizedBox.shrink());
      await model.disposeAsync();
    },
  );
}
