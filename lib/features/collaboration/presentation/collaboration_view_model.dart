import 'dart:async';

import 'package:dartitect_flutter/dartitect_flutter.dart';

import '../domain/collaboration.dart';

final class CollaborationViewModel extends DartitectViewModel {
  CollaborationViewModel(this.client);
  final CollaborationClient client;
  List<Json> groups = [];
  List<Json> participants = [];
  List<Json> messages = [];
  List<Json> checkpoints = [];
  String? group;
  String? message;
  bool connected = false;
  bool busy = false;
  bool _disposed = false;
  bool _refreshing = false;
  Timer? _timer;
  int after = 0;
  int checkpointAfter = 0;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<bool> run(Future<void> Function() action) async {
    if (busy || _disposed) return false;
    busy = true;
    message = null;
    _notify();
    try {
      await action();
      return true;
    } catch (error) {
      message = error is CollaborationFailure ? error.message : 'Collaboration operation failed. Check the saved state before retrying.';
      return false;
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> open({bool start = false}) => run(() async {
    await client.connect(start: start);
    connected = true;
    await refresh();
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!busy) unawaited(refresh());
    });
  });

  void hide() {
    _timer?.cancel();
    _timer = null;
  }

  /// Used by destructive workspace actions even when the panel is closed.
  Future<List<Json>> reservations() async {
    try {
      await client.connect();
      final snapshot = await client.call('snapshot');
      return (snapshot['participants'] as List)
          .map((row) => Map<String, Object?>.from(row as Map))
          .where((row) => row['state'] != 'completed')
          .toList();
    } on CollaborationFailure catch (error) {
      if (error.serviceAbsent) return [];
      rethrow;
    }
  }

  Future<void> refresh() async {
    if (_disposed || !connected || _refreshing) return;
    _refreshing = true;
    final selected = group;
    try {
      final value = await client.call('snapshot', {
        'group': selected,
        'after': after,
        'checkpoint_after': checkpointAfter,
      });
      if (_disposed || selected != group) return;
      groups = (value['groups'] as List)
          .map((v) => Map<String, Object?>.from(v as Map))
          .toList();
      participants = (value['participants'] as List)
          .map((v) => Map<String, Object?>.from(v as Map))
          .toList();
      messages = (value['messages'] as List)
          .map((v) => Map<String, Object?>.from(v as Map))
          .toList();
      checkpoints = (value['checkpoints'] as List)
          .map((v) => Map<String, Object?>.from(v as Map))
          .toList();
    } catch (error) {
      connected = false;
      hide();
      message = error is CollaborationFailure
          ? error.message
          : 'Service disconnected. Reconnect to load saved progress.';
    } finally {
      _refreshing = false;
      _notify();
    }
  }

  Future<void> select(String? value) async {
    group = value;
    after = 0;
    checkpointAfter = 0;
    messages = [];
    checkpoints = [];
    participants = [];
    // A stale poll is allowed to finish, but cannot replace this selection.
    while (_refreshing && !_disposed) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await refresh();
  }

  Future<void> action(String operation, [Json args = const {}]) =>
      run(() async {
        await client.call(operation, args);
        await refresh();
      });

  Future<void> createGroup(String name) => run(() async {
    final created = await client.call('create_group', {'name': name});
    await select(created['id'] as String);
  });

  Future<bool> addParticipant(Json values) => run(() async {
    final created = await client.call('add_participant', {
      ...values,
      'group_id': group,
    });
    // If connection fails the participant remains visible and can reconnect;
    // do not create another identity or replay an unknown initial turn.
    try {
      await client.call('connect', {'id': created['id']});
    } finally {
      await refresh();
    }
  });

  Future<void> stop() => run(() async {
    await client.call('stop');
    connected = false;
    hide();
    message = 'Service stopped. Messages and checkpoints are saved.';
  });

  String participantName(Object? id) =>
      participants.where((p) => p['id'] == id).firstOrNull?['name']
          as String? ??
      '$id';

  @override
  Future<void> disposeAsync() async {
    _disposed = true;
    hide();
    client.close();
    await super.disposeAsync();
  }
}
