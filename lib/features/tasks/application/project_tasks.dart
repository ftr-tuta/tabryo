import 'package:path/path.dart' as p;

import '../../projects/domain/project.dart';
import '../../terminals/domain/terminal_ports.dart';
import '../domain/project_task.dart';

/// Native project commands; construction and file discovery execute no code.
final class ProjectTasks {
  const ProjectTasks({required this.windows});
  final bool windows;

  ProjectTask prepare(
    DevelopmentProject project,
    ToolchainSelection tools,
    ProjectTaskKind kind, {
    String? target,
    String filter = '',
    String buildTarget = '',
    List<String> arguments = const [],
    TaskReport? report,
    TaskConfiguration? configuration,
  }) {
    if (project.native) {
      throw const ProjectFailure(
        'Use Game development to build and test native projects.',
      );
    }
    final python = project.kind == ProjectKind.python;
    final flutter = project.kind == ProjectKind.flutter;
    final coverage = report?.coveragePath != null;
    final executable = flutter
        ? (tools[ProjectTool.flutter] == null
              ? null
              : p.join(
                  tools[ProjectTool.flutter]!,
                  'bin',
                  windows ? 'flutter.bat' : 'flutter',
                ))
        : tools[python ? ProjectTool.python : ProjectTool.dart];
    if (executable == null || !p.isAbsolute(executable)) {
      throw const ProjectFailure(
        'Apply the project SDK or interpreter before preparing a task.',
      );
    }
    if (target != null &&
        (target.isEmpty ||
            !p.isAbsolute(target) ||
            !p.isWithin(project.directory, target))) {
      throw const ProjectFailure('Select a file inside the project.');
    }
    if (filter.length > 512 ||
        arguments.length > 64 ||
        arguments.any((v) => v.length > 4096 || v.contains('\u0000'))) {
      throw const ProjectFailure('Task arguments exceed the supported limits.');
    }
    if (kind == ProjectTaskKind.run && (flutter || target == null)) {
      throw const ProjectFailure(
        'Select a Dart or Python script. Flutter execution requires a device session.',
      );
    }
    if (kind == ProjectTaskKind.test &&
        (report == null || report.python != python)) {
      throw const ProjectFailure(
        'Prepare a native test report before running tests.',
      );
    }
    if (kind != ProjectTaskKind.run && arguments.isNotEmpty) {
      throw const ProjectFailure('Application arguments apply only to Run.');
    }
    final args = switch (kind) {
      ProjectTaskKind.test =>
        python
            ? [
                '-m',
                'pytest',
                '--color=no',
                '-o',
                'junit_family=xunit1',
                '--junitxml',
                report!.path,
                if (coverage) ...[
                  '--cov=.',
                  '--cov-report=lcov:${report.coveragePath}',
                ],
                if (filter.isNotEmpty) ...['-k', filter],
                ?target,
              ]
            : [
                if (coverage && !flutter) ...[
                  'run',
                  'coverage:test_with_coverage',
                  '--out',
                  report!.directory,
                  '--',
                ] else
                  'test',
                if (flutter) '--no-pub',
                if (coverage && flutter) ...[
                  '--coverage',
                  '--coverage-path',
                  report!.coveragePath!,
                ],
                '--reporter=expanded',
                '--file-reporter=json:${report!.path}',
                if (filter.isNotEmpty) ...['--plain-name', filter],
                ?target,
              ],
      ProjectTaskKind.analyze =>
        python
            ? ['-m', 'ruff', 'check', '.']
            : ['analyze', if (flutter) '--no-pub'],
      ProjectTaskKind.run =>
        python ? [target!, ...arguments] : ['run', target!, ...arguments],
      ProjectTaskKind.build =>
        flutter
            ? ['build', _flutterBuildTarget(buildTarget), '--no-pub']
            : python
            ? throw const ProjectFailure(
                'Python build is project-specific; use a reviewed terminal command.',
              )
            : target == null
            ? throw const ProjectFailure(
                'Select the Dart entrypoint to compile.',
              )
            : ['compile', 'exe', target],
    };
    return ProjectTask(
      project: project,
      tools: tools,
      kind: kind,
      target: target,
      report: report,
      configuration: configuration,
      command: ProjectCommand(
        title: '${kind.name} · ${project.name}',
        description: kind == ProjectTaskKind.test
            ? 'Runs tests from disk, including project configuration and test setup. Results come from the native runner. Save your documents first.'
            : 'Runs the selected project tool from disk. Project code can execute and build outputs can be written. Save your documents first.',
        spec: LaunchSpec(
          executable: executable,
          workingDirectory: project.directory,
          arguments: List.unmodifiable(args),
          environment: python
              ? {
                  'PYTHONNOUSERSITE': '1',
                  'PYTHONUNBUFFERED': '1',
                  if (coverage)
                    'COVERAGE_FILE': p.join(report!.directory, '.coverage'),
                }
              : const {},
          unsetEnvironment: python
              ? const ['PYTHONHOME', 'PYTHONPATH']
              : const [],
        ),
      ),
    );
  }

  String _flutterBuildTarget(String target) {
    if (!['web', 'apk', windows ? 'windows' : 'linux'].contains(target)) {
      throw const ProjectFailure(
        'Choose web, apk or this host platform for Flutter build.',
      );
    }
    return target;
  }
}
