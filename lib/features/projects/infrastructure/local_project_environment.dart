import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../../../core/cancellation.dart';
import '../domain/project.dart';

final class LocalProjectEnvironment implements ProjectEnvironment {
  LocalProjectEnvironment({
    Map<String, String>? environment,
    this.directoryLimit = 512,
  }) : environment = Map.unmodifiable(environment ?? Platform.environment);
  final Map<String, String> environment;
  final int directoryLimit;
  final _creations = <ProjectDestination>{};
  @override
  bool get windows => Platform.isWindows;
  static const _excluded = {
    '.git',
    '.dart_tool',
    '.venv',
    'venv',
    '.fvm',
    '.idea',
    '.vscode',
    '__pycache__',
    'node_modules',
    'build',
    'dist',
    '.tox',
    '.pytest_cache',
    'Binaries',
    'Intermediate',
    'Saved',
    'DerivedDataCache',
    'Content',
  };

  Future<String?> _text(String directory, String name) async {
    final file = File(p.join(directory, name));
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      return null;
    }
    final handle = await file.open();
    try {
      final bytes = await handle.read(64 * 1024 + 1);
      if (bytes.length > 64 * 1024) {
        throw const ProjectFailure('Project manifest exceeds 64 KiB.');
      }
      return utf8.decode(bytes);
    } finally {
      await handle.close();
    }
  }

  @override
  Future<ProjectDiscovery> discover(
    String root,
    Cancellation cancellation,
  ) async {
    if (!p.isAbsolute(root) ||
        !p.equals(await Directory(root).resolveSymbolicLinks(), root)) {
      throw const ProjectFailure(
        'Reopen the workspace at its current location.',
      );
    }
    final queue = <({String directory, int depth})>[
      (directory: root, depth: 0),
    ];
    final projects = <DevelopmentProject>[];
    final warnings = <String>[];
    var limited = false;
    void addProject(DevelopmentProject project) {
      if (projects.length == 64) {
        limited = true;
      } else {
        projects.add(project);
      }
    }

    var entries = 0;
    var visited = 0;
    while (queue.isNotEmpty) {
      cancellation.check();
      if (++visited > directoryLimit ||
          projects.length >= 64 ||
          entries >= 12000) {
        limited = true;
        break;
      }
      final current = queue.removeAt(0);
      // Recheck canonical identity before descending: never follow a replaced link.
      if (!p.equals(
        await Directory(current.directory).resolveSymbolicLinks(),
        current.directory,
      )) {
        continue;
      }
      try {
        final pubspec = await _text(current.directory, 'pubspec.yaml');
        if (pubspec != null) {
          final yaml = loadYaml(pubspec);
          if (yaml is! Map) throw const ProjectFailure('Invalid pubspec.yaml.');
          final dependencies = yaml['dependencies'];
          final devDependencies = yaml['dev_dependencies'];
          final flutter =
              (dependencies is Map && dependencies.containsKey('flutter')) ||
              (devDependencies is Map &&
                  devDependencies.containsKey('flutter_test')) ||
              yaml.containsKey('flutter');
          addProject(
            DevelopmentProject(
              workspace: root,
              directory: current.directory,
              name: yaml['name'] is String
                  ? yaml['name'] as String
                  : p.basename(current.directory),
              kind: flutter ? ProjectKind.flutter : ProjectKind.dart,
              manifests: const ['pubspec.yaml'],
              versionHint: yaml['environment'] is Map
                  ? (yaml['environment']['sdk'] as Object?)?.toString()
                  : null,
            ),
          );
        }
      } catch (error) {
        warnings.add('${current.directory}: $error');
      }
      // A broken Dart manifest must not hide Python in the same directory.
      try {
        final manifests = <String>[];
        String? pyproject;
        for (final name in [
          'pyproject.toml',
          'requirements.txt',
          'setup.py',
          'setup.cfg',
          'manage.py',
          'uv.lock',
          'poetry.lock',
          '.python-version',
        ]) {
          // Lock contents need not be parsed and can be much larger than manifests.
          if (await FileSystemEntity.type(
                p.join(current.directory, name),
                followLinks: false,
              ) ==
              FileSystemEntityType.file) {
            manifests.add(name);
            if (name == 'pyproject.toml') {
              pyproject = await _text(current.directory, name);
            }
          }
        }
        if (manifests.isNotEmpty) {
          final poetry =
              manifests.contains('poetry.lock') ||
              RegExp(
                r'^\s*\[tool\.poetry(?:\]|\.)',
                multiLine: true,
              ).hasMatch(pyproject ?? '');
          final uv =
              manifests.contains('uv.lock') ||
              RegExp(
                r'^\s*\[tool\.uv(?:\]|\.)',
                multiLine: true,
              ).hasMatch(pyproject ?? '');
          if (uv && poetry) {
            warnings.add(
              '${current.directory}: both uv and Poetry are configured; select the intended manager before setup.',
            );
          }
          addProject(
            DevelopmentProject(
              workspace: root,
              directory: current.directory,
              name: p.basename(current.directory),
              kind: ProjectKind.python,
              manager: poetry
                  ? PythonManager.poetry
                  : uv || pyproject != null
                  ? PythonManager.uv
                  : PythonManager.pip,
              manifests: List.unmodifiable(manifests),
              versionHint: (await _text(
                current.directory,
                '.python-version',
              ))?.trim(),
            ),
          );
        }
      } catch (error) {
        warnings.add('${current.directory}: $error');
      }
      // Native manifests are discovered independently of Dart/Python failures.
      try {
        var unreal = false;
        var count = 0;
        await for (final entry in Directory(
          current.directory,
        ).list(followLinks: false)) {
          cancellation.check();
          if (++count > 2000) {
            limited = true;
            break;
          }
          if (entry is! File ||
              p.extension(entry.path).toLowerCase() != '.uproject') {
            continue;
          }
          final name = p.basename(entry.path);
          final manifest = jsonDecode((await _text(current.directory, name))!);
          if (manifest is! Map || manifest['FileVersion'] is! int) {
            throw ProjectFailure('Invalid Unreal project: $name');
          }
          unreal = true;
          addProject(
            DevelopmentProject(
              workspace: root,
              directory: current.directory,
              name: p.basenameWithoutExtension(name),
              kind: ProjectKind.unreal,
              manifests: [name],
              versionHint: manifest['EngineAssociation']?.toString(),
            ),
          );
        }
        if (!unreal &&
            await _text(current.directory, 'CMakeLists.txt') != null) {
          addProject(
            DevelopmentProject(
              workspace: root,
              directory: current.directory,
              name: p.basename(current.directory),
              kind: ProjectKind.cpp,
              manifests: const ['CMakeLists.txt'],
            ),
          );
        }
      } catch (error) {
        if (error is Cancelled) rethrow;
        warnings.add('${current.directory}: $error');
      }
      cancellation.check();
      try {
        await for (final entry in Directory(
          current.directory,
        ).list(followLinks: false)) {
          cancellation.check();
          if (++entries > 12000) {
            limited = true;
            break;
          }
          if (entry is! Directory ||
              _excluded.contains(p.basename(entry.path)) ||
              p.basename(entry.path).startsWith('.tabryo-')) {
            continue;
          }
          if (current.depth >= 6 || queue.length >= directoryLimit) {
            limited = true;
            continue;
          }
          queue.add((directory: entry.path, depth: current.depth + 1));
        }
      } on FileSystemException catch (error) {
        warnings.add('${current.directory}: ${error.message}');
      }
    }
    cancellation.check();
    projects.sort((a, b) => a.directory.compareTo(b.directory));
    return ProjectDiscovery(
      List.unmodifiable(projects),
      limited: limited,
      warnings: List.unmodifiable(warnings),
    );
  }

  Iterable<String> _path(List<String> names) sync* {
    for (var folder in (environment['PATH'] ?? '').split(windows ? ';' : ':')) {
      if (folder.startsWith('"') && folder.endsWith('"')) {
        folder = folder.substring(1, folder.length - 1);
      }
      if (!p.isAbsolute(folder)) continue;
      // Windows Store launch aliases and pyenv shims are not interpreters.
      if (folder.toLowerCase().contains('windowsapps') ||
          p.basename(folder) == 'shims') {
        continue;
      }
      for (final name in names) {
        yield p.join(folder, name);
      }
    }
  }

  String? _fvmVersion(String source) {
    try {
      final configuration = jsonDecode(source);
      final version = configuration is Map ? configuration['flutter'] : null;
      return version is String ? version : null;
    } on FormatException {
      // Invalid optional version metadata does not suppress installed SDKs.
      return null;
    }
  }

  @override
  Future<ToolchainHints> toolchains(DevelopmentProject project) async {
    await validateProject(project);
    final candidates = <ProjectTool, List<ToolchainCandidate>>{};
    Future<void> add(ProjectTool tool, String path, String source) async {
      if (!p.isAbsolute(path)) return;
      path = p.normalize(path);
      final exists = tool == ProjectTool.flutter
          ? await File(p.join(path, 'bin', windows ? 'flutter.bat' : 'flutter'))
                .exists()
          : await File(path).exists();
      if (!exists) return;
      final values = candidates.putIfAbsent(tool, () => []);
      if (!values.any((c) => p.equals(c.path, path))) {
        values.add(ToolchainCandidate(path, source));
      }
    }

    final root = project.directory;
    await add(
      ProjectTool.flutter,
      p.join(root, '.fvm', 'flutter_sdk'),
      'FVM project SDK',
    );
    final fvm = await _text(root, '.fvmrc');
    if (fvm != null) {
      final version = _fvmVersion(fvm);
      final cache = environment['FVM_CACHE_PATH'];
      if (version != null &&
          RegExp(r'^[a-zA-Z0-9_.-]+$').hasMatch(version) &&
          cache != null) {
        await add(
          ProjectTool.flutter,
          p.join(cache, version),
          'FVM pinned version',
        );
      }
    }
    for (final executable in _path(windows ? ['flutter.bat'] : ['flutter'])) {
      if (!await File(executable).exists()) continue;
      final canonical = await File(executable).resolveSymbolicLinks();
      await add(ProjectTool.flutter, p.dirname(p.dirname(canonical)), 'PATH');
    }
    if (environment['FLUTTER_ROOT'] case final root?) {
      await add(ProjectTool.flutter, root, 'FLUTTER_ROOT');
    }
    for (final flutter
        in candidates[ProjectTool.flutter] ?? <ToolchainCandidate>[]) {
      await add(
        ProjectTool.dart,
        p.join(
          flutter.path,
          'bin',
          'cache',
          'dart-sdk',
          'bin',
          windows ? 'dart.exe' : 'dart',
        ),
        flutter.source,
      );
    }
    for (final executable in _path(
      windows ? ['dart.exe', 'dart.bat'] : ['dart'],
    )) {
      if (executable.endsWith('.bat')) continue;
      await add(ProjectTool.dart, executable, 'PATH');
    }
    if (environment['DART_SDK'] case final sdk?) {
      await add(
        ProjectTool.dart,
        p.join(sdk, 'bin', windows ? 'dart.exe' : 'dart'),
        'DART_SDK',
      );
    }
    await add(
      ProjectTool.python,
      p.join(
        root,
        '.venv',
        windows ? 'Scripts' : 'bin',
        windows ? 'python.exe' : 'python',
      ),
      'Project .venv',
    );
    for (final tool in [
      ProjectTool.uv,
      ProjectTool.poetry,
      ProjectTool.ruff,
      ProjectTool.black,
    ]) {
      await add(
        tool,
        p.join(
          root,
          '.venv',
          windows ? 'Scripts' : 'bin',
          windows ? '${tool.name}.exe' : tool.name,
        ),
        'Project .venv',
      );
    }
    final version = (await _text(root, '.python-version'))?.trim();
    final user = environment[windows ? 'USERPROFILE' : 'HOME'];
    final pyenvRoot =
        environment['PYENV_ROOT'] ??
        (user == null
            ? null
            : windows
            ? p.join(user, '.pyenv', 'pyenv-win')
            : p.join(user, '.pyenv'));
    if (version != null &&
        RegExp(r'^[a-zA-Z0-9_.-]+$').hasMatch(version) &&
        pyenvRoot != null) {
      await add(
        ProjectTool.python,
        windows
            ? p.join(pyenvRoot, 'versions', version, 'python.exe')
            : p.join(pyenvRoot, 'versions', version, 'bin', 'python'),
        '.python-version / pyenv',
      );
    }
    if (pyenvRoot != null &&
        await Directory(p.join(pyenvRoot, 'versions')).exists()) {
      var count = 0;
      await for (final entry in Directory(
        p.join(pyenvRoot, 'versions'),
      ).list(followLinks: false)) {
        if (++count > 24) break;
        if (entry is! Directory) continue;
        await add(
          ProjectTool.python,
          windows
              ? p.join(entry.path, 'python.exe')
              : p.join(entry.path, 'bin', 'python'),
          'Installed pyenv ${p.basename(entry.path)}',
        );
      }
    }
    for (final entry in <ProjectTool, List<String>>{
      ProjectTool.python: windows ? ['python.exe'] : ['python3', 'python'],
      ProjectTool.uv: windows ? ['uv.exe'] : ['uv'],
      ProjectTool.poetry: windows ? ['poetry.exe'] : ['poetry'],
      ProjectTool.pyenv: windows ? ['pyenv.bat'] : ['pyenv'],
      ProjectTool.node: windows ? ['node.exe'] : ['node'],
      ProjectTool.ruff: windows ? ['ruff.exe'] : ['ruff'],
      ProjectTool.black: windows ? ['black.exe'] : ['black'],
      ProjectTool.cmake: windows ? ['cmake.exe'] : ['cmake'],
      ProjectTool.git: windows ? ['git.exe'] : ['git'],
      ProjectTool.ctest: windows ? ['ctest.exe'] : ['ctest'],
      ProjectTool.clangd: windows ? ['clangd.exe'] : ['clangd'],
      ProjectTool.lldbDap: windows ? ['lldb-dap.exe'] : ['lldb-dap'],
      ProjectTool.codeLldb: windows ? ['codelldb.exe'] : ['codelldb'],
      ProjectTool.blender: windows ? ['blender.exe'] : ['blender'],
      ProjectTool.unreal: windows ? ['UnrealEditor.exe'] : ['UnrealEditor'],
      ProjectTool.insights: windows
          ? ['UnrealInsights.exe']
          : ['UnrealInsights'],
    }.entries) {
      for (final executable in _path(entry.value)) {
        await add(entry.key, executable, 'PATH');
      }
    }
    await add(
      ProjectTool.pyright,
      p.join(root, 'node_modules', 'pyright', 'dist', 'pyright-langserver.js'),
      'Project node_modules',
    );
    if (environment['UE_ROOT'] case final engine?) {
      await add(
        ProjectTool.unreal,
        p.join(
          engine,
          'Engine',
          'Binaries',
          windows ? 'Win64' : 'Linux',
          windows ? 'UnrealEditor.exe' : 'UnrealEditor',
        ),
        'UE_ROOT',
      );
    }
    if (environment['ProgramFiles'] case final programFiles? when windows) {
      for (final (folder, tool, suffix) in [
        (
          'Epic Games',
          ProjectTool.unreal,
          p.join('Engine', 'Binaries', 'Win64', 'UnrealEditor.exe'),
        ),
        ('Blender Foundation', ProjectTool.blender, 'blender.exe'),
      ]) {
        final parent = Directory(p.join(programFiles, folder));
        if (!await parent.exists()) continue;
        var count = 0;
        await for (final entry in parent.list(followLinks: false)) {
          if (++count > 32) break;
          if (entry is Directory) {
            await add(tool, p.join(entry.path, suffix), 'Installed $folder');
          }
        }
      }
      for (final (tool, name) in [
        (ProjectTool.clangd, 'clangd'),
        (ProjectTool.lldbDap, 'lldb-dap'),
      ]) {
        await add(
          tool,
          p.join(programFiles, 'LLVM', 'bin', '$name.exe'),
          'LLVM installation',
        );
      }
    }
    if (environment['LOCALAPPDATA'] case final local? when windows) {
      await add(
        ProjectTool.codeLldb,
        p.join(
          local,
          'Tabryo',
          'toolchains',
          'codelldb',
          'extension',
          'adapter',
          'codelldb.exe',
        ),
        'Local CodeLLDB adapter',
      );
      for (final (tool, name) in [
        (ProjectTool.clangd, 'clangd'),
        (ProjectTool.lldbDap, 'lldb-dap'),
      ]) {
        await add(
          tool,
          p.join(local, 'Tabryo', 'toolchains', 'llvm', 'bin', '$name.exe'),
          'Local LLVM toolchain',
        );
      }
    }
    if (environment['ProgramFiles(x86)'] case final base? when windows) {
      for (final edition in [
        'BuildTools',
        'Community',
        'Professional',
        'Enterprise',
      ]) {
        final bin = p.join(
          base,
          'Microsoft Visual Studio',
          '2022',
          edition,
          'Common7',
          'IDE',
          'CommonExtensions',
          'Microsoft',
          'CMake',
          'CMake',
          'bin',
        );
        await add(
          ProjectTool.msvcEnvironment,
          p.join(
            base,
            'Microsoft Visual Studio',
            '2022',
            edition,
            'Common7',
            'Tools',
            'VsDevCmd.bat',
          ),
          'Visual Studio $edition compiler and SDK',
        );
        await add(
          ProjectTool.cmake,
          p.join(bin, 'cmake.exe'),
          'Visual Studio $edition',
        );
        await add(
          ProjectTool.ctest,
          p.join(bin, 'ctest.exe'),
          'Visual Studio $edition',
        );
      }
    }
    for (final editor
        in candidates[ProjectTool.unreal] ?? <ToolchainCandidate>[]) {
      await add(
        ProjectTool.insights,
        p.join(
          p.dirname(editor.path),
          windows ? 'UnrealInsights.exe' : 'UnrealInsights',
        ),
        'Unreal engine',
      );
    }
    return ToolchainHints(Map.unmodifiable(candidates));
  }

  @override
  Future<void> validateProject(DevelopmentProject project) async {
    if (!p.isAbsolute(project.workspace) ||
        !p.isAbsolute(project.directory) ||
        !(p.equals(project.workspace, project.directory) ||
            p.isWithin(project.workspace, project.directory)) ||
        !p.equals(
          await Directory(project.workspace).resolveSymbolicLinks(),
          project.workspace,
        ) ||
        !p.equals(
          await Directory(project.directory).resolveSymbolicLinks(),
          project.directory,
        )) {
      throw const ProjectFailure(
        'The project moved or leaves the workspace. Scan it again.',
      );
    }
  }

  @override
  Future<void> validateSelection(ToolchainSelection selection) async {
    for (final entry in selection.paths.entries) {
      final tool = entry.key;
      final path = tool == ProjectTool.flutter
          ? p.join(entry.value, 'bin', windows ? 'flutter.bat' : 'flutter')
          : entry.value;
      if (!p.isAbsolute(path) ||
          !await File(path).exists() ||
          (windows &&
              tool != ProjectTool.flutter &&
              tool != ProjectTool.pyenv &&
              tool != ProjectTool.msvcEnvironment &&
              tool != ProjectTool.pyright &&
              p.extension(path).toLowerCase() != '.exe') ||
          (tool == ProjectTool.pyright &&
              p.extension(path).toLowerCase() != '.js') ||
          (tool == ProjectTool.msvcEnvironment &&
              (!windows || p.basename(path).toLowerCase() != 'vsdevcmd.bat')) ||
          (!windows &&
              tool != ProjectTool.pyright &&
              (await File(path).stat()).mode & 0x49 == 0)) {
        throw ProjectFailure(
          'Select an installed ${tool.name} ${tool == ProjectTool.flutter ? 'SDK directory' : 'executable'}: $path',
        );
      }
    }
    if (selection[ProjectTool.flutter] case final flutter?) {
      final dart = p.join(
        flutter,
        'bin',
        'cache',
        'dart-sdk',
        'bin',
        windows ? 'dart.exe' : 'dart',
      );
      if (!await File(dart).exists()) {
        throw const ProjectFailure(
          'The Flutter SDK is not initialized. Complete its official setup first.',
        );
      }
      if (selection[ProjectTool.dart] case final chosen?) {
        if (!p.equals(
          await File(chosen).resolveSymbolicLinks(),
          await File(dart).resolveSymbolicLinks(),
        )) {
          throw const ProjectFailure(
            'Flutter projects must use the Dart SDK bundled with their selected Flutter SDK.',
          );
        }
      }
    }
  }

  @override
  Future<void> validateCommand(
    DevelopmentProject project,
    ProjectCommand command,
  ) async {
    await validateProject(project);
    if (!p.equals(command.spec.workingDirectory, project.directory) ||
        !p.isAbsolute(command.spec.executable) ||
        !await File(command.spec.executable).exists()) {
      throw const ProjectFailure(
        'The command or selected executable changed. Review setup again.',
      );
    }
    final venv = p.join(project.directory, '.venv');
    if (command.createsEnvironment &&
        await FileSystemEntity.type(venv, followLinks: false) !=
            FileSystemEntityType.notFound) {
      throw const ProjectFailure(
        'The .venv destination already exists. Select it or manage it explicitly in a terminal.',
      );
    }
    if (command.requiresEnvironment) {
      if (!p.equals(await Directory(venv).resolveSymbolicLinks(), venv) ||
          !await File(p.join(venv, 'pyvenv.cfg')).exists() ||
          !await File(
            p.join(
              venv,
              windows ? 'Scripts' : 'bin',
              windows ? 'python.exe' : 'python',
            ),
          ).exists()) {
        throw const ProjectFailure(
          'Create a project-local .venv before installing dependencies.',
        );
      }
    }
  }

  @override
  Future<ProjectDestination> reserveDestination(
    String workspace,
    String name,
  ) async {
    if (!RegExp(r'^[a-z][a-z0-9_]{0,49}$').hasMatch(name) ||
        !p.isAbsolute(workspace) ||
        !p.equals(
          await Directory(workspace).resolveSymbolicLinks(),
          workspace,
        )) {
      throw const ProjectFailure(
        'Choose a current workspace and a lowercase project name (letters, digits, underscores).',
      );
    }
    final destination = p.join(workspace, name);
    if (await FileSystemEntity.type(destination, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const ProjectFailure(
        'The destination already exists. Choose a new name.',
      );
    }
    final staging = await Directory(workspace).createTemp('.tabryo-create-');
    final target = ProjectDestination(
      workspace: workspace,
      staging: staging.path,
      source: p.join(staging.path, name),
      destination: destination,
    );
    _creations.add(target);
    return target;
  }

  @override
  Future<void> finishCreation(
    ProjectCreation creation, {
    required bool publish,
  }) async {
    final target = creation.target;
    if (!_creations.remove(target)) {
      throw const ProjectFailure('This project creation is no longer active.');
    }
    if (!p.equals(
          await Directory(target.workspace).resolveSymbolicLinks(),
          target.workspace,
        ) ||
        !p.equals(
          await Directory(target.staging).resolveSymbolicLinks(),
          target.staging,
        )) {
      throw const ProjectFailure(
        'The creation directory moved. Generated files were retained.',
      );
    }
    if (publish) {
      final manifest = creation.kind == ProjectKind.python
          ? 'pyproject.toml'
          : 'pubspec.yaml';
      if (!p.equals(
            await Directory(target.source).resolveSymbolicLinks(),
            target.source,
          ) ||
          await FileSystemEntity.type(
                p.join(target.source, manifest),
                followLinks: false,
              ) !=
              FileSystemEntityType.file ||
          await FileSystemEntity.type(target.destination, followLinks: false) !=
              FileSystemEntityType.notFound) {
        throw ProjectFailure(
          'The generated project could not be published without overwriting existing content. Files remain at ${target.source}.',
        );
      }
      await Directory(target.source).rename(target.destination);
    }
    // Empty cancelled previews can be removed. Failed generator output is kept.
    try {
      await Directory(target.staging).delete();
    } on FileSystemException {
      if (!publish) {
        throw ProjectFailure(
          'Creation did not finish. Generated files remain at ${target.staging}.',
        );
      }
    }
  }
}
