import '../../projects/domain/project.dart';
import '../../tasks/domain/project_task.dart';

/// A deliberately published, immutable excerpt. Later edits are never streamed.
final class EditorContextSnapshot {
  EditorContextSnapshot({
    required this.id,
    required this.workspace,
    required this.path,
    required this.version,
    required this.start,
    required this.end,
    required this.text,
    required this.dirty,
    required this.capturedAt,
    this.includesDiagnostics = false,
    this.diagnosticsLimited = false,
    this.projectContext,
    this.taskCatalog,
    List<EditorContextDiagnostic> diagnostics = const [],
  }) : diagnostics = List.unmodifiable(diagnostics);
  final String id;
  final String workspace;
  final String path;
  final int version;
  final int start;
  final int end;
  final String text;
  final bool dirty;
  final DateTime capturedAt;
  final bool includesDiagnostics;
  final bool diagnosticsLimited;
  final List<EditorContextDiagnostic> diagnostics;
  final EditorProjectContext? projectContext;
  final EditorTaskCatalog? taskCatalog;
  Map<String, Object?> toJson() => {
    'id': id,
    'workspace': workspace,
    'path': path,
    'documentVersion': version,
    'startUtf16': start,
    'endUtf16': end,
    'text': text,
    'unsaved': dirty,
    'capturedAt': capturedAt.toUtc().toIso8601String(),
    if (projectContext != null) 'project': projectContext!.toJson(),
    if (taskCatalog != null) 'registeredTasks': taskCatalog!.toJson(),
    if (includesDiagnostics) ...{
      'diagnostics': [
        for (final diagnostic in diagnostics) diagnostic.toJson(),
      ],
      'diagnosticsLimited': diagnosticsLimited,
    },
  };
}

final class EditorTaskCatalog {
  EditorTaskCatalog(this.project, this.tools, TaskConfiguration configuration)
    : configuration = TaskConfiguration(
        configuration.source,
        List.unmodifiable([
          for (final task in configuration.tasks)
            SharedTask(
              name: task.name,
              kind: task.kind,
              target: task.target,
              filter: task.filter,
              buildTarget: task.buildTarget,
              arguments: List.unmodifiable(task.arguments),
              coverage: task.coverage,
            ),
        ]),
      );
  final DevelopmentProject project;
  final ToolchainSelection tools;
  final TaskConfiguration configuration;
  Map<String, Object?> toJson() => {
    'projectRoot': project.directory,
    'tasks': [
      for (final task in configuration.tasks)
        {'name': task.name, 'kind': task.kind.name, 'target': task.target},
    ],
    'execution': 'Requests wait for native command review. No arbitrary command or argument overrides.',
  };
}

final class EditorTaskRequest {
  EditorTaskRequest(this.id, this.snapshot, this.name);
  final String id;
  final EditorContextSnapshot snapshot;
  final String name;
  String decision = 'pending';
  ProjectTask? task;
  String get status => task != null && task!.status != TaskStatus.prepared
      ? task!.status.name
      : decision;
}

enum EditorCodexAction {
  explain(
    'Explain selection',
    'Explain this captured code within the current session objective.',
  ),
  fixDiagnostic(
    'Fix diagnostic',
    'Investigate the captured diagnostic and propose or apply the appropriate correction within the current session objective.',
  ),
  investigateTest(
    'Investigate test',
    'Investigate the captured test failure within the current session objective.',
  );

  const EditorCodexAction(this.label, this.instruction);
  final String label;
  final String instruction;
}

final class EditorCodexTarget {
  const EditorCodexTarget({
    required this.id,
    required this.name,
    required this.workspace,
    required this.thread,
    required this.objective,
    required this.writer,
  });
  final String id;
  final String name;
  final String workspace;
  final String thread;
  final String objective;
  final bool writer;
}

final class EditorProjectContext {
  EditorProjectContext({
    required this.root,
    required this.includesTests,
    required this.includesSessions,
    this.limited = false,
    this.gameContext,
    List<EditorTestContext> tests = const [],
    List<EditorSessionContext> sessions = const [],
  }) : tests = List.unmodifiable(tests),
       sessions = List.unmodifiable(sessions);
  final String root;
  final bool includesTests;
  final bool includesSessions;
  final bool limited;
  final Map<String, Object?>? gameContext;
  final List<EditorTestContext> tests;
  final List<EditorSessionContext> sessions;
  Map<String, Object?> toJson() => {
    'root': root,
    'limited': limited,
    if (gameContext != null) 'game': gameContext,
    if (includesTests) 'testRuns': [for (final run in tests) run.toJson()],
    if (includesSessions)
      'runningSessions': [for (final session in sessions) session.toJson()],
  };
}

final class EditorTestContext {
  EditorTestContext({
    required this.status,
    required this.complete,
    required this.successful,
    required Map<String, int> counts,
    this.target,
    this.exitCode,
    this.error,
    List<EditorTestFailure> failures = const [],
  }) : counts = Map.unmodifiable(counts),
       failures = List.unmodifiable(failures);
  final String status;
  final bool complete;
  final bool successful;
  final String? target;
  final int? exitCode;
  final String? error;
  final Map<String, int> counts;
  final List<EditorTestFailure> failures;
  Map<String, Object?> toJson() => {
    'status': status,
    'complete': complete,
    'successful': successful,
    'target': target,
    'exitCode': exitCode,
    'error': error,
    'counts': counts,
    'failures': [for (final failure in failures) failure.toJson()],
  };
}

final class EditorTestFailure {
  const EditorTestFailure({
    required this.name,
    required this.outcome,
    required this.details,
    this.path,
    this.line,
  });
  final String name;
  final String outcome;
  final String details;
  final String? path;
  final int? line;
  Map<String, Object?> toJson() => {
    'name': name,
    'outcome': outcome,
    'details': details,
    'path': path,
    'line': line,
  };
}

final class EditorSessionContext {
  const EditorSessionContext({
    required this.kind,
    required this.status,
    required this.program,
    required this.attach,
    required this.noDebug,
  });
  final String kind;
  final String status;
  final String program;
  final bool attach;
  final bool noDebug;
  Map<String, Object?> toJson() => {
    'kind': kind,
    'status': status,
    'program': program,
    'attach': attach,
    'noDebug': noDebug,
  };
}

final class EditorContextDiagnostic {
  const EditorContextDiagnostic({
    required this.server,
    required this.message,
    required this.start,
    required this.end,
    this.source,
    this.code,
    this.version,
    this.severity,
  });
  final String server;
  final String message;
  final int start;
  final int end;
  final String? source;
  final String? code;
  final int? version;
  final int? severity;
  Map<String, Object?> toJson() => {
    'server': server,
    'source': source,
    'code': code,
    'documentVersion': version,
    'message': message,
    'startUtf16': start,
    'endUtf16': end,
    'severity': severity,
  };
}

final class EditorProposal {
  EditorProposal(this.id, this.snapshot, this.text);
  final String id;
  final EditorContextSnapshot snapshot;
  final String text;
  String status = 'pending';
}

final class EditorContextFailure implements Exception {
  const EditorContextFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

abstract interface class EditorContextConnection {
  Uri get endpoint;
  String get token;
  Future<void> close();
}

abstract interface class EditorContextTransport {
  Future<EditorContextConnection> start(
    Future<Map<String, Object?>> Function(
      String method,
      Map<String, Object?> params,
    )
    call,
  );
}
