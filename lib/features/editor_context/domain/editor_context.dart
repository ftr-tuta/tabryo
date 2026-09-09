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
    if (includesDiagnostics) ...{
      'diagnostics': [
        for (final diagnostic in diagnostics) diagnostic.toJson(),
      ],
      'diagnosticsLimited': diagnosticsLimited,
    },
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
