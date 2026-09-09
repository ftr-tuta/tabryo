import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../domain/codex_connection.dart';
import 'codex_rpc_channel.dart';

/// Attaches to an explicitly selected local App Server. Closing the connection
/// does not stop the server or cancel its turns; its owner controls that lifetime.
final class WebSocketCodexConnection implements InteractiveCodexConnection {
  WebSocketCodexConnection({
    required this.endpoint,
    this.bearerToken,
    this.clientName = 'tabryo_sessions',
  });

  final Uri endpoint;
  final String? bearerToken;
  final String clientName;
  final _events = StreamController<CodexEvent>.broadcast();
  final _requests = StreamController<CodexServerRequest>.broadcast();
  CodexRpcChannel? _channel;
  StreamSubscription<CodexEvent>? _subscription;
  int _generation = 0;
  bool _ready = false;

  @override
  bool get connected => _ready && (_channel?.connected ?? false);
  @override
  Stream<CodexEvent> get events => _events.stream;
  @override
  Stream<CodexServerRequest> get requests => _requests.stream;

  @override
  Future<void> connect(String workspace) async {
    await close();
    final generation = ++_generation;
    if (endpoint.scheme != 'ws' ||
        endpoint.host != '127.0.0.1' ||
        endpoint.port == 0 ||
        endpoint.userInfo.isNotEmpty ||
        endpoint.hasQuery ||
        endpoint.hasFragment ||
        (endpoint.path.isNotEmpty && endpoint.path != '/')) {
      throw const CodexFailure('Select a local ws://127.0.0.1:PORT endpoint.');
    }
    WebSocket socket;
    var abandoned = false;
    final client = HttpClient();
    client.findProxy = (_) => 'DIRECT';
    client.connectionFactory = (uri, proxyHost, proxyPort) {
      if (uri.scheme != 'http' ||
          uri.host != endpoint.host ||
          uri.port != endpoint.port ||
          proxyHost != null) {
        throw const CodexFailure(
          'Codex redirected outside the selected local endpoint.',
        );
      }
      return Socket.startConnect(InternetAddress.loopbackIPv4, endpoint.port);
    };
    final opening = WebSocket.connect(
      endpoint.toString(),
      customClient: client,
      maxPayloadLength: 4 * 1024 * 1024,
      headers: {
        if (bearerToken != null) 'Authorization': 'Bearer $bearerToken',
      },
    );
    unawaited(
      opening.then<void>((value) {
        if (abandoned || generation != _generation) unawaited(value.close());
      }, onError: (Object _) {}),
    );
    try {
      socket = await opening.timeout(const Duration(seconds: 10));
    } catch (_) {
      abandoned = true;
      throw const CodexFailure('Could not connect to the local Codex session.');
    } finally {
      client.close(force: true);
    }
    if (generation != _generation) {
      await socket.close();
      throw const CodexFailure('Connection cancelled.');
    }
    socket.pingInterval = const Duration(seconds: 20);
    final channel = CodexRpcChannel(
      input: socket.map((frame) {
        if (frame is! String || frame.length > 4 * 1024 * 1024) {
          throw const FormatException();
        }
        // Validate one JSON document per WebSocket frame before JSONL framing.
        if (jsonDecode(frame) is! Map<String, dynamic>) {
          throw const FormatException();
        }
        return utf8.encode('$frame\n');
      }),
      send: (bytes) => socket.add(utf8.decode(bytes).trimRight()),
      closeTransport: () async {
        await socket.close().timeout(const Duration(seconds: 3));
      },
      onServerRequest: _requests.add,
    );
    _channel = channel;
    _subscription = channel.events.listen((event) {
      if (event.method == 'connection/closed') _ready = false;
      _events.add(event);
    });
    try {
      await channel.request('initialize', {
        'clientInfo': {
          'name': clientName,
          'title': 'Tabryo',
          'version': '0.1.0',
        },
        'capabilities': {'experimentalApi': false},
      });
      if (generation != _generation) {
        throw const CodexFailure('Connection cancelled.');
      }
      channel.initialized();
      _ready = true;
    } catch (_) {
      await channel.close();
      rethrow;
    }
  }

  @override
  Future<Map<String, Object?>> request(
    String method,
    Map<String, Object?> parameters,
  ) {
    if (!connected) throw const CodexFailure('Codex is disconnected.');
    return _channel!.request(method, parameters);
  }

  @override
  void respond(Object requestId, Map<String, Object?> result) {
    if (!connected) throw const CodexFailure('Codex is disconnected.');
    _channel!.respond(requestId, result);
  }

  @override
  Future<void> close() async {
    ++_generation;
    _ready = false;
    final channel = _channel;
    _channel = null;
    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
    await channel?.close();
  }
}
