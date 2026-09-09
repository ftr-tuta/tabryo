import 'dart:async';

import '../domain/collaboration.dart';

/// Serial dispatcher per participant. The model is never involved in receipts.
final class CollaborationBroker {
  CollaborationBroker(this.store);
  final CollaborationStore store;
  final sessions = <String, CollaborationSession>{};
  final _busy = <String>{};
  bool _closed = false;

  Future<void> pump() async {
    if (_closed) return;
    await Future.wait(sessions.keys.toList().map(pumpParticipant));
  }

  Future<void> pumpParticipant(String id) async {
    if (_closed || !_busy.add(id)) return;
    try {
      final participant = store.participant(id);
      final session = sessions[id];
      if (session == null || participant['state'] != 'active') return;
      for (final message in store.pending(id)) {
        if (_closed || store.participant(id)['state'] != 'active') return;
        final messageId = message['id'] as int;
        if (message['status'] == 'uncertain') {
          if (await session.containsMessage(messageId)) {
            store.delivery(messageId, 'forwarded');
          }
          // Absence is not proof of non-execution. Keep for recipient/UI review.
          continue;
        }
        store.delivery(messageId, 'dispatching');
        DeliveryOutcome outcome;
        try {
          outcome = await session.deliver(
            message,
            wake:
                message['kind'] == 'editor_context' ||
                (participant['auto_wake'] == 1 &&
                    message['kind'] != 'information'),
          );
        } catch (_) {
          outcome = DeliveryOutcome.uncertain;
        }
        store.delivery(messageId, switch (outcome) {
          DeliveryOutcome.forwarded => 'forwarded',
          DeliveryOutcome.deferred => 'stored',
          DeliveryOutcome.uncertain => 'uncertain',
        });
        // An idle informational message must not prevent a later authorized
        // request from waking this participant.
        if (outcome == DeliveryOutcome.uncertain ||
            (outcome == DeliveryOutcome.deferred &&
                message['kind'] != 'information')) {
          break;
        }
      }
    } finally {
      _busy.remove(id);
    }
  }

  Future<void> close() async {
    _closed = true;
    // Closing sessions first releases any pending request before the DB closes.
    await Future.wait(sessions.values.map((s) => s.close()));
    while (_busy.isNotEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    sessions.clear();
  }
}
