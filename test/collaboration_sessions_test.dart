import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:terminal_host/terminal_host.dart';
import 'package:tabryo/features/terminals/presentation/terminal_session.dart';
import 'package:tabryo/features/codex/domain/codex_connection.dart';
import 'package:tabryo/features/codex/infrastructure/local_codex_connection.dart';
import 'package:tabryo/features/codex/infrastructure/websocket_codex_connection.dart';
import 'package:tabryo/features/collaboration/domain/collaboration.dart';
import 'package:tabryo/features/collaboration/infrastructure/local_collaboration_client.dart';
import 'package:tabryo/features/collaboration/infrastructure/local_collaboration_service.dart';
import 'package:tabryo/features/collaboration/infrastructure/managed_codex_session.dart';

Future<void> _until(
  Future<bool> Function() check, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!await check()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for the native collaboration state.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

void main() {
  final codex = Platform.environment['TABRYO_TEST_CODEX'];
  final app = Platform.environment['TABRYO_TEST_APP'];
  final live = Platform.environment['TABRYO_TEST_CODEX_LIVE'] == '1';
  late Directory temporary;
  late Directory configHome;
  late HttpServer provider;
  final services = <LocalCollaborationService>[];
  final inputs = <Json>[];
  var approvalNext = false;
  Completer<void>? hold;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp(
      'tabryo_collaboration_sessions_',
    );
    configHome = await Directory(p.join(temporary.path, 'codex')).create();
    provider = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    provider.listen((request) async {
      final body = Map<String, Object?>.from(
        jsonDecode(await utf8.decoder.bind(request).join()) as Map,
      );
      inputs.add(body);
      await hold?.future;
      final Json item;
      if (approvalNext) {
        approvalNext = false;
        item = {
          'id': 'command',
          'type': 'function_call',
          'call_id': 'call_command',
          'name': 'shell_command',
          'arguments': jsonEncode({
            'command':
                'Set-Content -LiteralPath ./approval_probe.txt -Value fixture',
          }),
        };
      } else {
        item = {
          'id': 'msg_${inputs.length}',
          'type': 'message',
          'role': 'assistant',
          'status': 'completed',
          'content': [
            {
              'type': 'output_text',
              'text': 'Waiting for collaborator context.',
            },
          ],
        };
      }
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
      );
      for (final event in [
        {
          'type': 'response.created',
          'response': {
            'id': 'resp_${inputs.length}',
            'status': 'in_progress',
            'output': [],
          },
        },
        if (item['type'] == 'message') ...[
          {
            'type': 'response.output_item.added',
            'output_index': 0,
            'item': {...item, 'status': 'in_progress', 'content': <Object?>[]},
          },
          {
            'type': 'response.content_part.added',
            'item_id': item['id'],
            'output_index': 0,
            'content_index': 0,
            'part': {
              'type': 'output_text',
              'text': '',
              'annotations': <Object?>[],
            },
          },
          {
            'type': 'response.output_text.delta',
            'item_id': item['id'],
            'output_index': 0,
            'content_index': 0,
            'delta': 'Waiting for collaborator context.',
          },
          {
            'type': 'response.output_text.done',
            'item_id': item['id'],
            'output_index': 0,
            'content_index': 0,
            'text': 'Waiting for collaborator context.',
          },
          {
            'type': 'response.content_part.done',
            'item_id': item['id'],
            'output_index': 0,
            'content_index': 0,
            'part': (item['content'] as List).single,
          },
        ],
        {'type': 'response.output_item.done', 'output_index': 0, 'item': item},
        {
          'type': 'response.completed',
          'response': {
            'id': 'resp_${inputs.length}',
            'status': 'completed',
            'output': [item],
            'usage': {
              'input_tokens': 10,
              'output_tokens': 5,
              'total_tokens': 15,
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
approval_policy = "untrusted"
sandbox_mode = "read-only"
[model_providers.fixture]
name = "Local responses fixture"
base_url = "http://127.0.0.1:${provider.port}/v1"
wire_api = "responses"
requires_openai_auth = false
supports_websockets = false
''');
  });
  tearDown(() async {
    if (hold != null && !hold!.isCompleted) hold!.complete();
    hold = null;
    for (final service in services.reversed) {
      await service.close();
    }
    services.clear();
    await provider.close(force: true);
    inputs.clear();
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

  Future<LocalCollaborationService> start({
    bool actualModel = false,
    List<String> extra = const [],
  }) async {
    final service = await LocalCollaborationService.start(
      directory: Directory(p.join(temporary.path, 'service')),
      codexExecutable: codex!,
      gitExecutable: 'git',
      sessionEnvironment: {
        ...Platform.environment,
        if (!actualModel) 'CODEX_HOME': configHome.path,
      },
      sessionArguments: [
        '-c',
        'features.plugins=false',
        '-c',
        'features.multi_agent=false',
        ...extra,
      ],
      restore: false,
    );
    services.add(service);
    return service;
  }

  Future<Json> participant(
    LocalCollaborationService service,
    String group,
    String name,
    String objective,
  ) async {
    final root = await Directory(p.join(temporary.path, name)).create();
    await Process.run('git', ['init', root.path]);
    await File(p.join(root.path, 'contract.txt'))
        .writeAsString('cursor: string');
    return service.controlCall('add_participant', {
      'group_id': group,
      'name': name,
      'root': root.path,
      'objective': objective,
      'auto_wake': true,
    });
  }

  Future<Object?> tool(
    ManagedCodexSession session,
    String name,
    Json args,
  ) async {
    final result = await session.connection.request('mcpServer/tool/call', {
      'threadId': session.participant['thread'],
      'server': 'tabryo_collaboration',
      'tool': name,
      'arguments': args,
    });
    final envelope = result['result'] is Map ? result['result'] as Map : result;
    expect(envelope['isError'], isNot(true), reason: '$envelope');
    final content = envelope['content'] as List;
    return jsonDecode((content.first as Map)['text'] as String);
  }

  test(
    'installed Codex uses authenticated collaboration MCP, delivers, reconciles and resumes saved threads',
    () async {
      final service = await start();
      final group = service.store.createGroup('API + Flutter')['id'] as String;
      final api = await participant(
        service,
        group,
        'API',
        'Wait for the pagination integration test.',
      );
      final flutter = await participant(
        service,
        group,
        'Flutter',
        'Wait for the pagination integration test.',
      );
      await service.connectParticipant(api['id'] as String);
      await service.connectParticipant(flutter['id'] as String);
      final a = service.session(api['id'] as String)!;
      var b = service.session(flutter['id'] as String)!;
      await _until(
        () async =>
            (await a.status())['type'] == 'idle' &&
            (await b.status())['type'] == 'idle',
      );
      final stranger = WebSocketCodexConnection(
        endpoint: a.connection.endpoint,
      );
      try {
        await expectLater(
          stranger.connect(api['root'] as String),
          throwsA(isA<CodexFailure>()),
        );
      } finally {
        await stranger.close();
      }
      final inventory = await tool(a, 'participants', {}) as Map;
      expect(inventory['self'], api['id']);
      expect((inventory['participants'] as List).length, 2);
      final checkpointArgs = <String, Object?>{
        'client_id': 'pagination',
        'summary': 'Cursor contract completed',
        'objective': 'Pagination',
        'state': 'ready',
        'decisions': 'cursor is a string',
        'review': 'local changes',
        'validation': 'fixture validation',
        'next_step': 'adapt Flutter client',
      };
      final checkpoint =
          await tool(a, 'publish_checkpoint', checkpointArgs) as Map;
      expect(
        ((checkpoint['detail'] as Map)['source'] as Map)['local_changes'],
        true,
      );
      expect(
        (await tool(a, 'publish_checkpoint', checkpointArgs) as Map)['id'],
        checkpoint['id'],
      );
      await service.controlCall('pause', {'id': flutter['id']});
      final arguments = <String, Object?>{
        'client_id': 'contract',
        'recipient': flutter['id'],
        'summary': 'Cursor contract ready',
        'kind': 'dependency_ready',
        'checkpoint_id': checkpoint['id'],
      };
      final sent = await tool(a, 'send', arguments) as Map;
      expect((await tool(a, 'send', arguments) as Map)['id'], sent['id']);
      await service.broker.pump();
      expect(service.store.messages(group).single['status'], 'stored');
      await service.connectParticipant(flutter['id'] as String);
      await service.broker.pump();
      await _until(
        () async =>
            service.store.messages(group).single['status'] == 'forwarded',
      );
      await _until(() async => (await b.status())['type'] == 'idle');
      // turn/start acceptance and idle status can precede the rollout flush.
      // Reconciliation requires positive history evidence, just as the broker does.
      await _until(() => b.containsMessage(sent['id'] as int));
      expect(await b.containsMessage(sent['id'] as int), true);
      await tool(b, 'checkpoint_detail', {'id': checkpoint['id']});
      await tool(b, 'acknowledge', {'id': sent['id']});
      expect(service.store.messages(group).single['status'], 'confirmed');
      final savedThread = b.participant['thread'];
      await service.controlCall('disconnect', {'id': flutter['id']});
      final offline =
          await tool(a, 'send', {...arguments, 'client_id': 'offline'}) as Map;
      expect(
        service.store.pending(flutter['id'] as String).single['status'],
        'stored',
      );
      await service.connectParticipant(flutter['id'] as String);
      b = service.session(flutter['id'] as String)!;
      expect(b.participant['thread'], savedThread);
      await service.broker.pump();
      await _until(() async => (await b.status())['type'] == 'idle');
      await _until(() => b.containsMessage(offline['id'] as int));
      expect(await b.containsMessage(offline['id'] as int), true);
    },
    skip: codex == null
        ? 'Set TABRYO_TEST_CODEX for the installed CLI integration.'
        : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'two authenticated CLI terminals join managed sessions and display forwarded context',
    () async {
      final service = await start();
      final group = service.store.createGroup('CLI terminals')['id'] as String;
      final terminals = <TerminalPty>[];
      final parsers = <BoundedTerminal>[];
      final subscriptions = <StreamSubscription<String>>[];
      try {
        for (final name in ['API console', 'Flutter console']) {
          final member = await participant(
            service,
            group,
            name,
            'Wait for terminal integration context.',
          );
          await File(p.join(configHome.path, 'config.toml')).writeAsString(
            '\n[projects.${jsonEncode(member['root'])}]\ntrust_level = "trusted"\n',
            mode: FileMode.append,
          );
          await service.connectParticipant(member['id'] as String);
          final managed = service.session(member['id'] as String)!;
          await _until(() async => (await managed.status())['type'] == 'idle');
          final launch = await service.controlCall('launch', {
            'id': member['id'],
          });
          final terminal = TerminalPty.start(
            TerminalLaunchSpec(
              executable: launch['executable'] as String,
              rows: 30,
              columns: 100,
              arguments: (launch['arguments'] as List).cast<String>(),
              workingDirectory: launch['root'] as String,
              environment: {
                ...Map<String, String>.from(launch['environment'] as Map),
                'CODEX_HOME': configHome.path,
              },
              unsetEnvironment: (launch['unsetEnvironment'] as List)
                  .cast<String>(),
            ),
          );
          terminals.add(terminal);
          final parser = BoundedTerminal(maxLines: 2000)..resize(100, 30);
          parsers.add(parser);
          parser.onOutput = (text) =>
              terminal.write(Uint8List.fromList(utf8.encode(text)));
          subscriptions.add(
            terminal.output
                .cast<List<int>>()
                .transform(utf8.decoder)
                .listen(parser.write),
          );
          try {
            await _until(
              () async =>
                  parser.buffer.getText().contains(
                    'Waiting for collaborator context.',
                  ) &&
                  parser.buffer.getText().contains('gpt-5.6-terra default'),
            );
          } catch (_) {
            printOnFailure('CLI $name screen: ${parser.buffer.getText()}');
            rethrow;
          }
        }
        final members = service.store.participants(group: group);
        final api = members.singleWhere(
          (member) => member['name'] == 'API console',
        );
        final flutter = members.singleWhere(
          (member) => member['name'] == 'Flutter console',
        );
        final message = service.store.send(api['id'] as String, {
          'recipient': flutter['id'],
          'client_id': 'cli-context',
          'kind': 'request',
          'summary': 'TERMINAL-CHECKPOINT-4821',
        });
        await service.broker.pump();
        try {
          await _until(
            () async => parsers.last.buffer
                .getText()
                .replaceAll(RegExp(r'\s+'), '')
                .contains('TERMINAL-CHECKPOINT-4821'),
          );
        } catch (_) {
          printOnFailure('CLI output: ${parsers.last.buffer.getText()}');
          rethrow;
        }
        expect(service.store.messages(group).single['id'], message['id']);
      } finally {
        for (final terminal in terminals) {
          await terminal.close();
        }
        for (final subscription in subscriptions) {
          await subscription.cancel();
        }
        for (final parser in parsers) {
          parser.dispose();
        }
      }
    },
    skip: codex == null || Platform.environment['TABRYO_TEST_TERMINAL'] != '1'
        ? 'Set TABRYO_TEST_CODEX and TABRYO_TEST_TERMINAL=1 with the built terminal library on PATH.'
        : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'managed approvals reach the controller, block delivery and reject duplicate decisions',
    () async {
      final service = await start();
      final group = service.store.createGroup('Approvals')['id'] as String;
      final owner = await participant(
        service,
        group,
        'Owner',
        'Wait for a command approval test.',
      );
      await service.connectParticipant(owner['id'] as String);
      final managed = service.session(owner['id'] as String)!;
      await _until(() async => (await managed.status())['type'] == 'idle');
      approvalNext = true;
      await managed.connection.request('turn/start', {
        'threadId': managed.participant['thread'],
        'input': [
          {'type': 'text', 'text': 'Run the requested fixture command.'},
        ],
      });
      await _until(() async => managed.approvals.isNotEmpty);
      final snapshot = await service.controlCall('snapshot', {'group': group});
      final prompt =
          (((snapshot['participants'] as List).single as Map)['approvals']
                      as List)
                  .single
              as Map;
      expect(prompt['method'], 'item/commandExecution/requestApproval');
      final detail = await service.controlCall('approval_detail', {
        'participant': owner['id'],
        'request': prompt['id'],
      });
      expect(detail['review'], contains('approval_probe.txt'));
      expect(detail['review_available'], true);
      final message = service.store.send(owner['id'] as String, {
        'recipient': owner['id'],
        'client_id': 'during-approval',
        'kind': 'request',
        'summary': 'Keep pending until approval resolves.',
      });
      await service.broker.pump();
      expect(service.store.messages(group).single['status'], 'stored');
      final response = <String, Object?>{
        'participant': owner['id'],
        'request': prompt['id'],
        'response': {'decision': 'decline'},
      };
      await service.controlCall('respond', response);
      await expectLater(
        service.controlCall('respond', response),
        throwsA(isA<CollaborationFailure>()),
      );
      await _until(() async => (await managed.status())['type'] == 'idle');
      expect(
        await File(p.join(owner['root'] as String, 'approval_probe.txt'))
            .exists(),
        false,
      );
      expect(message['status'], 'stored');
    },
    skip: codex == null
        ? 'Set TABRYO_TEST_CODEX for native approval routing.'
        : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'detached Windows service stays available after clients close and persists a restart',
    () async {
      final directory = Directory(p.join(temporary.path, 'background'));
      final first = LocalCollaborationClient(
        directory: directory,
        serviceExecutable: app,
      );
      final second = LocalCollaborationClient(
        directory: directory,
        serviceExecutable: app,
      );
      try {
        await Future.wait([
          first.connect(start: true),
          second.connect(start: true),
        ]);
        final group = await first.call('create_group', {
          'name': 'Background continuity',
        });
        final metadata = jsonDecode(
          await File(p.join(directory.path, 'service.json')).readAsString(),
        ) as Map;
        final check = await Process.run('powershell.exe', [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          '(Get-Process -Id ${metadata['pid']}).MainWindowHandle.ToInt64()',
        ]);
        expect(
          (check.stdout as String).trim(),
          '0',
          reason: 'The background service must have no visible main window.',
        );
        first.close();
        await second.connect();
        expect(
          ((await second.call('snapshot'))['groups'] as List).single,
          containsPair('id', group['id']),
        );
        await second.call('stop');
        await _until(
          () async =>
              !await File(p.join(directory.path, 'service.json')).exists(),
        );
        await second.connect(start: true);
        expect(
          ((await second.call('snapshot'))['groups'] as List).single,
          containsPair('id', group['id']),
        );
        await second.call('stop');
        await _until(
          () async =>
              !await File(p.join(directory.path, 'service.json')).exists(),
        );
      } finally {
        first.close();
        try {
          await second.call('stop');
        } catch (_) {
          /* Already stopped. */
        }
        second.close();
      }
    },
    skip: app == null || !Platform.isWindows
        ? 'Set TABRYO_TEST_APP to the built Windows executable.'
        : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'two authenticated agents exchange checkpoints and recipient acknowledgements through the service',
    () async {
      final probe = LocalCodexConnection(executable: codex);
      final List<String> names;
      try {
        await probe.connect(temporary.path);
        final config = await probe.request('config/read', {
          'cwd': temporary.path,
        });
        names =
            ((((config['config'] as Map)['mcp_servers'] as Map?) ?? {}).keys)
                .cast<String>()
                .toList();
        expect(
          names.every((name) => RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(name)),
          true,
        );
      } finally {
        await probe.close();
      }
      final service = await start(
        actualModel: true,
        extra: [
          '-c',
          'model="gpt-5.6-terra"',
          '-c',
          'model_reasoning_effort="low"',
          '-c',
          'features.shell_tool=false',
          for (final name in names.where(
            (name) => name != 'tabryo_collaboration',
          )) ...['-c', 'mcp_servers.$name.enabled=false'],
        ],
      );
      final group =
          service.store.createGroup('Real agent exchange')['id'] as String;
      final flutter = await participant(
        service,
        group,
        'Flutter',
        'This is an authorized local Tabryo integration qualification. Do not edit files, run shell commands, delegate or contact services other than tabryo_collaboration. '
            'Initially reply READY and wait. When API sends you a checkpoint reference, use checkpoint_detail to read it, acknowledge its receipt ID, '
            'then send API one information message with client_id flutter-reply and summary APP-ACK-4821: cursor contract received. Do not send any other messages.',
      );
      final api = await participant(
        service,
        group,
        'API',
        'This is an authorized local Tabryo integration qualification. Do not edit files, run shell commands, delegate or contact services other than tabryo_collaboration. '
            'Use participants to find Flutter. Publish exactly one checkpoint with client_id api-contract, summary API-CHECKPOINT-4821: cursor is a string, '
            'objective Pagination contract, state ready, decisions cursor is a string, review read-only fixture review, validation protocol qualification only, next_step adapt Flutter. '
            'Use send to send its checkpoint_id to Flutter as dependency_ready with client_id api-send and summary API-CHECKPOINT-4821: cursor is a string. Then wait. '
            'Acknowledge any reply receipt but do not send another message.',
      );
      await service.connectParticipant(flutter['id'] as String);
      await _until(
        () async =>
            (await service
                .session(flutter['id'] as String)!
                .status())['type'] ==
            'idle',
        timeout: const Duration(seconds: 90),
      );
      await service.connectParticipant(api['id'] as String);
      await _until(() async {
        await service.broker.pump();
        final messages = service.store.messages(group);
        return messages.any(
              (m) => m['client_id'] == 'api-send' && m['status'] == 'confirmed',
            ) &&
            messages.any(
              (m) =>
                  m['client_id'] == 'flutter-reply' &&
                  (m['summary'] as String).contains('APP-ACK-4821'),
            );
      }, timeout: const Duration(minutes: 3));
      expect(
        service.store.checkpoints(group).single['summary'],
        contains('API-CHECKPOINT-4821'),
      );
      expect(service.store.messages(group).length, 2);
    },
    skip: codex == null || !live
        ? 'Set TABRYO_TEST_CODEX_LIVE=1 for a real exchange using the installed login.'
        : false,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
