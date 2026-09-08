import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../domain/codex_connection.dart';

/// Bounded JSONL framing for the bidirectional App Server protocol.
final class CodexRpcChannel {
  CodexRpcChannel({
    required Stream<List<int>> input,
    required this.send,
    required this.closeTransport,
    this.timeout = const Duration(seconds: 60),
    this.maxFrameBytes = 4 * 1024 * 1024,
    this.onServerRequest,
  }) {
    _input = input.listen(
      _receive,
      onError: (Object _) => _lost(),
      onDone: _lost,
      cancelOnError: true,
    );
  }

  final void Function(List<int>) send;
  final Future<void> Function() closeTransport;
  final Duration timeout;
  final int maxFrameBytes;
  final void Function(CodexServerRequest)? onServerRequest;
  final _events = StreamController<CodexEvent>.broadcast();
  final _pending = <int, Completer<Map<String, Object?>>>{};
  final _serverRequests = <Object, String>{};
  final _frame = BytesBuilder(copy: false);
  late final StreamSubscription<List<int>> _input;
  int _nextId = 0;
  bool _open = true;
  Future<void>? _closing;

  bool get connected => _open;
  Stream<CodexEvent> get events => _events.stream;

  Future<Map<String, Object?>> request(
    String method,
    Map<String, Object?> parameters,
  ) async {
    if (!_open) throw const CodexFailure('Codex is disconnected. Reconnect.');
    if (_pending.length >= 32) {
      throw const CodexFailure('Too many pending requests. Wait or reconnect.');
    }
    final id = ++_nextId;
    final completion = Completer<Map<String, Object?>>();
    final timer = Timer(timeout, () {
      if (_pending.remove(id) != null) {
        completion.completeError(
          const CodexFailure(
            'Codex did not respond in time. The operation may still be running. '
            'Check its state before retrying.',
          ),
        );
      }
    });
    _pending[id] = completion;
    try {
      _write({'id': id, 'method': method, 'params': parameters});
      return await completion.future;
    } on CodexFailure catch (error) {
      throw CodexFailure('$method: ${error.message}', code: error.code);
    } finally {
      timer.cancel();
      _pending.remove(id);
    }
  }

  void initialized() => _write({'method': 'initialized'});

  void respond(Object requestId, Map<String, Object?> result) {
    if (!_open || !_serverRequests.containsKey(requestId)) {
      throw const CodexFailure('This interaction is no longer pending.');
    }
    _write({'id': requestId, 'result': result});
    _serverRequests.remove(requestId);
  }

  void _write(Map<String, Object?> message) {
    final bytes = utf8.encode('${jsonEncode(message)}\n');
    if (bytes.length > maxFrameBytes) {
      throw const CodexFailure('Request exceeds the 4 MiB protocol limit.');
    }
    try {
      send(bytes);
    } catch (_) {
      throw const CodexFailure('Could not send the request. Reconnect Codex.');
    }
  }

  void _receive(List<int> bytes) {
    if (!_open) return;
    var start = 0;
    for (var i = 0; i <= bytes.length; i++) {
      if (i != bytes.length && bytes[i] != 10) continue;
      if (_frame.length + i - start > maxFrameBytes) {
        _lost('Codex output exceeded the 4 MiB message limit.');
        return;
      }
      _frame.add(Uint8List.fromList(bytes.sublist(start, i)));
      if (i < bytes.length && _frame.isNotEmpty) {
        try {
          final value = jsonDecode(utf8.decode(_frame.takeBytes()));
          if (value is! Map<String, dynamic>) throw const FormatException();
          _message(value);
        } catch (_) {
          _lost('Codex sent an invalid protocol message. Check compatibility.');
          return;
        }
      }
      start = i + 1;
    }
  }

  void _message(Map<String, Object?> message) {
    final method = message['method'];
    final id = message['id'];
    if (method is String) {
      if (id != null) {
        final handler = onServerRequest;
        if (handler != null) {
          if (id is! int && id is! String) throw const FormatException();
          final signature = jsonEncode([method, message['params']]);
          final existing = _serverRequests[id];
          if (existing == signature) {
            return; // Pending request replay on resume.
          }
          if (_serverRequests.length >= 32 || existing != null) {
            throw const FormatException();
          }
          _serverRequests[id] = signature;
          final parameters = message['params'];
          handler(
            CodexServerRequest(
              id,
              method,
              parameters is Map<String, Object?> ? parameters : const {},
            ),
          );
          return;
        }
        // This client does not grant server-initiated permissions or collect
        // elicitation input. Reject explicitly rather than leave a hung request.
        _write({
          'id': id,
          'error': {
            'code': -32601,
            'message': 'Interaction not supported by MCP Hub',
          },
        });
        _events.add(const CodexEvent('interaction/unsupported', {}));
      } else {
        final parameters = message['params'];
        if (method == 'serverRequest/resolved' && parameters is Map) {
          _serverRequests.remove(parameters['requestId']);
        }
        _events.add(
          CodexEvent(
            method,
            parameters is Map<String, Object?> ? parameters : const {},
          ),
        );
      }
      return;
    }
    final completion = _pending.remove(id);
    if (completion == null) return; // Late response after a timeout.
    final error = message['error'];
    if (error is Map) {
      final data = error['data'];
      final kind = data is Map ? data['config_write_error_code'] : null;
      final explanation = switch (kind) {
        'configLayerReadonly' =>
          'This configuration layer is read-only in Codex.',
        'configVersionConflict' =>
          'Configuration changed. Refresh and review a new preview.',
        _ => 'Codex rejected the request. Refresh configuration and check server setup.',
      };
      completion.completeError(
        CodexFailure(
          explanation,
          code: error['code'] is int ? error['code'] as int : null,
        ),
      );
    } else if (message['result'] case final Map<String, Object?> result) {
      completion.complete(result);
    } else {
      completion.completeError(
        const CodexFailure('Codex returned an unsupported response.'),
      );
    }
  }

  void _lost([
    String message = 'Codex disconnected. Reconnect to check server state.',
  ]) {
    if (!_open) return;
    _open = false;
    for (final completion in _pending.values) {
      completion.completeError(CodexFailure(message));
    }
    _pending.clear();
    _serverRequests.clear();
    _events.add(CodexEvent('connection/closed', {'message': message}));
    unawaited(close().catchError((Object _) {}));
  }

  Future<void> close() => _closing ??= () async {
    _open = false;
    for (final completion in _pending.values) {
      completion.completeError(
        const CodexFailure('Codex connection was closed.'),
      );
    }
    _pending.clear();
    _frame.clear();
    _serverRequests.clear();
    await _input.cancel();
    try {
      await closeTransport();
    } finally {
      await _events.close();
    }
  }();
}
