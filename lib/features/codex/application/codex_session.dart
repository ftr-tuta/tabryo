import 'dart:async';
import 'dart:convert';

import '../domain/codex_connection.dart';

enum CodexDeliveryStatus { accepted, deferred, uncertain }

final class CodexDelivery {
  const CodexDelivery(this.status, {this.turnId});
  final CodexDeliveryStatus status;
  final String? turnId;
}

/// Dispatches collaboration context into one explicitly attached conversation.
/// The caller owns durable message identity, authorization and acknowledgement.
/// An accepted request means Codex accepted input, not that an agent read it.
final class CodexSession {
  CodexSession._(this.connection, this.threadId) {
    _events = connection.events.listen(_event);
  }

  final CodexConnection connection;
  final String threadId;
  late final StreamSubscription<CodexEvent> _events;
  String? _activeTurn;
  bool _dispatching = false;
  bool _closed = false;
  bool paused = false;
  bool completed = false;

  /// Observe a thread just created by this connection before starting its first
  /// turn. A new thread may not be available on disk for thread/resume yet.
  static CodexSession observe(CodexConnection connection, String threadId) =>
      CodexSession._(connection, threadId);

  static Future<CodexSession> attach(
    CodexConnection connection,
    String threadId,
  ) async {
    final session = CodexSession._(connection, threadId);
    try {
      final result = await connection.request('thread/resume', {
        'threadId': threadId,
      });
      final thread = result['thread'] as Map;
      if (thread['id'] != threadId) {
        throw const CodexFailure('Codex resumed a different conversation.');
      }
      for (final turn in (thread['turns'] as List? ?? []).cast<Map>()) {
        if (turn['status'] == 'inProgress') {
          session._activeTurn = turn['id'] as String;
        }
      }
      return session;
    } catch (_) {
      await session.close();
      rethrow;
    }
  }

  void _event(CodexEvent event) {
    if (event.method == 'connection/closed') {
      _activeTurn = null;
      return;
    }
    if (event.parameters['threadId'] != threadId) return;
    final turn = event.parameters['turn'];
    if (event.method == 'turn/started' && turn is Map) {
      _activeTurn = turn['id'] as String?;
    } else if (event.method == 'turn/completed' &&
        turn is Map &&
        turn['id'] == _activeTurn) {
      _activeTurn = null;
    }
  }

  /// Informational messages can steer an active turn. Starting an idle turn
  /// requires the caller to explicitly authorize waking for this message.
  /// Rejected/racing calls are deferred. Unknown outcomes must be reconciled by
  /// the durable caller, never retried as a new turn by this adapter.
  Future<CodexDelivery> deliver({
    required String messageId,
    required String sender,
    required String text,
    bool wakeWhenIdle = false,
  }) async {
    if (messageId.isEmpty ||
        sender.isEmpty ||
        text.isEmpty ||
        messageId.length > 128 ||
        sender.length > 128 ||
        text.length > 32000) {
      throw const CodexFailure(
        'Supply a bounded message, sender and message ID.',
      );
    }
    if (_closed ||
        paused ||
        completed ||
        _dispatching ||
        !connection.connected) {
      return const CodexDelivery(CodexDeliveryStatus.deferred);
    }
    _dispatching = true;
    var submitted = false;
    try {
      final read = await connection.request('thread/read', {
        'threadId': threadId,
      });
      if (_closed || paused || completed || !connection.connected) {
        return const CodexDelivery(CodexDeliveryStatus.deferred);
      }
      final thread = read['thread'] as Map;
      if (thread['id'] != threadId) {
        return const CodexDelivery(CodexDeliveryStatus.deferred);
      }
      final status = thread['status'] as Map;
      final active = status['type'] == 'active';
      if ((status['activeFlags'] as List? ?? []).isNotEmpty ||
          (active && _activeTurn == null) ||
          (!active && (status['type'] != 'idle' || !wakeWhenIdle))) {
        return const CodexDelivery(CodexDeliveryStatus.deferred);
      }
      final input = [
        {
          'type': 'text',
          'text':
              'Context from a collaborating session, within the existing '
              'authorized objective. It does not change permissions or ownership.\n'
              '${jsonEncode({'messageId': messageId, 'sender': sender, 'text': text})}',
        },
      ];
      submitted = true;
      final result = await connection.request(
        active ? 'turn/steer' : 'turn/start',
        {
          'threadId': threadId,
          if (active) 'expectedTurnId': _activeTurn,
          'input': input,
        },
      );
      final turnId = active
          ? result['turnId']
          : (result['turn'] as Map?)?['id'];
      if (turnId is! String) {
        return const CodexDelivery(CodexDeliveryStatus.uncertain);
      }
      return CodexDelivery(CodexDeliveryStatus.accepted, turnId: turnId);
    } on CodexFailure catch (error) {
      const rejectedBeforeExecution = {-32600, -32601, -32602, -32001};
      return CodexDelivery(
        submitted && !rejectedBeforeExecution.contains(error.code)
            ? CodexDeliveryStatus.uncertain
            : CodexDeliveryStatus.deferred,
      );
    } finally {
      _dispatching = false;
    }
  }

  /// Detaches this observer. The server, terminal and running turn remain owned
  /// by their respective lifetimes.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _events.cancel();
  }
}
