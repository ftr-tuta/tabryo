import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../domain/editor_assets.dart';

/// Serves only an allowlisted, bundled editor on an unpredictable loopback URL.
/// The HTTP listener has no document, command, or filesystem API.
final class BundledEditorAssets implements EditorAssets {
  BundledEditorAssets({
    required this.load,
    required this.list,
    required this.profileDirectory,
  });
  final Future<Uint8List> Function(String) load;
  final Future<List<String>> Function() list;
  final String profileDirectory;
  HttpServer? _server;
  Future<EditorPage>? _opening;
  bool _closed = false;

  @override
  Future<EditorPage> open() => _opening ??= _open().onError<Object>((
    error,
    stack,
  ) {
    // A failed asset read/bind is retryable once the installation or local
    // resource becomes available. Keep sharing an in-flight successful open.
    _opening = null;
    Error.throwWithStackTrace(error, stack);
  });

  Future<EditorPage> _open() async {
    if (_closed) throw StateError('Editor assets are closed.');
    final assets = (await list())
        .where((name) => name.startsWith('assets/editor/'))
        .map((name) => name.substring('assets/editor/'.length))
        .where((name) => RegExp(r'^[a-zA-Z0-9_.-]+$').hasMatch(name))
        .toSet();
    if (!assets.contains('index.html') || !assets.contains('editor.js')) {
      throw StateError('The editor assets are missing from this installation.');
    }
    final token = List.generate(
      32,
      (_) => Random.secure().nextInt(256),
    ).map((n) => n.toRadixString(16).padLeft(2, '0')).join();
    await Directory(profileDirectory).create(recursive: true);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    if (_closed) {
      await server.close(force: true);
      throw StateError('Editor assets are closed.');
    }
    _server = server;
    final origin = 'http://127.0.0.1:${server.port}';
    server.listen(
      (request) => unawaited(_serve(request, assets, token, origin)),
    );
    return EditorPage(
      Uri.parse('$origin/$token/index.html#$token'),
      token,
      p.normalize(profileDirectory),
    );
  }

  Future<void> _serve(
    HttpRequest request,
    Set<String> assets,
    String token,
    String origin,
  ) async {
    final response = request.response;
    try {
      response.headers
        ..set('Cache-Control', 'no-store')
        ..set('X-Content-Type-Options', 'nosniff')
        ..set('Referrer-Policy', 'no-referrer')
        ..set('Cross-Origin-Resource-Policy', 'same-origin')
        ..set(
          'Content-Security-Policy',
          "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; "
              "font-src 'self'; img-src 'self' data:; worker-src 'self'; "
              "connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'",
        );
      final segments = request.uri.pathSegments;
      final requestOrigin = request.headers.value('origin');
      if (!['GET', 'HEAD'].contains(request.method) ||
          request.headers.value('host') != Uri.parse(origin).authority ||
          (requestOrigin != null && requestOrigin != origin) ||
          request.headers.value('sec-fetch-site') == 'cross-site' ||
          segments.length != 2 ||
          segments.first != token ||
          !assets.contains(segments.last)) {
        response.statusCode = HttpStatus.forbidden;
        return;
      }
      final name = segments.last;
      response.headers.contentType = switch (p.extension(name)) {
        '.html' => ContentType.html,
        '.js' => ContentType('text', 'javascript', charset: 'utf-8'),
        '.css' => ContentType('text', 'css', charset: 'utf-8'),
        '.ttf' => ContentType('font', 'ttf'),
        _ => ContentType.text,
      };
      final bytes = await load('assets/editor/$name');
      response.contentLength = bytes.length;
      if (request.method == 'GET') response.add(bytes);
    } catch (_) {
      response.statusCode = HttpStatus.internalServerError;
    } finally {
      await response.close();
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
    await _server?.close(force: true);
    _server = null;
  }
}
