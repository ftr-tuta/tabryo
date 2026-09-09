import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tabryo/features/codex/domain/codex_connection.dart';
import 'package:tabryo/features/codex/application/codex_session.dart';
import 'package:tabryo/features/codex/application/conversation_service.dart';
import 'package:tabryo/features/codex/infrastructure/local_codex_connection.dart';
import 'package:tabryo/features/codex/infrastructure/websocket_codex_connection.dart';
import 'package:terminal_host/terminal_host.dart';
import 'package:tabryo/features/terminals/presentation/terminal_session.dart';

void main() {
  final codex = Platform.environment['TABRYO_TEST_CODEX'];
  final terminalEnabled = Platform.environment['TABRYO_TEST_TERMINAL'] == '1';
  late Directory temporary;
  final processes = <Process>[];
  final connections = <WebSocketCodexConnection>[];
  final drains = <StreamSubscription<dynamic>>[];
  final providers = <HttpServer>[];
  final modelInputs = <String, List<Map<String, dynamic>>>{};
  final holds = <String, Completer<void>>{};
  final arrivals = <String, Completer<void>>{};

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('tabryo_sessions_test_');
  });

  tearDown(() async {
    for (final connection in connections.reversed) {
      await connection.close();
    }
    connections.clear();
    for (final process in processes.reversed) {
      await process.stdin.close();
      process.kill();
      await process.exitCode.timeout(const Duration(seconds: 10));
    }
    processes.clear();
    for (final drain in drains) {
      await drain.cancel();
    }
    drains.clear();
    for (final provider in providers) {
      await provider.close(force: true);
    }
    providers.clear();
    expect(
      p.dirname(temporary.absolute.path),
      Directory.systemTemp.absolute.path,
    );
    for (var attempt = 0; ; attempt++) {
      try {
        await temporary.delete(recursive: true);
        break;
      } on FileSystemException catch (error) {
        if (attempt == 99 || ![5, 32].contains(error.osError?.errorCode)) {
          rethrow;
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  Future<Uri> startServer(
    String name, {
    bool live = false,
    bool launch = true,
    List<String> disabledServers = const [],
  }) async {
    final workspace = await Directory(p.join(temporary.path, name)).create();
    final configHome = await Directory(p.join(workspace.path, 'codex'))
        .create();
    final provider = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    providers.add(provider);
    provider.listen((request) async {
      final body = jsonDecode(
        await utf8.decoder.bind(request).join(),
      ) as Map<String, dynamic>;
      (modelInputs[name] ??= []).add(body);
      if (arrivals[name] case final arrival?) {
        if (!arrival.isCompleted) arrival.complete();
      }
      await holds[name]?.future;
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
      );
      final Map<String, Object?> item;
      if (name == 'approval' && modelInputs[name]!.length == 1) {
        final tools =
            ((body['tools'] as List?) ??
                    [
                      {'name': 'shell_command'},
                    ])
                .cast<Map>();
        final commandTool = tools.firstWhere(
          (tool) =>
              ['shell_command', 'shell', 'exec_command'].contains(tool['name']),
        );
        item = {
          'id': 'call_item',
          'type': 'function_call',
          'call_id': 'call_approval',
          'name': commandTool['name'],
          'arguments': jsonEncode({
            if (commandTool['name'] == 'exec_command')
              'cmd':
                  'Set-Content -LiteralPath ./approval_probe.txt -Value fixture'
            else if (commandTool['name'] == 'shell')
              'command': [
                'powershell.exe',
                '-NoProfile',
                '-Command',
                'Set-Content -LiteralPath ./approval_probe.txt -Value fixture',
              ]
            else
              'command': 'Set-Content -LiteralPath ./approval_probe.txt -Value fixture',
          }),
        };
      } else {
        item = {
          'id': 'msg_test',
          'type': 'message',
          'role': 'assistant',
          'status': 'completed',
          'content': [
            {'type': 'output_text', 'text': 'checkpoint ready'},
          ],
        };
      }
      for (final event in [
        {
          'type': 'response.created',
          'response': {
            'id': 'resp_test',
            'status': 'in_progress',
            'output': [],
          },
        },
        {'type': 'response.output_item.done', 'output_index': 0, 'item': item},
        {
          'type': 'response.completed',
          'response': {
            'id': 'resp_test',
            'status': 'completed',
            'output': [item],
            'usage': {
              'input_tokens': 10,
              'output_tokens': 4,
              'total_tokens': 14,
            },
          },
        },
      ]) {
        request.response.write(
          'event: ${event['type']}\ndata: ${jsonEncode(event)}\n\n',
        );
      }
      await request.response.close();
    });
    await File(p.join(configHome.path, 'config.toml')).writeAsString('''
model = "gpt-5.6-terra"
model_provider = "fixture"
approval_policy = "on-request"
sandbox_mode = "read-only"
[model_providers.fixture]
name = "Local test provider"
base_url = "http://127.0.0.1:${provider.port}/v1"
wire_api = "responses"
requires_openai_auth = false
supports_websockets = false
[projects.${jsonEncode(workspace.path)}]
trust_level = "trusted"
''');
    if (!launch) return Uri();
    final reservation = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final port = reservation.port;
    await reservation.close();
    final endpoint = Uri.parse('ws://127.0.0.1:$port');
    final environment = {
      ...Platform.environment,
      'CODEX_HOME': live
          ? (Platform.environment['CODEX_HOME'] ??
                p.join(Platform.environment['USERPROFILE']!, '.codex'))
          : configHome.path,
    };
    for (final key in const [
      'CODEX_APP_TOOLS_PIPE_PATH',
      'CODEX_THREAD_ID',
      'CODEX_SESSION_ID',
      'CODEX_INTERNAL_ORIGINATOR_OVERRIDE',
      // Exercise the test's explicit read-only/on-request policy, including
      // when the parent desktop task runs with a broader permission override.
      'CODEX_PERMISSION_PROFILE',
      'OPENAI_API_KEY',
    ]) {
      environment.remove(key);
    }
    final process = await Process.start(
      codex!,
      [
        'app-server',
        '--listen',
        '$endpoint',
        if (live) ...[
          '-c',
          'model="gpt-5.6-terra"',
          '-c',
          'model_reasoning_effort="low"',
          '-c',
          'features.plugins=false',
          '-c',
          'features.multi_agent=false',
          '-c',
          'features.shell_tool=false',
          '-c',
          'mcp_servers={}',
          for (final server in disabledServers) ...[
            '-c',
            'mcp_servers.$server.enabled=false',
          ],
        ],
      ],
      environment: environment,
      includeParentEnvironment: false,
      workingDirectory: workspace.path,
    );
    processes.add(process);
    drains.add(process.stdout.listen((_) {}));
    drains.add(process.stderr.listen((_) {}));
    return endpoint;
  }

  Future<WebSocketCodexConnection> attach(Uri endpoint, String name) async {
    final connection = WebSocketCodexConnection(
      endpoint: endpoint,
      clientName: name,
    );
    connections.add(connection);
    for (var attempt = 0; ; attempt++) {
      try {
        await connection.connect(temporary.path);
        return connection;
      } on CodexFailure {
        if (attempt == 40) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  }

  test(
    'rejects remote endpoints and embedded credentials before connecting',
    () async {
      for (final endpoint in [
        'ws://example.com:5000',
        'ws://localhost:5000',
        'ws://user:secret@127.0.0.1:5000',
        'ws://127.0.0.1:5000?token=secret',
      ]) {
        final connection = WebSocketCodexConnection(
          endpoint: Uri.parse(endpoint),
        );
        connections.add(connection);
        await expectLater(
          connection.connect(temporary.path),
          throwsA(isA<CodexFailure>()),
        );
      }
    },
  );

  test(
    'two local servers keep projects isolated while clients resume the same session',
    () async {
      final endpointA = await startServer('api');
      final endpointB = await startServer('app');
      final ownerA = await attach(endpointA, 'tabryo_owner_a');
      final terminalA = await attach(endpointA, 'tabryo_terminal_a');
      final ownerB = await attach(endpointB, 'tabryo_owner_b');
      final terminalB = await attach(endpointB, 'tabryo_terminal_b');
      final startedA = await ownerA.request('thread/start', {
        'cwd': p.join(temporary.path, 'api'),
      });
      final startedB = await ownerB.request('thread/start', {
        'cwd': p.join(temporary.path, 'app'),
      });
      final threadA = (startedA['thread'] as Map)['id'];
      final threadB = (startedB['thread'] as Map)['id'];
      expect(threadA, isNot(threadB));
      // Codex persists a newly created conversation after its first input.
      for (final (owner, thread) in [(ownerA, threadA), (ownerB, threadB)]) {
        final completed = owner.events.firstWhere(
          (event) => event.method == 'turn/completed',
        );
        await owner.request('turn/start', {
          'threadId': thread,
          'input': [
            {'type': 'text', 'text': 'Prepare a checkpoint.'},
          ],
        });
        final event = await completed.timeout(const Duration(seconds: 30));
        expect((event.parameters['turn'] as Map)['status'], 'completed');
      }
      final resumedA = await terminalA.request('thread/resume', {
        'threadId': threadA,
      });
      final resumedB = await terminalB.request('thread/resume', {
        'threadId': threadB,
      });
      expect((resumedA['thread'] as Map)['id'], threadA);
      expect((resumedB['thread'] as Map)['id'], threadB);
      await expectLater(
        ownerB.request('thread/read', {'threadId': threadA}),
        throwsA(isA<CodexFailure>()),
      );
      await terminalA.close();
      final stillLoaded = await ownerA.request('thread/read', {
        'threadId': threadA,
      });
      expect((stillLoaded['thread'] as Map)['id'], threadA);
      await terminalA.connect(temporary.path);
      final reconnected = await terminalA.request('thread/resume', {
        'threadId': threadA,
      });
      expect((reconnected['thread'] as Map)['id'], threadA);
    },
    skip: codex == null
        ? 'Set TABRYO_TEST_CODEX for native App Server tests.'
        : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'a redirect cannot send the session credential to another endpoint',
    () async {
      final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final source = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      providers.addAll([source, target]);
      var reachedTarget = false;
      target.listen((request) async {
        reachedTarget = true;
        request.response.statusCode = 403;
        await request.response.close();
      });
      source.listen((request) async {
        request.response.statusCode = 302;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          'http://127.0.0.1:${target.port}/',
        );
        await request.response.close();
      });
      final connection = WebSocketCodexConnection(
        endpoint: Uri.parse('ws://127.0.0.1:${source.port}'),
        bearerToken: 'synthetic-test-token',
      );
      connections.add(connection);
      await expectLater(
        connection.connect(temporary.path),
        throwsA(isA<CodexFailure>()),
      );
      expect(reachedTarget, false);
    },
  );

  test('ambiguous delivery replies are distinguished from definite rejections without replay', () async {
    for (final errorCode in [null, -32603, -32602]) {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      providers.add(server);
      var deliveries = 0;
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.listen((frame) {
          final message = jsonDecode(frame as String) as Map;
          if (message['id'] == null) return;
          if (message['method'] == 'turn/start') {
            deliveries++;
            if (errorCode == null) {
              socket.close(); // Input accepted; its acknowledgement was lost.
            } else {
              socket.add(
                jsonEncode({
                  'id': message['id'],
                  'error': {'code': errorCode, 'message': 'synthetic failure'},
                }),
              );
            }
            return;
          }
          socket.add(
            jsonEncode({
              'id': message['id'],
              'result': message['method'] == 'initialize'
                  ? <String, Object?>{}
                  : {
                      'thread': {
                        'id': 'recipient',
                        'status': {'type': 'idle'},
                        'turns': [],
                      },
                    },
            }),
          );
        });
      });
      final connection = await attach(
        Uri.parse('ws://127.0.0.1:${server.port}'),
        'tabryo_recipient',
      );
      final session = await CodexSession.attach(connection, 'recipient');
      addTearDown(session.close);
      final result = await session.deliver(
        messageId: 'checkpoint-1',
        sender: 'api',
        text: 'Dependency ready.',
        wakeWhenIdle: true,
      );
      expect(
        result.status,
        errorCode == -32602
            ? CodexDeliveryStatus.deferred
            : CodexDeliveryStatus.uncertain,
      );
      expect(deliveries, 1);
      await connection.close();
      final next = await session.deliver(
        messageId: 'checkpoint-1',
        sender: 'api',
        text: 'Dependency ready.',
        wakeWhenIdle: true,
      );
      expect(next.status, CodexDeliveryStatus.deferred);
      expect(deliveries, 1);
    }
  });

  test(
    'steering reaches the active turn and an idle recipient starts a new turn',
    () async {
      final endpoint = await startServer('delivery');
      final owner = await attach(endpoint, 'tabryo_owner');
      final terminal = await attach(endpoint, 'tabryo_terminal');
      final started = await owner.request('thread/start', {
        'cwd': temporary.path,
        'approvalPolicy': 'untrusted',
        'sandbox': 'read-only',
      });
      final thread = (started['thread'] as Map)['id'];
      final completed = owner.events
          .where((event) => event.method == 'turn/completed')
          .asBroadcastStream();
      final firstDone = completed.first;
      await owner.request('turn/start', {
        'threadId': thread,
        'input': [
          {'type': 'text', 'text': 'Initialize.'},
        ],
      });
      await firstDone.timeout(const Duration(seconds: 30));
      await terminal.request('thread/resume', {'threadId': thread});
      final session = await CodexSession.attach(owner, thread as String);
      addTearDown(session.close);
      holds['delivery'] = Completer<void>();
      arrivals['delivery'] = Completer<void>();
      final secondDone = completed.first;
      final turn = await terminal.request('turn/start', {
        'threadId': thread,
        'input': [
          {'type': 'text', 'text': 'Work on the client.'},
        ],
      });
      final turnId = (turn['turn'] as Map)['id'];
      await arrivals['delivery']!.future.timeout(const Duration(seconds: 20));
      final accepted = await session.deliver(
        messageId: 'message-123',
        sender: 'api',
        text: 'Cursor is a string.',
      );
      expect(accepted.status, CodexDeliveryStatus.accepted);
      expect(accepted.turnId, turnId);
      holds.remove('delivery')!.complete();
      await secondDone.timeout(const Duration(seconds: 30));
      final read = await owner.request('thread/read', {
        'threadId': thread,
        'includeTurns': true,
      });
      expect(jsonEncode(read), contains('message-123'));
      final thirdDone = completed.first;
      Future<CodexDelivery> dispatch({bool wake = false}) => session.deliver(
        messageId: 'message-124',
        sender: 'Tabryo editor',
        text: jsonEncode({
          'action': 'Explain selection',
          'text': 'ação 🌱',
          'unsaved': true,
        }),
        wakeWhenIdle: wake,
        fromEditor: true,
      );
      expect((await dispatch()).status, CodexDeliveryStatus.deferred);
      session.paused = true;
      expect((await dispatch(wake: true)).status, CodexDeliveryStatus.deferred);
      session.paused = false;
      session.completed = true;
      expect((await dispatch(wake: true)).status, CodexDeliveryStatus.deferred);
      session.completed = false;
      final next = await dispatch(wake: true);
      expect(next.status, CodexDeliveryStatus.accepted);
      expect(next.turnId, isNot(turnId));
      await thirdDone.timeout(const Duration(seconds: 30));
      final received = jsonEncode(
        await terminal.request('thread/read', {
          'threadId': thread,
          'includeTurns': true,
        }),
      );
      expect(
        received,
        contains('Context explicitly sent by the user from the Tabryo editor,'),
      );
      expect(received, contains('message-124'));
      expect(received, contains('ação 🌱'));
    },
    skip: codex == null
        ? 'Set TABRYO_TEST_CODEX for native App Server tests.'
        : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'installed Codex graphical chat uses local streaming and authoritative history',
    () async {
      await startServer('graphical', launch: false);
      final root = p.join(temporary.path, 'graphical');
      final connection = LocalCodexConnection(
        executable: codex,
        interactive: true,
        environment: {
          'CODEX_HOME': p.join(root, 'codex'),
          'OPENAI_API_KEY': '',
        },
      );
      final service = ConversationService(connection);
      addTearDown(service.close);
      final thread = await service.create(root);
      expect(thread.controlled, isTrue);
      expect(thread.configuration['approvalPolicy'], 'on-request');
      final done = connection.events.firstWhere(
        (e) => e.method == 'turn/completed',
      );
      service.draft(thread.id, 'Direct user request ação');
      await service.send(thread.id, thread.draft);
      expect(service.error, isNull);
      await done.timeout(const Duration(seconds: 30));
      await service.select(thread.id);
      expect(
        thread.items.values
            .where((item) => item['type'] == 'agentMessage')
            .map(itemText)
            .join(),
        contains('checkpoint ready'),
      );
      expect(
        thread.items.values
            .where((item) => item['type'] == 'userMessage')
            .map(itemText)
            .join(),
        contains('Direct user request ação'),
      );
      final messages = thread.items.keys.toSet();
      await service.select(thread.id);
      expect(thread.items.keys.toSet(), messages);
      await service.list(root);
      expect(service.conversations.keys, contains(thread.id));
      expect(modelInputs['graphical'], hasLength(1));
      await service.close();
      final reopened = ConversationService(
        LocalCodexConnection(
          executable: codex,
          interactive: true,
          environment: {
            'CODEX_HOME': p.join(root, 'codex'),
            'OPENAI_API_KEY': '',
          },
        ),
      );
      addTearDown(reopened.close);
      await reopened.list(root);
      await reopened.select(thread.id);
      expect(reopened.selected!.resumable, isTrue);
      expect(reopened.selected!.controlled, isFalse);
      await reopened.resumeCreatedConversation(thread.id);
      expect(reopened.selected!.controlled, isTrue);
      final resumedTurn = reopened.connection.events.firstWhere(
        (e) => e.method == 'turn/completed',
      );
      await reopened.send(thread.id, 'Continue the conversation');
      await resumedTurn.timeout(const Duration(seconds: 30));
      expect(modelInputs['graphical'], hasLength(2));
    },
    skip: codex == null
        ? 'Set TABRYO_TEST_CODEX for native App Server tests.'
        : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'native approval is shared with the terminal and resolved once',
    () async {
      final endpoint = await startServer('approval');
      final owner = await attach(endpoint, 'tabryo_owner');
      final terminal = await attach(endpoint, 'tabryo_terminal');
      final started = await owner.request('thread/start', {
        'cwd': temporary.path,
        'approvalPolicy': 'untrusted',
        'sandbox': 'read-only',
      });
      final thread = (started['thread'] as Map)['id'];
      final approval = owner.requests.first;
      final completed = owner.events.firstWhere(
        (event) => event.method == 'turn/completed',
      );
      await owner.request('turn/start', {
        'threadId': thread,
        'input': [
          {'type': 'text', 'text': 'Exercise an approval.'},
        ],
      });
      final pending = await approval.timeout(const Duration(seconds: 30));
      expect(pending.method, 'item/commandExecution/requestApproval');
      final observer = await attach(endpoint, 'tabryo_observer');
      final session = await CodexSession.attach(observer, thread as String);
      addTearDown(session.close);
      final deferred = await session.deliver(
        messageId: 'approval-wait',
        sender: 'api',
        text: 'Dependency ready.',
        wakeWhenIdle: true,
      );
      expect(deferred.status, CodexDeliveryStatus.deferred);
      final terminalApproval = terminal.requests.first;
      await terminal.request('thread/resume', {'threadId': thread});
      final forwarded = await terminalApproval.timeout(
        const Duration(seconds: 30),
      );
      expect(forwarded.parameters['threadId'], thread);
      final resolved = owner.events.firstWhere(
        (event) => event.method == 'serverRequest/resolved',
      );
      terminal.respond(forwarded.id, {'decision': 'decline'});
      await resolved.timeout(const Duration(seconds: 30));
      expect(
        () => owner.respond(pending.id, {'decision': 'accept'}),
        throwsA(isA<CodexFailure>()),
      );
      await completed.timeout(const Duration(seconds: 30));
      expect(
        await File(p.join(temporary.path, 'approval_probe.txt')).exists(),
        false,
      );
    },
    skip: codex == null
        ? 'Set TABRYO_TEST_CODEX for native App Server tests.'
        : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'two installed CLI terminals attach and display messages sent by another client',
    () async {
      final terminals = <TerminalPty>[];
      final parsers = <BoundedTerminal>[];
      final subscriptions = <StreamSubscription<String>>[];
      try {
        for (final name in ['cli_api', 'cli_app']) {
          final endpoint = await startServer(name);
          final owner = await attach(endpoint, 'tabryo_controller_$name');
          final workspace = p.join(temporary.path, name);
          final started = await owner.request('thread/start', {
            'cwd': workspace,
          });
          final thread = (started['thread'] as Map)['id'] as String;
          final initialDone = owner.events.firstWhere(
            (e) => e.method == 'turn/completed',
          );
          await owner.request('turn/start', {
            'threadId': thread,
            'input': [
              {'type': 'text', 'text': 'Initialize the collaboration.'},
            ],
          });
          await initialDone.timeout(const Duration(seconds: 30));
          final pty = TerminalPty.start(
            TerminalLaunchSpec(
              executable: codex!,
              rows: 30,
              columns: 100,
              arguments: ['resume', '--remote', '$endpoint', thread],
              workingDirectory: workspace,
              environment: {'CODEX_HOME': p.join(workspace, 'codex')},
              unsetEnvironment: const [
                'CODEX_APP_TOOLS_PIPE_PATH',
                'CODEX_THREAD_ID',
                'CODEX_SESSION_ID',
                'CODEX_INTERNAL_ORIGINATOR_OVERRIDE',
                'CODEX_PERMISSION_PROFILE',
                'OPENAI_API_KEY',
              ],
            ),
          );
          terminals.add(pty);
          final parser = BoundedTerminal(maxLines: 1000);
          parsers.add(parser);
          parser.resize(100, 30);
          parser.onOutput = (value) =>
              pty.write(Uint8List.fromList(utf8.encode(value)));
          final visible = Completer<void>();
          final received = Completer<void>();
          var waitingForMessage = false;
          subscriptions.add(
            pty.output.cast<List<int>>().transform(utf8.decoder).listen((text) {
              parser.write(text);
              final screen = parser.buffer.getText();
              if (!visible.isCompleted && screen.contains('checkpoint ready')) {
                visible.complete();
              }
              if (waitingForMessage &&
                  !received.isCompleted &&
                  screen.contains('message-cli-$name')) {
                received.complete();
              }
            }),
          );
          await visible.future.timeout(
            const Duration(seconds: 30),
            onTimeout: () => fail(
              'CLI did not render its resumed conversation: ${parser.buffer.getText()}',
            ),
          );
          waitingForMessage = true;
          final done = owner.events.firstWhere(
            (e) => e.method == 'turn/completed',
          );
          await owner.request('turn/start', {
            'threadId': thread,
            'input': [
              {
                'type': 'text',
                'text': 'Checkpoint message-cli-$name from the other project.',
              },
            ],
          });
          await done.timeout(const Duration(seconds: 30));
          await received.future.timeout(
            const Duration(seconds: 30),
            onTimeout: () => fail(
              'CLI did not display the forwarded message: ${parser.buffer.getText()}',
            ),
          );
        }
      } finally {
        for (final terminal in terminals) {
          await terminal.close();
        }
        for (final sub in subscriptions) {
          await sub.cancel();
        }
        for (final parser in parsers) {
          parser.dispose();
        }
      }
    },
    skip: codex == null || !terminalEnabled
        ? 'Set TABRYO_TEST_CODEX and TABRYO_TEST_TERMINAL=1 with the built native terminal library on PATH.'
        : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'two authenticated agents exchange a real checkpoint through their local servers',
    () async {
      Future<String> answer(
        WebSocketCodexConnection connection,
        String workspace,
        String prompt,
      ) async {
        final config = await connection.request('config/read', {
          'cwd': workspace,
        });
        final effective = config['config'] as Map;
        expect(
          ((effective['mcp_servers'] as Map?) ?? {}).entries
              .where((e) => (e.value as Map)['enabled'] != false)
              .map((e) => e.key)
              .toList(),
          isEmpty,
          reason:
              'Live protocol checks must not initialize unrelated MCP servers.',
        );
        final started = await connection.request('thread/start', {
          'cwd': workspace,
          'ephemeral': true,
          'approvalPolicy': 'on-request',
          'sandbox': 'read-only',
        });
        final thread = (started['thread'] as Map)['id'];
        final messages = <String>[];
        final subscription = connection.events.listen((event) {
          if (event.method == 'item/completed' &&
              event.parameters['threadId'] == thread) {
            final item = event.parameters['item'] as Map;
            if (item['type'] == 'agentMessage') {
              messages.add(item['text'] as String);
            }
          }
        });
        try {
          final done = connection.events.firstWhere(
            (e) =>
                e.method == 'turn/completed' &&
                e.parameters['threadId'] == thread,
          );
          await connection.request('turn/start', {
            'threadId': thread,
            'input': [
              {'type': 'text', 'text': prompt},
            ],
          });
          final completed = await done.timeout(const Duration(seconds: 90));
          expect((completed.parameters['turn'] as Map)['status'], 'completed');
          return messages.join('\n');
        } finally {
          await subscription.cancel();
        }
      }

      final probe = await attach(
        await startServer('live_config', live: true),
        'tabryo_live_config',
      );
      final configuration = await probe.request('config/read', {
        'cwd': temporary.path,
      });
      final disabledServers =
          (((configuration['config'] as Map)['mcp_servers'] as Map?) ?? {}).keys
              .cast<String>()
              .toList();
      expect(
        disabledServers.every(
          (name) => RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(name),
        ),
        true,
      );
      await probe.close();
      final a = await attach(
        await startServer(
          'live_api',
          live: true,
          disabledServers: disabledServers,
        ),
        'tabryo_live_api',
      );
      final b = await attach(
        await startServer(
          'live_app',
          live: true,
          disabledServers: disabledServers,
        ),
        'tabryo_live_app',
      );
      final checkpoint = await answer(
        a,
        p.join(temporary.path, 'live_api'),
        'This is an authorized Tabryo protocol integration test in a disposable workspace. Do not use tools, delegate, or change files. Return exactly this checkpoint text: API-CHECKPOINT-4821: cursor is a string.',
      );
      expect(checkpoint, contains('API-CHECKPOINT-4821'));
      final response = await answer(
        b,
        p.join(temporary.path, 'live_app'),
        'This is an authorized Tabryo protocol integration test in a disposable workspace. Do not use tools, delegate, or change files. A collaborating API session sent this checkpoint: $checkpoint\nReply exactly: APP-ACK-4821: cursor contract received.',
      );
      expect(response, contains('APP-ACK-4821'));
    },
    skip: codex == null || Platform.environment['TABRYO_TEST_CODEX_LIVE'] != '1'
        ? 'Set TABRYO_TEST_CODEX_LIVE=1 to use the installed Codex login and two real model turns.'
        : false,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
