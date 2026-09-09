import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tabryo/features/editor/infrastructure/bundled_editor_assets.dart';

void main() {
  test(
    'asset initialization can reconnect after a transient failure',
    () async {
      final directory = await Directory.systemTemp.createTemp('editor-assets-');
      var unavailable = true;
      final assets = BundledEditorAssets(
        load: (name) async => Uint8List.fromList(utf8.encode(name)),
        list: () async {
          if (unavailable) throw const FileSystemException('Unavailable');
          return ['assets/editor/index.html', 'assets/editor/editor.js'];
        },
        profileDirectory: directory.path,
      );
      addTearDown(() async {
        await assets.close();
        await directory.delete(recursive: true);
      });
      await expectLater(assets.open(), throwsA(isA<FileSystemException>()));
      unavailable = false;
      final page = await assets.open();
      expect((await assets.open()).uri, page.uri);
    },
  );

  test(
    'bundled editor serves only its local capability and blocks cross origins',
    () async {
      final directory = await Directory.systemTemp.createTemp('editor-assets-');
      final assets = BundledEditorAssets(
        load: (name) async => Uint8List.fromList(utf8.encode(name)),
        list: () async => [
          'assets/editor/index.html',
          'assets/editor/editor.js',
          'private.txt',
        ],
        profileDirectory: directory.path,
      );
      final client = HttpClient();
      addTearDown(() async {
        client.close(force: true);
        await assets.close();
        await directory.delete(recursive: true);
      });
      final page = await assets.open();
      expect((await assets.open()).uri, page.uri);
      expect(page.uri.host, '127.0.0.1');
      final request = await client.getUrl(page.uri);
      final response = await request.close();
      expect(response.statusCode, 200);
      expect(
        response.headers.value('content-security-policy'),
        contains("frame-ancestors 'none'"),
      );
      expect(
        await response.transform(utf8.decoder).join(),
        'assets/editor/index.html',
      );
      for (final scenario in [
        ('GET', page.uri.resolve('/wrong/index.html'), <String, String>{}),
        ('GET', page.uri.resolve('private.txt'), <String, String>{}),
        ('POST', page.uri, <String, String>{}),
        ('GET', page.uri, {'Origin': 'https://example.invalid'}),
        ('GET', page.uri, {'Host': 'example.invalid'}),
        ('GET', page.uri, {'Sec-Fetch-Site': 'cross-site'}),
      ]) {
        final denied = await client.openUrl(scenario.$1, scenario.$2);
        scenario.$3.forEach(denied.headers.set);
        final result = await denied.close();
        expect(result.statusCode, 403, reason: '$scenario');
        await result.drain<void>();
      }
      await assets.close();
      client.close(force: true);
      final reconnect = HttpClient();
      addTearDown(() => reconnect.close(force: true));
      await expectLater(
        reconnect.getUrl(page.uri),
        throwsA(isA<SocketException>()),
      );
    },
  );
}
