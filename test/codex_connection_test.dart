import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tabryo/features/codex/domain/codex_connection.dart';
import 'package:tabryo/features/codex/infrastructure/codex_rpc_channel.dart';
import 'package:tabryo/features/codex/application/conversation_service.dart';

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

  test('conversation streams reconcile items, approvals, questions and interruption', () async {
    final connection = ConversationConnection();
    final service = ConversationService(connection);
    addTearDown(service.close);
    final conversation = await service.create('/workspace');
    expect(conversation.configuration['approvalPolicy'], 'on-request');
    service.draft(conversation.id, 'hello');
    await service.send(conversation.id, 'hello');
    expect(conversation.activeTurn, 'turn-1');
    connection.emit('item/started', {
      'item': {'id': 'answer', 'type': 'agentMessage', 'text': ''},
    });
    connection.emit('item/agentMessage/delta', {
      'itemId': 'answer',
      'delta': 'Hello',
    });
    connection.emit('item/agentMessage/delta', {
      'itemId': 'answer',
      'delta': ' world',
    });
    expect(conversation.items['answer']?['text'], 'Hello world');
    connection.emit('item/completed', {
      'item': {'id': 'answer', 'type': 'agentMessage', 'text': 'Hello world'},
    });
    connection.emit('item/agentMessage/delta', {
      'itemId': 'answer',
      'delta': ' duplicate',
    });
    expect(conversation.items['answer']?['text'], 'Hello world');
    final approval = CodexServerRequest(
      'approval',
      'item/commandExecution/requestApproval',
      {'threadId': conversation.id, 'command': 'git status'},
    );
    connection.interactions.add(approval);
    expect(conversation.requests.values, [approval]);
    service.respond(conversation.id, approval, {'decision': 'decline'});
    expect(connection.responses.single.$2, {'decision': 'decline'});
    expect(
      () => service.respond(conversation.id, approval, {'decision': 'accept'}),
      throwsA(isA<CodexFailure>()),
    );
    const question = CodexServerRequest(
      'question',
      'item/tool/requestUserInput',
      {'threadId': 'chat'},
    );
    connection.interactions.add(question);
    service.respond(conversation.id, question, {
      'answers': {
        'scope': {
          'answers': ['local'],
        },
      },
    });
    await service.send(conversation.id, 'Focus on tests');
    expect(connection.calls.last.$1, 'turn/steer');
    expect(connection.calls.last.$2['expectedTurnId'], 'turn-1');
    await service.interrupt(conversation.id);
    expect(connection.calls.last.$1, 'turn/interrupt');
    connection.emit('turn/completed', {
      'turn': {'id': 'turn-1', 'status': 'interrupted'},
    });
    expect(conversation.activeTurn, isNull);
  });

  test('uncertain conversation sends never replay and external history never transfers control', () async {
    final connection = ConversationConnection();
    final service = ConversationService(connection);
    addTearDown(service.close);
    final conversation = await service.create('/workspace');
    connection.failSend = true;
    service.draft(conversation.id, 'once');
    await service.send(conversation.id, 'once');
    final identity = conversation.uncertainId;
    expect(identity, isNotNull);
    expect(conversation.draft, 'once');
    await expectLater(
      service.send(conversation.id, 'once'),
      throwsA(isA<CodexFailure>()),
    );
    connection.online = false;
    connection.emit('connection/closed', {});
    connection.history = [
      {
        'id': 'turn-1',
        'status': 'completed',
        'items': [
          {
            'id': identity,
            'type': 'userMessage',
            'content': [
              {'type': 'text', 'text': 'once'},
            ],
          },
          {'id': 'answer', 'type': 'agentMessage', 'text': 'Finished'},
        ],
      },
    ];
    await service.connect('/workspace');
    expect(conversation.controlled, isTrue);
    expect(conversation.uncertainId, isNull);
    expect(conversation.draft, isEmpty);
    expect(connection.calls.where((c) => c.$1 == 'turn/start'), hasLength(1));
    await service.list('/workspace');
    await service.select('external');
    expect(service.selected!.controlled, isFalse);
    expect(connection.calls.last.$1, 'thread/read');
    await expectLater(
      service.send('external', 'do something'),
      throwsA(isA<CodexFailure>()),
    );
    expect(
      connection.calls.where(
        (c) => c.$1 == 'thread/resume' && c.$2['threadId'] == 'external',
      ),
      isEmpty,
    );
  });

  test(
    'conversation display stays bounded while approvals and new output survive',
    () async {
      final connection = ConversationConnection();
      final service = ConversationService(connection);
      addTearDown(service.close);
      final conversation = await service.create('/workspace');
      await service.send(conversation.id, 'run');
      const approval = CodexServerRequest(
        'keep-approval',
        'item/commandExecution/requestApproval',
        {'threadId': 'chat', 'itemId': 'tool-0'},
      );
      connection.interactions.add(approval);
      for (var i = 0; i < 16; i++) {
        connection.emit('item/completed', {
          'item': {
            'id': 'tool-$i',
            'type': 'commandExecution',
            'aggregatedOutput': 'x' * 300000,
          },
        });
      }
      expect(conversation.historyTruncated, isTrue);
      expect(
        conversation.items.values
            .map(itemText)
            .fold<int>(0, (n, s) => n + s.length),
        lessThanOrEqualTo(2 * 1024 * 1024),
      );
      expect(conversation.items, contains('tool-0'));
      expect(conversation.requests.values, [approval]);
      connection.emit('item/commandExecution/outputDelta', {
        'itemId': 'stream',
        'delta': 'x' * 300000,
      });
      connection.emit('item/commandExecution/outputDelta', {
        'itemId': 'stream',
        'delta': 'latest output',
      });
      expect(
        itemText(conversation.items['stream']!),
        endsWith('latest output'),
      );
      service.respond(conversation.id, approval, {'decision': 'decline'});
      expect(connection.responses.single.$2, {'decision': 'decline'});
    },
  );

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

final class ConversationConnection implements InteractiveCodexConnection {
  bool online = false, failSend = false;
  final notifications = StreamController<CodexEvent>.broadcast(sync: true);
  final interactions = StreamController<CodexServerRequest>.broadcast(
    sync: true,
  );
  final calls = <(String, Map<String, Object?>)>[];
  final responses = <(Object, Map<String, Object?>)>[];
  List<Map<String, Object?>> history = [];
  @override
  bool get connected => online;
  @override
  Stream<CodexEvent> get events => notifications.stream;
  @override
  Stream<CodexServerRequest> get requests => interactions.stream;
  void emit(String method, Map<String, Object?> parameters) =>
      notifications.add(
        CodexEvent(method, {
          'threadId': 'chat',
          'turnId': 'turn-1',
          ...parameters,
        }),
      );
  @override
  Future<void> connect(String workspace) async {
    online = true;
  }

  @override
  Future<Map<String, Object?>> request(
    String method,
    Map<String, Object?> parameters,
  ) async {
    calls.add((method, parameters));
    if (method == 'thread/start' ||
        method == 'thread/resume' ||
        method == 'thread/read') {
      return {
        'thread': {
          'id': parameters['threadId'] ?? 'chat',
          'cwd': '/workspace',
          'preview': 'Chat',
          'turns': history,
        },
        'model': 'cli-model',
        'approvalPolicy': 'on-request',
        'sandbox': {'type': 'workspaceWrite'},
      };
    }
    if (method == 'thread/list') {
      return {
        'data': [
          {
            'id': 'external',
            'cwd': '/workspace',
            'preview': 'External session',
          },
        ],
        'nextCursor': null,
      };
    }
    if (method == 'turn/start') {
      if (failSend) throw const CodexFailure('Connection lost');
      return {
        'turn': {'id': 'turn-1', 'status': 'inProgress'},
      };
    }
    return {};
  }

  @override
  void respond(Object requestId, Map<String, Object?> response) {
    responses.add((requestId, response));
  }

  @override
  Future<void> close() async {
    online = false;
    await notifications.close();
    await interactions.close();
  }
}
