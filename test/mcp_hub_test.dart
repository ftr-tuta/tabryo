import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabryo/features/codex/domain/codex_connection.dart';
import 'package:tabryo/features/mcp/application/mcp_hub.dart';
import 'package:tabryo/features/mcp/domain/mcp_server.dart';
import 'package:tabryo/features/mcp/presentation/mcp_hub_screen.dart';
import 'package:tabryo/features/mcp/presentation/mcp_hub_view_model.dart';

final class MemoryCodex implements CodexConnection {
  final controller = StreamController<CodexEvent>.broadcast();
  final requests = <(String, Map<String, Object?>)>[];
  bool open = false;
  bool failStart = false;
  bool versionConflict = false;
  bool repeatCursor = false;
  bool projectOverride = false;
  int connections = 0;
  int version = 1;
  Completer<Map<String, Object?>>? toolResult;
  final definitions = <String, Object?>{
    'echo': <String, Object?>{
      'command': 'dart',
      'args': ['server.dart'],
      'enabled': true,
      'env': {'SECRET': 'sentinel-credential'},
      'future_option': {'retain': true},
    },
  };
  @override
  bool get connected => open;
  @override
  Stream<CodexEvent> get events => controller.stream;
  @override
  Future<void> connect(String workspace) async {
    open = true;
    connections++;
  }

  @override
  Future<void> close() async {
    open = false;
  }

  @override
  Future<Map<String, Object?>> request(
    String method,
    Map<String, Object?> parameters,
  ) async {
    requests.add((method, parameters));
    switch (method) {
      case 'config/read':
        return {
          'config': {'mcp_servers': jsonDecode(jsonEncode(definitions))},
          'layers': [
            {
              'name': {
                'type': 'user',
                'file': Platform.isWindows
                    ? r'C:\user\config.toml'
                    : '/user/config.toml',
              },
              'version': 'v$version',
              'config': {'mcp_servers': jsonDecode(jsonEncode(definitions))},
            },
            if (projectOverride)
              {
                'name': {
                  'type': 'project',
                  'dotCodexFolder': '/project/.codex',
                },
                'version': 'p1',
                'config': {
                  'mcp_servers': {
                    'echo': {'command': 'other'},
                  },
                },
              },
          ],
          'origins': {},
        };
      case 'thread/start':
        if (failStart) {
          throw const CodexFailure('A required server failed to start.');
        }
        return {
          'thread': {'id': 'inspection'},
        };
      case 'mcpServerStatus/list':
        return {
          'data': [
            for (final name in definitions.keys)
              {
                'name': name,
                'authStatus': 'unsupported',
                'tools': {
                  if (name == 'dart_flutter')
                    'dtd': {
                      'name': 'dtd',
                      'inputSchema': {'type': 'object'},
                    },
                  'echo': {
                    'name': 'echo',
                    'inputSchema': {'type': 'object'},
                  },
                },
                'resources': [
                  {'name': 'Hello', 'uri': 'fixture://hello'},
                ],
                'resourceTemplates': [],
              },
          ],
          'nextCursor': repeatCursor ? 'same' : null,
        };
      case 'config/batchWrite':
        if (versionConflict || parameters['expectedVersion'] != 'v$version') {
          throw const CodexFailure(
            'Configuration changed. Refresh and review a new preview.',
          );
        }
        for (final raw in parameters['edits'] as List) {
          final edit = raw as Map;
          final keys = (edit['keyPath'] as String).split('.');
          if (keys.length == 2) {
            if (edit['value'] == null) {
              definitions.remove(keys[1]);
            } else {
              definitions[keys[1]] = edit['value'];
            }
          } else {
            (definitions[keys[1]] as Map)[keys[2]] = edit['value'];
          }
        }
        version++;
        return {'status': 'ok', 'version': 'v$version'};
      case 'mcpServer/tool/call':
        return toolResult?.future ??
            {
              'content': [
                {
                  'type': 'text',
                  'text': 'sentinel-credential Bearer another-secret',
                },
              ],
              'token': 'hidden-value',
            };
      case 'mcpServer/resource/read':
        return {
          'contents': [
            {'uri': 'fixture://hello', 'text': 'Hello'},
          ],
        };
      case 'mcpServer/oauth/login':
        return {
          'authorizationUrl': 'https://auth.example/authorize?state=private',
        };
      default:
        throw StateError('Unexpected request $method');
    }
  }
}

void main() {
  late MemoryCodex connection;
  late McpHub hub;
  late McpHubViewModel model;
  final root = Platform.isWindows ? r'C:\project' : '/project';
  setUp(() {
    connection = MemoryCodex();
    hub = McpHub(connection);
    model = McpHubViewModel(hub);
  });
  tearDown(() async {
    await model.disposeAsync();
    await connection.controller.close();
  });

  Future<void> connect() async {
    await model.selectWorkspace(root);
    expect(await model.connect(), true);
  }

  test('construction and workspace selection start no process', () async {
    await model.selectWorkspace(root);
    expect(connection.connections, 0);
    expect(connection.requests, isEmpty);
  });

  test('Dart session sharing requires the selected SDK and rejects retired sessions or tool errors', () async {
    final sdk = McpServerDraft(
      name: 'dart_flutter',
      transport: McpTransport.stdio,
      command: '$root/dart',
      arguments: ['mcp-server', '--dart-sdk', root],
      workingDirectory: root,
    );
    connection.definitions['dart_flutter'] = {
      'command': 'different-sdk',
      'args': sdk.arguments,
      'cwd': root,
    };
    await connect();
    final uri = Uri.parse('ws://127.0.0.1:4321/session/');
    int calls() => connection.requests
        .where((request) => request.$1 == 'mcpServer/tool/call')
        .length;
    expect(await model.connectDartSession(sdk, uri, () => true), isFalse);
    expect(calls(), 0);
    (connection.definitions['dart_flutter'] as Map)['command'] = sdk.command;
    await model.refresh();
    expect(await model.connectDartSession(sdk, uri, () => false), isFalse);
    expect(calls(), 0);
    expect(await model.connectDartSession(sdk, uri, () => true), isTrue);
    expect(connection.requests.last.$2['arguments'], {
      'command': 'connect',
      'uri': uri.toString(),
    });
    final result = connection.toolResult = Completer<Map<String, Object?>>();
    var current = true;
    final connecting = model.connectDartSession(sdk, uri, () => current);
    await Future<void>.delayed(Duration.zero);
    current = false;
    result.complete({'content': [], 'isError': false});
    expect(await connecting, isFalse);
    expect(model.inspection, isNull);
    connection.toolResult = Completer<Map<String, Object?>>()
      ..complete({'isError': true, 'content': []});
    expect(await model.connectDartSession(sdk, uri, () => true), isFalse);
    expect(model.message, contains('could not connect'));
  });

  test(
    'approved edits are immutable and fabricated edits are refused',
    () async {
      await connect();
      final arguments = ['original.dart'];
      final change = hub.configure(
        McpServerDraft(
          name: 'echo',
          transport: McpTransport.stdio,
          arguments: arguments,
        ),
        editing: true,
      );
      arguments[0] = 'changed.dart';
      expect(change.edits.single['value'], ['original.dart']);
      expect(
        () => (change.edits.single['value'] as List).add('other'),
        throwsUnsupportedError,
      );
      final fabricated = McpConfigChange(
        filePath: change.filePath,
        expectedVersion: change.expectedVersion,
        edits: const [
          {
            'keyPath': 'approval_policy',
            'value': 'never',
            'mergeStrategy': 'replace',
          },
        ],
        description: 'Unrelated edit',
        preview: '',
      );
      await expectLater(hub.apply(fabricated), throwsA(isA<CodexFailure>()));
      expect(
        connection.requests.any((r) => r.$1 == 'config/batchWrite'),
        false,
      );
      await hub.apply(change);
      expect((connection.definitions['echo'] as Map)['args'], [
        'original.dart',
      ]);
    },
  );

  test(
    'a previously selected server cannot be called after disabling it',
    () async {
      await connect();
      final old = hub.servers.single;
      await hub.apply(hub.setEnabled(old, false));
      await expectLater(
        hub.callTool(old, 'echo', {}),
        throwsA(isA<CodexFailure>()),
      );
      expect(
        connection.requests.any((r) => r.$1 == 'mcpServer/tool/call'),
        false,
      );
    },
  );

  test('inspection strips credential-bearing URL components', () async {
    await connect();
    final result = hub.inspect({
      'text': 'https://name:password@host.example/mcp?token=private-value',
    });
    expect(result, contains('https://host.example/mcp'));
    expect(result, isNot(contains('password')));
    expect(result, isNot(contains('private-value')));
  });

  test('OAuth completion clears the transient sign-in URL', () async {
    connection.definitions['echo'] = {'url': 'https://server.example/mcp'};
    await connect();
    expect(await model.authenticate(model.servers.single), true);
    expect(model.authorizationUrl, startsWith('https://auth.example/'));
    connection.controller.add(
      const CodexEvent('mcpServer/oauthLogin/completed', {
        'name': 'echo',
        'success': true,
      }),
    );
    await Future<void>.delayed(Duration.zero);
    expect(model.authorizationUrl, isNull);
    expect(model.message, contains('Authentication completed'));
  });

  testWidgets(
    'tool execution waits for review and fits a scaled narrow window',
    (tester) async {
      tester.view.physicalSize = const Size(650, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await connect();
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.5)),
            child: child!,
          ),
          home: McpHubScreen(model: model),
        ),
      );
      await tester.pumpAndSettle();
      final tool = find.widgetWithText(ListTile, 'echo');
      await tester.ensureVisible(tool);
      await tester.tap(tool);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Review call'));
      await tester.pumpAndSettle();
      expect(
        connection.requests.any((r) => r.$1 == 'mcpServer/tool/call'),
        false,
      );
      await tester.tap(find.text('Call tool'));
      await tester.pumpAndSettle();
      expect(
        connection.requests.where((r) => r.$1 == 'mcpServer/tool/call').length,
        1,
      );
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'edits preserve unknown fields and use the approved file version',
    () async {
      await connect();
      final change = hub.configure(
        const McpServerDraft(
          name: 'echo',
          transport: McpTransport.stdio,
          arguments: ['updated.dart'],
        ),
        editing: true,
      );
      expect(
        connection.requests.where((r) => r.$1 == 'config/batchWrite'),
        isEmpty,
      );
      expect(change.expectedVersion, 'v1');
      expect(change.preview, isNot(contains('sentinel-credential')));
      await hub.apply(change);
      final written = connection.requests
          .singleWhere((r) => r.$1 == 'config/batchWrite')
          .$2;
      expect(written['expectedVersion'], 'v1');
      expect(written['edits'], [
        {
          'keyPath': 'mcp_servers.echo.args',
          'value': ['updated.dart'],
          'mergeStrategy': 'replace',
        },
      ]);
      expect((connection.definitions['echo'] as Map)['future_option'], {
        'retain': true,
      });
      expect(connection.connections, 2);
    },
  );

  test(
    'rejects stale previews and propagates external version conflicts',
    () async {
      await connect();
      final change = hub.setEnabled(hub.servers.single, false);
      connection.versionConflict = true;
      await expectLater(hub.apply(change), throwsA(isA<CodexFailure>()));
      expect((connection.definitions['echo'] as Map)['enabled'], true);
      connection.versionConflict = false;
      connection.version++;
      await hub.readConfiguration();
      final writes = connection.requests
          .where((r) => r.$1 == 'config/batchWrite')
          .length;
      await expectLater(hub.apply(change), throwsA(isA<CodexFailure>()));
      expect(
        connection.requests.where((r) => r.$1 == 'config/batchWrite').length,
        writes,
      );
    },
  );

  test('project overrides cannot be edited or implicitly trusted', () async {
    connection.projectOverride = true;
    await connect();
    expect(hub.servers.single.editable, false);
    expect(
      () => hub.setEnabled(hub.servers.single, false),
      throwsA(isA<CodexFailure>()),
    );
    expect(connection.requests.any((r) => r.$1.contains('Write')), false);
  });

  test(
    'invalid names, remote plaintext and credential URLs are refused',
    () async {
      await connect();
      for (final draft in [
        const McpServerDraft(
          name: 'x.enabled',
          transport: McpTransport.stdio,
          command: 'dart',
        ),
        const McpServerDraft(
          name: 'remote',
          transport: McpTransport.streamableHttp,
          url: 'http://remote.example/mcp',
        ),
        const McpServerDraft(
          name: 'remote',
          transport: McpTransport.streamableHttp,
          url: 'https://secret@remote.example/mcp',
        ),
        const McpServerDraft(
          name: 'remote',
          transport: McpTransport.streamableHttp,
          url: 'https://remote.example/mcp?token=secret',
        ),
        const McpServerDraft(
          name: 'remote',
          transport: McpTransport.streamableHttp,
          url: 'https://remote.example/mcp',
          bearerEnvironmentName: 'SECRET=value',
        ),
      ]) {
        expect(() => hub.configure(draft), throwsA(isA<CodexFailure>()));
      }
    },
  );

  test(
    'a required server startup failure leaves configuration repair available',
    () async {
      connection.failStart = true;
      await model.selectWorkspace(root);
      expect(await model.connect(), false);
      expect(model.connected, true);
      expect(model.servers.single.name, 'echo');
      expect(hub.setEnabled(model.servers.single, false).edits, isNotEmpty);
    },
  );

  test('inventory cursor cycles terminate with a recoverable error', () async {
    connection.repeatCursor = true;
    await model.selectWorkspace(root);
    expect(await model.connect(), false);
    expect(model.message, contains('repeated a page'));
    expect(
      connection.requests.where((r) => r.$1 == 'mcpServerStatus/list').length,
      2,
    );
  });

  test(
    'tool calls use the inspection session and redact known credentials',
    () async {
      await connect();
      expect(
        await model.callTool(model.servers.single, 'echo', {'value': 'hi'}),
        true,
      );
      expect(model.inspection, isNot(contains('sentinel-credential')));
      expect(model.inspection, isNot(contains('another-secret')));
      expect(model.inspection, isNot(contains('hidden-value')));
      final call = connection.requests.last;
      expect(call.$1, 'mcpServer/tool/call');
      expect(call.$2, {
        'threadId': 'inspection',
        'server': 'echo',
        'tool': 'echo',
        'arguments': {'value': 'hi'},
      });
    },
  );

  test(
    'disconnect clears transient results and rejects a late tool result',
    () async {
      await connect();
      connection.toolResult = Completer<Map<String, Object?>>();
      final pending = model.callTool(model.servers.single, 'echo', {});
      await model.disconnect();
      connection.toolResult!.complete({
        'content': ['late result'],
      });
      await pending;
      expect(model.inspection, isNull);
      expect(model.servers, isEmpty);
      expect(model.connected, false);
    },
  );

  testWidgets(
    'Hub previews official SDK registration and cancellation leaves configuration intact',
    (tester) async {
      await connect();
      await tester.pumpWidget(
        MaterialApp(
          home: McpHubScreen(
            model: model,
            dartFlutterServer: () async => McpServerDraft(
              name: 'dart_flutter',
              transport: McpTransport.stdio,
              command: '$root/dart',
              arguments: const ['mcp-server'],
              workingDirectory: root,
            ),
          ),
        ),
      );
      await tester.tap(find.text('Register Dart/Flutter SDK'));
      await tester.pumpAndSettle();
      expect(find.text('Save and reconnect'), findsOneWidget);
      expect(
        connection.requests.any((r) => r.$1 == 'config/batchWrite'),
        isFalse,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(connection.definitions, isNot(contains('dart_flutter')));
      await tester.tap(find.text('Register Dart/Flutter SDK'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save and reconnect'));
      await tester.pumpAndSettle();
      expect((connection.definitions['dart_flutter'] as Map)['args'], [
        'mcp-server',
      ]);
      expect(jsonEncode(connection.definitions), isNot(contains('ws://')));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Hub requires explicit connection and previews a disable before writing',
    (tester) async {
      await model.selectWorkspace(root);
      await tester.pumpWidget(MaterialApp(home: McpHubScreen(model: model)));
      expect(connection.connections, 0);
      await tester.tap(find.text('Connect Codex'));
      await tester.pumpAndSettle();
      expect(
        find.text('Inventory reported by Codex'),
        findsNothing,
      ); // Narrow layout uses the selector.
      await tester.tap(find.text('Disable'));
      await tester.pumpAndSettle();
      expect(find.text('Save and reconnect'), findsOneWidget);
      expect(
        connection.requests.any((r) => r.$1 == 'config/batchWrite'),
        false,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(
        connection.requests.any((r) => r.$1 == 'config/batchWrite'),
        false,
      );
      await tester.tap(find.text('Disable'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save and reconnect'));
      await tester.pumpAndSettle();
      expect((connection.definitions['echo'] as Map)['enabled'], false);
      expect(find.text('Enable'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
