import 'package:path/path.dart' as p;

import '../../terminals/domain/terminal_ports.dart';
import '../domain/project.dart';

/// Reviewable native commands. Construction never executes a project or tool.
final class ProjectSetup {
  const ProjectSetup(this.environment);
  final ProjectEnvironment environment;

  String pythonEnvironment(String directory) => p.join(
    directory,
    '.venv',
    environment.windows ? 'Scripts' : 'bin',
    environment.windows ? 'python.exe' : 'python',
  );

  List<ProjectCommand> commands(
    DevelopmentProject project,
    ToolchainSelection tools, {
    PythonManager? pythonManager,
  }) {
    final directory = project.directory;
    final venv = p.join(directory, '.venv');
    final python = pythonEnvironment(directory);
    final overrides = <String, String>{
      'PYTHONNOUSERSITE': '1',
      'PIP_DISABLE_PIP_VERSION_CHECK': '1',
      'UV_PROJECT_ENVIRONMENT': venv,
      'UV_PYTHON_DOWNLOADS': 'never',
      'PIP_CONFIG_FILE': environment.windows ? 'NUL' : '/dev/null',
      'POETRY_VIRTUALENVS_IN_PROJECT': 'true',
    };
    const unset = [
      'VIRTUAL_ENV',
      'CONDA_PREFIX',
      'PYTHONHOME',
      'PYTHONPATH',
      'PIP_TARGET',
      'PIP_PREFIX',
      'PIP_USER',
      'UV_PYTHON',
      'UV_PYTHON_INSTALL_DIR',
      'UV_WORKING_DIR',
      'UV_PROJECT',
      'UV_SYSTEM_PYTHON',
      'UV_TARGET',
      'UV_PREFIX',
    ];
    ProjectCommand command(
      String title,
      String description,
      String executable,
      List<String> arguments, {
      bool needsVenv = false,
      bool createsVenv = false,
      Map<String, String> extra = const {},
    }) => ProjectCommand(
      title: title,
      description: description,
      requiresEnvironment: needsVenv,
      createsEnvironment: createsVenv,
      spec: LaunchSpec(
        executable: executable,
        workingDirectory: directory,
        arguments: List.unmodifiable(arguments),
        environment: project.kind == ProjectKind.python
            ? Map.unmodifiable({...overrides, ...extra})
            : const {},
        unsetEnvironment: project.kind == ProjectKind.python
            ? unset.where((name) => !extra.containsKey(name)).toList()
            : const [],
      ),
    );
    final commands = <ProjectCommand>[];
    if (tools[ProjectTool.dart] case final dart?
        when project.kind == ProjectKind.dart) {
      commands.add(
        command(
          'Get Dart dependencies',
          'Downloads packages and updates pubspec.lock using the selected SDK.',
          dart,
          ['pub', 'get'],
        ),
      );
    }
    if (tools[ProjectTool.flutter] case final flutter?
        when project.kind == ProjectKind.flutter) {
      commands.add(
        command(
          'Get Flutter dependencies',
          'Downloads packages and updates pubspec.lock using the selected Flutter SDK.',
          p.join(
            flutter,
            'bin',
            environment.windows ? 'flutter.bat' : 'flutter',
          ),
          ['pub', 'get'],
        ),
      );
    }
    if (project.kind != ProjectKind.python) return commands;
    final manager = pythonManager ?? project.manager;
    final interpreter = tools[ProjectTool.python];
    final uv = tools[ProjectTool.uv];
    if (interpreter != null) {
      if (manager == PythonManager.uv && uv != null) {
        commands.add(
          command(
            'Create Python environment',
            'Creates $venv with the selected interpreter. Existing destinations are refused.',
            uv,
            ['venv', '--python', interpreter, venv],
            createsVenv: true,
          ),
        );
      } else {
        commands.add(
          command(
            'Create Python environment',
            'Creates $venv with the selected interpreter and pip. Existing destinations are refused.',
            interpreter,
            ['-m', 'venv', venv],
            createsVenv: true,
          ),
        );
      }
    }
    switch (manager) {
      case PythonManager.uv:
        if (uv == null) {
          commands.add(
            command(
              'Install uv in the project environment',
              'Installs uv inside $venv using pip. Then scan and choose its executable.',
              python,
              ['-m', 'pip', 'install', '--require-virtualenv', 'uv'],
              needsVenv: true,
            ),
          );
        }
        if (uv != null) {
          if (project.manifests.contains('pyproject.toml')) {
            commands.add(
              command(
                'Sync uv dependencies',
                'Synchronizes the project .venv, which may remove packages absent from its lock. Package builds can execute code.',
                uv,
                [
                  'sync',
                  '--project',
                  directory,
                  '--python',
                  python,
                  if (project.manifests.contains('uv.lock')) '--locked',
                ],
                needsVenv: true,
              ),
            );
          } else if (project.manifests.contains('requirements.txt')) {
            commands.add(
              command(
                'Install requirements with uv',
                'Installs requirements.txt into $venv. Package builds can execute code.',
                uv,
                [
                  'pip',
                  'install',
                  '--python',
                  python,
                  '-r',
                  p.join(directory, 'requirements.txt'),
                ],
                needsVenv: true,
              ),
            );
          }
          commands.add(
            command(
              'Install Python development tools',
              'Installs Pyright, Ruff, debugpy and pytest in $venv. This does not enable their IDE integrations.',
              uv,
              [
                'pip',
                'install',
                '--python',
                python,
                'pyright',
                'ruff',
                'debugpy',
                'pytest',
              ],
              needsVenv: true,
            ),
          );
        }
      case PythonManager.poetry:
        if (tools[ProjectTool.poetry] case final poetry?) {
          commands.add(
            command(
              'Install Poetry dependencies',
              'Installs the Poetry project and lock dependencies into $venv. Package builds can execute code.',
              poetry,
              ['install'],
              needsVenv: true,
              extra: {
                'VIRTUAL_ENV': venv,
                'POETRY_VIRTUALENVS_CREATE': 'false',
              },
            ),
          );
        }
      case PythonManager.pip:
        if (project.manifests.contains('requirements.txt')) {
          commands.add(
            command(
              'Install Python requirements',
              'Installs requirements.txt into $venv. Package builds can execute code.',
              python,
              [
                '-m',
                'pip',
                'install',
                '--require-virtualenv',
                '-r',
                p.join(directory, 'requirements.txt'),
              ],
              needsVenv: true,
            ),
          );
        } else if (project.manifests.any(
          ['pyproject.toml', 'setup.py', 'setup.cfg'].contains,
        )) {
          commands.add(
            command(
              'Install Python project',
              'Installs this project into $venv. Its build backend can execute code.',
              python,
              ['-m', 'pip', 'install', '--require-virtualenv', '-e', directory],
              needsVenv: true,
            ),
          );
        }
    }
    if (manager != PythonManager.uv) {
      commands.add(
        command(
          'Install Python development tools',
          'Installs Pyright, Ruff, debugpy and pytest in $venv. This does not enable their IDE integrations.',
          python,
          [
            '-m',
            'pip',
            'install',
            '--require-virtualenv',
            'pyright',
            'ruff',
            'debugpy',
            'pytest',
          ],
          needsVenv: true,
        ),
      );
    }
    return commands;
  }

  Future<ProjectCreation> prepareCreation(
    String workspace,
    String name,
    ProjectKind kind,
    ToolchainSelection tools,
  ) async {
    final requiredTools = switch (kind) {
      ProjectKind.dart => [ProjectTool.dart],
      ProjectKind.flutter => [ProjectTool.flutter],
      ProjectKind.python => [ProjectTool.python, ProjectTool.uv],
    };
    tools = ToolchainSelection({
      for (final tool in requiredTools) tool: ?tools[tool],
    });
    await environment.validateSelection(tools);
    final executable = switch (kind) {
      ProjectKind.dart => tools[ProjectTool.dart],
      ProjectKind.flutter =>
        tools[ProjectTool.flutter] == null
            ? null
            : p.join(
                tools[ProjectTool.flutter]!,
                'bin',
                environment.windows ? 'flutter.bat' : 'flutter',
              ),
      ProjectKind.python => tools[ProjectTool.uv],
    };
    if (executable == null ||
        (kind == ProjectKind.python && tools[ProjectTool.python] == null)) {
      throw const ProjectFailure(
        'Select the installed SDK, or uv and a Python interpreter, before creating a project.',
      );
    }
    final target = await environment.reserveDestination(workspace, name.trim());
    final arguments = switch (kind) {
      ProjectKind.dart => [
        'create',
        '--no-pub',
        '--template=console',
        target.source,
      ],
      ProjectKind.flutter => [
        'create',
        '--no-pub',
        '--project-name',
        name.trim(),
        '--platforms=windows,linux,web,android',
        target.source,
      ],
      ProjectKind.python => [
        'init',
        '--no-package',
        '--no-workspace',
        '--vcs',
        'none',
        '--python',
        tools[ProjectTool.python]!,
        '--name',
        name.trim(),
        target.source,
      ],
    };
    return ProjectCreation(
      target,
      kind,
      ProjectCommand(
        title: 'Create ${kind.name} project',
        description:
            'Creates ${target.destination} with the official tool. Dependencies are installed separately. The generated folder is published only after the command succeeds.',
        spec: LaunchSpec(
          executable: executable,
          workingDirectory: workspace,
          arguments: List.unmodifiable(arguments),
          environment: const {'UV_PYTHON_DOWNLOADS': 'never'},
          unsetEnvironment: const [
            'VIRTUAL_ENV',
            'PYTHONHOME',
            'PYTHONPATH',
            'CONDA_PREFIX',
            'UV_PROJECT',
            'UV_WORKING_DIR',
          ],
        ),
      ),
    );
  }
}
