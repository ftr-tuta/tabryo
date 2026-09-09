import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tabryo/features/codex/domain/codex_connection.dart';
import 'package:tabryo/features/codex/infrastructure/codex_rpc_channel.dart';

void main() {
  late StreamController<List<int>> input;
  late List<Map<String, dynamic>> output;
  late CodexRpcChannel channel;
  late int closes;

  void receive(Map<String, Object?> message) =>
      input.add(utf8.encode('${jsonEncode(message)}\n'));

  setUp(() {
    input = StreamController<List<int>>(sync: true);
    output = [];
    closes = 0;
    channel = CodexRpcChannel(
      input: input.stream,
      send: (bytes) =>
          output.add(jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>),
      closeTransport: () async {
        closes++;
      },
      timeout: const Duration(milliseconds: 30),
      maxFrameBytes: 1024,
    );
  });
  tearDown(() async {
    await channel.close();
    await input.close();
  });

  test(
    'correlates interleaved replies and preserves split UTF-8 frames',
    () async {
      final first = channel.request('one', {});
      final second = channel.request('two', {});
      receive({
        'id': output[1]['id'],
        'result': {'value': 2},
      });
      final bytes = utf8.encode(
        '${jsonEncode({
          'id': output[0]['id'],
          'result': {'value': 'ação'},
        })}\n',
      );
      for (final byte in bytes) {
        input.add([byte]);
      }
      expect(await first, {'value': 'ação'});
      expect(await second, {'value': 2});
    },
  );

  test('initialization notification has no id or jsonrpc header', () {
    channel.initialized();
    expect(output.single, {'method': 'initialized'});
  });

  test(
    'interactive clients forward approvals and answer each request once',
    () async {
      await channel.close();
      await input.close();
      input = StreamController<List<int>>(sync: true);
      final requests = <CodexServerRequest>[];
      channel = CodexRpcChannel(
        input: input.stream,
        send: (bytes) =>
            output.add(jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>),
        closeTransport: () async {},
        onServerRequest: requests.add,
      );
      receive({
        'id': 'permission',
        'method': 'item/permissions/requestApproval',
        'params': {'threadId': 'a'},
      });
      expect(output, isEmpty);
      expect(requests.single.parameters['threadId'], 'a');
      receive({
        'id': 'permission',
        'method': 'item/permissions/requestApproval',
        'params': {'threadId': 'a'},
      });
      expect(requests, hasLength(1));
      channel.respond('permission', {'permissions': {}});
      expect(output.single, {
        'id': 'permission',
        'result': {'permissions': {}},
      });
      expect(
        () => channel.respond('permission', {}),
        throwsA(isA<CodexFailure>()),
      );
    },
  );

  test(
    'an approval resolved by another client cannot be answered again',
    () async {
      await channel.close();
      await input.close();
      input = StreamController<List<int>>(sync: true);
      channel = CodexRpcChannel(
        input: input.stream,
        send: (bytes) =>
            output.add(jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>),
        closeTransport: () async {},
        onServerRequest: (_) {},
      );
      receive({
        'id': 77,
        'method': 'item/fileChange/requestApproval',
        'params': {},
      });
      receive({
        'method': 'serverRequest/resolved',
        'params': {'requestId': 77},
      });
      expect(
        () => channel.respond(77, {'decision': 'accept'}),
        throwsA(isA<CodexFailure>()),
      );
      expect(output, isEmpty);
    },
  );

  test(
    'refuses unsupported server approvals without granting permissions',
    () async {
      final notification = channel.events.first;
      receive({
        'id': 'approval',
        'method': 'item/permissions/requestApproval',
        'params': {'secret': 'do not surface'},
      });
      expect(output.single['id'], 'approval');
      expect(output.single['result'], isNull);
      expect((output.single['error'] as Map)['code'], -32601);
      final event = await notification;
      expect(event.method, 'interaction/unsupported');
      expect(event.parameters, isEmpty);
    },
  );

  test('does not expose raw error messages or data', () async {
    final response = channel.request('config/batchWrite', {});
    final expectation = expectLater(
      response,
      throwsA(
        isA<CodexFailure>().having(
          (e) => e.toString(),
          'safe message',
          isNot(contains('TOP_SECRET')),
        ),
      ),
    );
    receive({
      'id': output.single['id'],
      'error': {
        'code': -32600,
        'message': 'TOP_SECRET',
        'data': {'token': 'TOP_SECRET'},
      },
    });
    await expectation;
  });

  test(
    'a timed-out request ignores late replies and allows another request',
    () async {
      final first = channel.request('slow', {});
      await expectLater(
        first,
        throwsA(
          isA<CodexFailure>().having(
            (e) => e.message,
            'message',
            contains('may still be running'),
          ),
        ),
      );
      receive({
        'id': output.first['id'],
        'result': {'late': true},
      });
      final next = channel.request('fast', {});
      receive({
        'id': output.last['id'],
        'result': {'ok': true},
      });
      expect(await next, {'ok': true});
    },
  );

  test('bounds an unterminated frame and closes the owned transport', () async {
    final response = channel.request('pending', {});
    final expectation = expectLater(response, throwsA(isA<CodexFailure>()));
    input.add(List.filled(1025, 65));
    await expectation;
    await channel.close();
    expect(channel.connected, false);
    expect(closes, 1);
  });

  test('malformed input fails pending requests instead of hanging', () async {
    final response = channel.request('pending', {});
    final expectation = expectLater(response, throwsA(isA<CodexFailure>()));
    input.add(utf8.encode('not-json\n'));
    await expectation;
    expect(channel.connected, false);
  });

  test('closing cancels pending requests and is idempotent', () async {
    final response = channel.request('pending', {});
    final expectation = expectLater(response, throwsA(isA<CodexFailure>()));
    await channel.close();
    await expectation;
    await channel.close();
    expect(closes, 1);
    await expectLater(
      channel.request('closed', {}),
      throwsA(isA<CodexFailure>()),
    );
  });
}
