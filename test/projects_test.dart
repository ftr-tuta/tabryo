import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tabryo/core/cancellation.dart';
import 'package:tabryo/features/editor/domain/document_formatter.dart';
import 'package:tabryo/features/editor/presentation/editor_view_model.dart';
import 'package:tabryo/features/preferences/domain/preferences.dart';
import 'package:tabryo/features/projects/domain/project.dart';
import 'package:tabryo/features/projects/infrastructure/local_project_environment.dart';
import 'package:tabryo/features/projects/presentation/projects_screen.dart';
import 'package:tabryo/features/projects/presentation/projects_view_model.dart';

import 'editor_test.dart' show MemoryDocuments;

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
    await file('node_modules/hidden/pubspec.yaml', 'name: ignored');
    await file('.venv/site-packages/pyproject.toml');
    final environment = LocalProjectEnvironment(environment: {});
    final result = await environment.discover(root, Cancellation());
    expect(result.projects, hasLength(5));
    expect(result.projects.where((v) => v.directory == root), hasLength(2));
    expect(result.projects.map((v) => v.id).toSet(), hasLength(5));
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

  test(
    'toolchain hints retain venv identity, FVM and pinned pyenv versions',
    () async {
      await file('pubspec.yaml', 'name: app\nflutter:\n');
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
