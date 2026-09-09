import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tabryo/core/cancellation.dart';
import 'package:tabryo/features/games/application/game_commands.dart';
import 'package:tabryo/features/games/application/game_service.dart';
import 'package:tabryo/features/games/domain/game_workspace.dart';
import 'package:tabryo/features/games/infrastructure/local_game_workspace.dart';
import 'package:tabryo/features/games/infrastructure/local_game_processes.dart';
import 'package:tabryo/features/games/presentation/game_panel.dart';
import 'package:tabryo/features/projects/domain/project.dart';
import 'package:tabryo/features/projects/infrastructure/local_project_environment.dart';
import 'package:tabryo/features/tasks/domain/project_task.dart';
import 'package:tabryo/features/terminals/domain/terminal_ports.dart';
import 'package:tabryo/features/debugger/application/debug_service.dart';
import 'package:tabryo/features/debugger/application/debug_profiles.dart';
import 'package:tabryo/features/debugger/domain/debug_session.dart';
import 'package:tabryo/features/debugger/infrastructure/dap_connection.dart';
import 'package:tabryo/features/language/application/language_service.dart';
import 'package:tabryo/features/language/domain/language_server.dart';
import 'package:tabryo/features/language/infrastructure/lsp_connection.dart';

void main() {
  test(
    'installed Unreal builds a reflected C++ module tests it and generates clangd commands',
    () async {
      final root = await temporaryProject();
      final tools = ToolchainSelection({
        ProjectTool.unreal: Platform.environment['TABRYO_TEST_UNREAL']!,
        ProjectTool.clangd: Platform.environment['TABRYO_TEST_CLANGD']!,
      });
      await writeFile(
        root,
        'Arena.uproject',
        jsonEncode({
          'FileVersion': 3,
          'EngineAssociation': '5.8',
          'Modules': [
            {'Name': 'Arena', 'Type': 'Runtime', 'LoadingPhase': 'Default'},
          ],
        }),
      );
      await writeFile(
        root,
        'Source/ArenaEditor.Target.cs',
        '''using UnrealBuildTool;
public class ArenaEditorTarget : TargetRules {
  public ArenaEditorTarget(TargetInfo Target) : base(Target) {
    Type = TargetType.Editor;
    DefaultBuildSettings = BuildSettingsVersion.V7;
    IncludeOrderVersion = EngineIncludeOrderVersion.Unreal5_8;
    ExtraModuleNames.Add("Arena");
  }
}
''',
      );
      await writeFile(
        root,
        'Source/Arena/Arena.Build.cs',
        '''using UnrealBuildTool;
public class Arena : ModuleRules {
  public Arena(ReadOnlyTargetRules Target) : base(Target) {
    PCHUsage = PCHUsageMode.UseExplicitOrSharedPCHs;
    PublicDependencyModuleNames.AddRange(new string[] {"Core", "CoreUObject", "Engine"});
  }
}
''',
      );
      await writeFile(
        root,
        'Source/Arena/Arena.cpp',
        '''#include "Modules/ModuleManager.h"
IMPLEMENT_PRIMARY_GAME_MODULE(FDefaultGameModuleImpl, Arena, "Arena");
''',
      );
      await writeFile(root, 'Source/Arena/Rules.h', '''#pragma once
#include "CoreMinimal.h"
#include "UObject/Object.h"
#include "Rules.generated.h"
UCLASS()
class ARENA_API URules : public UObject {
  GENERATED_BODY()
public:
  UFUNCTION(BlueprintPure)
  static int32 Damage(int32 Raw, int32 Armor);
};
''');
      await writeFile(root, 'Source/Arena/Rules.cpp', '''#include "Rules.h"
#include "Misc/AutomationTest.h"
int32 URules::Damage(int32 Raw, int32 Armor) { return FMath::Max(0, Raw - Armor); }
#if WITH_DEV_AUTOMATION_TESTS
IMPLEMENT_SIMPLE_AUTOMATION_TEST(FNativeRulesTest, "Arena.NativeRules", EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)
bool FNativeRulesTest::RunTest(const FString& Parameters) {
  TestEqual(TEXT("Native damage"), URules::Damage(40, 7), 33);
  TestEqual(TEXT("No negative damage"), URules::Damage(5, 7), 0);
  return true;
}
#endif
''');
      await writeFile(
        root,
        '.tabryo/game.json',
        '{"version":1,"target":"ArenaEditor","testFilter":"Arena.NativeRules"}',
      );
      final files = LocalGameWorkspace();
      final discovery = await LocalProjectEnvironment().discover(
        root,
        Cancellation(),
      );
      final workspace = await files.load(
        discovery.projects.singleWhere((p) => p.kind == ProjectKind.unreal),
        Cancellation(),
      );
      final service = GameService(files, LocalGameProcesses());
      addTearDown(service.dispose);
      final commands = GameCommands(windows: Platform.isWindows);
      for (final action in [
        GameAction.build,
        GameAction.test,
        GameAction.compileCommands,
      ]) {
        final run = await service.start(
          commands.action(
            workspace,
            tools,
            action,
            reportPath: p.join(root, 'Saved', 'Automation', 'rules'),
          ),
        );
        await nativeUntil(
          () => run.complete,
          () =>
              '${run.error}\n${run.processes.map((p) => p.output).join('\n')}',
          timeout: const Duration(minutes: 15),
        );
        expect(
          run.successful,
          true,
          reason:
              '${run.error}\n${run.processes.map((p) => p.output).join('\n')}',
        );
        if (action == GameAction.test) {
          expect(run.tests!.cases.single.name, 'Arena.NativeRules');
        }
      }
      final db = jsonDecode(
        await File(p.join(root, 'compile_commands.json')).readAsString(),
      ) as List;
      expect(db.any((e) => (e['file'] as String).endsWith('Rules.cpp')), true);
      final unit = db.firstWhere(
        (e) => (e['file'] as String).endsWith('Rules.cpp'),
      ) as Map;
      // UBT keeps include paths and defines in the compiler's response file.
      final response = await File('${unit['output']}.rsp').readAsString();
      final sharedPath = RegExp(r'@"([^"]+)"').firstMatch(response)!.group(1)!;
      expect(await File(sharedPath).readAsString(), contains('Inc'));
      final language = LanguageService(LocalLanguageServers());
      addTearDown(language.close);
      await language.start(
        LanguageServerSpec(
          kind: LanguageServerKind.clangd,
          workspace: root,
          root: root,
          executable: tools[ProjectTool.clangd]!,
          compilationDatabase: root,
        ),
      );
      final path = p.join(root, 'Source', 'Arena', 'Rules.cpp');
      final document = LanguageDocument(
        root,
        path,
        await File(path).readAsString(),
        1,
      );
      language.synchronize([document]);
      final symbols = await language.request(
        document,
        'textDocument/documentSymbol',
        {},
      );
      expect(jsonEncode(symbols), contains('Damage'));
      expect(
        language.problems.where((p) => p.diagnostic['severity'] == 1),
        isEmpty,
        reason: jsonEncode(language.problems.map((p) => p.diagnostic).toList()),
      );
    },
    skip: Platform.environment['TABRYO_TEST_UNREAL_CPP'] != '1',
    timeout: const Timeout(Duration(minutes: 25)),
  );

  test(
    'native C++ workflow builds, tests, compares rules and debugs with symbols',
    () async {
      final root = await temporaryProject();
      final env = Platform.environment;
      final tools = ToolchainSelection({
        ProjectTool.cmake: env['TABRYO_TEST_CMAKE']!,
        ProjectTool.ctest: env['TABRYO_TEST_CTEST']!,
        ProjectTool.clangd: env['TABRYO_TEST_CLANGD']!,
        if (env['TABRYO_TEST_MSVC_ENV'] != null)
          ProjectTool.msvcEnvironment: env['TABRYO_TEST_MSVC_ENV']!,
        if (env['TABRYO_TEST_CODELLDB'] != null)
          ProjectTool.codeLldb: env['TABRYO_TEST_CODELLDB']!,
        if (env['TABRYO_TEST_LLDB_DAP'] != null)
          ProjectTool.lldbDap: env['TABRYO_TEST_LLDB_DAP']!,
      });
      await writeFile(
        root,
        'CMakeLists.txt',
        '''cmake_minimum_required(VERSION 3.20)
project(NativeRules LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
add_library(rules rules.cpp)
add_executable(game main.cpp)
target_link_libraries(game PRIVATE rules)
add_executable(rules_lab lab.cpp)
target_link_libraries(rules_lab PRIVATE rules)
add_executable(server server.cpp)
target_link_libraries(server PRIVATE rules)
enable_testing()
add_test(NAME Rules COMMAND game)
''',
      );
      const rules = '''int damage_after_armor(int damage, int armor) {
  int remaining = damage - armor;
  return remaining > 0 ? remaining : 0;
}
''';
      await writeFile(root, 'rules.cpp', rules);
      await writeFile(root, 'main.cpp', '''int damage_after_armor(int, int);
int main() {
  int result = damage_after_armor(40, 7);
  return result == 33 ? 0 : 1;
}
''');
      await writeFile(root, 'server.cpp', '''#include <iostream>
#include <thread>
#include <chrono>
int damage_after_armor(int, int);
int main() {
  for (;;) {
    std::cout << "READY " << damage_after_armor(40, 7) << std::endl;
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
  }
}
''');
      await writeFile(root, 'lab.cpp', r'''#include <iostream>
#include <string>
int damage_after_armor(int, int);
int main() {
  std::string input;
  std::getline(std::cin, input);
  if (input.find("fixture") == std::string::npos) return 2;
  std::cout << "{\"version\":1,\"codeVersion\":\"native-fixture\",\"dataVersion\":\"fixture-inputs\",\"cases\":[{\"id\":\"fixture\",\"metrics\":{\"damage\":" << damage_after_armor(40, 7) << "},\"explanation\":[\"Executed the linked native rules library\"]}]}" << std::endl;
}
''');
      final extension = Platform.isWindows ? '.exe' : '';
      await writeFile(
        root,
        '.tabryo/game.json',
        jsonEncode({
          'version': 1,
          'configuration': 'Debug',
          'cmakePreset': 'native',
          'lab': {'name': 'Rules', 'executable': 'build/rules_lab$extension'},
          'versionFiles': ['rules.cpp', 'lab.cpp'],
        }),
      );
      await writeFile(
        root,
        'CMakePresets.json',
        jsonEncode({
          'version': 3,
          'configurePresets': [
            {
              'name': 'native',
              'generator': 'Ninja',
              'binaryDir': '\${sourceDir}/build',
              'cacheVariables': {
                'CMAKE_CXX_COMPILER': env['TABRYO_TEST_CXX']!,
                'CMAKE_MAKE_PROGRAM': env['TABRYO_TEST_NINJA']!,
              },
            },
          ],
        }),
      );
      final project = DevelopmentProject(
        workspace: root,
        directory: root,
        name: 'NativeRules',
        kind: ProjectKind.cpp,
        manifests: const ['CMakeLists.txt'],
      );
      final files = LocalGameWorkspace();
      final workspace = await files.load(project, Cancellation());
      final service = GameService(files, LocalGameProcesses());
      addTearDown(service.dispose);
      final commands = GameCommands(windows: Platform.isWindows);
      for (final action in [
        GameAction.configure,
        GameAction.build,
        GameAction.test,
      ]) {
        final run = await service.start(
          commands.action(
            workspace,
            tools,
            action,
            reportPath: p.join(root, 'Saved', 'Automation', 'results.xml'),
          ),
        );
        await nativeUntil(
          () => run.complete,
          () =>
              '${run.error}\n${run.processes.map((p) => p.output).join('\n')}',
        );
        expect(
          run.successful,
          true,
          reason:
              '${run.error}\n${run.processes.map((p) => p.output).join('\n')}',
        );
        if (action == GameAction.test) {
          expect(run.tests!.cases.single.name, 'Rules');
        }
      }
      expect(
        await File(p.join(root, 'build', 'compile_commands.json')).exists(),
        true,
      );
      final fingerprint = await files.fingerprint(workspace);
      final comparison = await service.start(
        commands.laboratory(
          workspace,
          tools,
          '{"cases":[{"id":"fixture"}]}',
          fingerprint,
        ),
      );
      await nativeUntil(
        () => comparison.complete,
        () => comparison.error ?? 'laboratory pending',
      );
      expect(comparison.successful, true, reason: comparison.error);
      expect(comparison.lab!.cases.single['metrics'], {'damage': 33});
      final language = LanguageService(LocalLanguageServers());
      addTearDown(language.close);
      await language.start(
        LanguageServerSpec(
          kind: LanguageServerKind.clangd,
          workspace: root,
          root: root,
          executable: tools[ProjectTool.clangd]!,
          compilationDatabase: p.join(root, 'build'),
          environmentScript: tools[ProjectTool.msvcEnvironment],
        ),
      );
      final doc = LanguageDocument(root, p.join(root, 'rules.cpp'), rules, 1);
      language.synchronize([doc]);
      final symbols = await language.request(
        doc,
        'textDocument/documentSymbol',
        {},
      );
      expect(symbols, isNotEmpty);
      final hover = await language.request(doc, 'textDocument/hover', {
        'position': {'line': 0, 'character': 8},
      });
      expect(hover, isA<Map>());
      final debugger = DebugService(LocalDebugAdapters());
      addTearDown(debugger.dispose);
      await debugger.start(
        debugProfile(
          project: project,
          tools: tools,
          program: p.join(root, 'build', 'game$extension'),
          breakpoints: {
            p.join(root, 'rules.cpp'): [const DebugBreakpoint(3)],
          },
        ),
      );
      await nativeUntil(
        () =>
            debugger.status == DebugStatus.paused && debugger.frames.isNotEmpty,
        () => '${debugger.status}: ${debugger.error}\n${debugger.output}',
      );
      expect(
        debugger.verifiedBreakpoints.values
            .expand((v) => v)
            .any((b) => b['verified'] == true),
        true,
      );
      expect(await debugger.evaluate('remaining'), '33');
      await debugger.control('continue');
      await nativeUntil(
        () => !debugger.active,
        () => '${debugger.status}: ${debugger.error}\n${debugger.output}',
      );
      expect(debugger.exitCode, 0);
      // On Linux, sibling PID attach depends on the machine's ptrace policy.
      // Windows qualification exercises PDB symbols and detach without killing.
      if (Platform.isWindows) {
        await debugger.stop();
        final server = await service.start(
          GamePlan(
            workspace: workspace,
            title: 'Native server',
            toolPaths: tools.paths,
            processes: [
              GameProcessSpec(
                'Server',
                LaunchSpec(
                  executable: p.join(root, 'build', 'server$extension'),
                  workingDirectory: root,
                ),
                persistent: true,
                readyText: 'READY',
              ),
            ],
          ),
        );
        await nativeUntil(
          () => server.processes.single.state == GameProcessState.ready,
          () => '${server.error}',
        );
        final pid = server.processes.single.pid!;
        expect(service.ownsPid(root, pid), true);
        await debugger.start(
          debugProfile(
            project: project,
            tools: tools,
            program: p.join(root, 'build', 'server$extension'),
            attachPid: pid,
            breakpoints: {
              p.join(root, 'rules.cpp'): [const DebugBreakpoint(3)],
            },
          ),
        );
        await nativeUntil(
          () =>
              debugger.status == DebugStatus.paused &&
              debugger.frames.isNotEmpty,
          () => '${debugger.status}: ${debugger.error}\n${debugger.output}',
        );
        expect(await debugger.evaluate('remaining'), '33');
        await debugger.stop();
        final length = server.processes.single.output.length;
        await nativeUntil(
          () => server.processes.single.output.length > length,
          () => '${server.error}',
        );
        expect(service.ownsPid(root, pid), true);
        await service.stop(server);
        expect(service.ownsPid(root, pid), false);
      }
    },
    skip: Platform.environment['TABRYO_TEST_NATIVE_GAME'] != '1',
    timeout: const Timeout(Duration(minutes: 3)),
  );
  test(
    'installed Blender and Unreal export import reimport validate and report native tests',
    () async {
      final root = await temporaryProject();
      final env = Platform.environment;
      final tools = ToolchainSelection({
        ProjectTool.blender: env['TABRYO_TEST_BLENDER']!,
        ProjectTool.unreal: env['TABRYO_TEST_UNREAL']!,
      });
      await writeFile(
        root,
        'Arena.uproject',
        jsonEncode({
          'FileVersion': 3,
          'EngineAssociation': '5.8',
          'Plugins': [
            {'Name': 'PythonScriptPlugin', 'Enabled': true},
            {'Name': 'EditorScriptingUtilities', 'Enabled': true},
          ],
        }),
      );
      await writeFile(
        root,
        '.tabryo/game.json',
        jsonEncode({
          'version': 1,
          'blenderExport': 'Art/export.py',
          'unrealImport': 'Art/import.py',
          'contentValidation': 'Art/validate.py',
          'testFilter': 'System.Core.Serialization.CbField.DateTime',
          'assets': [
            {
              'path': 'Content/Cube.uasset',
              'source': 'Art/Cube.blend',
              'exported': 'Art/Cube.fbx',
              'objectPath': '/Game/Cube',
            },
          ],
        }),
      );
      await writeFile(root, 'Art/create.py', '''import bpy, sys
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.mesh.primitive_cube_add(size=2)
bpy.ops.wm.save_as_mainfile(filepath=sys.argv[-1])
''');
      await writeFile(root, 'Art/export.py', '''import bpy, sys
bpy.ops.export_scene.fbx(filepath=sys.argv[-1], use_selection=False)
''');
      await writeFile(root, 'Art/import.py', '''import os, unreal
task = unreal.AssetImportTask()
task.filename = os.environ['TABRYO_ASSET_SOURCE']
task.destination_path = '/Game'
task.destination_name = 'Cube'
task.automated = True
task.replace_existing = True
task.save = True
unreal.AssetToolsHelpers.get_asset_tools().import_asset_tasks([task])
mesh = unreal.load_asset(os.environ['TABRYO_ASSET_OBJECT'])
assert isinstance(mesh, unreal.StaticMesh), 'Import did not produce a static mesh'
assert unreal.EditorAssetLibrary.save_loaded_asset(mesh), 'Imported asset was not saved'
unreal.log('TABRYO_CONTENT_IMPORTED')
''');
      await writeFile(root, 'Art/validate.py', '''import os, unreal
mesh = unreal.load_asset(os.environ['TABRYO_ASSET_OBJECT'])
assert isinstance(mesh, unreal.StaticMesh), 'Saved mesh reference was lost'
assert mesh.get_num_lods() > 0, 'Mesh has no LOD'
unreal.log('TABRYO_CONTENT_VALIDATED')
''');
      final files = LocalGameWorkspace();
      final workspace = await files.load(project(root), Cancellation());
      final service = GameService(files, LocalGameProcesses());
      addTearDown(service.dispose);
      final commands = GameCommands(windows: Platform.isWindows);
      Future<GameRun> execute(GamePlan plan) async {
        final run = await service.start(plan);
        await nativeUntil(
          () => run.complete,
          () =>
              '${run.error}\n${run.processes.map((p) => p.output).join('\n')}',
          timeout: const Duration(minutes: 10),
        );
        expect(
          run.successful,
          true,
          reason:
              '${run.error}\n${run.processes.map((p) => p.output).join('\n')}',
        );
        return run;
      }

      await execute(
        GamePlan(
          workspace: workspace,
          title: 'Create source asset',
          toolPaths: tools.paths,
          processes: [
            commands.process(
              workspace,
              'Blender',
              tools[ProjectTool.blender]!,
              [
                '--background',
                '--factory-startup',
                '--python-exit-code',
                '1',
                '--python',
                p.join(root, 'Art', 'create.py'),
                '--',
                p.join(root, 'Art', 'Cube.blend'),
              ],
            ),
          ],
        ),
      );
      final asset = workspace.configuration.assets.single;
      await execute(commands.content(workspace, tools, asset, export: true));
      expect(
        await File(p.join(root, 'Art', 'Cube.fbx')).length(),
        greaterThan(0),
      );
      for (var pass = 0; pass < 2; pass++) {
        final imported = await execute(
          commands.content(workspace, tools, asset, import: true),
        );
        expect(
          imported.processes.single.output,
          contains('TABRYO_CONTENT_IMPORTED'),
        );
        expect(
          await File(p.join(root, 'Content', 'Cube.uasset')).length(),
          greaterThan(0),
        );
      }
      final validated = await execute(
        commands.content(workspace, tools, asset, validate: true),
      );
      expect(
        validated.processes.single.output,
        contains('TABRYO_CONTENT_VALIDATED'),
      );
      final tests = await execute(
        commands.action(
          workspace,
          tools,
          GameAction.test,
          reportPath: p.join(root, 'Saved', 'Automation', 'native'),
        ),
      );
      expect(tests.tests!.cases, isNotEmpty);
    },
    skip: Platform.environment['TABRYO_TEST_CONTENT'] != '1',
    timeout: const Timeout(Duration(minutes: 20)),
  );

  test('discovers Unreal descriptors and CMake independently and excludes generated trees', () async {
    final root = await temporaryProject();
    await writeFile(
      root,
      'Arena.uproject',
      '{"FileVersion":3,"EngineAssociation":"5.8"}',
    );
    await writeFile(root, 'rules/CMakeLists.txt', 'project(Rules)');
    await writeFile(root, 'Intermediate/Hidden.uproject', '{"FileVersion":3}');
    await writeFile(root, 'pubspec.yaml', '[');
    final result = await LocalProjectEnvironment().discover(
      root,
      Cancellation(),
    );
    expect(
      result.projects.map((p) => p.kind),
      containsAll([ProjectKind.unreal, ProjectKind.cpp]),
    );
    expect(result.projects.any((p) => p.name == 'Hidden'), false);
    expect(result.warnings, isNotEmpty);
  });

  test(
    'discovers target types, modules, plugins and source asset mappings',
    () async {
      final root = await temporaryProject();
      await writeFile(root, 'Arena.uproject', '{"FileVersion":3}');
      await writeFile(
        root,
        'Source/ArenaServer.Target.cs',
        'Type = TargetType.Server;',
      );
      await writeFile(
        root,
        'Source/ArenaEditor.Target.cs',
        'Type = TargetType.Editor;',
      );
      await writeFile(root, 'Source/Arena/Arena.Build.cs', 'class Arena {}');
      await writeFile(root, 'Plugins/Inventory/Inventory.uplugin', '{}');
      await writeFile(root, 'Art/Weapon.blend', 'binary');
      await writeFile(root, 'Content/Weapon.uasset', 'binary');
      await writeFile(
        root,
        '.tabryo/game.json',
        jsonEncode({
          'version': 1,
          'assets': [
            {
              'path': 'Content/Weapon.uasset',
              'source': 'Art/Weapon.blend',
              'objectPath': '/Game/Weapon.Weapon',
            },
          ],
        }),
      );
      final files = LocalGameWorkspace();
      final workspace = await files.load(project(root), Cancellation());
      expect(
        workspace.targets.map((t) => t.type),
        containsAll(['Server', 'Editor']),
      );
      expect(workspace.modules, hasLength(1));
      expect(workspace.plugins, hasLength(1));
      final asset = workspace.assets.firstWhere((a) => a.source != null);
      expect(await files.assetProblems(workspace, asset), isEmpty);
      expect(
        workspace.assets.where((a) => a.path == 'Content/Weapon.uasset'),
        hasLength(1),
      );
    },
  );

  test('game configuration rejects traversal, unknown keys and invalid readiness profiles', () {
    for (final value in [
      {'version': 1, 'buildDirectory': '../outside'},
      {'version': 1, 'archiveDirectory': 'C:/outside'},
      {'version': 1, 'clients': 256},
      {'version': 1, 'map': '/Game/Map;quit'},
      {
        'version': 1,
        'services': [
          {'name': 'backend', 'executable': 'service', 'readyText': ''},
        ],
      },
      {'version': 1, 'secrets': {}},
    ]) {
      expect(
        () => GameConfiguration.parse(jsonEncode(value)),
        throwsA(isA<GameFailure>()),
      );
    }
  });

  test(
    'settings reject concurrent edits and never replace the newer file',
    () async {
      final root = await temporaryProject();
      final files = LocalGameWorkspace();
      final workspace = await files.load(project(root), Cancellation());
      const changed = '{"version":1,"port":7780}';
      await writeFile(root, '.tabryo/game.json', changed);
      await expectLater(
        files.save(workspace, '{"version":1}'),
        throwsA(isA<GameFailure>()),
      );
      expect(
        await File(p.join(root, '.tabryo/game.json')).readAsString(),
        changed,
      );
      final current = await files.load(project(root), Cancellation());
      await files.save(current, '{"version":1,"port":7781}');
      expect(
        (await files.load(project(root), Cancellation())).configuration.port,
        7781,
      );
    },
  );

  test(
    'native commands address real targets and preserve paths with spaces',
    () {
      final root = p.absolute('sample game');
      final workspace = GameWorkspace(
        project: project(root),
        configuration: GameConfiguration(),
        configurationSource: '{}',
        targets: const [
          UnrealTarget('ArenaEditor', 'Editor', 'Source/ArenaEditor.Target.cs'),
          UnrealTarget('ArenaServer', 'Server', 'Source/ArenaServer.Target.cs'),
        ],
      );
      final tools = ToolchainSelection({
        ProjectTool.unreal: p.join(
          root,
          'UE 5.8',
          'Engine',
          'Binaries',
          'Win64',
          'UnrealEditor.exe',
        ),
      });
      const commands = GameCommands(windows: true);
      final server = commands.action(
        workspace,
        tools,
        GameAction.build,
        reportPath: p.join(root, 'report'),
        target: 'ArenaServer',
      );
      expect(server.processes.single.launch.arguments.take(3), [
        'ArenaServer',
        'Win64',
        'Development',
      ]);
      expect(
        server.processes.single.launch.arguments,
        contains('-Project=${p.join(root, 'Arena.uproject')}'),
      );
      expect(
        server.processes.single.launch.executable,
        p.join(root, 'UE 5.8', 'Engine', 'Build', 'BatchFiles', 'Build.bat'),
      );
      expect(
        () => commands.action(
          workspace,
          tools,
          GameAction.build,
          reportPath: 'unused',
          target: 'Invented',
        ),
        throwsA(isA<GameFailure>()),
      );
      final tests = commands.action(
        workspace,
        tools,
        GameAction.test,
        reportPath: p.join(root, 'report'),
      );
      expect(
        tests.processes.single.launch.arguments,
        contains('-TestExit=Automation Test Queue Empty'),
      );
      expect(tests.testReport, true);
      final session = commands.session(workspace, tools);
      expect(session.processes, hasLength(3));
      expect(session.processes[1].dependsOn, ['Game server']);
      expect(session.processes[1].launch.arguments, contains('127.0.0.1:7777'));
    },
  );

  test(
    'native reports cannot turn failed or unfinished Unreal tests green',
    () {
      final proj = project(p.absolute('game'));
      final result = LocalGameWorkspace.unrealReport(
        jsonEncode({
          'failed': 1,
          'tests': [
            {
              'fullTestPath': 'Project.Combat',
              'state': 'Fail',
              'entries': [
                {
                  'event': {'message': 'damage mismatch'},
                },
              ],
            },
            {'fullTestPath': 'Project.Career', 'state': 'InProcess'},
          ],
        }),
        proj,
      );
      expect(result.complete, false);
      expect(result.successful, false);
      expect(result.cases.first.details, contains('damage mismatch'));
      expect(
        () => LocalGameWorkspace.unrealReport('{"tests":[]}', proj),
        throwsA(isA<GameFailure>()),
      );
    },
  );

  test(
    'multiplayer waits for fragmented readiness and stops only owned processes',
    () async {
      final files = MemoryGameFiles();
      final host = MemoryGameProcesses();
      final service = GameService(files, host);
      addTearDown(service.dispose);
      final plan = memoryPlan([
        spec('server', persistent: true, ready: 'READY'),
        spec('client', persistent: true, depends: ['server']),
      ]);
      final pending = service.start(plan);
      await until(() => host.started.length == 1);
      host.started.first.out.add(utf8.encode('REA'));
      await Future<void>.delayed(Duration.zero);
      expect(host.started, hasLength(1));
      host.started.first.out.add(utf8.encode('DY\n'));
      final run = await pending;
      expect(host.started, hasLength(2));
      expect(run.processes.first.state, GameProcessState.ready);
      expect(service.reservations, hasLength(1));
      await expectLater(service.start(plan), throwsA(isA<GameFailure>()));
      await service.stop(run);
      expect(host.started.every((p) => p.closed), true);
      expect(run.complete, true);
      expect(run.stopped, true);
      expect(service.reservations, isEmpty);
    },
  );

  test('session profiles preserve build and character arguments and require real dependency readiness', () {
    final config = GameConfiguration.parse(
      jsonEncode({
        'version': 1,
        'sessions': [
          {
            'name': 'Dedicated',
            'buildVersion': 'commit-123',
            'scenario': 'recruit versus specialist',
            'processes': [
              {
                'name': 'Server',
                'executable': 'Binaries/Server.exe',
                'readyText': 'Listening',
              },
              {
                'name': 'Client',
                'executable': 'Binaries/Client.exe',
                'arguments': ['-Profile=recruit'],
                'dependsOn': ['Server'],
              },
            ],
          },
        ],
      }),
    );
    final plan = const GameCommands(windows: true).configuredSession(
      memoryPlan([]).workspace,
      ToolchainSelection(),
      config.sessions.single,
    );
    expect(plan.scenario['buildVersion'], 'commit-123');
    expect(plan.processes.last.launch.arguments, ['-Profile=recruit']);
    expect(plan.processes.last.dependsOn, ['Server']);
    expect(
      () => GameSessionProfile.parse({
        'name': 'bad',
        'buildVersion': 'x',
        'scenario': '',
        'processes': [
          {'name': 'Server', 'executable': 'server'},
          {
            'name': 'Client',
            'executable': 'client',
            'dependsOn': ['Server'],
          },
        ],
      }),
      throwsA(isA<GameFailure>()),
    );
  });

  test('a lone process times out without readiness and a clean early exit cannot start clients', () async {
    final host = MemoryGameProcesses();
    final service = GameService(MemoryGameFiles(), host);
    addTearDown(service.dispose);
    final run = await service.start(
      memoryPlan([
        spec(
          'Server',
          persistent: true,
          ready: 'Ready',
          timeout: const Duration(milliseconds: 20),
        ),
      ]),
    );
    await until(() => run.complete);
    expect(run.error, contains('readiness'));
    final pending = service.start(
      memoryPlan([
        spec('Server', persistent: true, ready: 'Ready'),
        spec('Client', persistent: true, depends: ['Server']),
      ]),
    );
    await until(() => host.started.length == 2);
    host.started.last.exit.complete(0);
    final failed = await pending;
    await until(() => failed.complete);
    expect(failed.error, contains('before reporting readiness'));
    expect(host.started, hasLength(2));
  });

  test(
    'compile database output must contain native translation units',
    () async {
      final root = await temporaryProject();
      final files = LocalGameWorkspace();
      final workspace = await files.load(project(root), Cancellation());
      final plan = GamePlan(
        workspace: workspace,
        title: 'compileCommands',
        processes: [],
        compilationDatabase: p.join(root, 'compile_commands.json'),
      );
      await expectLater(files.verifyOutputs(plan), throwsA(isA<GameFailure>()));
      await writeFile(root, 'compile_commands.json', '[]');
      await expectLater(files.verifyOutputs(plan), throwsA(isA<GameFailure>()));
      await writeFile(
        root,
        'compile_commands.json',
        jsonEncode([
          {
            'directory': root,
            'file': 'rules.cpp',
            'arguments': ['clang++', '-c', 'rules.cpp'],
          },
        ]),
      );
      await files.verifyOutputs(plan);
    },
  );

  test(
    'readiness timeout retires the server and never starts clients',
    () async {
      final host = MemoryGameProcesses();
      final service = GameService(MemoryGameFiles(), host);
      addTearDown(service.dispose);
      final run = await service.start(
        memoryPlan([
          spec(
            'server',
            persistent: true,
            ready: 'READY',
            timeout: const Duration(milliseconds: 20),
          ),
          spec('client', persistent: true, depends: ['server']),
        ]),
      );
      await until(() => run.complete);
      expect(run.error, contains('readiness'));
      expect(host.started, hasLength(1));
      expect(host.started.single.closed, true);
      expect(run.successful, false);
      expect(service.reservations, isEmpty);
    },
  );

  test(
    'stopping a pending process launch still retires the late child',
    () async {
      final host = MemoryGameProcesses()..gate = Completer<void>();
      final service = GameService(MemoryGameFiles(), host);
      addTearDown(service.dispose);
      final started = service.start(
        memoryPlan([spec('server', persistent: true)]),
      );
      await until(() => host.calls == 1);
      final stopped = service.stop(service.runs.single);
      host.gate!.complete();
      await started;
      await stopped;
      expect(host.started.single.closed, true);
      expect(service.reservations, isEmpty);
      expect(service.runs.single.stopped, true);
    },
  );

  test(
    'unexpected server exit retires clients and preserves failed state',
    () async {
      final host = MemoryGameProcesses();
      final service = GameService(MemoryGameFiles(), host);
      addTearDown(service.dispose);
      final run = await service.start(
        memoryPlan([
          spec('server', persistent: true),
          spec('client', persistent: true),
        ]),
      );
      host.started.first.exit.complete(9);
      await until(() => run.complete);
      expect(run.error, contains('server'));
      expect(run.successful, false);
      expect(host.started.last.closed, true);
    },
  );

  test('final process bytes and native report determine the outcome', () async {
    final host = MemoryGameProcesses();
    final files = MemoryGameFiles()
      ..results = const TestResults(
        [TestCaseResult(name: 'Damage', outcome: TestOutcome.failed)],
        complete: true,
        successful: false,
      );
    final service = GameService(files, host);
    addTearDown(service.dispose);
    final original = memoryPlan([spec('tests')]);
    final run = await service.start(
      GamePlan(
        workspace: original.workspace,
        title: 'test',
        processes: original.processes,
        testReport: true,
        reportPath: 'report.xml',
      ),
    );
    host.started.single.finalOutput =
        'Source/Rules.cpp(12,3): error C2001: failed\n';
    host.started.single.exit.complete(0);
    await until(() => run.complete);
    expect(run.processes.single.output, contains('error C2001'));
    expect(run.problems.single.line, 12);
    expect(
      run.problems.single.path,
      p.join(run.plan.workspace.project.directory, 'Source', 'Rules.cpp'),
    );
    expect(run.successful, false);
    expect(run.tests!.cases.single.outcome, TestOutcome.failed);
  });

  test(
    'laboratory requires matching native cases and unchanged code/data',
    () async {
      final host = MemoryGameProcesses();
      final files = MemoryGameFiles();
      final service = GameService(files, host);
      addTearDown(service.dispose);
      final original = memoryPlan([spec('lab')]);
      final plan = GamePlan(
        workspace: original.workspace,
        title: 'lab',
        processes: original.processes,
        fingerprint: 'before',
        labRequest: const {
          'cases': [
            {'id': 'specialist'},
          ],
        },
      );
      final run = await service.start(plan);
      host.started.single.out.add(
        utf8.encode(
          jsonEncode({
            'version': 1,
            'codeVersion': 'code-a',
            'dataVersion': 'data-b',
            'cases': [
              {
                'id': 'specialist',
                'metrics': {'reload': 3.2},
                'explanation': ['native result'],
              },
            ],
          }),
        ),
      );
      files.currentFingerprint = 'changed';
      host.started.single.exit.complete(0);
      await until(() => run.complete);
      expect(run.lab, isNull);
      expect(run.error, contains('changed'));
      expect(
        () => LabResult.parse(
          '{"version":1,"codeVersion":"","dataVersion":"d","cases":[]}',
          'x',
        ),
        throwsA(isA<GameFailure>()),
      );
    },
  );

  test(
    'laboratory freshness includes native executable and authoring bytes',
    () async {
      final root = await temporaryProject();
      await writeFile(root, 'rules.exe', 'binary-a');
      await writeFile(root, 'rules.cpp', 'code');
      await writeFile(root, 'data.json', '{}');
      await writeFile(
        root,
        '.tabryo/game.json',
        jsonEncode({
          'version': 1,
          'lab': {'name': 'Rules', 'executable': 'rules.exe'},
          'versionFiles': ['rules.cpp', 'data.json'],
        }),
      );
      final files = LocalGameWorkspace();
      final workspace = await files.load(project(root), Cancellation());
      final first = await files.fingerprint(workspace);
      await writeFile(root, 'data.json', '{"changed":true}');
      expect(await files.fingerprint(workspace), isNot(first));
    },
  );

  test('Blender export disables embedded autoexecution and reimport uses native Python', () {
    final original = memoryPlan([spec('unused')]).workspace;
    final workspace = GameWorkspace(
      project: original.project,
      configurationSource: '{}',
      configuration: GameConfiguration(
        blenderExport: 'scripts/export.py',
        unrealImport: 'scripts/import.py',
      ),
    );
    final tools = ToolchainSelection({
      ProjectTool.blender: p.absolute('blender.exe'),
      ProjectTool.unreal: p.absolute('Engine/Binaries/Win64/UnrealEditor.exe'),
    });
    const commands = GameCommands(windows: true);
    const asset = GameAsset(
      path: 'Content/Weapon.fbx',
      source: 'Art/Weapon.blend',
      exported: 'Content/Weapon.fbx',
      objectPath: '/Game/Weapon',
    );
    final export = commands
        .content(workspace, tools, asset, export: true)
        .processes
        .single
        .launch;
    expect(export.arguments.first, '--disable-autoexec');
    expect(
      export.arguments,
      containsAllInOrder([
        '--background',
        '--python-exit-code',
        '1',
        '--python',
      ]),
    );
    final import = commands
        .content(workspace, tools, asset, import: true)
        .processes
        .single
        .launch;
    expect(import.arguments, contains('-run=pythonscript'));
    expect(import.environment['TABRYO_ASSET_OBJECT'], '/Game/Weapon');
  });

  testWidgets(
    'game panel exposes a reviewable native workflow without starting processes',
    (tester) async {
      final files = MemoryGameFiles();
      final host = MemoryGameProcesses();
      final service = GameService(files, host);
      addTearDown(service.dispose);
      final workspace = memoryPlan([spec('unused')]).workspace;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: GamePanel(
                service: service,
                project: workspace.project,
                tools: ToolchainSelection(),
                windows: true,
                onRun: (_) async {},
                onOpen: (_, _) async {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Game development'), findsOneWidget);
      expect(find.text('Run native tests'), findsOneWidget);
      expect(find.text('Native rules laboratory'), findsOneWidget);
      expect(host.started, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'Windows engine batch commands preserve spaces and metacharacters',
    () async {
      final root = await temporaryProject();
      await writeFile(
        root,
        'Engine tools/Build.bat',
        '@echo off\r\necho %1\r\necho %2\r\nexit /b 0\r\n',
      );
      final child = await LocalGameProcesses().start(
        LaunchSpec(
          executable: p.join(root, 'Engine tools', 'Build.bat'),
          workingDirectory: root,
          arguments: ['Project folder/game.uproject', 'a & b'],
        ),
      );
      addTearDown(child.close);
      final output = child.stdout.transform(utf8.decoder).join();
      final error = child.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .join();
      await child.input(null);
      final code = await child.exitCode;
      await child.close();
      expect(code, 0, reason: await error);
      expect(await output, contains('"Project folder/game.uproject"'));
      expect(await output, contains('"a & b"'));
      await expectLater(
        LocalGameProcesses().start(
          LaunchSpec(
            executable: p.join(root, 'Engine tools', 'Build.bat'),
            workingDirectory: root,
            arguments: ['a&b'],
          ),
        ),
        throwsFormatException,
      );
    },
    skip: !Platform.isWindows,
  );

  test(
    'owned game process captures native stdout and never requires a terminal',
    () async {
      final executable = Platform.isWindows
          ? '${Platform.environment['SystemRoot']}\\System32\\where.exe'
          : '/bin/echo';
      final child = await LocalGameProcesses().start(
        LaunchSpec(
          executable: executable,
          workingDirectory: Directory.current.path,
          arguments: Platform.isWindows ? ['cmd.exe'] : ['native output'],
        ),
      );
      final output = child.stdout.transform(utf8.decoder).join();
      final error = child.stderr.transform(utf8.decoder).join();
      await child.input(null);
      expect(await child.exitCode, 0);
      await child.close();
      expect(await output, isNotEmpty);
      expect(await error, isEmpty);
    },
  );
}

DevelopmentProject project(String root) => DevelopmentProject(
  workspace: root,
  directory: root,
  name: 'Arena',
  kind: ProjectKind.unreal,
  manifests: const ['Arena.uproject'],
);
Future<String> temporaryProject() async {
  final dir = await Directory.systemTemp.createTemp('game_development_');
  addTearDown(() => dir.delete(recursive: true));
  return dir.resolveSymbolicLinks();
}

Future<void> writeFile(String root, String relative, String text) async {
  final file = File(p.join(root, relative));
  await file.parent.create(recursive: true);
  await file.writeAsString(text);
}

GameProcessSpec spec(
  String name, {
  bool persistent = false,
  String? ready,
  List<String> depends = const [],
  Duration timeout = const Duration(seconds: 1),
}) => GameProcessSpec(
  name,
  LaunchSpec(
    executable: p.absolute('fake.exe'),
    workingDirectory: p.absolute('game'),
  ),
  persistent: persistent,
  readyText: ready,
  dependsOn: depends,
  readyTimeout: timeout,
);
GamePlan memoryPlan(List<GameProcessSpec> processes) => GamePlan(
  workspace: GameWorkspace(
    project: project(p.absolute('game')),
    configuration: GameConfiguration(),
    configurationSource: LocalGameWorkspace.initialConfiguration,
  ),
  title: 'session',
  processes: processes,
);
Future<void> until(bool Function() done) async {
  final end = DateTime.now().add(const Duration(seconds: 5));
  while (!done()) {
    if (DateTime.now().isAfter(end)) {
      throw StateError('Condition did not complete.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<void> nativeUntil(
  bool Function() done,
  String Function() describe, {
  Duration timeout = const Duration(seconds: 60),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) throw StateError(describe());
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

class MemoryGameFiles implements GameWorkspaceFiles {
  TestResults results = const TestResults([
    TestCaseResult(name: 'Rules', outcome: TestOutcome.passed),
  ], complete: true);
  String currentFingerprint = 'before';
  @override
  Future<void> validatePlan(GamePlan plan) async {}
  @override
  Future<void> verifyOutputs(GamePlan plan) async {}
  @override
  Future<String> fingerprint(GameWorkspace workspace) async =>
      currentFingerprint;
  @override
  Future<TestResults> report(GamePlan plan) async => results;
  @override
  Future<GameWorkspace> load(
    DevelopmentProject project,
    Cancellation cancellation,
  ) async => memoryPlan([]).workspace;
  @override
  Future<void> save(GameWorkspace workspace, String source) async {}
  @override
  Future<List<String>> assetProblems(
    GameWorkspace workspace,
    GameAsset asset,
  ) async => [];
  @override
  Future<Uint8List> preview(GameWorkspace workspace, GameAsset asset) async =>
      Uint8List(0);
  @override
  Future<String> checkedPath(
    DevelopmentProject project,
    String relative, {
    bool exists = true,
  }) async => p.join(project.directory, relative);
}

class MemoryGameProcesses implements GameProcesses {
  final started = <MemoryGameProcess>[];
  Completer<void>? gate;
  int calls = 0;
  @override
  Future<GameProcess> start(
    LaunchSpec spec, {
    String? environmentScript,
  }) async {
    calls++;
    await gate?.future;
    final process = MemoryGameProcess(100 + calls);
    started.add(process);
    return process;
  }
}

class MemoryGameProcess implements GameProcess {
  MemoryGameProcess(this.pid);
  @override
  final int pid;
  final out = StreamController<List<int>>();
  final err = StreamController<List<int>>();
  final exit = Completer<int>();
  bool closed = false;
  String? finalOutput;
  String? received;
  @override
  Stream<List<int>> get stdout => out.stream;
  @override
  Stream<List<int>> get stderr => err.stream;
  @override
  Future<int> get exitCode => exit.future;
  @override
  Future<void> input(String? text) async {
    received = text;
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    if (finalOutput != null) out.add(utf8.encode(finalOutput!));
    if (!exit.isCompleted) exit.complete(0);
    await out.close();
    await err.close();
  }
}
