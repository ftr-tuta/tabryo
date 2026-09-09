import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../../core/cancellation.dart';
import '../../projects/domain/project.dart';
import '../../projects/infrastructure/local_project_environment.dart';
import '../../tasks/domain/project_task.dart';
import '../../tasks/infrastructure/native_test_results.dart';
import '../domain/game_workspace.dart';

final class LocalGameWorkspace implements GameWorkspaceFiles {
  static const configurationName = '.tabryo/game.json';
  static const initialConfiguration =
      '{\n  "version": 1,\n  "configuration": "Development",\n  "map": "/Game/Maps/Main",\n  "port": 7777,\n  "clients": 2,\n  "testFilter": "Project",\n  "services": [],\n  "assets": [],\n  "versionFiles": []\n}\n';

  Future<void> validateProject(DevelopmentProject project) =>
      LocalProjectEnvironment().validateProject(project);

  @override
  Future<String> checkedPath(
    DevelopmentProject project,
    String relative, {
    bool exists = true,
  }) async {
    final path = p.normalize(p.join(project.directory, gameRelative(relative)));
    if (!p.isWithin(project.directory, path) &&
        !p.equals(project.directory, path)) {
      throw const GameFailure('Path leaves the project.');
    }
    var ancestor = path;
    while (await FileSystemEntity.type(ancestor, followLinks: false) ==
        FileSystemEntityType.notFound) {
      if (exists) throw GameFailure('Project path is unavailable: $relative');
      ancestor = p.dirname(ancestor);
    }
    final type = await FileSystemEntity.type(ancestor, followLinks: false);
    final canonical = type == FileSystemEntityType.directory
        ? await Directory(ancestor).resolveSymbolicLinks()
        : await File(ancestor).resolveSymbolicLinks();
    if (type == FileSystemEntityType.link || !p.equals(canonical, ancestor)) {
      throw const GameFailure('Project paths must not follow links.');
    }
    return path;
  }

  Future<String> read(String path, {int limit = 256 * 1024}) async {
    final file = File(path);
    if ((await file.stat()).type != FileSystemEntityType.file) {
      throw const GameFailure('Expected a regular file.');
    }
    final handle = await file.open();
    try {
      final bytes = await handle.read(limit + 1);
      if (bytes.length > limit) {
        throw GameFailure('File exceeds $limit bytes: ${p.basename(path)}');
      }
      return utf8.decode(bytes);
    } finally {
      await handle.close();
    }
  }

  @override
  Future<GameWorkspace> load(
    DevelopmentProject project,
    Cancellation cancellation,
  ) async {
    await validateProject(project);
    if (!project.native) {
      throw const GameFailure('Select an Unreal or CMake project.');
    }
    final configPath = await checkedPath(
      project,
      configurationName,
      exists: false,
    );
    final source = await File(configPath).exists()
        ? await read(configPath)
        : initialConfiguration;
    final config = GameConfiguration.parse(source);
    final targets = <UnrealTarget>[];
    final modules = <String>[];
    final plugins = <String>[];
    final assets = <GameAsset>[...config.assets];
    var visited = 0;
    var limited = false;
    final queue = <Directory>[Directory(project.directory)];
    while (queue.isNotEmpty) {
      cancellation.check();
      final directory = queue.removeAt(0);
      if (!p.equals(await directory.resolveSymbolicLinks(), directory.path)) {
        continue;
      }
      await for (final entry in directory.list(followLinks: false)) {
        cancellation.check();
        if (++visited > 20000) {
          limited = true;
          break;
        }
        final name = p.basename(entry.path);
        if (entry is Directory &&
            !const {
              '.git',
              '.tabryo',
              'Binaries',
              'Intermediate',
              'Saved',
              'DerivedDataCache',
              'build',
              '.venv',
              'node_modules',
            }.contains(name) &&
            !p.equals(
              entry.path,
              p.join(project.directory, config.buildDirectory),
            )) {
          if (p.split(p.relative(entry.path, from: project.directory)).length <=
              12) {
            queue.add(entry);
          } else {
            limited = true;
          }
        } else if (entry is File) {
          final relative = p.relative(entry.path, from: project.directory);
          if (name.endsWith('.Target.cs') && targets.length < 128) {
            final text = await read(entry.path, limit: 64 * 1024);
            final type = RegExp(
              r'\bType\s*=\s*TargetType\.(Editor|Game|Client|Server|Program)\b',
            ).firstMatch(text)?.group(1);
            if (type != null) {
              targets.add(
                UnrealTarget(
                  name.substring(0, name.length - '.Target.cs'.length),
                  type,
                  relative,
                ),
              );
            }
          } else if (name.endsWith('.Build.cs') && modules.length < 512) {
            modules.add(relative);
          } else if (name.endsWith('.uplugin') && plugins.length < 256) {
            plugins.add(relative);
          } else if (const {
            '.blend',
            '.uasset',
            '.umap',
            '.fbx',
            '.gltf',
            '.glb',
            '.wav',
            '.png',
            '.tga',
          }.contains(p.extension(name).toLowerCase())) {
            if (assets.length < 2000 &&
                !assets.any(
                  (a) =>
                      p.equals(p.join(project.directory, a.path), entry.path),
                )) {
              assets.add(GameAsset(path: relative));
            } else if (assets.length >= 2000) {
              limited = true;
            }
          }
        }
      }
      if (limited && visited > 20000) break;
    }
    targets.sort((a, b) => a.name.compareTo(b.name));
    assets.sort((a, b) => a.path.compareTo(b.path));
    return GameWorkspace(
      project: project,
      configuration: config,
      configurationSource: source,
      targets: List.unmodifiable(targets),
      modules: List.unmodifiable(modules),
      plugins: List.unmodifiable(plugins),
      assets: List.unmodifiable(assets),
      limited: limited,
    );
  }

  @override
  Future<void> save(GameWorkspace workspace, String source) async {
    GameConfiguration.parse(source);
    await validateProject(workspace.project);
    final path = await checkedPath(
      workspace.project,
      configurationName,
      exists: false,
    );
    final file = File(path);
    final baseline = await file.exists()
        ? await read(path)
        : initialConfiguration;
    if (baseline != workspace.configurationSource) {
      throw const GameFailure(
        'Game settings changed on disk. Reload before saving.',
      );
    }
    await file.parent.create(recursive: true);
    await checkedPath(workspace.project, configurationName, exists: false);
    final temporary = File('$path.saving');
    if (await temporary.exists()) {
      throw const GameFailure('A settings save is already pending.');
    }
    await temporary.create(exclusive: true);
    try {
      await temporary.writeAsString(source, flush: true);
      if ((await file.exists() ? await read(path) : initialConfiguration) !=
          baseline) {
        throw const GameFailure('Game settings changed while saving.');
      }
      await temporary.rename(path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  @override
  Future<void> validatePlan(GamePlan plan) async {
    final workspace = plan.workspace;
    final project = workspace.project;
    await validateProject(project);
    final path = await checkedPath(project, configurationName, exists: false);
    if ((await File(path).exists() ? await read(path) : initialConfiguration) !=
        workspace.configurationSource) {
      throw const GameFailure(
        'Settings changed after review. Reload and prepare again.',
      );
    }
    for (final input in {...project.manifests, ...plan.inputPaths}) {
      await checkedPath(project, input);
    }
    for (final output in plan.outputPaths) {
      await checkedPath(project, output, exists: false);
    }
    if (project.kind == ProjectKind.unreal &&
        plan.toolPaths[ProjectTool.unreal] != null) {
      final engine = p.dirname(
        p.dirname(p.dirname(p.dirname(plan.toolPaths[ProjectTool.unreal]!))),
      );
      final versionPath = p.join(engine, 'Engine', 'Build', 'Build.version');
      final version = jsonDecode(await read(versionPath));
      final association = project.versionHint;
      if (version is! Map) {
        throw const GameFailure(
          'Unreal installation is incomplete: Build.version is unavailable.',
        );
      }
      final installed = '${version['MajorVersion']}.${version['MinorVersion']}';
      if (association != null &&
          RegExp(r'^\d+\.\d+$').hasMatch(association) &&
          association != installed) {
        throw GameFailure(
          'This project selects Unreal $association but the chosen engine is $installed. Select the matching engine or upgrade the project in Unreal first.',
        );
      }
    }
    await checkedPath(
      project,
      workspace.configuration.buildDirectory,
      exists: false,
    );
    await checkedPath(
      project,
      workspace.configuration.archiveDirectory,
      exists: false,
    );
    for (final spec in plan.processes) {
      final launch = spec.launch;
      if (!p.isAbsolute(launch.executable) ||
          !await File(launch.executable).exists() ||
          !p.equals(launch.workingDirectory, project.directory)) {
        throw GameFailure('Executable unavailable: ${launch.executable}');
      }
      if (p.isWithin(project.directory, launch.executable)) {
        await checkedPath(
          project,
          p.relative(launch.executable, from: project.directory),
        );
      }
      if (launch.arguments.length > 128 ||
          launch.arguments.any(
            (a) =>
                a.length > 8192 ||
                a.contains('\u0000') ||
                a.contains('\n') ||
                a.contains('\r'),
          )) {
        throw const GameFailure('Invalid process arguments.');
      }
    }
    final report = plan.reportPath;
    if (report != null) {
      await checkedPath(
        project,
        p.relative(report, from: project.directory),
        exists: false,
      );
      if (await FileSystemEntity.type(report, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw const GameFailure(
          'Native report destination already exists. Prepare a fresh run.',
        );
      }
      await Directory(p.dirname(report)).create(recursive: true);
    }
    if (plan.fingerprint != null &&
        await fingerprint(workspace) != plan.fingerprint) {
      throw const GameFailure(
        'Native rules or data changed after laboratory review.',
      );
    }
  }

  @override
  Future<void> verifyOutputs(GamePlan plan) async {
    final path = plan.compilationDatabase;
    if (path == null) return;
    await checkedPath(
      plan.workspace.project,
      p.relative(path, from: plan.workspace.project.directory),
    );
    final value = jsonDecode(await read(path, limit: 64 * 1024 * 1024));
    if (value is! List ||
        value.isEmpty ||
        value.any(
          (entry) =>
              entry is! Map ||
              entry['directory'] is! String ||
              entry['file'] is! String ||
              !(entry['command'] is String || entry['arguments'] is List),
        )) {
      throw const GameFailure(
        'The native tool did not produce a nonempty compilation database. For CMake, select a Ninja or Makefiles preset.',
      );
    }
  }

  /// Hash selected rule inputs plus the actual executable; fail rather than silently
  /// label an incomplete snapshot current. The native response also versions data.
  @override
  Future<String> fingerprint(GameWorkspace workspace) async {
    final config = workspace.configuration;
    if (config.lab == null || config.versionFiles.isEmpty) {
      throw const GameFailure(
        'Configure lab and versionFiles covering the native rules and authoring data.',
      );
    }
    final hashes = <String>[workspace.configurationSource];
    for (final relative in {config.lab!.executable, ...config.versionFiles}) {
      final path = await checkedPath(workspace.project, relative);
      final file = File(path);
      if ((await file.stat()).size > 1024 * 1024 * 1024) {
        throw const GameFailure('A laboratory version input exceeds 1 GiB.');
      }
      hashes.add('$relative:${await sha256.bind(file.openRead()).first}');
    }
    return sha256.convert(utf8.encode(hashes.join('\n'))).toString();
  }

  @override
  Future<TestResults> report(GamePlan plan) async {
    final project = plan.workspace.project;
    final file = project.kind == ProjectKind.unreal
        ? p.join(plan.reportPath!, 'index.json')
        : plan.reportPath!;
    await checkedPath(project, p.relative(file, from: project.directory));
    final source = await read(file, limit: 4 * 1024 * 1024);
    if (project.kind == ProjectKind.cpp) {
      final result = NativeTestResults.parse(source, project, python: true);
      if (result.cases.isEmpty) {
        throw const GameFailure('CTest produced no test cases.');
      }
      return result;
    }
    return unrealReport(source, project);
  }

  static TestResults unrealReport(String source, DevelopmentProject project) {
    final value = jsonDecode(source.replaceFirst('\uFEFF', ''));
    if (value is! Map ||
        value['tests'] is! List ||
        (value['tests'] as List).isEmpty ||
        (value['tests'] as List).length > 10000) {
      throw const GameFailure(
        'Unreal did not produce a complete nonempty Automation report.',
      );
    }
    final cases = <TestCaseResult>[];
    for (final test in value['tests'] as List) {
      if (test is! Map ||
          test['fullTestPath'] is! String ||
          test['state'] is! String) {
        throw const GameFailure('Malformed Unreal Automation case.');
      }
      final outcome = switch (test['state']) {
        'Success' => TestOutcome.passed,
        'Fail' => TestOutcome.failed,
        'Skipped' => TestOutcome.skipped,
        _ => TestOutcome.incomplete,
      };
      final entries = test['entries'];
      final details = entries is List
          ? entries
                .take(50)
                .map((e) => e is Map ? '${e['event']}' : '$e')
                .join('\n')
          : '';
      cases.add(
        TestCaseResult(
          name: test['fullTestPath'] as String,
          outcome: outcome,
          details: details,
        ),
      );
    }
    return TestResults(
      List.unmodifiable(cases),
      complete: cases.every((c) => c.outcome != TestOutcome.incomplete),
      successful:
          cases.every(
            (c) =>
                c.outcome == TestOutcome.passed ||
                c.outcome == TestOutcome.skipped,
          ) &&
          (value['failed'] ?? 0) == 0 &&
          (value['notRun'] ?? 0) == 0,
    );
  }

  @override
  Future<List<String>> assetProblems(
    GameWorkspace workspace,
    GameAsset asset,
  ) async {
    final problems = <String>[];
    for (final relative in [
      asset.path,
      ?asset.source,
      ?asset.exported,
      ?asset.preview,
      ...asset.dependencies,
    ]) {
      try {
        await checkedPath(workspace.project, relative);
      } catch (error) {
        problems.add('$relative: $error');
      }
    }
    return problems;
  }

  @override
  Future<Uint8List> preview(GameWorkspace workspace, GameAsset asset) async {
    final path = await checkedPath(
      workspace.project,
      asset.preview ?? asset.path,
    );
    if (!{
      '.png',
      '.jpg',
      '.jpeg',
      '.webp',
    }.contains(p.extension(path).toLowerCase())) {
      throw const GameFailure(
        'Map preview to a PNG, JPEG or WebP exported by the content tool.',
      );
    }
    final input = await File(path).open();
    try {
      final bytes = await input.read(4 * 1024 * 1024 + 1);
      if (bytes.length > 4 * 1024 * 1024) {
        throw const GameFailure('Asset preview exceeds 4 MiB.');
      }
      return bytes;
    } finally {
      await input.close();
    }
  }
}
