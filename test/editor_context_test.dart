import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tabryo/core/preview_cache.dart';
import 'package:tabryo/features/editor/infrastructure/local_document_files.dart';
import 'package:tabryo/features/editor/presentation/editor_view_model.dart';
import 'package:tabryo/features/editor/presentation/editor_context_dialog.dart';
import 'package:tabryo/features/editor_context/application/editor_context_service.dart';
import 'package:tabryo/features/editor_context/domain/editor_context.dart';
import 'package:tabryo/features/editor_context/infrastructure/local_editor_context.dart';

import 'editor_test.dart' show MemoryDocuments;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('HTTP editor context authenticates an immutable excerpt and rejects stale replacements', () async {
    final directory = await Directory.systemTemp.createTemp(
      'tabryo_editor_context_',
    );
    final root = await directory.resolveSymbolicLinks();
    const original = 'private prefix\nação 🌱\nprivate suffix\n';
    final file = await File(p.join(root, 'main.dart')).writeAsString(original);
    final service = EditorContextService(LocalEditorContext());
    final editor = EditorViewModel(
      LocalDocumentFiles(PreviewCache()),
      contextSharing: service,
    );
    final client = NativeHttp().createHttpClient(null)
      ..findProxy = (_) => 'DIRECT';
    addTearDown(() async {
      client.close(force: true);
      await editor.disposeAsync();
      await directory.delete(recursive: true);
    });
    editor.selectWorkspace(root);
    await editor.open(root, file.path);
    final buffer = editor.active!;
    buffer.controller.selection = const TextSelection(
      baseOffset: 15,
      extentOffset: 22,
    );
    final stale = await editor.prepareContext(wholeDocument: false);
    buffer.controller.text += '// newer\n';
    await expectLater(
      editor.publishContext(stale, 'Codex'),
      throwsA(isA<EditorContextFailure>()),
    );
    expect(service.connection, isNull);
    buffer.controller.text = original;
    buffer.controller.selection = const TextSelection(
      baseOffset: 15,
      extentOffset: 22,
    );
    final snapshot = await editor.prepareContext(wholeDocument: false);
    expect(snapshot.text, 'ação 🌱');
    await editor.publishContext(snapshot, 'Codex');
    final connection = service.connection!;
    final initialized = await rpc(client, connection, 'initialize', {
      'protocolVersion': '2025-11-25',
    });
    expect(initialized['result']['protocolVersion'], '2025-11-25');
    final read = await rpc(client, connection, 'resources/read', {
      'uri': 'tabryo://editor/context',
    });
    final context = jsonDecode(read['result']['contents'][0]['text'] as String);
    expect(context['text'], 'ação 🌱');
    expect(jsonEncode(context), isNot(contains('private prefix')));
    expect(
      (await rpc(client, connection, 'resources/read', {
        'uri': 'file:///private',
      }))['error'],
      isNotNull,
    );
    for (final headers in [
      {'Authorization': 'Bearer wrong'},
      {'Origin': 'https://example.invalid'},
      {'Host': 'example.invalid'},
    ]) {
      final result = await rpc(client, connection, 'ping', {}, headers);
      expect(
        result['httpStatus'],
        headers.containsKey('Authorization') ? 401 : 403,
      );
    }
    final arguments = {
      'client_id': 'edit-1',
      'snapshot_id': snapshot.id,
      'text': 'nova ação',
    };
    final proposed = await rpc(client, connection, 'tools/call', {
      'name': 'propose_replacement',
      'arguments': arguments,
    });
    expect(proposed['result']['isError'], isFalse);
    await rpc(client, connection, 'tools/call', {
      'name': 'propose_replacement',
      'arguments': arguments,
    });
    expect(service.proposals, hasLength(1));
    expect(buffer.controller.text, original);
    expect(await file.readAsString(), original);
    final duplicate = await rpc(client, connection, 'tools/call', {
      'name': 'propose_replacement',
      'arguments': {...arguments, 'text': 'conflicting'},
    });
    expect(duplicate['result']['isError'], isTrue);
    buffer.controller.text += 'later typing';
    final frozen = await rpc(client, connection, 'tools/call', {
      'name': 'editor_context',
    });
    expect(
      jsonDecode(frozen['result']['content'][0]['text'] as String)['text'],
      snapshot.text,
    );
    await expectLater(
      editor.applyContextProposal(service.proposals['edit-1']!),
      throwsA(isA<EditorContextFailure>()),
    );
    expect(buffer.controller.text, endsWith('later typing'));
    editor.selectWorkspace(p.join(root, 'another'));
    expect(service.snapshot, isNull);
    expect(service.proposals, isEmpty);
    await editor.revokeContext();
    await expectLater(
      rpc(client, connection, 'ping'),
      throwsA(isA<IOException>()),
    );
  });

  test('review applies only the shared range, preserves disk, and rechecks revocation during reads', () async {
    final files = MemoryDocuments();
    final transport = MemoryContextTransport();
    final service = EditorContextService(transport);
    final editor = EditorViewModel(files, contextSharing: service);
    addTearDown(editor.disposeAsync);
    final root = p.absolute('context');
    final path = p.join(root, 'main.dart');
    files.content[path] = 'before old after';
    editor.selectWorkspace(root);
    await editor.open(root, path);
    editor.active!.controller.selection = const TextSelection(
      baseOffset: 7,
      extentOffset: 10,
    );
    final snapshot = await editor.prepareContext(wholeDocument: false);
    await editor.publishContext(snapshot, 'Codex');
    await transport.call!('tools/call', {
      'name': 'propose_replacement',
      'arguments': {
        'client_id': 'one',
        'snapshot_id': snapshot.id,
        'text': 'new',
      },
    });
    final proposal = service.proposals['one']!;
    await editor.applyContextProposal(proposal);
    expect(editor.active!.controller.text, 'before new after');
    expect(files.content[path], 'before old after');
    expect(files.writes, 0);
    expect(proposal.status, 'applied');
    await editor.revokeContext();
    final next = await editor.prepareContext(wholeDocument: true);
    await editor.publishContext(next, 'Codex');
    await transport.call!('tools/call', {
      'name': 'propose_replacement',
      'arguments': {'client_id': 'two', 'snapshot_id': next.id, 'text': 'bad'},
    });
    files.reading = Completer<void>();
    final applying = editor.applyContextProposal(service.proposals['two']!);
    final rejected = expectLater(
      applying,
      throwsA(isA<EditorContextFailure>()),
    );
    await Future<void>.delayed(Duration.zero);
    await editor.revokeContext();
    files.reading!.complete();
    await rejected;
    expect(editor.active!.controller.text, 'before new after');
    expect(files.writes, 0);
    await expectLater(
      transport.call!('ping', {}),
      throwsA(isA<EditorContextFailure>()),
    );
  });

  test('revoking pending startup drains the endpoint and prevents exposure after disposal', () async {
    final transport = MemoryContextTransport()..opening = Completer();
    final service = EditorContextService(transport);
    final snapshot = EditorContextSnapshot(
      id: 'pending',
      workspace: '/fixture',
      path: '/fixture/main.dart',
      version: 1,
      start: 0,
      end: 4,
      text: 'text',
      dirty: true,
      capturedAt: DateTime.now(),
    );
    final publishing = service.publish(snapshot, 'Codex');
    final revoking = service.revoke();
    expect(service.connection, isNull);
    await expectLater(
      transport.call!('ping', {}),
      throwsA(isA<EditorContextFailure>()),
    );
    final connection = MemoryContextConnection();
    transport.opening!.complete(connection);
    await Future.wait([publishing, revoking]);
    expect(connection.closed, isTrue);
    expect(service.snapshot, isNull);
    final disposal = service.dispose();
    await expectLater(
      service.publish(snapshot, 'Codex'),
      throwsA(isA<EditorContextFailure>()),
    );
    await disposal;
  });

  testWidgets('context sharing and replacements require native review', (
    tester,
  ) async {
    final files = MemoryDocuments();
    final transport = MemoryContextTransport();
    final service = EditorContextService(transport);
    final editor = EditorViewModel(files, contextSharing: service);
    final root = p.absolute('context_ui');
    final path = p.join(root, 'main.dart');
    files.content[path] = 'original';
    editor.selectWorkspace(root);
    await editor.open(root, path);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => EditorContextDialog(model: editor),
              ),
              child: const Text('Context'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Context'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Share the whole document'));
    await tester.tap(find.text('Review editor context'));
    await tester.pumpAndSettle();
    expect(transport.starts, 0);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(transport.starts, 0);
    await tester.tap(find.text('Review editor context'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Publish reviewed context'));
    await tester.pumpAndSettle();
    expect(transport.starts, 1);
    await transport.call!('tools/call', {
      'name': 'propose_replacement',
      'arguments': {
        'client_id': 'review',
        'snapshot_id': service.snapshot!.id,
        'text': 'reviewed',
      },
    });
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Review replacement'));
    await tester.tap(find.text('Review replacement'));
    await tester.pumpAndSettle();
    expect(editor.active!.controller.text, 'original');
    await tester.tap(find.text('Apply unsaved replacement'));
    await tester.pumpAndSettle();
    expect(editor.active!.controller.text, 'reviewed');
    expect(files.writes, 0);
    await tester.ensureVisible(find.text('Revoke editor context'));
    await tester.tap(find.text('Revoke editor context'));
    await tester.pumpAndSettle();
    expect(service.connection, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(editor.disposeAsync);
  });
}

final class NativeHttp extends HttpOverrides {}

Future<Map<String, dynamic>> rpc(
  HttpClient client,
  EditorContextConnection connection,
  String method, [
  Map<String, Object?> params = const {},
  Map<String, String> headers = const {},
]) async {
  final request = await client.postUrl(connection.endpoint);
  request.headers.contentType = ContentType.json;
  request.headers.set('Authorization', 'Bearer ${connection.token}');
  request.headers.set('Accept', 'application/json, text/event-stream');
  headers.forEach(request.headers.set);
  request.write(
    jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params}),
  );
  final response = await request.close();
  final text = await response.transform(utf8.decoder).join();
  if (response.statusCode != 200) return {'httpStatus': response.statusCode};
  return jsonDecode(text) as Map<String, dynamic>;
}

final class MemoryContextTransport implements EditorContextTransport {
  int starts = 0;
  Completer<EditorContextConnection>? opening;
  Future<Map<String, Object?>> Function(String, Map<String, Object?>)? call;
  @override
  Future<EditorContextConnection> start(
    Future<Map<String, Object?>> Function(String, Map<String, Object?>) call,
  ) async {
    starts++;
    this.call = call;
    return opening == null ? MemoryContextConnection() : await opening!.future;
  }
}

final class MemoryContextConnection implements EditorContextConnection {
  bool closed = false;
  @override
  Uri get endpoint => Uri.parse('http://127.0.0.1:1234/mcp');
  @override
  String get token => 'test-only';
  @override
  Future<void> close() async {
    closed = true;
  }
}
