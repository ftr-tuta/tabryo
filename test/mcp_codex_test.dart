import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tabryo/features/codex/domain/codex_connection.dart';
import 'package:tabryo/features/codex/infrastructure/local_codex_connection.dart';
import 'package:tabryo/features/editor_context/application/editor_context_service.dart';
import 'package:tabryo/features/editor_context/domain/editor_context.dart';
import 'package:tabryo/features/editor_context/infrastructure/local_editor_context.dart';
import 'package:tabryo/features/mcp/application/mcp_hub.dart';
import 'package:tabryo/features/mcp/domain/mcp_server.dart';

// The fixture implements real MCP messages. It has no access to user files or
// credentials and does not invoke a model. Both transports share its responses.
const mcpFixture = r'''
import 'dart:convert';
import 'dart:io';

Map<String, Object?> response(Map<String, dynamic> message) {
  final params = message['params'] as Map? ?? {};
  final result = switch (message['method']) {
    'initialize' => {'protocolVersion': params['protocolVersion'], 'capabilities': {'tools': {}, 'resources': {}}, 'serverInfo': {'name': 'fixture', 'version': '1.0.0'}},
    'tools/list' => {'tools': [{'name': 'echo', 'description': 'Returns the input value.', 'inputSchema': {'type': 'object', 'properties': {'value': {'type': 'string'}}, 'required': ['value']}, 'annotations': {'readOnlyHint': true, 'destructiveHint': false}}]},
    'resources/list' => {'resources': [{'name': 'Greeting', 'uri': 'fixture://greeting', 'mimeType': 'text/plain'}]},
    'resources/templates/list' => {'resourceTemplates': []},
    'resources/read' => {'contents': [{'uri': 'fixture://greeting', 'mimeType': 'text/plain', 'text': 'hello resource'}]},
    'tools/call' => {'content': [{'type': 'text', 'text': '${(params['arguments'] as Map?)?['value']}'}]},
    'ping' => <String, Object?>{},
    _ => null,
  };
  return {'jsonrpc': '2.0', 'id': message['id'], if (result != null) 'result': result else 'error': {'code': -32601, 'message': 'Method not found'}};
}

Future<void> main(List<String> arguments) async {
  if (arguments.isEmpty) {
    await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
      final message = jsonDecode(line) as Map<String, dynamic>;
      if (message['id'] != null) stdout.writeln(jsonEncode(response(message)));
    }
  } else {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    stdout.writeln(server.port);
    await for (final request in server) {
      if (request.method != 'POST') { request.response.statusCode = 405; await request.response.close(); continue; }
      final message = jsonDecode(await utf8.decoder.bind(request).join()) as Map<String, dynamic>;
      if (message['id'] == null) { request.response.statusCode = 202; }
      else { request.response.headers.contentType = ContentType.json; request.response.write(jsonEncode(response(message))); }
      await request.response.close();
    }
  }
}
''';

void main() {
  final codex = Platform.environment['TABRYO_TEST_CODEX'];
  final dart = Platform.environment['TABRYO_TEST_DART'];
  final enabled = codex != null && dart != null;
  late Directory temporary;
  late Directory configHome;
  late Directory workspace;
  late File config;
  late File server;
  late LocalCodexConnection connection;
  late McpHub hub;
  final children = <Process>[];

  setUp(() async {
    if (!enabled) return;
    temporary = await Directory.systemTemp.createTemp('tabryo_mcp_test_');
    configHome = await Directory(p.join(temporary.path, 'user')).create();
    workspace = await Directory(p.join(temporary.path, 'workspace')).create();
    config = File(p.join(configHome.path, 'config.toml'));
    await config.writeAsString(
      '# preserve user comment\nmodel = "gpt-5.6-terra"\n',
    );
    server = await File(p.join(workspace.path, 'server.dart'))
        .writeAsString(mcpFixture);
    connection = LocalCodexConnection(
      executable: codex,
      environment: {'CODEX_HOME': configHome.path, 'RUST_LOG': 'off'},
    );
    hub = McpHub(connection);
  });
  tearDown(() async {
    if (!enabled) return;
    await hub.close();
    for (final child in children) {
      child.kill();
      await child.exitCode;
    }
    children.clear();
    // Only this test's newly created directory is removed.
    expect(
      p.dirname(temporary.absolute.path),
      Directory.systemTemp.absolute.path,
    );
    // Windows can briefly retain a sharing lock after process exit. Bound the
    // cleanup wait; a persistent lock still fails the test.
    for (var attempt = 0; attempt < 100; attempt++) {
      try {
        if (await temporary.exists()) await temporary.delete(recursive: true);
        break;
      } on FileSystemException catch (error) {
        if (attempt == 99 || ![5, 32].contains(error.osError?.errorCode)) {
          rethrow;
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  test(
    'installed Codex preserves TOML, rejects a stale version and removes only the selected server',
    () async {
      await connection.connect(workspace.path);
      final configRead = await connection.request('config/read', {
        'cwd': workspace.path,
        'includeLayers': true,
      });
      final user = (configRead['layers'] as List).cast<Map>().singleWhere(
        (l) => (l['name'] as Map)['type'] == 'user',
      );
      final version = user['version'];
      await config.writeAsString(
        '# concurrent comment\nmodel_reasoning_effort = "low"\n',
        mode: FileMode.append,
      );
      await expectLater(
        connection.request('config/batchWrite', {
          'filePath': config.path,
          'expectedVersion': version,
          'edits': [
            {
              'keyPath': 'mcp_servers.sample',
              'value': {'command': dart, 'enabled': false},
              'mergeStrategy': 'replace',
            },
          ],
        }),
        throwsA(isA<CodexFailure>()),
      );
      expect(await config.readAsString(), contains('# concurrent comment'));
      expect(await config.readAsString(), isNot(contains('mcp_servers')));
      await hub.connect(workspace.path);
      final change = hub.configure(
        McpServerDraft(
          name: 'sample',
          transport: McpTransport.stdio,
          command: dart,
          arguments: [server.path],
        ),
      );
      await hub.apply(change);
      expect(await config.readAsString(), contains('# preserve user comment'));
      expect(await config.readAsString(), contains('# concurrent comment'));
      expect(hub.servers.single.name, 'sample');
      await hub.apply(hub.remove(hub.servers.single));
      final content = await config.readAsString();
      expect(content, contains('model = "gpt-5.6-terra"'));
      expect(content, contains('# preserve user comment'));
      expect(content, isNot(contains('[mcp_servers.sample]')));
      expect(hub.servers, isEmpty);
    },
    skip: enabled ? false : 'Set TABRYO_TEST_CODEX and TABRYO_TEST_DART for isolated Codex protocol tests.',
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'a standalone client does not inherit the parent Desktop tools context',
    () async {
      await File(p.join(workspace.path, 'app-server')).writeAsString(r'''
import 'dart:convert';
import 'dart:io';
Future<void> main() async {
  await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map;
    if (message['id'] == null) continue;
    stdout.writeln(jsonEncode({'id': message['id'], 'result': {
      'desktopContext': ['CODEX_APP_TOOLS_PIPE_PATH', 'CODEX_THREAD_ID', 'CODEX_SESSION_ID', 'CODEX_INTERNAL_ORIGINATOR_OVERRIDE'].any(Platform.environment.containsKey),
      'policyRetained': Platform.environment['CODEX_PERMISSION_PROFILE'] == 'test-policy',
      'homeRetained': Platform.environment['CODEX_HOME'] != null,
    }}));
  }
}
''');
      final independent = LocalCodexConnection(
        executable: dart,
        environment: {
          'CODEX_APP_TOOLS_PIPE_PATH': 'private-parent-pipe',
          'CODEX_THREAD_ID': 'private-parent-thread',
          'CODEX_SESSION_ID': 'private-parent-session',
          'CODEX_INTERNAL_ORIGINATOR_OVERRIDE': 'private-parent-client',
          'CODEX_PERMISSION_PROFILE': 'test-policy',
          'CODEX_HOME': configHome.path,
        },
      );
      try {
        await independent.connect(workspace.path);
        expect(await independent.request('environment/read', {}), {
          'desktopContext': false,
          'policyRetained': true,
          'homeRetained': true,
        });
      } finally {
        await independent.close();
      }
    },
    skip: enabled ? false : 'Set TABRYO_TEST_CODEX and TABRYO_TEST_DART for isolated protocol tests.',
  );

  test(
    'installed Codex reads a scoped editor share and queues a reviewed replacement',
    () async {
      final context = EditorContextService(LocalEditorContext());
      addTearDown(context.dispose);
      await context.publish(
        EditorContextSnapshot(
          id: 'editor-selection',
          workspace: workspace.path,
          path: p.join(workspace.path, 'main.dart'),
          version: 3,
          start: 10,
          end: 14,
          text: 'ação',
          dirty: true,
          capturedAt: DateTime.now(),
        ),
        'Codex',
      );
      final endpoint = context.connection!;
      await config.writeAsString(
        '\n[mcp_servers.editor]\nurl = ${jsonEncode('${endpoint.endpoint}')}\n'
        'http_headers = { Authorization = ${jsonEncode('Bearer ${endpoint.token}')} }\n',
        mode: FileMode.append,
      );
      await hub.connect(workspace.path);
      final selected = hub.servers.singleWhere((s) => s.name == 'editor');
      expect(
        selected.tools.keys,
        containsAll([
          'editor_context',
          'propose_replacement',
          'proposal_status',
        ]),
      );
      expect(
        await hub.readResource(selected, 'tabryo://editor/context'),
        contains('ação'),
      );
      expect(
        await hub.callTool(selected, 'editor_context', {}),
        contains('editor-selection'),
      );
      expect(
        await hub.callTool(selected, 'propose_replacement', {
          'client_id': 'codex-review',
          'snapshot_id': 'editor-selection',
          'text': 'revisão',
        }),
        contains('pending'),
      );
      final proposal = context.proposals.values.single;
      expect(proposal.text, 'revisão');
      context.decided(proposal, applied: false);
      expect(
        await hub.callTool(selected, 'proposal_status', {
          'client_id': 'codex-review',
        }),
        contains('rejected'),
      );
      await context.revoke();
      await expectLater(
        hub.callTool(selected, 'editor_context', {}),
        throwsA(isA<CodexFailure>()),
      );
    },
    skip: enabled ? false : 'Set TABRYO_TEST_CODEX and TABRYO_TEST_DART for isolated Codex protocol tests.',
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'installed Codex discovers and calls real STDIO and Streamable HTTP MCP servers',
    () async {
      final http = await Process.start(dart!, [server.path, 'http']);
      children.add(http);
      final stderr = http.stderr.listen((_) {});
      addTearDown(stderr.cancel);
      final lines = http.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      final port = int.parse(
        await lines.first.timeout(const Duration(seconds: 15)),
      );
      await config.writeAsString(
        '\n[mcp_servers.local]\ncommand = ${jsonEncode(dart)}\nargs = [${jsonEncode(server.path)}]\n'
        '\n[mcp_servers.http]\nurl = "http://127.0.0.1:$port/mcp"\n',
        mode: FileMode.append,
      );
      await hub.connect(workspace.path);
      expect(hub.servers.map((s) => s.name), containsAll(['local', 'http']));
      for (final name in ['local', 'http']) {
        final selected = hub.servers.singleWhere((s) => s.name == name);
        expect(selected.tools, contains('echo'));
        final result = await hub.callTool(selected, 'echo', {
          'value': 'ação $name',
        });
        expect(result, contains('ação $name'));
        expect(
          await hub.readResource(selected, 'fixture://greeting'),
          contains('hello resource'),
        );
      }
      final local = hub.servers.singleWhere((s) => s.name == 'local');
      await hub.apply(hub.setEnabled(local, false));
      expect(hub.servers.singleWhere((s) => s.name == 'local').enabled, false);
      await expectLater(
        hub.callTool(
          hub.servers.singleWhere((s) => s.name == 'local'),
          'echo',
          {},
        ),
        throwsA(isA<CodexFailure>()),
      );
    },
    skip: enabled ? false : 'Set TABRYO_TEST_CODEX and TABRYO_TEST_DART for isolated Codex protocol tests.',
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
