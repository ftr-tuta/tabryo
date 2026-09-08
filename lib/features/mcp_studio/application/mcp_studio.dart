import 'dart:convert';

import 'package:path/path.dart' as p;

import '../../mcp/domain/mcp_server.dart';
import '../../terminals/domain/terminal_ports.dart';
import '../domain/studio_project.dart';
import 'dart_project.dart';
import 'python_project.dart';
import 'typescript_project.dart';

final class McpStudio {
  McpStudio(this.storage);
  final StudioStorage storage;
  StudioPlan? _prepared;
  bool _writing = false;

  Future<StudioPlan> prepare(
    String parent,
    String name,
    StudioLanguage language,
    String runtime,
  ) async {
    _prepared = null;
    if (!RegExp(r'^[a-z][a-z0-9_]{0,47}$').hasMatch(name) ||
        RegExp(r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])$').hasMatch(name)) {
      throw const StudioFailure(
        'Use a lowercase project name, starting with a letter, with up to 48 letters, digits or underscores.',
      );
    }
    await storage.validateParent(parent);
    if (runtime.isNotEmpty && !p.isAbsolute(runtime)) {
      throw const StudioFailure('Choose an absolute runtime executable path.');
    }
    final files = switch (language) {
      StudioLanguage.dart => dartProject(name),
      StudioLanguage.python => pythonProject(name),
      StudioLanguage.typescript => typescriptProject(name),
    };
    final plan = StudioPlan(
      parent: parent,
      path: p.join(parent, name),
      name: name,
      language: language,
      runtime: runtime,
      files: files,
    );
    final commands = this.commands(plan);
    files['README.md'] =
        '''# $name

A local STDIO MCP server. Tool: `greet` (`{"name":"Ada"}`), resource:
`greeting://info`, prompt: `welcome` (`{"name":"Ada"}`).

Open the source in Tabryo's editor, save changes, then review and run each command
in order from MCP Studio. Installation contacts the public package registry.
Runtime: ${runtime.isEmpty ? 'choose an absolute native executable in Studio' : runtime}

${commands.map((c) => '## ${c.title}\n\nExecutable: ${c.spec.executable}\n\nArguments: `${jsonEncode(c.spec.arguments)}`\n').join('\n')}
Commands run in this project directory. A failed step must be corrected before
continuing. Direct SDK versions are pinned. Retain generated dependency lockfiles
in version control; transitive resolution is not frozen in this initial template.

After installation and a green test, select **Register in MCP Hub** in Studio.
Review the user configuration before saving and reconnecting. The Hub can list
and call tools and read resources through Codex. Prompts are exercised by the
project's native test; this Codex inspector does not expose prompt retrieval.

STDOUT is reserved for protocol messages; application logs go to stderr. Do not
print credentials. No network listener is opened by the template. Native tests
exercise tools, resources and prompts without a model or credentials.
''';
    return _prepared = StudioPlan(
      parent: parent,
      path: plan.path,
      name: name,
      language: language,
      runtime: runtime,
      files: files,
    );
  }

  Future<StudioPlan> create(StudioPlan plan) async {
    if (_writing || !identical(_prepared, plan)) {
      throw const StudioFailure(
        'Review the current project before creating it.',
      );
    }
    _prepared = null;
    _writing = true;
    try {
      await storage.publish(plan);
      return plan;
    } finally {
      _writing = false;
    }
  }

  String entryFile(StudioPlan plan) => switch (plan.language) {
    StudioLanguage.dart => 'lib/server.dart',
    StudioLanguage.python => 'server.py',
    StudioLanguage.typescript => 'src/server.ts',
  };

  String _python(StudioPlan plan) => p.join(
    plan.path,
    '.venv',
    storage.windows ? 'Scripts' : 'bin',
    storage.windows ? 'python.exe' : 'python',
  );

  List<StudioCommand> commands(StudioPlan plan) {
    StudioCommand command(
      String title,
      String executable,
      List<String> args, {
      bool installs = false,
    }) => StudioCommand(
      title,
      LaunchSpec(
        executable: executable,
        workingDirectory: plan.path,
        arguments: List.unmodifiable(args),
      ),
      installs: installs,
    );
    final runtime = plan.runtime.isEmpty
        ? '<runtime not selected>'
        : plan.runtime;
    return switch (plan.language) {
      StudioLanguage.dart => [
        command('Install dependencies', runtime, [
          'pub',
          'get',
        ], installs: true),
        command('Test tools, resources and prompts', runtime, ['test']),
      ],
      StudioLanguage.python => [
        command('Create virtual environment', runtime, ['-m', 'venv', '.venv']),
        command('Install dependencies', _python(plan), [
          '-m',
          'pip',
          'install',
          '-r',
          'requirements.txt',
        ], installs: true),
        command('Test tools, resources and prompts', _python(plan), [
          '-m',
          'pytest',
        ]),
      ],
      StudioLanguage.typescript => [
        command('Install dependencies', runtime, [
          storage.npmCli(runtime) ?? '<npm CLI not found>',
          'install',
          '--ignore-scripts',
          '--no-audit',
          '--no-fund',
        ], installs: true),
        command('Build TypeScript', runtime, [
          'node_modules/typescript/bin/tsc',
        ]),
        command('Test tools, resources and prompts', runtime, [
          '--test',
          'test/server.test.mjs',
        ]),
      ],
    };
  }

  Future<LaunchSpec> prepareCommand(StudioPlan plan, int index) async {
    await storage.validateProject(plan);
    final spec = commands(plan)[index].spec;
    await storage.validateExecutable(spec.executable);
    if (plan.language == StudioLanguage.typescript && index == 0) {
      await storage.validateFile(spec.arguments.first);
    }
    return spec;
  }

  Future<McpServerDraft> registration(StudioPlan plan) async {
    await storage.validateProject(plan);
    final executable = plan.language == StudioLanguage.python
        ? _python(plan)
        : plan.runtime;
    await storage.validateExecutable(executable);
    await storage.validateFile(
      p.join(plan.path, switch (plan.language) {
        StudioLanguage.dart => 'bin/server.dart',
        StudioLanguage.python => 'server.py',
        StudioLanguage.typescript => 'dist/server.js',
      }),
    );
    return McpServerDraft(
      name: plan.name,
      transport: McpTransport.stdio,
      command: executable,
      workingDirectory: plan.path,
      arguments: switch (plan.language) {
        StudioLanguage.dart => ['run', 'bin/server.dart'],
        StudioLanguage.python => ['server.py'],
        StudioLanguage.typescript => ['dist/server.js'],
      },
    );
  }
}
