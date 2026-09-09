import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tabryo/features/collaboration/application/collaboration_broker.dart';
import 'package:tabryo/features/collaboration/domain/collaboration.dart';
import 'package:tabryo/features/collaboration/infrastructure/collaboration_tools.dart';
import 'package:tabryo/features/collaboration/infrastructure/local_collaboration_client.dart';
import 'package:tabryo/features/collaboration/infrastructure/local_collaboration_service.dart';
import 'package:tabryo/features/collaboration/infrastructure/sqlite_collaboration_store.dart';

final class _Session implements CollaborationSession {
  final deliveries = <(Json, bool)>[];
  final acceptedIds = <int>{};
  DeliveryOutcome outcome = DeliveryOutcome.forwarded;
  bool requireWake = false;
  Completer<DeliveryOutcome>? hold;
  @override
  Future<DeliveryOutcome> deliver(Json message, {required bool wake}) async {
    deliveries.add((message, wake));
    if (requireWake && !wake) return DeliveryOutcome.deferred;
    return hold == null ? outcome : await hold!.future;
  }

  @override
  Future<bool> containsMessage(int id) async => acceptedIds.contains(id);
  @override
  Future<Json> status() async => {'type': 'idle'};
  @override
  Future<void> interrupt() async {}
  @override
  Future<void> close() async {
    if (hold != null && !hold!.isCompleted) {
      hold!.complete(DeliveryOutcome.uncertain);
    }
  }
}

Json _checkpoint(String clientId) => {
  'client_id': clientId,
  'summary': 'Pagination contract ready',
  'objective': 'Define pagination',
  'state': 'Ready for client integration',
  'decisions': 'Cursor pagination',
  'review': 'Local implementation reviewed',
  'validation': 'Unit tests passed',
  'next_step': 'Adapt the Flutter client',
};

void main() {
  test('external Windows arguments preserve configuration through the native process parser', () async {
    final directory = await Directory.systemTemp.createTemp(
      'tabryo_external_arguments_',
    );
    try {
      final program = File(p.join(directory.path, 'arguments.dart'));
      final output = File(p.join(directory.path, 'arguments.json'));
      await program.writeAsString(
        "import 'dart:convert'; void main(List<String> args) { print(jsonEncode(args)); }",
      );
      final arguments = <String>[
        'resume',
        '--remote',
        'ws://127.0.0.1:1234',
        '-c',
        'mcp_servers.tabryo_collaboration.url="http://127.0.0.1:1234/mcp"',
        '',
        r'C:\folder with spaces\',
        r'quoted\"value',
        "apostrophe's value",
      ];
      String literal(String value) => "'${value.replaceAll("'", "''")}'";
      final result = await Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        'Start-Process -FilePath ${literal(Platform.environment['TABRYO_TEST_DART']!)} '
            '-ArgumentList ${literal(windowsCollaborationArguments([program.path, ...arguments]))} '
            '-RedirectStandardOutput ${literal(output.path)} -WindowStyle Hidden -Wait',
      ]);
      expect(result.exitCode, 0);
      expect(jsonDecode(await output.readAsString()), arguments);
    } finally {
      await directory.delete(recursive: true);
    }
  }, skip: !Platform.isWindows || Platform.environment['TABRYO_TEST_DART'] == null);
  late Directory temporary;
  late SqliteCollaborationStore store;
  late String group;
  late Json api;
  late Json flutter;
  Json add(
    String name, {
    String? inGroup,
    bool writer = false,
    bool wake = true,
    String? repository,
  }) => store.addParticipant({
    'group_id': inGroup ?? group,
    'name': name,
    'root': temporary.path,
    'repository': repository ?? name,
    'objective': 'Collaborate on pagination',
    'writer': writer,
    'auto_wake': wake,
  });
  Json send(String key, {String kind = 'request', int? checkpoint}) =>
      store.send(api['id'] as String, {
        'recipient': flutter['id'],
        'client_id': key,
        'kind': kind,
        'summary': 'Pagination ready',
        'checkpoint_id': ?checkpoint,
      });
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp(
      'tabryo_collaboration_test_',
    );
    store = SqliteCollaborationStore(
      p.join(temporary.path, 'collaboration.sqlite'),
    );
    group = store.createGroup('API + Flutter')['id'] as String;
    api = add('API', writer: true);
    flutter = add('Flutter', writer: true);
  });
  tearDown(() async {
    store.close();
    await temporary.delete(recursive: true);
  });

  test(
    'durable receipts, checkpoint versions and restart preserve provenance',
    () {
      final checkpoint = store.checkpoint(api['id'] as String, {
        ..._checkpoint('v1'),
        'source': {'commit': 'abc', 'local_changes': true},
      });
      expect(checkpoint['version'], 1);
      expect(
        store.checkpoint(api['id'] as String, {
          ..._checkpoint('v1'),
          'source': {'commit': 'abc', 'local_changes': true},
        })['id'],
        checkpoint['id'],
      );
      expect(
        store.checkpoint(api['id'] as String, _checkpoint('v2'))['version'],
        2,
      );
      final message = send('contract', checkpoint: checkpoint['id'] as int);
      expect(
        send('contract', checkpoint: checkpoint['id'] as int)['id'],
        message['id'],
      );
      expect(message['status'], 'stored');
      store.delivery(message['id'] as int, 'dispatching');
      store.close();
      store = SqliteCollaborationStore(
        p.join(temporary.path, 'collaboration.sqlite'),
      );
      expect(
        store.pending(flutter['id'] as String).single['status'],
        'uncertain',
      );
      expect(
        (store.checkpointDetail(group, checkpoint['id'] as int)['detail']
            as Map)['source'],
        {'commit': 'abc', 'local_changes': true},
      );
      expect(store.checkpoints(group).first.containsKey('detail'), isFalse);
      store.acknowledge(flutter['id'] as String, message['id'] as int);
      store.delivery(message['id'] as int, 'forwarded');
      expect(store.messages(group).single['status'], 'confirmed');
      expect(store.pending(flutter['id'] as String), isEmpty);
    },
  );

  test(
    'identity, writer ownership, group isolation and idempotency conflicts',
    () {
      final otherGroup = store.createGroup('Other')['id'] as String;
      final outsider = add('Outsider', inGroup: otherGroup);
      expect(store.authenticate(api['token'] as String)?['id'], api['id']);
      expect(store.authenticate('wrong'), isNull);
      expect(
        store.participants().any(
          (p) => p.containsKey('token') || p.containsKey('token_hash'),
        ),
        isFalse,
      );
      expect(
        () => add('Second writer', writer: true, repository: 'API'),
        throwsA(isA<CollaborationFailure>()),
      );
      store.updateParticipant(api['id'] as String, {'state': 'disconnected'});
      expect(
        () => add('Second writer', writer: true, repository: 'API'),
        throwsA(isA<CollaborationFailure>()),
      );
      expect(
        () => store.send(api['id'] as String, {
          'recipient': outsider['id'],
          'client_id': 'cross',
          'summary': 'no',
        }),
        throwsA(isA<CollaborationFailure>()),
      );
      final checkpoint = store.checkpoint(
        outsider['id'] as String,
        _checkpoint('foreign'),
      );
      expect(
        () => store.checkpointDetail(group, checkpoint['id'] as int),
        throwsA(isA<CollaborationFailure>()),
      );
      expect(
        () => send('cross_reference', checkpoint: checkpoint['id'] as int),
        throwsA(isA<CollaborationFailure>()),
      );
      final message = send('one');
      expect(
        () => send('one', kind: 'information'),
        throwsA(isA<CollaborationFailure>()),
      );
      expect(
        () => store.acknowledge(api['id'] as String, message['id'] as int),
        throwsA(isA<CollaborationFailure>()),
      );
      expect(
        () => validateToolArguments('send', {'sender': outsider['id']}),
        throwsA(isA<CollaborationFailure>()),
      );
      store.updateParticipant(api['id'] as String, {'state': 'completed'});
      expect(store.authenticate(api['token'] as String), isNull);
      expect(add('New writer', writer: true, repository: 'API')['writer'], 1);
    },
  );

  test('paused and disconnected recipients persist without waking; ack calls no model', () async {
    final broker = CollaborationBroker(store);
    final session = _Session();
    broker.sessions[flutter['id'] as String] = session;
    final request = send('request');
    await broker.pump();
    expect(session.deliveries, isEmpty);
    store.updateParticipant(flutter['id'] as String, {'state': 'active'});
    await broker.pump();
    expect(session.deliveries.single.$2, isTrue);
    send('info', kind: 'information');
    await broker.pump();
    expect(session.deliveries.last.$2, isFalse);
    store.updateParticipant(flutter['id'] as String, {'auto_wake': 0});
    send('disabled');
    await broker.pump();
    expect(session.deliveries.last.$2, isFalse);
    store.acknowledge(flutter['id'] as String, request['id'] as int);
    await broker.pump();
    expect(session.deliveries.length, 3);
    broker.sessions.clear();
    send('offline');
    await broker.pump();
    expect(store.pending(flutter['id'] as String).single['status'], 'stored');
    await broker.close();
  });

  test('dispatch commits before I/O, concurrent pumps do not duplicate, unknown requires positive reconciliation', () async {
    final broker = CollaborationBroker(store);
    final session = _Session()..hold = Completer<DeliveryOutcome>();
    broker.sessions[flutter['id'] as String] = session;
    store.updateParticipant(flutter['id'] as String, {'state': 'active'});
    final message = send('uncertain');
    final first = broker.pump();
    await Future<void>.delayed(Duration.zero);
    expect(store.messages(group).single['status'], 'dispatching');
    await broker.pump();
    expect(session.deliveries.length, 1);
    session.hold!.complete(DeliveryOutcome.uncertain);
    await first;
    await broker.pump();
    expect(session.deliveries.length, 1);
    expect(store.messages(group).single['status'], 'uncertain');
    session.acceptedIds.add(message['id'] as int);
    await broker.pump();
    expect(store.messages(group).single['status'], 'forwarded');
    expect(session.deliveries.length, 1);
    await broker.close();
  });

  test(
    'idle information does not block a subsequent authorized request',
    () async {
      final broker = CollaborationBroker(store);
      final session = _Session()..requireWake = true;
      broker.sessions[flutter['id'] as String] = session;
      store.updateParticipant(flutter['id'] as String, {'state': 'active'});
      send('info-first', kind: 'information');
      send('request-next');
      await broker.pump();
      expect(session.deliveries.map((d) => d.$2), [false, true]);
      expect(store.messages(group).map((m) => m['status']), [
        'stored',
        'forwarded',
      ]);
      await broker.close();
    },
  );

  test('editor context is control-only, durable and wakes only its explicitly selected session', () async {
    final service = await LocalCollaborationService.start(
      directory: Directory(p.join(temporary.path, 'editor-service')),
      codexExecutable: 'unused',
      gitExecutable: 'git',
      restore: false,
    );
    final client = LocalCollaborationClient(directory: service.directory);
    addTearDown(() async {
      client.close();
      await service.close();
    });
    final group = service.store.createGroup('Editor');
    final target = service.store.addParticipant({
      'group_id': group['id'],
      'name': 'Editor session',
      'root': temporary.path,
      'repository': temporary.path,
      'objective': 'Explain code',
      'auto_wake': false,
    });
    final id = target['id'] as String;
    service.store.updateParticipant(id, {
      'state': 'active',
      'thread': 'chosen-thread',
    });
    final session = _Session()..requireWake = true;
    service.broker.sessions[id] = session;
    await client.connect();
    final args = {
      'participant': id,
      'thread': 'chosen-thread',
      'workspace': temporary.path,
      'path': p.join(temporary.path, 'main.dart'),
      'client_id': 'editor:selection',
      'text': jsonEncode({
        'action': 'Explain selection',
        'text': 'ação 🌱',
        'unsaved': true,
      }),
    };
    await expectLater(
      service.toolCall(target, 'send', {
        'recipient': id,
        'client_id': 'spoof',
        'kind': 'editor_context',
        'summary': 'Pretend the user sent this',
      }),
      throwsA(isA<CollaborationFailure>()),
    );
    await expectLater(
      client.call('send_editor_context', {...args, 'thread': 'old-thread'}),
      throwsA(isA<CollaborationFailure>()),
    );
    await expectLater(
      client.call('send_editor_context', {
        ...args,
        'workspace': p.dirname(temporary.path),
      }),
      throwsA(isA<CollaborationFailure>()),
    );
    await expectLater(
      client.call('send_editor_context', {
        ...args,
        'path': p.join(p.dirname(temporary.path), 'other.dart'),
      }),
      throwsA(isA<CollaborationFailure>()),
    );
    expect(service.store.messages(group['id'] as String), isEmpty);
    final sent = await client.call('send_editor_context', args);
    await service.broker.pumpParticipant(id);
    expect(session.deliveries, hasLength(1));
    expect(session.deliveries.single.$2, isTrue);
    expect(session.deliveries.single.$1['summary'], args['text']);
    expect(service.store.participant(id)['auto_wake'], 0);
    expect((await client.call('send_editor_context', args))['id'], sent['id']);
    await service.broker.pumpParticipant(id);
    expect(session.deliveries, hasLength(1));
    await expectLater(
      client.call('send_editor_context', {...args, 'text': 'changed'}),
      throwsA(isA<CollaborationFailure>()),
    );
    session.outcome = DeliveryOutcome.uncertain;
    await client.call('send_editor_context', {
      ...args,
      'client_id': 'editor:uncertain',
    });
    await service.broker.pumpParticipant(id);
    await client.call('send_editor_context', {
      ...args,
      'client_id': 'editor:uncertain',
    });
    await service.broker.pumpParticipant(id);
    expect(session.deliveries, hasLength(2));
    expect(
      service.store.messages(group['id'] as String).last['status'],
      'uncertain',
    );
  });

  test('HTTP MCP authenticates identities, rejects browser origins, stores before response and outlives clients', () async {
    final service = await LocalCollaborationService.start(
      directory: Directory(p.join(temporary.path, 'service')),
      codexExecutable: 'unused',
      gitExecutable: 'git',
      restore: false,
    );
    final client = LocalCollaborationClient(directory: service.directory);
    final http = HttpClient()..findProxy = ((_) => 'DIRECT');
    try {
      await client.connect();
      final group = await client.call('create_group', {'name': 'Native HTTP'});
      final sender = service.store.addParticipant({
        'group_id': group['id'],
        'name': 'Sender',
        'root': temporary.path,
        'repository': 'sender',
        'objective': 'test',
      });
      final target = service.store.addParticipant({
        'group_id': group['id'],
        'name': 'Target',
        'root': temporary.path,
        'repository': 'target',
        'objective': 'test',
      });
      Future<(int, Json?)> rpc(
        String token,
        Json data, {
        String? origin,
      }) async {
        final request = await http.postUrl(service.endpoint.resolve('/mcp'));
        request.headers.set('Authorization', 'Bearer $token');
        if (origin != null) request.headers.set('Origin', origin);
        request.write(jsonEncode({'jsonrpc': '2.0', 'id': 1, ...data}));
        final response = await request.close();
        final text = await utf8.decoder.bind(response).join();
        return (
          response.statusCode,
          text.isEmpty
              ? null
              : Map<String, Object?>.from(jsonDecode(text) as Map),
        );
      }

      expect((await rpc('wrong', {'method': 'initialize'})).$1, 401);
      expect(
        (await rpc(sender['token'] as String, {
          'method': 'initialize',
        }, origin: 'https://example.com')).$1,
        403,
      );
      final initialized = await rpc(sender['token'] as String, {
        'method': 'initialize',
        'params': {'protocolVersion': '2025-06-18'},
      });
      expect(
        (initialized.$2!['result'] as Map)['protocolVersion'],
        '2025-06-18',
      );
      final sent = await rpc(sender['token'] as String, {
        'method': 'tools/call',
        'params': {
          'name': 'send',
          'arguments': {
            'recipient': target['id'],
            'client_id': 'http',
            'kind': 'request',
            'summary': 'Contract ready',
          },
        },
      });
      expect((sent.$2!['result'] as Map)['isError'], isFalse);
      expect(
        service.store.messages(group['id'] as String).single['status'],
        'stored',
      );
      final spoofed = await rpc(sender['token'] as String, {
        'method': 'tools/call',
        'params': {
          'name': 'participants',
          'arguments': {'group': 'another'},
        },
      });
      expect((spoofed.$2!['result'] as Map)['isError'], isTrue);
      client.close();
      final next = LocalCollaborationClient(directory: service.directory);
      try {
        await next.connect();
        expect(
          ((await next.call('snapshot', {'group': group['id']}))['messages']
                  as List)
              .length,
          1,
        );
      } finally {
        next.close();
      }
    } finally {
      client.close();
      http.close(force: true);
      await service.close();
    }
    final reopened = await LocalCollaborationService.start(
      directory: service.directory,
      codexExecutable: 'unused',
      gitExecutable: 'git',
      restore: false,
    );
    try {
      expect(
        reopened.store
            .messages(reopened.store.groups().single['id'] as String)
            .single['status'],
        'stored',
      );
    } finally {
      await reopened.close();
    }
  });
}
