import '../../../core/cancellation.dart';
import '../../projects/domain/project.dart';

enum ProjectTaskKind { analyze, test, run, build }

enum TestOutcome { passed, failed, skipped, incomplete }

enum TaskStatus { prepared, running, passed, failed, cancelled }

final class TestFileDiscovery {
  const TestFileDiscovery(this.paths, {this.limited = false});
  final List<String> paths;
  final bool limited;
}

final class TestCaseResult {
  const TestCaseResult({
    required this.name,
    required this.outcome,
    this.path,
    this.line,
    this.details = '',
  });
  final String name;
  final TestOutcome outcome;
  final String? path;
  final int? line;
  final String details;
}

final class TestResults {
  const TestResults(
    this.cases, {
    required this.complete,
    this.successful = true,
  });
  final List<TestCaseResult> cases;
  final bool complete;
  final bool successful;
}

final class TaskReport {
  const TaskReport(this.directory, this.path, this.python);
  final String directory;
  final String path;
  final bool python;
}

final class ProjectTask {
  ProjectTask({
    required this.project,
    required this.kind,
    required this.command,
    required this.tools,
    this.target,
    this.report,
  });
  final DevelopmentProject project;
  final ProjectTaskKind kind;
  final ProjectCommand command;
  final ToolchainSelection tools;
  final String? target;
  final TaskReport? report;
  TaskStatus status = TaskStatus.prepared;
  int? sessionId;
  int? exitCode;
  bool stopRequested = false;
  String? error;
  TestResults? results;
}

abstract interface class TaskFiles {
  Future<TestFileDiscovery> discover(
    DevelopmentProject project,
    List<String> excludedRoots,
    Cancellation cancellation,
  );
  Future<void> validateTarget(DevelopmentProject project, String target);
  Future<TaskReport> createReport({required bool python});
  Future<TestResults> readReport(TaskReport report, DevelopmentProject project);
  Future<void> discardReport(TaskReport report);
}
