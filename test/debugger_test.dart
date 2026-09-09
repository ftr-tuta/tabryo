import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:dtd/dtd.dart';
import 'package:vm_service/vm_service_io.dart';
import 'package:path/path.dart' as p;
import 'package:tabryo/core/cancellation.dart';
import 'package:tabryo/core/preview_cache.dart';
import 'package:tabryo/features/editor/infrastructure/local_document_files.dart';
import 'package:tabryo/features/editor/infrastructure/local_dart_formatter.dart';
import 'package:tabryo/features/editor/presentation/editor_view_model.dart';
import 'package:tabryo/features/projects/infrastructure/local_project_environment.dart';
import 'package:tabryo/features/projects/presentation/projects_view_model.dart';
import 'package:tabryo/features/workspaces/presentation/workbench_view_model.dart';
import 'package:tabryo/features/debugger/application/debug_service.dart';
import 'package:tabryo/features/debugger/application/debug_profiles.dart';
import 'package:tabryo/features/debugger/domain/debug_session.dart';
import 'package:tabryo/features/debugger/infrastructure/dap_connection.dart';
import 'package:tabryo/features/debugger/infrastructure/debug_process.dart';
import 'package:tabryo/features/projects/domain/project.dart';

import 'workbench_test.dart'
    show MemoryHost, MemoryLauncher, MemoryFiles, NoGit, MemoryPreferences;

void main() {
  test(
    'Inspector source locations reject remote, malformed and encoded NUL paths',
    () {
      final source = File(p.join(Directory.systemTemp.path, 'inspector.dart'))
          .uri;
      final valid = {'fileUri': source.toString(), 'line': 3, 'column': 5};
      expect(
        DebugSourceLocation.fromInspector(valid)?.path,
        source.toFilePath(),
      );
      for (final file in [
        'https://example.invalid/a.dart',
        'file://server/share/a.dart',
        'file:relative.dart',
        '$source%00',
        '$source?read=true',
      ]) {
        expect(
          DebugSourceLocation.fromInspector({...valid, 'fileUri': file}),
          isNull,
          reason: file,
        );
      }
      expect(DebugSourceLocation.fromInspector({...valid, 'line': 0}), isNull);
      expect(
        DebugSourceLocation.fromInspector({...valid, 'column': '1'}),
        isNull,
      );
    },
  );
  test('debug configuration rejects external endpoints, escaped directories and breakpoints in run mode', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'tabryo_debug_config_',
    );
    final root = await temporary.resolveSymbolicLinks();
    final source = await File(p.join(root, 'main.dart'))
        .writeAsString('void main() {}');
    addTearDown(() => temporary.delete(recursive: true));
    final project = DevelopmentProject(
      workspace: root,
      directory: root,
      name: 'app',
      kind: ProjectKind.dart,
    );
    final tools = ToolchainSelection({
      ProjectTool.dart: p.join(
        Platform.environment['FLUTTER_ROOT']!,
        'bin',
        'cache',
        'dart-sdk',
        'bin',
        Platform.isWindows ? 'dart.exe' : 'dart',
      ),
    });
    final configurations = [
      for (final address in [
        'http://example.com:1234/',
        'http://localhost:1234/',
        'http://user@127.0.0.1:1234/',
        'http://127.0.0.1:1234/?target=other',
      ])
        DebugConfiguration(
          project: project,
          tools: tools,
          program: source.path,
          attachUri: Uri.parse(address),
        ),
      DebugConfiguration(
        project: project,
        tools: tools,
        program: source.path,
        workingDirectory: p.dirname(root),
      ),
      DebugConfiguration(
        project: project,
        tools: tools,
        program: source.path,
        noDebug: true,
        breakpoints: {
          source.path: [const DebugBreakpoint(1)],
        },
      ),
    ];
    for (final config in configurations) {
      DebugConnection? connection;
      try {
        await expectLater(() async {
          connection = await LocalDebugAdapters().start(config);
        }, throwsA(isA<DebugFailure>()));
      } finally {
        await connection?.close();
      }
    }
  });

  for (final python in [false, true]) {
    test(
      '${python ? 'Python' : 'Dart'} local attach pauses and detaches without stopping the existing application',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'tabryo_attach_',
        );
        final root = await directory.resolveSymbolicLinks();
        final info = File(p.join(root, 'service.json'));
        final source = File(p.join(root, python ? 'main.py' : 'main.dart'));
        final text = python
            ? 'import debugpy, json, sys, time\n'
                  'address = debugpy.listen(("127.0.0.1", 0))\n'
                  'with open(sys.argv[1], "w") as f: json.dump({"uri": "tcp://127.0.0.1:" + str(address[1])}, f)\n'
                  'debugpy.wait_for_client()\n'
                  'count = 41\n'
                  'print(count + 1, flush=True)\n'
                  'while True:\n'
                  '    print("TICK", flush=True)\n'
                  '    time.sleep(0.1)\n'
            : "import 'dart:async';\nvoid main() {\n  var count = 41;\n  print(count + 1);\n  Timer.periodic(const Duration(milliseconds: 100), (_) => print('TICK'));\n}\n";
        await source.writeAsString(text);
        final executable = python
            ? Platform.environment['TABRYO_TEST_PYTHON'] ?? _python()
            : p.join(
                Platform.environment['FLUTTER_ROOT']!,
                'bin',
                'cache',
                'dart-sdk',
                'bin',
                Platform.isWindows ? 'dart.exe' : 'dart',
              );
        final child = await DebugProcess.start(
          executable,
          python
              ? [source.path, info.path]
              : [
                  '--enable-vm-service=0',
                  '--pause-isolates-on-start',
                  '--write-service-info=${info.path}',
                  source.path,
                ],
          root,
        );
        var exited = false;
        unawaited(child.process.exitCode.then((_) => exited = true));
        var ticks = 0;
        final output = child.process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen((line) {
              if (line == 'TICK') ticks++;
            });
        final errors = child.process.stderr.listen((_) {});
        final service = DebugService(LocalDebugAdapters());
        addTearDown(() async {
          await service.dispose();
          await child.close();
          await output.cancel();
          await errors.cancel();
          await directory.delete(recursive: true);
        });
        await _until(() => info.existsSync() && info.lengthSync() > 0);
        final uri = Uri.parse(
          (jsonDecode(await info.readAsString()) as Map)['uri'] as String,
        );
        await service.start(
          DebugConfiguration(
            project: DevelopmentProject(
              workspace: root,
              directory: root,
              name: 'attach',
              kind: python ? ProjectKind.python : ProjectKind.dart,
            ),
            tools: ToolchainSelection({
              python ? ProjectTool.python : ProjectTool.dart: executable,
            }),
            program: source.path,
            attachUri: uri,
            breakpoints: {
              source.path: [DebugBreakpoint(python ? 6 : 4)],
            },
          ),
        );
        if (!python) {
          await _until(() => service.status == DebugStatus.paused);
          expect(service.stopReason, 'entry');
          await service.control('continue');
        }
        await _until(
          () =>
              service.status == DebugStatus.paused && service.scopes.isNotEmpty,
          describe: () =>
              '${service.status}/${service.stopReason}: ${service.error}, frames=${service.frames.length}, scopes=${service.scopes.length}',
        );
        expect(await service.evaluate('count + 1'), '42');
        await service.addWatch('count');
        expect(service.watches.single.value, '41');
        await service.stop();
        expect(service.active, isFalse);
        await _until(() => ticks >= 2);
        expect(exited, isFalse);
        expect(service.watches.single.value, isNull);
      },
      skip: python && Platform.environment['TABRYO_TEST_DEBUG_PYTHON'] != '1',
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }

  test('unsupported conditions refuse launch and watches discard a replaced paused frame', () async {
    final denied = MemoryAdapters();
    final unsupported = DebugService(denied);
    final base = memoryConfiguration();
    addTearDown(unsupported.dispose);
    await expectLater(
      unsupported.start(
        DebugConfiguration(
          project: base.project,
          tools: base.tools,
          program: base.program,
          breakpoints: {
            base.program: [const DebugBreakpoint(3, condition: 'count > 0')],
          },
        ),
      ),
      throwsA(isA<DebugFailure>()),
    );
    expect(denied.connection.commands, isNot(contains('launch')));
    expect(denied.connection.closed, isTrue);

    final adapters = MemoryAdapters();
    final service = DebugService(adapters);
    addTearDown(service.dispose);
    await service.start(base);
    adapters.connection.emit('stopped', {'threadId': 1});
    await _until(() => service.scopes.isNotEmpty);
    final watch = adapters.connection.watchReply =
        Completer<Map<String, dynamic>>();
    final adding = service.addWatch('count');
    await _until(() => adapters.connection.commands.contains('evaluate'));
    await service.control('continue'); // DAP permits no continued event here.
    expect(service.status, DebugStatus.running);
    watch.complete({'result': 'stale'});
    await adding;
    expect(service.watches.single.value, isNull);
    adapters.connection.watchReply = null;
    adapters.connection.emit('stopped', {'threadId': 1});
    await _until(() => service.watches.single.value != null);
    expect(service.watches.single.value, 'fresh');
    final lateFrame = adapters.connection.watchReply =
        Completer<Map<String, dynamic>>();
    final changingFrame = service.selectFrame(10);
    await _until(() => service.frameId == 10 && service.scopes.isNotEmpty);
    adapters.connection.watchReply = null;
    await service.selectFrame(9);
    lateFrame.complete({'result': 'wrong frame'});
    await changingFrame;
    expect(service.watches.single.value, 'fresh');
    service.removeWatch('count');
    expect(service.watches, isEmpty);
  });

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
          "class App extends StatefulWidget { const App({super.key}); @override State<App> createState() => AppState(); }\n"
          "class AppState extends State<App> { @override void initState() { super.initState(); print('STATE_CREATED'); }\n"
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
      final editor = EditorViewModel(
        LocalDocumentFiles(PreviewCache()),
        formatter: LocalDartFormatter(),
      )..dartFormatters = {root: dart};
      final projects = ProjectsViewModel(LocalProjectEnvironment());
      final git = NoGit();
      final workbench = WorkbenchViewModel(
        host: MemoryHost(),
        launcher: MemoryLauncher(),
        files: MemoryFiles(),
        gitReader: git,
        gitMutator: git,
        preferencesStore: MemoryPreferences(),
        editor: editor,
        debugger: service,
        projects: projects,
      );
      addTearDown(() async {
        await workbench.shutdown();
        await directory.delete(recursive: true);
      });
      await workbench.openWorkspace(root);
      projects.discovery = ProjectDiscovery([project]);
      projects.selections[project.id] = tools;
      final devices = await adapters.devices(project, tools);
      expect(devices.any((device) => device.id == platform), isTrue);
      await workbench.startDebugger(
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
      await service.selectWidget(true);
      final daemon = await DartToolingDaemon.connect(service.dtdUri!);
      final inspector = await vmServiceConnectUri(
        service.vmService!
            .replace(
              scheme: 'ws',
              path:
                  '${service.vmService!.path.replaceFirst(RegExp(r'/ws$'), '').replaceFirst(RegExp(r'/$'), '')}/ws',
            )
            .toString(),
      );
      addTearDown(() async {
        await inspector.dispose();
        await daemon.close();
      });
      expect(
        (await daemon.getVmServices()).vmServicesInfos.single.uri,
        service.vmService.toString(),
      );
      final isolate = (await inspector.getVM()).isolates!.first.id!;
      const group = 'inspection-source-test';
      final tree = await inspector.callServiceExtension(
        'ext.flutter.inspector.getRootWidgetSummaryTree',
        isolateId: isolate,
        args: {'objectGroup': group},
      );
      Map? sourceWidget(Object? node) {
        if (node is! Map) return null;
        final location = DebugSourceLocation.fromInspector(
          node['creationLocation'],
        );
        if (location != null && p.equals(location.path, source.path)) {
          return node;
        }
        for (final child in (node['children'] as List? ?? [])) {
          final found = sourceWidget(child);
          if (found != null) return found;
        }
        return null;
      }

      final selected = sourceWidget(tree.json?['result']);
      expect(
        selected,
        isNotNull,
        reason: 'The real Inspector tree must include project widgets.',
      );
      await inspector.callServiceExtension(
        'ext.flutter.inspector.setSelectionById',
        isolateId: isolate,
        args: {'arg': selected!['valueId'], 'objectGroup': group},
      );
      await _until(
        () => editor.active?.path == source.path,
        describe: () => service.error ?? 'Inspector did not navigate.',
      );
      final location = DebugSourceLocation.fromInspector(
        selected['creationLocation'],
      )!;
      expect(
        editor.active!.controller.selection.baseOffset,
        editor.active!.controller.text
                .split('\n')
                .take(location.line - 1)
                .fold<int>(0, (n, line) => n + line.length + 1) +
            location.column -
            1,
      );
      await service.openSelectedWidgetSource();
      expect(service.error, isNull);
      await inspector.callServiceExtension(
        'ext.flutter.inspector.disposeGroup',
        isolateId: isolate,
        args: {'objectGroup': group},
      );
      await service.selectWidget(false);
      final states = RegExp('STATE_CREATED').allMatches(service.output).length;
      final boots = RegExp('BOOT_READY').allMatches(service.output).length;
      await editor.open(root, source.path);
      final buffer = editor.active!;
      buffer.controller.text = code('RELOADED_READY');
      expect(await editor.save(buffer), isTrue, reason: buffer.error);
      await _until(() => service.output.contains('RELOADED_READY'));
      expect(RegExp('STATE_CREATED').allMatches(service.output).length, states);
      expect(RegExp('BOOT_READY').allMatches(service.output).length, boots);
      await service.control('hotRestart');
      await _until(
        () => RegExp('BOOT_READY').allMatches(service.output).length > boots,
      );
      await service.stop();
      expect(service.active, isFalse);
      expect(service.dtdUri, isNull);
      await daemon.done.timeout(const Duration(seconds: 10));
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
        final backend = await Directory(p.join(root, 'backend')).create();
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
            backend.path,
          ]);
          expect(created.exitCode, 0, reason: '${created.stderr}');
          source = await File(p.join(backend.path, 'app', 'views.py'))
              .writeAsString(
                'import os\n'
                'from django.http import JsonResponse\n'
                'def index(request):\n'
                '    count = 41\n'
                '    return JsonResponse({"answer": count + 1, "setting": os.environ["BACKEND_SETTING"], "directory": os.path.basename(os.getcwd())})\n',
              );
          await File(p.join(backend.path, 'app', 'urls.py')).writeAsString(
            'from django.urls import path\nfrom .views import index\nurlpatterns = [path("", index)]\n',
          );
          program = p.join(backend.path, 'manage.py');
          line = 5;
        } else {
          source = await File(p.join(backend.path, 'main.py')).writeAsString(
            'import os\n'
            'from fastapi import FastAPI\napp = FastAPI()\n'
            '@app.get("/")\nasync def index():\n'
            '    count = 41\n'
            '    return {"answer": count + 1, "setting": os.environ["BACKEND_SETTING"], "directory": os.path.basename(os.getcwd())}\n',
          );
          program = source.path;
          line = 7;
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
            workingDirectory: backend.path,
            environment: {'BACKEND_SETTING': 'configured'},
            breakpoints: {
              source.path: [DebugBreakpoint(line)],
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
          'setting': 'configured',
          'directory': 'backend',
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
    'successful saves coalesce reloads and stop retires pending checks',
    () async {
      final adapters = MemoryAdapters();
      final service = DebugService(adapters);
      addTearDown(service.dispose);
      final base = memoryConfiguration();
      await service.start(
        DebugConfiguration(
          project: DevelopmentProject(
            workspace: base.project.workspace,
            directory: base.project.directory,
            name: 'Flutter',
            kind: ProjectKind.flutter,
          ),
          tools: base.tools,
          program: base.program,
          device: 'desktop',
        ),
      );
      adapters.connection.emit('flutter.appStarted');
      await _until(() => service.appStarted);
      var checks = 0;
      Future<bool> check() async {
        checks++;
        return true;
      }

      for (var i = 0; i < 5; i++) {
        service.scheduleReloadAfterSave(check);
      }
      await _until(() => adapters.connection.commands.contains('hotReload'));
      expect(checks, 1);
      expect(
        adapters.connection.commands.where((c) => c == 'hotReload').length,
        1,
      );
      expect(adapters.connection.lastHotReason, 'save');
      adapters.connection.emit('stopped', {'threadId': 7});
      await _until(() => service.status == DebugStatus.paused);
      service.scheduleReloadAfterSave(check);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(checks, 1);
      adapters.connection.emit('continued');
      await _until(() => checks == 2);
      final held = Completer<bool>();
      var waiting = false;
      service.scheduleReloadAfterSave(() {
        waiting = true;
        return held.future;
      });
      await _until(() => waiting);
      final count = adapters.connection.commands
          .where((c) => c == 'hotReload')
          .length;
      await service.stop();
      held.complete(true);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(
        adapters.connection.commands.where((c) => c == 'hotReload').length,
        count,
      );
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
    'Inspector navigation coalesces selections and Stop retires queued source',
    () async {
      final adapters = MemoryAdapters();
      final service = DebugService(adapters);
      addTearDown(service.dispose);
      await service.start(memoryConfiguration());
      adapters.connection.emit('dart.debuggerUris', {
        'vmServiceUri': 'http://127.0.0.1:1234/token/',
      });
      await _until(() => service.vmService != null);
      adapters.toolsReady.complete(adapters.tools);
      await service.openDevTools(external: false);
      final opened = <String>[];
      final held = Completer<void>();
      service.onInspectorSource = (location) async {
        opened.add(location.path);
        if (opened.length == 1) await held.future;
      };
      adapters.tools.sources.add(const DebugSourceLocation('first.dart', 1, 1));
      await _until(() => opened.isNotEmpty);
      adapters.tools.sources.add(
        const DebugSourceLocation('superseded.dart', 1, 1),
      );
      adapters.tools.sources.add(
        const DebugSourceLocation('latest.dart', 1, 1),
      );
      await Future<void>.delayed(Duration.zero);
      held.complete();
      await _until(() => opened.length == 2);
      expect(opened, ['first.dart', 'latest.dart']);
      final stopped = Completer<void>();
      service.onInspectorSource = (location) async {
        opened.add(location.path);
        await stopped.future;
      };
      adapters.tools.sources.add(
        const DebugSourceLocation('active.dart', 1, 1),
      );
      await _until(() => opened.length == 3);
      adapters.tools.sources.add(
        const DebugSourceLocation('retired.dart', 1, 1),
      );
      await Future<void>.delayed(Duration.zero);
      await service.stop();
      stopped.complete();
      await Future<void>.delayed(Duration.zero);
      expect(opened, ['first.dart', 'latest.dart', 'active.dart']);
      expect(service.dtdUri, isNull);
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
        'void main() {\n  for (var count = 39; count < 42; count++) {\n    print(count + 1);\n  }\n}\n',
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
            source.path: [const DebugBreakpoint(3, condition: 'count == 41')],
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
      expect(service.stopReason, 'breakpoint');
      await service.addWatch('count');
      expect(service.watches.single.value, '41');
      await service.addWatch('missingLocalName');
      expect(service.watches.last.error, isNotEmpty);
      await _until(() => service.vmService != null);
      final cancellation = Cancellation();
      final devTools = await LocalDebugAdapters().devTools(
        service.configuration!,
        service.vmService!,
        cancellation,
      );
      try {
        final dtd = await DartToolingDaemon.connect(devTools.dtdUri);
        try {
          final apps = await dtd.getVmServices();
          expect(apps.vmServicesInfos.single.uri, service.vmService.toString());
          final roots = await dtd.getIDEWorkspaceRoots();
          expect(
            roots.ideWorkspaceRoots.map((uri) => p.normalize(uri.toFilePath())),
            [p.normalize(root)],
          );
          await expectLater(
            dtd.setIDEWorkspaceRoots('not-the-owner', [
              Uri.directory(Directory.systemTemp.path),
            ]),
            throwsA(isA<Exception>()),
          );
        } finally {
          await dtd.close();
        }
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
        'for count in range(39, 42):\n'
        '    print(count + 1, flush=True)\n'
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
            source.path: [const DebugBreakpoint(5, condition: 'count == 41')],
          },
        ),
      );
      await _until(
        () => service.status == DebugStatus.paused && service.scopes.isNotEmpty,
      );
      expect(service.frames.first['line'], 5);
      expect(service.stopCount, 1);
      await service.addWatch('count');
      expect(service.watches.single.value, '41');
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
  Completer<Map<String, dynamic>>? watchReply;
  String? lastHotReason;
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
    if (command == 'hotReload') lastHotReason = arguments['reason'] as String?;
    if (command == 'stackTrace' && stackError != null) throw stackError!;
    if (command == 'initialize') {
      return {'supportsConfigurationDoneRequest': true};
    }
    if (command == 'launch') emit('initialized');
    if (command == 'stackTrace') {
      return {
        'stackFrames': [
          {'id': 9, 'line': 3},
          {'id': 10, 'line': 4},
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
    if (command == 'evaluate') {
      return watchReply?.future ?? Future.value({'result': 'fresh'});
    }
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
  @override
  Uri get dtdUri => Uri.parse('ws://127.0.0.1:1236/');
  final sources = StreamController<DebugSourceLocation>.broadcast();
  @override
  Stream<DebugSourceLocation> get sourceLocations => sources.stream;
  @override
  Future<void> selectWidget(bool enabled) async {}
  @override
  Future<DebugSourceLocation> selectedWidgetSource() async =>
      throw const DebugFailure('No selection.');
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
    await sources.close();
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
