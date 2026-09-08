import 'package:dartitect_flutter/dartitect_flutter.dart';
import 'package:path/path.dart' as p;

import '../../../core/cancellation.dart';
import '../../projects/domain/project.dart';
import '../application/project_tasks.dart';
import '../domain/project_task.dart';

final class TasksViewModel extends DartitectViewModel {
  TasksViewModel(this.files, {required bool windows})
    : planner = ProjectTasks(windows: windows);
  final TaskFiles files;
  final ProjectTasks planner;
  final runs = <ProjectTask>[];
  final _prepared = <ProjectTask>{};
  final discoveries = <String, TestFileDiscovery>{};
  bool scanning = false;
  String? message;
  Cancellation? _scan;
  bool _closed = false;
  int _preparing = 0;

  Future<void> discover(
    DevelopmentProject project,
    List<DevelopmentProject> projects,
  ) async {
    _scan?.cancel();
    final cancel = _scan = Cancellation();
    scanning = true;
    message = null;
    notifyListeners();
    try {
      final result = await files.discover(
        project,
        projects
            .where((v) => p.isWithin(project.directory, v.directory))
            .map((v) => v.directory)
            .toList(),
        cancel,
      );
      cancel.check();
      if (!_closed) {
        if (!discoveries.containsKey(project.id) && discoveries.length >= 32) {
          discoveries.remove(discoveries.keys.first);
        }
        discoveries[project.id] = result;
      }
    } on Cancelled {
      return;
    } catch (error) {
      if (!_closed && !cancel.isCancelled) message = '$error';
    } finally {
      if (!_closed && identical(_scan, cancel)) {
        scanning = false;
        notifyListeners();
      }
    }
  }

  Future<ProjectTask> prepare(
    DevelopmentProject project,
    ToolchainSelection tools,
    ProjectTaskKind kind, {
    String? target,
    String filter = '',
    String buildTarget = '',
    List<String> arguments = const [],
  }) async {
    if (_closed || _prepared.length + _preparing >= 4) {
      throw const ProjectFailure('Close the previous task review first.');
    }
    _preparing++;
    TaskReport? report;
    try {
      if (kind == ProjectTaskKind.test) {
        report = await files.createReport(
          python: project.kind == ProjectKind.python,
        );
      }
      if (_closed) throw const ProjectFailure('The task panel closed.');
      if (target != null) await files.validateTarget(project, target);
      if (_closed) throw const ProjectFailure('The task panel closed.');
      final task = planner.prepare(
        project,
        tools,
        kind,
        target: target,
        filter: filter,
        buildTarget: buildTarget,
        arguments: arguments,
        report: report,
      );
      _prepared.add(task);
      return task;
    } catch (_) {
      if (report != null) await files.discardReport(report);
      rethrow;
    } finally {
      _preparing--;
    }
  }

  bool isPrepared(ProjectTask task) => !_closed && _prepared.contains(task);

  void started(ProjectTask task, int sessionId) {
    _prepared.remove(task);
    task.status = TaskStatus.running;
    task.sessionId = sessionId;
    if (runs.length >= 20) {
      runs.removeWhere((t) => t.status != TaskStatus.running);
    }
    runs.add(task);
    if (!_closed) notifyListeners();
  }

  Future<void> discard(ProjectTask task) async {
    if (!_prepared.contains(task)) return;
    if (task.report != null) await files.discardReport(task.report!);
    _prepared.remove(task);
  }

  Future<void> finished(ProjectTask task, int? exitCode) async {
    task.exitCode = exitCode;
    task.status = task.stopRequested
        ? TaskStatus.cancelled
        : exitCode == 0
        ? TaskStatus.passed
        : TaskStatus.failed;
    if (task.report case final report?) {
      try {
        task.results = await files.readReport(report, task.project);
        if (!task.stopRequested &&
            (!task.results!.complete ||
                !task.results!.successful ||
                task.results!.cases.any(
                  (v) => [
                    TestOutcome.failed,
                    TestOutcome.incomplete,
                  ].contains(v.outcome),
                ))) {
          task.status = TaskStatus.failed;
          task.error = 'Test results contain failures or are incomplete. Inspect the terminal.';
        }
      } catch (error) {
        if (!task.stopRequested) task.status = TaskStatus.failed;
        task.error = '$error';
      } finally {
        try {
          await files.discardReport(report);
        } catch (error) {
          task.error =
              '${task.error ?? ''}\nTemporary report retained at ${report.directory}: $error';
        }
      }
    }
    if (!_closed) notifyListeners();
  }

  void stopping(ProjectTask task) {
    task.stopRequested = true;
    if (!_closed) notifyListeners();
  }

  @override
  Future<void> disposeAsync() async {
    _closed = true;
    _scan?.cancel();
    for (final task in _prepared.toList()) {
      try {
        await discard(task);
      } catch (error) {
        message =
            'Temporary task files retained at ${task.report?.directory}: $error';
      }
    }
    await super.disposeAsync();
  }
}
