import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../domain/editor_context.dart';

final class LocalEditorContext implements EditorContextTransport {
  @override
  Future<EditorContextConnection> start(
    Future<Map<String, Object?>> Function(String, Map<String, Object?>) call,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.idleTimeout = const Duration(seconds: 15);
    final random = Random.secure();
    final token = base64Url.encode(
      List.generate(32, (_) => random.nextInt(256)),
    );
    return _Connection(server, token, call);
  }
}

final class _Connection implements EditorContextConnection {
  _Connection(this.server, this.token, this.call)
    : endpoint = Uri.parse('http://127.0.0.1:${server.port}/mcp') {
    server.listen((request) => unawaited(_handle(request)));
  }
  final HttpServer server;
  final Future<Map<String, Object?>> Function(String, Map<String, Object?>)
  call;
  @override
  final String token;
  bool _closed = false;
  Future<void>? _closing;
  int _requests = 0;
  @override
  final Uri endpoint;
  bool _authorized(String? value) {
    final expected = 'Bearer $token';
    if (value == null || value.length != expected.length) return false;
    var difference = 0;
    for (var i = 0; i < value.length; i++) {
      difference |= value.codeUnitAt(i) ^ expected.codeUnitAt(i);
    }
    return difference == 0;
  }

  Future<void> _handle(HttpRequest request) async {
    var admitted = false;
    Object? id;
    try {
      final origin = request.headers.value('origin');
      if (request.headers.value('host') != endpoint.authority ||
          (origin != null && origin != endpoint.origin)) {
        request.response.statusCode = HttpStatus.forbidden;
        return;
      }
      if (!_authorized(request.headers.value('authorization'))) {
        request.response.statusCode = HttpStatus.unauthorized;
        return;
      }
      if (request.uri.path != '/mcp' || request.uri.hasQuery) {
        request.response.statusCode = HttpStatus.notFound;
        return;
      }
      if (request.method != 'POST') {
        request.response.statusCode = HttpStatus.methodNotAllowed;
        request.response.headers.set('Allow', 'POST');
        return;
      }
      final protocol = request.headers.value('MCP-Protocol-Version');
      if ((protocol != null &&
              !{'2025-03-26', '2025-06-18', '2025-11-25'}.contains(protocol)) ||
          request.headers.contentType?.mimeType != 'application/json') {
        request.response.statusCode = HttpStatus.badRequest;
        return;
      }
      if (_closed || _requests >= 8) {
        request.response.statusCode = HttpStatus.serviceUnavailable;
        return;
      }
      _requests++;
      admitted = true;
      final bytes = <int>[];
      await for (final chunk in request.timeout(const Duration(seconds: 15))) {
        if (bytes.length + chunk.length > 4 * 1024 * 1024) {
          request.response.statusCode = HttpStatus.requestEntityTooLarge;
          return;
        }
        bytes.addAll(chunk);
      }
      final value = jsonDecode(utf8.decode(bytes));
      if (value is! Map<String, dynamic> ||
          value['jsonrpc'] != '2.0' ||
          value['method'] is! String ||
          (value['params'] != null && value['params'] is! Map)) {
        throw const FormatException();
      }
      if (!value.containsKey('id')) {
        request.response.statusCode = HttpStatus.accepted;
        return;
      }
      id = value['id'];
      if (id is! int && id is! String) throw const FormatException();
      if (_closed) {
        request.response.statusCode = HttpStatus.gone;
        return;
      }
      final result = await call(
        value['method'] as String,
        Map<String, Object?>.from(value['params'] as Map? ?? {}),
      );
      if (_closed) return;
      request.response.headers.contentType = ContentType.json;
      request.response.headers.set('Cache-Control', 'no-store');
      request.response.write(
        jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result}),
      );
    } on EditorContextFailure catch (failure) {
      if (_closed) return;
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': id,
          'error': {'code': -32602, 'message': failure.message},
        }),
      );
    } catch (_) {
      if (!_closed) request.response.statusCode = HttpStatus.badRequest;
    } finally {
      if (admitted) _requests--;
      try {
        await request.response.close();
      } catch (_) {
        /* The client or grant closed. */
      }
    }
  }

  @override
  Future<void> close() => _closing ??= () async {
    _closed = true;
    await server.close(force: true);
  }();
}
