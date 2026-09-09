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
  const TaskReport(
    this.directory,
    this.path,
    this.python, {
    this.coveragePath,
    this.auxiliaryPaths = const [],
  });
  final String directory;
  final String path;
  final bool python;
  final String? coveragePath;
  final List<String> auxiliaryPaths;
}

final class CoverageFileResult {
  CoverageFileResult(this.path, Map<int, int> lines)
    : lines = Map.unmodifiable(lines);
  final String path;
  final Map<int, int> lines;
  int get covered => lines.values.where((hits) => hits > 0).length;
}

final class CoverageResults {
  const CoverageResults(this.files, {this.excludedFiles = 0});
  final List<CoverageFileResult> files;
  final int excludedFiles;
  int get total => files.fold(0, (n, f) => n + f.lines.length);
  int get covered => files.fold(0, (n, f) => n + f.covered);
}

final class SharedTask {
  const SharedTask({
    required this.name,
    required this.kind,
    this.target,
    this.filter = '',
    this.buildTarget = '',
    this.arguments = const [],
    this.coverage = false,
  });
  final String name;
  final ProjectTaskKind kind;
  final String? target;
  final String filter;
  final String buildTarget;
  final List<String> arguments;
  final bool coverage;
}

final class TaskConfiguration {
  const TaskConfiguration(this.source, this.tasks, {this.launches = const []});
  final String source;
  final List<SharedTask> tasks;
  final List<ProjectLaunchProfile> launches;
}

final class ProjectTask {
  ProjectTask({
    required this.project,
    required this.kind,
    required this.command,
    required this.tools,
    this.target,
    this.report,
    this.configuration,
  });
  final DevelopmentProject project;
  final ProjectTaskKind kind;
  final ProjectCommand command;
  final ToolchainSelection tools;
  final String? target;
  final TaskReport? report;
  final TaskConfiguration? configuration;
  TaskStatus status = TaskStatus.prepared;
  int? sessionId;
  int? exitCode;
  bool stopRequested = false;
  String? error;
  TestResults? results;
  CoverageResults? coverage;
  String? coverageError;
}

abstract interface class TaskFiles {
  Future<TestFileDiscovery> discover(
    DevelopmentProject project,
    List<String> excludedRoots,
    Cancellation cancellation,
  );
  Future<void> validateTarget(DevelopmentProject project, String target);
  Future<TaskConfiguration> readConfiguration(DevelopmentProject project);
  Future<TaskReport> createReport({
    required bool python,
    bool coverage = false,
    bool dartCoverage = false,
  });
  Future<TestResults> readReport(TaskReport report, DevelopmentProject project);
  Future<CoverageResults> readCoverage(
    TaskReport report,
    DevelopmentProject project,
  );
  Future<void> discardReport(TaskReport report);
}
