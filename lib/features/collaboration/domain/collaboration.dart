typedef Json = Map<String, Object?>;

final class CollaborationFailure implements Exception {
  const CollaborationFailure(this.message, {this.serviceAbsent = false});
  final String message;
  final bool serviceAbsent;
  @override
  String toString() => message;
}

String requiredText(Json data, String key, {int max = 32000}) {
  final value = data[key];
  if (value is! String || value.trim().isEmpty || value.length > max) {
    throw CollaborationFailure('Supply $key (1–$max characters).');
  }
  return value;
}

abstract interface class CollaborationStore {
  List<Json> groups();
  Json createGroup(String name);
  List<Json> participants({String? group});
  Json participant(String id);
  Json addParticipant(Json values);
  void updateParticipant(String id, Json values);
  Json? authenticate(String token);
  Json send(String sender, Json values);
  List<Json> messages(String group, {int after = 0, int limit = 100});
  List<Json> pending(String recipient);
  void delivery(int id, String status, {String? turn});
  Json acknowledge(String recipient, int id);
  Json checkpoint(String author, Json values);
  List<Json> checkpoints(String group, {String? author, int after = 0});
  Json checkpointDetail(String group, int id);
  void close();
}

abstract interface class CollaborationClient {
  Future<void> connect({bool start = false});
  Future<Json> call(String operation, [Json arguments = const {}]);
  void close();
}

enum DeliveryOutcome { forwarded, deferred, uncertain }

abstract interface class CollaborationSession {
  Future<DeliveryOutcome> deliver(Json message, {required bool wake});

  /// True is positive evidence of acceptance. False never authorizes retry.
  Future<bool> containsMessage(int id);
  Future<Json> status();
  Future<void> interrupt();
  Future<void> close();
}
