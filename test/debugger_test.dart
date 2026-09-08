import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tabryo/core/cancellation.dart';
import 'package:tabryo/features/debugger/application/debug_service.dart';
import 'package:tabryo/features/debugger/application/debug_profiles.dart';
import 'package:tabryo/features/debugger/domain/debug_session.dart';
import 'package:tabryo/features/debugger/infrastructure/dap_connection.dart';
import 'package:tabryo/features/projects/domain/project.dart';

void main() {
  test(
    'Flutter discovers the desktop device, runs, reloads and restarts saved code',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'tabryo_flutter_debug_',
      );
      final root = await directory.resolveSymbolicLinks();
      final sdk = Platform.environment['FLUTTER_ROOT']!;
      final dart = p.join(
        sdk,
        'bin',
        'cache',
        'dart-sdk',
        'bin',
        Platform.isWindows ? 'dart.exe' : 'dart',
      );
      final platform = Platform.isWindows ? 'windows' : 'linux';
      final created = await Process.run(dart, [
        p.join(sdk, 'bin', 'cache', 'flutter_tools.snapshot'),
        'create',
        '--platforms=$platform',
        '--project-name=debug_app',
        '--no-pub',
        root,
      ]);
      expect(
        created.exitCode,
        0,
        reason: '${created.stdout}\n${created.stderr}',
      );
      // The exercised app only imports Flutter; unrelated template packages
      // must not turn an offline debugger check into a network dependency.
      await File(p.join(root, 'pubspec.yaml')).writeAsString(
        'name: debug_app\nenvironment:\n  sdk: ^3.13.2\ndependencies:\n  flutter:\n    sdk: flutter\nflutter:\n  uses-material-design: true\n',
      );
      final source = File(p.join(root, 'lib', 'main.dart'));
      String code(String message) =>
          "import 'package:flutter/material.dart';\n"
          "void main() { print('BOOT_READY'); runApp(const App()); }\n"
          "class App extends StatelessWidget { const App({super.key});\n"
          "@override Widget build(BuildContext context) { print('$message'); return const MaterialApp(home: Text('$message')); } }\n";
      await source.writeAsString(code('FIRST_READY'));
      final setup = await Process.run(dart, [
        p.join(sdk, 'bin', 'cache', 'flutter_tools.snapshot'),
        'pub',
        'get',
        '--offline',
      ], workingDirectory: root);
      expect(setup.exitCode, 0, reason: '${setup.stdout}\n${setup.stderr}');
      final project = DevelopmentProject(
        workspace: root,
        directory: root,
        name: 'Flutter debug',
        kind: ProjectKind.flutter,
      );
      final tools = ToolchainSelection({
        ProjectTool.flutter: sdk,
        ProjectTool.dart: dart,
      });
      final adapters = LocalDebugAdapters();
      final service = DebugService(adapters);
      addTearDown(() async {
        await service.dispose();
        await directory.delete(recursive: true);
      });
      final devices = await adapters.devices(project, tools);
      expect(devices.any((device) => device.id == platform), isTrue);
      await service.start(
        debugProfile(
          project: project,
          tools: tools,
          program: source.path,
          device: platform,
        ),
      );
      await _until(
        () => service.appStarted && service.output.contains('FIRST_READY'),
        timeout: const Duration(minutes: 3),
        describe: () =>
            'Flutter startup: ${service.status}, appStarted=${service.appStarted}, error=${service.error}\n${service.output}',
      );
      expect(service.vmService, isNotNull);
      await source.writeAsString(code('RELOADED_READY'));
      await service.control('hotReload');
      await _until(() => service.output.contains('RELOADED_READY'));
      final boots = RegExp('BOOT_READY').allMatches(service.output).length;
      await service.control('hotRestart');
      await _until(
        () => RegExp('BOOT_READY').allMatches(service.output).length > boots,
      );
      await service.stop();
      expect(service.active, isFalse);
    },
    skip: Platform.environment['TABRYO_TEST_FLUTTER_DEBUG'] != '1',
    timeout: const Timeout(Duration(minutes: 5)),
  );

  for (final profile in ['Django', 'FastAPI']) {
    test(
      '$profile profile serves a local request through a verified breakpoint',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'tabryo_backend_',
        );
        final root = await directory.resolveSymbolicLinks();
        final python = Platform.environment['TABRYO_TEST_PYTHON'] ?? _python();
        final tools = ToolchainSelection({ProjectTool.python: python});
        final service = DebugService(LocalDebugAdapters());
        final client = HttpClient();
        addTearDown(() async {
          client.close(force: true);
          await service.dispose();
          await directory.delete(recursive: true);
        });
        late final File source;
        late final String program;
        late final int line;
        if (profile == 'Django') {
          final created = await Process.run(python, [
            '-m',
            'django',
            'startproject',
            'app',
            root,
          ]);
          expect(created.exitCode, 0, reason: '${created.stderr}');
          source = await File(p.join(root, 'app', 'views.py')).writeAsString(
            'from django.http import JsonResponse\n'
            'def index(request):\n'
            '    count = 41\n'
            '    return JsonResponse({"answer": count + 1})\n',
          );
          await File(p.join(root, 'app', 'urls.py')).writeAsString(
            'from django.urls import path\nfrom .views import index\nurlpatterns = [path("", index)]\n',
          );
          program = p.join(root, 'manage.py');
          line = 4;
        } else {
          source = await File(p.join(root, 'main.py')).writeAsString(
            'from fastapi import FastAPI\napp = FastAPI()\n'
            '@app.get("/")\nasync def index():\n'
            '    count = 41\n'
            '    return {"answer": count + 1}\n',
          );
          program = source.path;
          line = 6;
        }
        final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final port = socket.port;
        await socket.close();
        await service.start(
          debugProfile(
            project: DevelopmentProject(
              workspace: root,
              directory: root,
              name: profile,
              kind: ProjectKind.python,
            ),
            tools: tools,
            program: program,
            profile: profile,
            port: port,
            breakpoints: {
              source.path: [line],
            },
          ),
        );
        await _until(
          () => service.output.contains(
            profile == 'Django'
                ? 'development server at http://127.0.0.1:$port/'
                : 'Uvicorn running on',
          ),
          describe: () =>
              '$profile startup: ${service.status}, error=${service.error}\n${service.output}',
        );
        final response = client
            .getUrl(Uri.parse('http://127.0.0.1:$port/'))
            .then((request) => request.close());
        await _until(
          () =>
              service.status == DebugStatus.paused && service.scopes.isNotEmpty,
        );
        expect(
          service.verifiedBreakpoints[source.path]!.single['verified'],
          isTrue,
        );
        expect(service.frames.first['source']['path'], source.path);
        expect(await service.evaluate('count + 1'), '42');
        await service.control('continue');
        final result = await response;
        expect(result.statusCode, HttpStatus.ok);
        expect(jsonDecode(await result.transform(utf8.decoder).join()), {
          'answer': 42,
        });
        await service.stop();
        expect(service.active, isFalse);
      },
      skip: Platform.environment['TABRYO_TEST_DEBUG_PYTHON'] != '1',
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }

  test(
    'Stop waits for an adapter being created and prevents overlapping starts',
    () async {
      final adapters = MemoryAdapters()
        ..creation = Completer<DebugConnection>();
      final service = DebugService(adapters);
      addTearDown(service.dispose);
      final starting = service.start(memoryConfiguration());
      await _until(() => adapters.starts == 1);
      await expectLater(
        service.start(memoryConfiguration()),
        throwsA(isA<DebugFailure>()),
      );
      final stopping = service.stop();
      await Future<void>.delayed(Duration.zero);
      expect(service.active, isTrue);
      adapters.creation!.complete(adapters.connection);
      await starting;
      await stopping;
      expect(adapters.connection.closed, isTrue);
      expect(adapters.connection.commands, isEmpty);
      expect(service.active, isFalse);
    },
  );

  test(
    'normal exit retires an inspection failure from the preceding pause',
    () async {
      final adapters = MemoryAdapters();
      adapters.connection.stackError = const DebugFailure(
        'getStack: Service connection disposed',
      );
      final service = DebugService(adapters);
      addTearDown(service.dispose);
      await service.start(memoryConfiguration());
      adapters.connection.emit('stopped', {'threadId': 7});
      await _until(() => service.error != null);
      adapters.connection.emit('exited', {'exitCode': 0});
      adapters.connection.emit('terminated');
      await _until(() => !service.active);
      expect(service.error, isNull);
      expect(service.exitCode, 0);
    },
  );

  test(
    'resuming discards late variables and stopping closes pending DevTools',
    () async {
      final adapters = MemoryAdapters();
      final service = DebugService(adapters);
      addTearDown(service.dispose);
      await service.start(memoryConfiguration());
      adapters.connection.emit('stopped', {'threadId': 7});
      await _until(() => service.scopes.isNotEmpty);
      final loading = service.loadVariables(10);
      await Future<void>.delayed(Duration.zero);
      adapters.connection.emit('continued');
      await _until(() => service.status == DebugStatus.running);
      adapters.connection.variables.complete({
        'variables': [
          {'name': 'stale', 'value': '1'},
        ],
      });
      await loading;
      expect(service.variables, isEmpty);
      adapters.connection.emit('dart.debuggerUris', {
        'vmServiceUri': 'http://127.0.0.1:1234/token/',
      });
      await _until(() => service.vmService != null);
      final opening = service.openDevTools();
      await _until(() => adapters.devToolsCancellation != null);
      final stopping = service.stop();
      await _until(() => adapters.devToolsCancellation!.isCancelled);
      expect(service.active, isTrue);
      adapters.toolsReady.complete(adapters.tools);
      await opening;
      await stopping;
      expect(adapters.tools.opened, isFalse);
      expect(adapters.tools.closed, isTrue);
      expect(service.devToolsUri, isNull);
      expect(service.active, isFalse);
    },
  );

  test(
    'DAP frames Unicode and refuses reverse requests and orphan replies',
    () async {
      final parser = DapFramer();
      final bytes = DapFramer.encode({
        'seq': 1,
        'type': 'event',
        'event': 'output',
        'body': {'output': 'ação 🌱'},
      });
      final values = <Map<String, dynamic>>[];
      for (final byte in bytes) {
        values.addAll(parser.add([byte]));
      }
      expect(values.single['body']['output'], 'ação 🌱');
      expect(
        () =>
            DapFramer().add(ascii.encode('Content-Length: 999999999\r\n\r\n')),
        throwsFormatException,
      );
      final input = StreamController<List<int>>();
      final sent = <Map<String, dynamic>>[];
      final connection = DapConnection(
        input.stream,
        (bytes) => sent.addAll(DapFramer().add(bytes)),
        () async {},
      );
      final events = connection.events.listen((_) {});
      input.add(
        DapFramer.encode({
          'seq': 2,
          'type': 'request',
          'command': 'runInTerminal',
          'arguments': {},
        }),
      );
      await Future<void>.delayed(Duration.zero);
      expect(sent.single['success'], isFalse);
      final pending = connection.request('threads');
      final rejected = expectLater(pending, throwsA(isA<DebugFailure>()));
      await input.close();
      await rejected;
      await connection.close();
      await events.cancel();
    },
  );

  test(
    'Dart adapter stops at a breakpoint, exposes variables, steps and exits',
    () async {
      final directory = await Directory.systemTemp.createTemp('tabryo_debug_');
      final root = await directory.resolveSymbolicLinks();
      final source = await File(p.join(root, 'main.dart')).writeAsString(
        'void main() {\n  var count = 41;\n  print(count + 1);\n}\n',
      );
      final sdk = Platform.environment['FLUTTER_ROOT']!;
      final dart = p.join(
        sdk,
        'bin',
        'cache',
        'dart-sdk',
        'bin',
        Platform.isWindows ? 'dart.exe' : 'dart',
      );
      final service = DebugService(LocalDebugAdapters());
      addTearDown(() async {
        await service.dispose();
        await directory.delete(recursive: true);
      });
      final project = DevelopmentProject(
        workspace: root,
        directory: root,
        name: 'debug',
        kind: ProjectKind.dart,
      );
      await service.start(
        DebugConfiguration(
          project: project,
          tools: ToolchainSelection({ProjectTool.dart: dart}),
          program: source.path,
          breakpoints: {
            source.path: [3],
          },
        ),
      );
      await _until(
        () => service.status == DebugStatus.paused && service.scopes.isNotEmpty,
      );
      expect(service.frames.first['line'], 3);
      expect(
        service.verifiedBreakpoints[source.path]!.single['verified'],
        isTrue,
      );
      final local = service.scopes.firstWhere(
        (s) =>
            s['variablesReference'] is int &&
            (s['variablesReference'] as int) > 0,
      );
      await service.loadVariables(local['variablesReference'] as int);
      expect(
        service.variables.any(
          (v) => v['name'] == 'count' && '${v['value']}' == '41',
        ),
        isTrue,
      );
      expect(await service.evaluate('count + 1'), '42');
      await _until(() => service.vmService != null);
      final cancellation = Cancellation();
      final devTools = await LocalDebugAdapters().devTools(
        service.configuration!,
        service.vmService!,
        cancellation,
      );
      try {
        expect(
          devTools.uri.queryParameters['uri'],
          service.vmService.toString(),
        );
        final client = HttpClient();
        try {
          final response = await (await client.getUrl(devTools.uri)).close();
          expect(response.statusCode, HttpStatus.ok);
          expect(
            await response.transform(utf8.decoder).join(),
            contains('<html'),
          );
        } finally {
          client.close(force: true);
        }
      } finally {
        await devTools.close();
      }
      cancellation.cancel();
      await expectLater(
        LocalDebugAdapters().devTools(
          service.configuration!,
          service.vmService!,
          cancellation,
        ),
        throwsA(isA<Cancelled>()),
      );
      final stops = service.stopCount;
      await service.control('next');
      await _until(
        () =>
            service.status == DebugStatus.terminated ||
            (service.status == DebugStatus.paused &&
                service.stopCount > stops &&
                service.frames.isNotEmpty &&
                service.scopes.isNotEmpty),
      );
      if (service.status == DebugStatus.paused) {
        await service.control('continue');
      }
      await _until(() => service.status == DebugStatus.terminated);
      expect(service.output, contains('42'));
      expect(service.error, isNull);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'Python adapter debugs the selected environment and Stop reaps descendants',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'tabryo_python_debug_',
      );
      final root = await directory.resolveSymbolicLinks();
      final source = await File(p.join(root, 'main.py')).writeAsString(
        'import subprocess, sys, time\n'
        'child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])\n'
        'print("CHILD:" + str(child.pid), flush=True)\n'
        'count = 41\n'
        'print(count + 1, flush=True)\n'
        'time.sleep(60)\n',
      );
      final python = Platform.environment['TABRYO_TEST_PYTHON'] ?? _python();
      final service = DebugService(LocalDebugAdapters());
      addTearDown(() async {
        await service.dispose();
        await directory.delete(recursive: true);
      });
      final project = DevelopmentProject(
        workspace: root,
        directory: root,
        name: 'python',
        kind: ProjectKind.python,
      );
      await service.start(
        DebugConfiguration(
          project: project,
          tools: ToolchainSelection({ProjectTool.python: python}),
          program: source.path,
          breakpoints: {
            source.path: [5],
          },
        ),
      );
      await _until(
        () => service.status == DebugStatus.paused && service.scopes.isNotEmpty,
      );
      expect(service.frames.first['line'], 5);
      final child = int.parse(
        RegExp(r'CHILD:(\d+)').firstMatch(service.output)!.group(1)!,
      );
      expect(await service.evaluate('count + 1'), '42');
      await service.control('continue');
      await _until(() => service.output.contains('42'));
      await service.stop();
      expect(service.active, isFalse);
      if (Platform.isWindows) {
        final listed = await Process.run('tasklist', [
          '/FI',
          'PID eq $child',
          '/FO',
          'CSV',
          '/NH',
        ]);
        expect('${listed.stdout}', isNot(contains('"$child"')));
      } else {
        expect(await Directory('/proc/$child').exists(), isFalse);
      }
    },
    skip: Platform.environment['TABRYO_TEST_DEBUG_PYTHON'] != '1',
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

DebugConfiguration memoryConfiguration() => DebugConfiguration(
  project: const DevelopmentProject(
    workspace: '/workspace',
    directory: '/workspace',
    name: 'app',
    kind: ProjectKind.dart,
  ),
  tools: ToolchainSelection({ProjectTool.dart: '/sdk/dart'}),
  program: '/workspace/main.dart',
);

final class MemoryAdapters implements DebugAdapters {
  final connection = MemoryDebugConnection();
  final tools = MemoryDebugTools();
  final toolsReady = Completer<DebugTools>();
  Completer<DebugConnection>? creation;
  Cancellation? devToolsCancellation;
  int starts = 0;
  @override
  Future<DebugConnection> start(DebugConfiguration configuration) {
    starts++;
    return creation?.future ?? Future.value(connection);
  }

  @override
  Future<List<FlutterDevice>> devices(
    DevelopmentProject project,
    ToolchainSelection tools,
  ) async => [];
  @override
  Future<DebugTools> devTools(
    DebugConfiguration configuration,
    Uri service,
    Cancellation cancellation,
  ) {
    devToolsCancellation = cancellation;
    return toolsReady.future;
  }
}

final class MemoryDebugConnection implements DebugConnection {
  Object? stackError;
  final controller = StreamController<Map<String, dynamic>>.broadcast();
  final variables = Completer<Map<String, dynamic>>();
  final commands = <String>[];
  bool closed = false;
  void emit(String name, [Map<String, dynamic> body = const {}]) =>
      controller.add({'event': name, 'body': body});
  @override
  Stream<Map<String, dynamic>> get events => controller.stream;
  @override
  Future<Map<String, dynamic>> request(
    String command, [
    Map<String, Object?> arguments = const {},
  ]) async {
    commands.add(command);
    if (command == 'stackTrace' && stackError != null) throw stackError!;
    if (command == 'initialize') {
      return {'supportsConfigurationDoneRequest': true};
    }
    if (command == 'launch') emit('initialized');
    if (command == 'stackTrace') {
      return {
        'stackFrames': [
          {'id': 9, 'line': 3},
        ],
      };
    }
    if (command == 'scopes') {
      return {
        'scopes': [
          {'name': 'locals', 'variablesReference': 10},
        ],
      };
    }
    if (command == 'variables') return variables.future;
    return {};
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    await controller.close();
  }
}

final class MemoryDebugTools implements DebugTools {
  bool opened = false;
  bool closed = false;
  @override
  Uri get uri => Uri.parse('http://127.0.0.1:1235/');
  @override
  Future<void> open() async {
    opened = true;
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

String _python() {
  for (final directory in (Platform.environment['PATH'] ?? '').split(
    Platform.isWindows ? ';' : ':',
  )) {
    final path = p.join(
      directory,
      Platform.isWindows ? 'python.exe' : 'python',
    );
    if (File(path).existsSync()) return path;
  }
  throw StateError('Set TABRYO_TEST_PYTHON to an environment with debugpy.');
}

Future<void> _until(
  bool Function() predicate, {
  String Function()? describe,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail(
        'The debugger did not reach the expected state. ${describe?.call() ?? ''}',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }
}
