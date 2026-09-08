Map<String, String> dartProject(String name) => {
  'pubspec.yaml': '''name: $name
description: A local MCP server with a greeting tool, resource and prompt.
version: 0.1.0
publish_to: none
environment:
  sdk: '>=3.11.0 <4.0.0'
dependencies:
  dart_mcp: 0.5.2
dev_dependencies:
  test: 1.32.0
''',
  '.gitignore': '.dart_tool/\nbuild/\n',
  'bin/server.dart':
      '''import 'dart:io';
import 'package:dart_mcp/stdio.dart';
import 'package:$name/server.dart';

void main() {
  GreetingServer(stdioChannel(input: stdin, output: stdout));
}
''',
  'lib/server.dart': r'''import 'package:dart_mcp/server.dart';

// STDOUT belongs to the MCP protocol. Send application logs to stderr.
base class GreetingServer extends MCPServer
    with ToolsSupport, ResourcesSupport, PromptsSupport {
  GreetingServer(super.channel)
      : super.fromStreamChannel(
          implementation: Implementation(name: 'greeting', version: '0.1.0'),
        ) {
    registerTool(
      Tool(name: 'greet', description: 'Create a friendly greeting.',
        inputSchema: Schema.object(
          properties: {'name': Schema.string()}, required: ['name'])),
      (request) => CallToolResult(content: [
        TextContent(text: greet(request.arguments!['name'] as String)),
      ]),
    );
    addResource(
      Resource(uri: 'greeting://info', name: 'Greeting information', mimeType: 'text/plain'),
      (request) => ReadResourceResult(contents: [
        TextResourceContents(uri: request.uri, text: 'A local greeting server.'),
      ]),
    );
    addPrompt(
      Prompt(name: 'welcome', description: 'Draft a welcome message.',
        arguments: [PromptArgument(name: 'name', required: true)]),
      (request) => GetPromptResult(messages: [
        PromptMessage(role: Role.user,
          content: TextContent(text: 'Welcome ${request.arguments!['name']} warmly.')),
      ]),
    );
  }
}

String greet(String name) => 'Hello, $name!';
''',
  'test/server_test.dart': r'''import 'dart:async';
import 'dart:io';
import 'package:dart_mcp/client.dart';
import 'package:dart_mcp/stdio.dart';
import 'package:test/test.dart';

void main() {
  test('STDIO exposes greeting, information and welcome', () async {
    final process = await Process.start(Platform.resolvedExecutable,
      ['run', 'bin/server.dart']);
    final errors = process.stderr.drain<void>();
    final client = MCPClient(Implementation(name: 'server-test', version: '1.0.0'));
    final server = client.connectServer(stdioChannel(
      input: process.stdout, output: process.stdin));
    addTearDown(() async {
      await client.shutdown();
      process.kill();
      await process.exitCode;
      await errors;
    });
    await server.initialize(InitializeRequest(
      protocolVersion: ProtocolVersion.latestSupported,
      capabilities: client.capabilities, clientInfo: client.implementation));
    server.notifyInitialized();
    expect((await server.listTools()).tools.map((t) => t.name), contains('greet'));
    final greeting = await server.callTool(CallToolRequest(name: 'greet',
      arguments: {'name': 'Ada'}));
    expect((greeting.content.single as TextContent).text, 'Hello, Ada!');
    final invalid = await server.callTool(CallToolRequest(name: 'greet', arguments: {}));
    expect(invalid.isError, isTrue);
    expect((await server.listResources()).resources.single.uri, 'greeting://info');
    final resource = await server.readResource(ReadResourceRequest(uri: 'greeting://info'));
    expect((resource.contents.single as TextResourceContents).text, contains('local greeting'));
    expect((await server.listPrompts()).prompts.single.name, 'welcome');
    final prompt = await server.getPrompt(GetPromptRequest(name: 'welcome', arguments: {'name': 'Ada'}));
    expect((prompt.messages.single.content as TextContent).text, contains('Ada'));
  }, timeout: const Timeout(Duration(seconds: 30)));
}
''',
};
