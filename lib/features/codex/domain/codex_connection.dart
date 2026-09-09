/// The local Codex protocol boundary. Implementations own their transport.
abstract interface class CodexConnection {
  bool get connected;
  Stream<CodexEvent> get events;
  Future<void> connect(String workspace);
  Future<Map<String, Object?>> request(
    String method,
    Map<String, Object?> parameters,
  );
  Future<void> close();
}

abstract interface class InteractiveCodexConnection implements CodexConnection {
  Stream<CodexServerRequest> get requests;
  void respond(Object requestId, Map<String, Object?> response);
}

final class CodexEvent {
  const CodexEvent(this.method, this.parameters);
  final String method;
  final Map<String, Object?> parameters;
}

/// A request remains pending until a connected client answers or Codex clears it.
/// Receiving it never grants permission to the requested operation.
final class CodexServerRequest {
  const CodexServerRequest(this.id, this.method, this.parameters);
  final Object id;
  final String method;
  final Map<String, Object?> parameters;
}

/// Messages are local, safe explanations, never raw server errors or stderr.
final class CodexFailure implements Exception {
  const CodexFailure(this.message, {this.code});
  final String message;
  final int? code;
  @override
  String toString() => message;
}
