import 'dart:convert';
import 'dart:typed_data';

import '../../../core/cancellation.dart';

import '../../projects/domain/project.dart';
import '../../terminals/domain/terminal_ports.dart';
import '../../tasks/domain/project_task.dart';

enum GameAction {
  configure,
  build,
  compileCommands,
  test,
  editor,
  cook,
  package,
  validateContent,
}

enum GameProcessState { starting, running, ready, passed, failed, stopped }

enum GameProblemKind { compiler, unrealHeader, asset, test, runtime }

abstract interface class GameProcess {
  int get pid;
  Stream<List<int>> get stdout;
  Stream<List<int>> get stderr;
  Future<int> get exitCode;
  Future<void> input(String? text);
  Future<void> close();
}

abstract interface class GameProcesses {
  Future<GameProcess> start(LaunchSpec spec, {String? environmentScript});
}

abstract interface class GameWorkspaceFiles {
  Future<GameWorkspace> load(
    DevelopmentProject project,
    Cancellation cancellation,
  );
  Future<void> save(GameWorkspace workspace, String source);
  Future<void> validatePlan(GamePlan plan);
  Future<void> verifyOutputs(GamePlan plan);
  Future<String> fingerprint(GameWorkspace workspace);
  Future<TestResults> report(GamePlan plan);
  Future<List<String>> assetProblems(GameWorkspace workspace, GameAsset asset);
  Future<Uint8List> preview(GameWorkspace workspace, GameAsset asset);
  Future<String> checkedPath(
    DevelopmentProject project,
    String relative, {
    bool exists = true,
  });
}

final class GameFailure implements Exception {
  const GameFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

final class UnrealTarget {
  const UnrealTarget(this.name, this.type, this.path);
  final String name;
  final String type;
  final String path;
}

final class GameAsset {
  const GameAsset({
    required this.path,
    this.source,
    this.exported,
    this.objectPath,
    this.preview,
    this.dependencies = const [],
  });
  final String path;
  final String? source;
  final String? exported;
  final String? objectPath;
  final String? preview;
  final List<String> dependencies;
}

/// Portable project-owned settings. Local executable paths remain toolchain choices.
final class GameConfiguration {
  GameConfiguration({
    this.buildDirectory = 'build',
    this.cmakePreset,
    this.configuration = 'Development',
    this.map = '/Game/Maps/Main',
    this.port = 7777,
    this.clients = 2,
    this.testFilter = 'Project',
    this.target = '',
    this.archiveDirectory = 'Saved/Packages',
    this.lab,
    this.services = const [],
    this.sessions = const [],
    this.assets = const [],
    this.pipeline,
    this.blenderExport,
    this.unrealImport,
    this.contentValidation,
    this.versionFiles = const [],
  });
  final String buildDirectory;
  final String? cmakePreset;
  final String configuration;
  final String map;
  final int port;
  final int clients;
  final String testFilter;
  final String target;
  final String archiveDirectory;
  final GameExecutable? lab;
  final List<GameExecutable> services;
  final List<GameSessionProfile> sessions;
  final List<GameAsset> assets;
  final GameExecutable? pipeline;
  final String? blenderExport;
  final String? unrealImport;
  final String? contentValidation;
  final List<String> versionFiles;

  factory GameConfiguration.parse(String text) {
    if (utf8.encode(text).length > 256 * 1024) {
      throw const GameFailure('Game configuration exceeds 256 KiB.');
    }
    final value = jsonDecode(text);
    if (value is! Map || value['version'] != 1) {
      throw const GameFailure('Game configuration requires version 1.');
    }
    final allowed = {
      'version',
      'buildDirectory',
      'cmakePreset',
      'configuration',
      'map',
      'port',
      'clients',
      'testFilter',
      'target',
      'archiveDirectory',
      'lab',
      'services',
      'sessions',
      'assets',
      'pipeline',
      'blenderExport',
      'unrealImport',
      'contentValidation',
      'versionFiles',
    };
    if (value.keys.any((k) => !allowed.contains(k))) {
      throw const GameFailure('Unknown game configuration field.');
    }
    String string(String key, String fallback) =>
        gameString(value[key] ?? fallback, key);
    int integer(String key, int fallback, int min, int max) {
      final n = value[key] ?? fallback;
      if (n is! int || n < min || n > max) {
        throw GameFailure('$key must be between $min and $max.');
      }
      return n;
    }

    final services = value['services'] ?? [];
    final sessions = value['sessions'] ?? [];
    final assets = value['assets'] ?? [];
    if (sessions is! List ||
        sessions.length > 20 ||
        services is! List ||
        services.length > 8 ||
        assets is! List ||
        assets.length > 2000) {
      throw const GameFailure('Too many services or assets.');
    }
    final parsedServices = services.map(GameExecutable.parse).toList();
    if (parsedServices.map((s) => s.name).toSet().length !=
        parsedServices.length) {
      throw const GameFailure('Service names must be unique.');
    }
    final config = GameConfiguration(
      buildDirectory: gameRelative(string('buildDirectory', 'build')),
      cmakePreset: value['cmakePreset'] == null
          ? null
          : gameString(value['cmakePreset'], 'cmakePreset'),
      configuration: string('configuration', 'Development'),
      map: string('map', '/Game/Maps/Main'),
      port: integer('port', 7777, 1024, 65535),
      clients: integer('clients', 2, 1, 16),
      testFilter: string('testFilter', 'Project'),
      target: string('target', ''),
      archiveDirectory: gameRelative(
        string('archiveDirectory', 'Saved/Packages'),
      ),
      lab: value['lab'] == null ? null : GameExecutable.parse(value['lab']),
      pipeline: value['pipeline'] == null
          ? null
          : GameExecutable.parse(value['pipeline']),
      services: List.unmodifiable(parsedServices),
      sessions: List.unmodifiable(sessions.map(GameSessionProfile.parse)),
      assets: List.unmodifiable(
        assets.map((v) {
          if (v is! Map ||
              v.keys.any(
                (k) => !{
                  'path',
                  'source',
                  'exported',
                  'objectPath',
                  'preview',
                  'dependencies',
                }.contains(k),
              )) {
            throw const GameFailure('Invalid asset mapping.');
          }
          final object = v['objectPath'] == null
              ? null
              : gameString(v['objectPath'], 'objectPath');
          if (object != null &&
              !RegExp(r'^/Game/[A-Za-z0-9_/]+(?:\.[A-Za-z0-9_]+)?$')
                  .hasMatch(object)) {
            throw const GameFailure('Invalid Unreal object path.');
          }
          return GameAsset(
            path: gameRelative(gameString(v['path'], 'asset path')),
            source: v['source'] == null
                ? null
                : gameRelative(gameString(v['source'], 'source')),
            exported: v['exported'] == null
                ? null
                : gameRelative(gameString(v['exported'], 'exported')),
            objectPath: object,
            preview: v['preview'] == null
                ? null
                : gameRelative(gameString(v['preview'], 'preview')),
            dependencies: gameStrings(
              v['dependencies'] ?? [],
              'dependencies',
            ).map(gameRelative).toList(),
          );
        }),
      ),
      blenderExport: value['blenderExport'] == null
          ? null
          : gameRelative(gameString(value['blenderExport'], 'blenderExport')),
      unrealImport: value['unrealImport'] == null
          ? null
          : gameRelative(gameString(value['unrealImport'], 'unrealImport')),
      contentValidation: value['contentValidation'] == null
          ? null
          : gameRelative(
              gameString(value['contentValidation'], 'contentValidation'),
            ),
      versionFiles: gameStrings(
        value['versionFiles'] ?? [],
        'versionFiles',
      ).map(gameRelative).toList(),
    );
    if (!{
          'Debug',
          'DebugGame',
          'Development',
          'Shipping',
          'Test',
          'Release',
          'RelWithDebInfo',
        }.contains(config.configuration) ||
        !RegExp(r'^/Game/[A-Za-z0-9_/]+$').hasMatch(config.map) ||
        !RegExp(r'^[A-Za-z0-9_. -]{1,256}$').hasMatch(config.testFilter) ||
        !RegExp(r'^[A-Za-z0-9_-]*$').hasMatch(config.target)) {
      throw const GameFailure(
        'Invalid build configuration, map, test filter or target.',
      );
    }
    return config;
  }
}

String gameString(Object? value, String name) {
  if (value is! String ||
      value.length > 4096 ||
      value.contains('\u0000') ||
      value.contains('\n') ||
      value.contains('\r')) {
    throw GameFailure('Invalid $name.');
  }
  return value;
}

List<String> gameStrings(Object? value, String name) {
  if (value is! List || value.length > 64) {
    throw GameFailure('Invalid $name list (limit 64).');
  }
  return List.unmodifiable(value.map((v) => gameString(v, name)));
}

String gameRelative(String value) {
  if (value.isEmpty ||
      value.startsWith('/') ||
      value.startsWith('\\') ||
      value.contains(':') ||
      value.split(RegExp(r'[/\\]')).any((s) => s == '..' || s.isEmpty)) {
    throw const GameFailure('Use a relative project path without traversal.');
  }
  return value.replaceAll('\\', '/');
}

final class GameExecutable {
  const GameExecutable({
    required this.name,
    required this.executable,
    this.arguments = const [],
    this.readyText,
    this.readyTimeoutSeconds = 90,
    this.dependsOn = const [],
  });
  final String name;
  final String executable;
  final List<String> arguments;
  final String? readyText;
  final int readyTimeoutSeconds;
  final List<String> dependsOn;
  factory GameExecutable.parse(Object? value) {
    if (value is! Map ||
        value.keys.any(
          (k) => !{
            'name',
            'executable',
            'arguments',
            'readyText',
            'readyTimeoutSeconds',
            'dependsOn',
          }.contains(k),
        )) {
      throw const GameFailure('Invalid executable profile.');
    }
    final name = gameString(value['name'], 'profile name');
    final executable = gameRelative(
      gameString(value['executable'], 'executable'),
    );
    final ready = value['readyText'] == null
        ? null
        : gameString(value['readyText'], 'readyText');
    final timeout = value['readyTimeoutSeconds'] ?? 90;
    if (name.trim().isEmpty ||
        name.length > 80 ||
        ready?.isEmpty == true ||
        timeout is! int ||
        timeout < 1 ||
        timeout > 1800) {
      throw const GameFailure('Invalid process name or readiness timeout.');
    }
    return GameExecutable(
      name: name,
      executable: executable,
      arguments: gameStrings(value['arguments'] ?? [], 'arguments'),
      readyText: ready,
      readyTimeoutSeconds: timeout,
      dependsOn: gameStrings(value['dependsOn'] ?? [], 'dependsOn'),
    );
  }
}

final class GameSessionProfile {
  const GameSessionProfile(
    this.name,
    this.buildVersion,
    this.scenario,
    this.processes,
  );
  final String name;
  final String buildVersion;
  final String scenario;
  final List<GameExecutable> processes;
  factory GameSessionProfile.parse(Object? value) {
    if (value is! Map ||
        value.keys.any(
          (k) => !{'name', 'buildVersion', 'scenario', 'processes'}.contains(k),
        )) {
      throw const GameFailure('Invalid session profile.');
    }
    final name = gameString(value['name'], 'session name');
    final version = gameString(value['buildVersion'], 'buildVersion');
    final scenario = gameString(value['scenario'], 'scenario');
    final list = value['processes'];
    if (name.isEmpty ||
        version.isEmpty ||
        list is! List ||
        list.isEmpty ||
        list.length > 25) {
      throw const GameFailure(
        'A session needs a name, buildVersion and 1–25 processes.',
      );
    }
    final processes = list.map(GameExecutable.parse).toList();
    final names = <String>{};
    for (final process in processes) {
      if (process.dependsOn.any((n) => !names.contains(n)) ||
          !names.add(process.name)) {
        throw const GameFailure(
          'Session names must be unique and dependencies must precede clients.',
        );
      }
    }
    for (final dependency in processes.expand((p) => p.dependsOn).toSet()) {
      if (processes.firstWhere((p) => p.name == dependency).readyText == null) {
        throw const GameFailure(
          'Session dependencies require readiness markers.',
        );
      }
    }
    return GameSessionProfile(
      name,
      version,
      scenario,
      List.unmodifiable(processes),
    );
  }
}

final class GameWorkspace {
  const GameWorkspace({
    required this.project,
    required this.configuration,
    required this.configurationSource,
    this.targets = const [],
    this.modules = const [],
    this.plugins = const [],
    this.assets = const [],
    this.limited = false,
  });
  final DevelopmentProject project;
  final GameConfiguration configuration;
  final String configurationSource;
  final List<UnrealTarget> targets;
  final List<String> modules;
  final List<String> plugins;
  final List<GameAsset> assets;
  final bool limited;
}

final class GameProcessSpec {
  const GameProcessSpec(
    this.name,
    this.launch, {
    this.readyText,
    this.readyTimeout = const Duration(seconds: 90),
    this.dependsOn = const [],
    this.persistent = false,
    this.input,
    this.environmentScript,
  });
  final String name;
  final LaunchSpec launch;
  final String? readyText;
  final Duration readyTimeout;
  final List<String> dependsOn;
  final bool persistent;
  final String? input;
  final String? environmentScript;
}

final class GamePlan {
  GamePlan({
    required this.workspace,
    required this.title,
    required this.processes,
    this.reportPath,
    this.testReport = false,
    this.labRequest,
    this.fingerprint,
    this.toolPaths = const {},
    this.artifactDirectory,
    this.compilationDatabase,
    this.scenario = const {},
    this.inputPaths = const [],
    this.outputPaths = const [],
  });
  final GameWorkspace workspace;
  final String title;
  final List<GameProcessSpec> processes;
  final String? reportPath;
  final bool testReport;
  final Map<String, Object?>? labRequest;
  final String? fingerprint;
  final Map<ProjectTool, String> toolPaths;
  final String? artifactDirectory;
  final String? compilationDatabase;
  final Map<String, String> scenario;
  final List<String> inputPaths;
  final List<String> outputPaths;
}

final class GameProblem {
  const GameProblem(
    this.kind,
    this.message, {
    this.path,
    this.line,
    this.column = 1,
  });
  final GameProblemKind kind;
  final String message;
  final String? path;
  final int? line;
  final int column;
}

final class GameProcessRun {
  GameProcessRun(this.spec);
  final GameProcessSpec spec;
  GameProcessState state = GameProcessState.starting;
  String output = '';
  bool outputLimited = false;
  int? pid;
  int? exitCode;
  String? error;
  bool get active => const {
    GameProcessState.starting,
    GameProcessState.running,
    GameProcessState.ready,
  }.contains(state);
}

final class GameRun {
  GameRun(this.plan)
    : processes = [for (final spec in plan.processes) GameProcessRun(spec)];
  final GamePlan plan;
  final List<GameProcessRun> processes;
  final DateTime started = DateTime.now().toUtc();
  bool starting = true;
  bool stopped = false;
  bool complete = false;
  String? error;
  TestResults? tests;
  LabResult? lab;
  final List<GameProblem> problems = [];
  bool get active => starting || processes.any((p) => p.active);
  bool get successful =>
      complete &&
      !stopped &&
      error == null &&
      processes.every((p) => p.state == GameProcessState.passed) &&
      (!plan.testReport ||
          (tests?.complete == true && tests?.successful == true));
}

/// Results are calculated by the game's native core. Tabryo validates and renders.
final class LabResult {
  LabResult(this.codeVersion, this.dataVersion, this.cases, this.fingerprint);
  final String codeVersion;
  final String dataVersion;
  final List<Map<String, dynamic>> cases;
  final String fingerprint;
  factory LabResult.parse(String output, String fingerprint) {
    if (utf8.encode(output).length > 1024 * 1024) {
      throw const GameFailure('Laboratory result exceeds 1 MiB.');
    }
    final value = jsonDecode(output);
    if (value is! Map ||
        value['version'] != 1 ||
        value['cases'] is! List ||
        (value['cases'] as List).isEmpty ||
        (value['cases'] as List).length > 64) {
      throw const GameFailure(
        'The native laboratory must return version 1 and 1–64 cases.',
      );
    }
    final code = gameString(value['codeVersion'], 'codeVersion');
    final data = gameString(value['dataVersion'], 'dataVersion');
    if (code.isEmpty || data.isEmpty) {
      throw const GameFailure(
        'Laboratory results must identify code and data versions.',
      );
    }
    final cases = <Map<String, dynamic>>[];
    for (final item in value['cases'] as List) {
      if (item is! Map ||
          item['id'] is! String ||
          item['metrics'] is! Map ||
          item['explanation'] is! List) {
        throw const GameFailure(
          'Each case requires id, metrics and explanation.',
        );
      }
      gameString(item['id'], 'case ID');
      if ((item['id'] as String).isEmpty ||
          cases.any((c) => c['id'] == item['id'])) {
        throw const GameFailure('Case IDs must be nonempty and unique.');
      }
      if ((item['metrics'] as Map).isEmpty ||
          (item['metrics'] as Map).length > 128 ||
          (item['metrics'] as Map).entries.any(
            (e) =>
                e.key is! String ||
                (e.key as String).isEmpty ||
                (e.key as String).length > 128 ||
                e.value is! num ||
                !(e.value as num).isFinite,
          )) {
        throw const GameFailure('Metrics must be finite numeric values.');
      }
      gameStrings(item['explanation'], 'explanation');
      cases.add(Map<String, dynamic>.unmodifiable(item));
    }
    return LabResult(code, data, List.unmodifiable(cases), fingerprint);
  }
}
