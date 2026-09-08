import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/cancellation.dart';
import '../../projects/domain/project.dart';
import '../domain/project_task.dart';
import '../application/shared_tasks.dart';
import 'native_coverage.dart';
import 'native_test_results.dart';

final class LocalTaskFiles implements TaskFiles {
  final _reports = <TaskReport>{};
  static const reportLimit = 4 * 1024 * 1024;
  static const _excluded = {
    '.git',
    '.venv',
    'venv',
    'node_modules',
    '.dart_tool',
    'build',
    '.fvm',
    '__pycache__',
    '.pytest_cache',
    '.mypy_cache',
    '.ruff_cache',
  };

  @override
  Future<TestFileDiscovery> discover(
    DevelopmentProject project,
    List<String> excludedRoots,
    Cancellation cancellation,
  ) async {
    await _validateRoot(project);
    final paths = <String>[];
    final queue = [(project.directory, 0)];
    var entries = 0;
    var directories = 0;
    var limited = false;
    while (queue.isNotEmpty) {
      cancellation.check();
      final (directory, depth) = queue.removeAt(0);
      if (++directories > 512) {
        limited = true;
        break;
      }
      if (!p.equals(
        await Directory(directory).resolveSymbolicLinks(),
        directory,
      )) {
        continue;
      }
      await for (final entity in Directory(
        directory,
      ).list(followLinks: false)) {
        cancellation.check();
        if (++entries > 12000 || paths.length >= 1000) {
          return TestFileDiscovery(
            List.unmodifiable(paths..sort()),
            limited: true,
          );
        }
        final name = p.basename(entity.path);
        if (entity is Directory &&
            !_excluded.contains(name) &&
            !excludedRoots.any((r) => p.equals(r, entity.path))) {
          if (depth < 6) {
            queue.add((entity.path, depth + 1));
          } else {
            limited = true;
          }
        } else if (entity is File &&
            (project.kind == ProjectKind.python
                ? name.endsWith('.py') &&
                      (name.startsWith('test_') || name.endsWith('_test.py'))
                : name.endsWith('_test.dart'))) {
          paths.add(entity.path);
        }
      }
    }
    return TestFileDiscovery(
      List.unmodifiable(paths..sort()),
      limited: limited,
    );
  }

  Future<void> _validateRoot(DevelopmentProject project) async {
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
      throw const ProjectFailure('Reopen the project at its current location.');
    }
  }

  @override
  Future<void> validateTarget(DevelopmentProject project, String target) async {
    await _validateRoot(project);
    if (!p.isAbsolute(target) ||
        !p.isWithin(project.directory, target) ||
        !p.equals(await File(target).resolveSymbolicLinks(), target) ||
        await FileSystemEntity.type(target, followLinks: false) !=
            FileSystemEntityType.file) {
      throw const ProjectFailure(
        'The selected file moved or leaves the project. Refresh and review again.',
      );
    }
  }

  @override
  Future<TaskConfiguration> readConfiguration(
    DevelopmentProject project,
  ) async {
    final path = p.join(project.directory, '.tabryo', 'project.json');
    await validateTarget(project, path);
    return SharedTasks.parse(await _readFile(path, 64 * 1024));
  }

  @override
  Future<TaskReport> createReport({
    required bool python,
    bool coverage = false,
    bool dartCoverage = false,
  }) async {
    final directory = await Directory.systemTemp.createTemp('tabryo-tests-');
    final canonical = await directory.resolveSymbolicLinks();
    final report = TaskReport(
      canonical,
      p.join(canonical, python ? 'results.xml' : 'results.jsonl'),
      python,
      coveragePath: coverage ? p.join(canonical, 'lcov.info') : null,
      auxiliaryPaths: [
        if (coverage && python) p.join(canonical, '.coverage'),
        if (coverage && dartCoverage) p.join(canonical, 'coverage.json'),
      ],
    );
    _reports.add(report);
    return report;
  }

  Future<void> _validateReport(TaskReport report) async {
    if (!_reports.contains(report) ||
        !p.equals(
          await Directory(report.directory).resolveSymbolicLinks(),
          report.directory,
        ) ||
        !p.equals(p.dirname(report.path), report.directory)) {
      throw const ProjectFailure(
        'The temporary test report moved; it was retained.',
      );
    }
  }

  @override
  Future<TestResults> readReport(
    TaskReport report,
    DevelopmentProject project,
  ) async {
    await _validateReport(report);
    return NativeTestResults.parse(
      await _readFile(report.path, reportLimit),
      project,
      python: report.python,
    );
  }

  @override
  Future<CoverageResults> readCoverage(
    TaskReport report,
    DevelopmentProject project,
  ) async {
    await _validateReport(report);
    if (report.coveragePath == null) {
      throw const ProjectFailure('Coverage was not requested.');
    }
    return NativeCoverage.parse(
      await _readFile(report.coveragePath!, reportLimit),
      project,
    );
  }

  Future<String> _readFile(String path, int limit) async {
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const ProjectFailure(
        'The test runner produced no readable report. Inspect its terminal.',
      );
    }
    final handle = await File(path).open();
    try {
      if (await handle.length() > limit) {
        throw const ProjectFailure(
          'File exceeds its supported size. Narrow the selection.',
        );
      }
      final bytes = await handle.read(limit + 1);
      if (bytes.length > limit) {
        throw const ProjectFailure('Test report grew beyond 4 MiB.');
      }
      return utf8.decode(bytes);
    } finally {
      await handle.close();
    }
  }

  @override
  Future<void> discardReport(TaskReport report) async {
    if (!_reports.contains(report)) return;
    await _validateReport(report);
    for (final path in [
      report.path,
      ?report.coveragePath,
      ...report.auxiliaryPaths,
    ]) {
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type == FileSystemEntityType.file) {
        await File(path).delete();
      } else if (type != FileSystemEntityType.notFound) {
        throw const ProjectFailure(
          'Unexpected test report type; temporary files were retained.',
        );
      }
    }
    // Remove only known native outputs. Unexpected content is retained.
    await Directory(report.directory).delete();
    _reports.remove(report);
  }
}
