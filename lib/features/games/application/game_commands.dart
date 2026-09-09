import 'dart:convert';

import 'package:path/path.dart' as p;

import '../../projects/domain/project.dart';
import '../../terminals/domain/terminal_ports.dart';
import '../domain/game_workspace.dart';

/// Commands stay usable through the engine's native tools outside Tabryo.
final class GameCommands {
  const GameCommands({required this.windows});
  final bool windows;
  String tool(ToolchainSelection tools, ProjectTool name) {
    final executable = tools[name];
    if (executable == null || !p.isAbsolute(executable)) {
      throw GameFailure(
        'Select the installed ${name.name} executable in Toolchains.',
      );
    }
    return executable;
  }

  String engine(ToolchainSelection tools) => p.dirname(
    p.dirname(p.dirname(p.dirname(tool(tools, ProjectTool.unreal)))),
  );
  String descriptor(GameWorkspace workspace) => p.join(
    workspace.project.directory,
    workspace.project.manifests.firstWhere(
      (m) => m.toLowerCase().endsWith('.uproject'),
    ),
  );
  String script(ToolchainSelection tools, String name) => p.joinAll([
    engine(tools),
    'Engine',
    'Build',
    'BatchFiles',
    if (!windows && name == 'Build') 'Linux',
    '$name.${windows ? 'bat' : 'sh'}',
  ]);
  String commandEditor(ToolchainSelection tools) => p.join(
    p.dirname(tool(tools, ProjectTool.unreal)),
    windows ? 'UnrealEditor-Cmd.exe' : 'UnrealEditor',
  );
  String cmakeConfiguration(GameConfiguration config) =>
      config.configuration == 'Development'
      ? 'RelWithDebInfo'
      : config.configuration;

  GameProcessSpec process(
    GameWorkspace workspace,
    String name,
    String executable,
    List<String> arguments, {
    bool persistent = false,
    String? readyText,
    List<String> dependsOn = const [],
    String? input,
    String? environmentScript,
    Map<String, String> environment = const {},
  }) => GameProcessSpec(
    name,
    LaunchSpec(
      executable: executable,
      workingDirectory: workspace.project.directory,
      arguments: List.unmodifiable(arguments),
      environment: environment,
    ),
    persistent: persistent,
    readyText: readyText,
    dependsOn: dependsOn,
    input: input,
    environmentScript: environmentScript,
  );

  GamePlan action(
    GameWorkspace workspace,
    ToolchainSelection tools,
    GameAction action, {
    required String reportPath,
    String? target,
  }) {
    final project = workspace.project;
    final c = workspace.configuration;
    final root = project.directory;
    final build = p.join(root, c.buildDirectory);
    final nativeConfig = cmakeConfiguration(c);
    final processes = <GameProcessSpec>[];
    String? report;
    String? artifact;
    if (project.kind == ProjectKind.cpp) {
      final executable = tool(
        tools,
        action == GameAction.test ? ProjectTool.ctest : ProjectTool.cmake,
      );
      final arguments = switch (action) {
        GameAction.configure || GameAction.compileCommands => [
          if (c.cmakePreset != null) '--preset=${c.cmakePreset}',
          '-S',
          root,
          '-B',
          build,
          '-DCMAKE_EXPORT_COMPILE_COMMANDS=ON',
          '-DCMAKE_BUILD_TYPE=$nativeConfig',
        ],
        GameAction.build => [
          '--build',
          build,
          '--config',
          nativeConfig,
          if ((target ?? c.target).isNotEmpty) ...[
            '--target',
            target ?? c.target,
          ],
        ],
        GameAction.test => [
          '--test-dir',
          build,
          '-C',
          nativeConfig,
          '--output-on-failure',
          '--no-tests=error',
          '--output-junit',
          reportPath,
          if (c.testFilter != 'Project') ...['-R', c.testFilter],
        ],
        _ => throw const GameFailure('This action requires an Unreal project.'),
      };
      processes.add(
        process(
          workspace,
          action.name,
          executable,
          arguments,
          environmentScript: tools[ProjectTool.msvcEnvironment],
        ),
      );
      if (action == GameAction.test) report = reportPath;
    } else {
      final uproject = descriptor(workspace);
      final platform = windows ? 'Win64' : 'Linux';
      final chosen =
          target ??
          (c.target.isNotEmpty
              ? c.target
              : workspace.targets
                    .where((t) => t.type == 'Editor')
                    .firstOrNull
                    ?.name);
      if (const {
            GameAction.build,
            GameAction.compileCommands,
          }.contains(action) &&
          (chosen == null || !workspace.targets.any((t) => t.name == chosen))) {
        throw const GameFailure(
          'Choose a discovered .Target.cs target. Blueprint-only projects can use Editor, testing and packaging.',
        );
      }
      final common = [
        uproject,
        '-unattended',
        '-nop4',
        '-nosplash',
        '-stdout',
        '-FullStdOutLogOutput',
      ];
      switch (action) {
        case GameAction.configure:
          throw const GameFailure(
            'Unreal projects use their .uproject, module rules and engine selection. Use Build or Generate compile commands.',
          );
        case GameAction.build:
        case GameAction.compileCommands:
          processes.add(
            process(
              workspace,
              action.name,
              script(tools, 'Build'),
              [
                chosen!,
                platform,
                c.configuration,
                '-Project=$uproject',
                '-WaitMutex',
                '-NoHotReloadFromIDE',
                if (action == GameAction.compileCommands) ...[
                  '-Mode=GenerateClangDatabase',
                  '-OutputDir=$root',
                  if (workspace.project.versionHint == '5.8')
                    '-Include=${root.replaceAll('\\', '/')}/...',
                ],
              ],
              environment:
                  action == GameAction.compileCommands &&
                      windows &&
                      tools[ProjectTool.clangd] != null
                  ? {
                      'LLVM_PATH': p.dirname(
                        p.dirname(tools[ProjectTool.clangd]!),
                      ),
                    }
                  : const {},
            ),
          );
        case GameAction.editor:
          processes.add(
            process(
              workspace,
              'Unreal Editor',
              tool(tools, ProjectTool.unreal),
              [uproject],
              persistent: true,
            ),
          );
        case GameAction.test:
          report = reportPath;
          processes.add(
            process(workspace, 'Unreal Automation', commandEditor(tools), [
              ...common,
              '-NullRHI',
              '-ExecCmds=Automation RunTests ${c.testFilter}',
              '-TestExit=Automation Test Queue Empty',
              '-ReportExportPath=$reportPath',
            ]),
          );
        case GameAction.cook:
        case GameAction.package:
          artifact = p.join(root, c.archiveDirectory);
          processes.add(
            process(workspace, action.name, script(tools, 'RunUAT'), [
              'BuildCookRun',
              '-project=$uproject',
              '-noP4',
              '-unattended',
              '-platform=$platform',
              '-clientconfig=${c.configuration}',
              '-build',
              '-cook',
              if (action == GameAction.package) ...[
                '-stage',
                '-pak',
                '-package',
                '-archive',
                '-archivedirectory=$artifact',
              ],
            ]),
          );
        case GameAction.validateContent:
          processes.add(
            process(
              workspace,
              'Validate Unreal content',
              commandEditor(tools),
              [...common, '-run=DataValidation', '-NullRHI'],
            ),
          );
      }
    }
    return GamePlan(
      workspace: workspace,
      title: action.name,
      processes: List.unmodifiable(processes),
      reportPath: report,
      testReport: action == GameAction.test,
      toolPaths: tools.paths,
      artifactDirectory: artifact,
      compilationDatabase: action == GameAction.compileCommands
          ? p.join(
              project.kind == ProjectKind.cpp ? build : root,
              'compile_commands.json',
            )
          : null,
    );
  }

  GameProcessSpec executable(
    GameWorkspace workspace,
    GameExecutable value, {
    bool persistent = false,
    List<String>? dependsOn,
    String? input,
  }) => GameProcessSpec(
    value.name,
    LaunchSpec(
      executable: p.join(workspace.project.directory, value.executable),
      workingDirectory: workspace.project.directory,
      arguments: value.arguments,
    ),
    persistent: persistent,
    readyText: value.readyText,
    dependsOn: dependsOn ?? value.dependsOn,
    readyTimeout: Duration(seconds: value.readyTimeoutSeconds),
    input: input,
  );

  GamePlan configuredSession(
    GameWorkspace workspace,
    ToolchainSelection tools,
    GameSessionProfile profile,
  ) => GamePlan(
    workspace: workspace,
    title: profile.name,
    toolPaths: tools.paths,
    scenario: {
      'buildVersion': profile.buildVersion,
      'scenario': profile.scenario,
    },
    processes: [
      for (final process in profile.processes)
        executable(workspace, process, persistent: true),
    ],
  );

  GamePlan session(GameWorkspace workspace, ToolchainSelection tools) {
    if (workspace.project.kind != ProjectKind.unreal) {
      throw const GameFailure('Network editor sessions require Unreal.');
    }
    final c = workspace.configuration;
    final editor = tool(tools, ProjectTool.unreal);
    final uproject = descriptor(workspace);
    final services = [
      for (final s in c.services) executable(workspace, s, persistent: true),
    ];
    if (services.any((s) => s.readyText == null)) {
      throw const GameFailure(
        'Each backend service needs a readiness log marker before a multiplayer session can start.',
      );
    }
    return GamePlan(
      workspace: workspace,
      title: 'Multiplayer editor session',
      scenario: {
        'map': c.map,
        'port': '${c.port}',
        'clients': '${c.clients}',
        'engine': workspace.project.versionHint ?? 'selected toolchain',
      },
      toolPaths: tools.paths,
      processes: List.unmodifiable([
        ...services,
        process(
          workspace,
          'Game server',
          editor,
          [
            uproject,
            c.map,
            '-server',
            '-unattended',
            '-nosplash',
            '-stdout',
            '-FullStdOutLogOutput',
            '-port=${c.port}',
          ],
          persistent: true,
          readyText: 'Game Engine Initialized',
          dependsOn: services.map((s) => s.name).toList(),
        ),
        for (var i = 0; i < c.clients; i++)
          process(
            workspace,
            'Client ${i + 1}',
            editor,
            [
              uproject,
              '127.0.0.1:${c.port}',
              '-game',
              '-windowed',
              '-ResX=960',
              '-ResY=540',
              '-nosplash',
              '-stdout',
              '-FullStdOutLogOutput',
            ],
            persistent: true,
            dependsOn: const ['Game server'],
          ),
      ]),
    );
  }

  GamePlan laboratory(
    GameWorkspace workspace,
    ToolchainSelection tools,
    String source,
    String fingerprint,
  ) {
    if (utf8.encode(source).length > 256 * 1024) {
      throw const GameFailure('Laboratory input exceeds 256 KiB.');
    }
    final input = jsonDecode(source);
    if (input is! Map<String, dynamic> ||
        input['cases'] is! List ||
        (input['cases'] as List).isEmpty ||
        (input['cases'] as List).length > 64) {
      throw const GameFailure(
        'Enter 1–64 cases in a JSON object with a cases array.',
      );
    }
    final ids = <String>{};
    for (final c in input['cases'] as List) {
      if (c is! Map ||
          c['id'] is! String ||
          (c['id'] as String).isEmpty ||
          !ids.add(c['id'] as String)) {
        throw const GameFailure('Laboratory inputs need unique case IDs.');
      }
    }
    final lab = workspace.configuration.lab;
    if (lab == null) {
      throw const GameFailure(
        'Configure lab.executable to run the game’s native rules process.',
      );
    }
    final request = Map<String, Object?>.unmodifiable({...input, 'version': 1});
    return GamePlan(
      workspace: workspace,
      title: 'Rules laboratory',
      toolPaths: tools.paths,
      processes: [
        executable(workspace, lab, input: '${jsonEncode(request)}\n'),
      ],
      labRequest: request,
      fingerprint: fingerprint,
    );
  }

  GamePlan content(
    GameWorkspace workspace,
    ToolchainSelection tools,
    GameAsset asset, {
    bool export = false,
    bool import = false,
    bool validate = false,
  }) {
    final c = workspace.configuration;
    final root = workspace.project.directory;
    final source = asset.source ?? asset.path;
    final specs = <GameProcessSpec>[];
    if (import || validate) {
      final importSource = asset.exported ?? asset.source ?? asset.path;
      if (import && p.extension(importSource).toLowerCase() == '.blend') {
        throw const GameFailure(
          'Map exported to the interchange file produced by Blender (for example FBX).',
        );
      }
      final file = validate ? c.contentValidation : c.unrealImport;
      if (file == null) {
        throw const GameFailure(
          'Configure the project-owned Unreal Python import/validation script first.',
        );
      }
      specs.add(
        process(
          workspace,
          validate ? 'Validate asset' : 'Import / reimport asset',
          commandEditor(tools),
          [
            descriptor(workspace),
            '-run=pythonscript',
            '-script=${p.join(root, file)}',
            '-unattended',
            '-nop4',
            '-stdout',
            '-FullStdOutLogOutput',
          ],
        ),
      );
      final launch = specs.single.launch;
      specs[0] = GameProcessSpec(
        specs.single.name,
        LaunchSpec(
          executable: launch.executable,
          workingDirectory: root,
          arguments: launch.arguments,
          environment: {
            'TABRYO_ASSET_SOURCE': p.join(root, importSource),
            'TABRYO_ASSET_PATH': p.join(root, asset.path),
            'TABRYO_ASSET_OBJECT': asset.objectPath ?? '',
          },
        ),
      );
    } else {
      if (p.extension(source).toLowerCase() != '.blend') {
        throw const GameFailure('Select a .blend source mapping.');
      }
      if (export && c.blenderExport == null) {
        throw const GameFailure(
          'Configure the project-owned Blender export script first.',
        );
      }
      if (export &&
          {
            '.uasset',
            '.umap',
            '.blend',
          }.contains(p.extension(asset.exported ?? asset.path).toLowerCase())) {
        throw const GameFailure(
          'Configure an exported interchange path before exporting this asset.',
        );
      }
      specs.add(
        process(
          workspace,
          export ? 'Export Blender asset' : 'Blender',
          tool(tools, ProjectTool.blender),
          [
            '--disable-autoexec',
            if (export) '--background',
            p.join(root, source),
            if (export) ...[
              '--python-exit-code',
              '1',
              '--python',
              p.join(root, c.blenderExport!),
              '--',
              p.join(root, asset.exported ?? asset.path),
            ],
          ],
          persistent: !export,
        ),
      );
    }
    return GamePlan(
      workspace: workspace,
      title: specs.single.name,
      processes: specs,
      toolPaths: tools.paths,
      inputPaths: [
        if (import || validate)
          validate ? c.contentValidation! : c.unrealImport!,
        if (import) asset.exported ?? asset.source ?? asset.path,
        if (validate) asset.path,
        if (!import && !validate) source,
        if (export) c.blenderExport!,
      ],
      outputPaths: [
        if (export) asset.exported ?? asset.path,
        if (import) asset.path,
      ],
    );
  }
}
