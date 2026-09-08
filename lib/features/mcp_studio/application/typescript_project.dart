import 'dart:convert';

Map<String, String> typescriptProject(String name) => {
  'package.json':
      '${const JsonEncoder.withIndent('  ').convert({
        'name': name,
        'version': '0.1.0',
        'private': true,
        'type': 'module',
        'scripts': {'build': 'tsc', 'start': 'node dist/server.js', 'test': 'node --test test/server.test.mjs'},
        'dependencies': {'@modelcontextprotocol/sdk': '1.30.0', 'zod': '4.5.4'},
        'devDependencies': {'typescript': '5.9.3', '@types/node': '24.10.1'},
        'engines': {'node': '>=22'},
      })}\n',
  'tsconfig.json': '''{
  "compilerOptions": {
    "target": "ES2022",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "strict": true,
    "outDir": "dist",
    "rootDir": "src",
    "skipLibCheck": true
  },
  "include": ["src/**/*.ts"]
}
''',
  '.gitignore': 'node_modules/\ndist/\n',
  'src/server.ts':
      '''import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { z } from 'zod';

const server = new McpServer({ name: '$name', version: '0.1.0' });

server.registerTool('greet', {
  description: 'Create a friendly greeting.',
  inputSchema: { name: z.string() },
}, async ({ name }) => ({
  content: [{ type: 'text', text: `Hello, \${name}!` }],
}));

server.registerResource('information', 'greeting://info', {
  mimeType: 'text/plain',
}, async (uri) => ({
  contents: [{ uri: uri.href, text: 'A local greeting server.' }],
}));

server.registerPrompt('welcome', {
  description: 'Draft a welcome message.',
  argsSchema: { name: z.string() },
}, ({ name }) => ({
  messages: [{ role: 'user', content: { type: 'text', text: `Welcome \${name} warmly.` } }],
}));

// STDOUT belongs to MCP. Use console.error for application logs.
await server.connect(new StdioServerTransport());
''',
  'test/server.test.mjs': '''import test from 'node:test';
import assert from 'node:assert/strict';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

test('STDIO exposes greeting, information and welcome', { timeout: 30000 }, async () => {
  const transport = new StdioClientTransport({
    command: process.execPath, args: ['dist/server.js'], stderr: 'pipe',
  });
  const client = new Client({ name: 'server-test', version: '1.0.0' });
  try {
    await client.connect(transport);
    const tools = await client.listTools();
    assert.ok(tools.tools.some(tool => tool.name === 'greet'));
    const greeting = await client.callTool({ name: 'greet', arguments: { name: 'Ada' } });
    assert.equal(greeting.content[0].text, 'Hello, Ada!');
    const invalid = await client.callTool({ name: 'greet', arguments: {} });
    assert.equal(invalid.isError, true);
    const resources = await client.listResources();
    assert.equal(resources.resources[0].uri, 'greeting://info');
    const resource = await client.readResource({ uri: 'greeting://info' });
    assert.match(resource.contents[0].text, /local greeting/);
    const prompts = await client.listPrompts();
    assert.equal(prompts.prompts[0].name, 'welcome');
    const prompt = await client.getPrompt({ name: 'welcome', arguments: { name: 'Ada' } });
    assert.match(prompt.messages[0].content.text, /Ada/);
  } finally {
    await client.close();
  }
});
''',
};
