import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tabryo/features/codex/infrastructure/local_codex_connection.dart';
import 'package:tabryo/features/mcp/application/mcp_hub.dart';
import 'package:tabryo/features/mcp_studio/application/mcp_studio.dart';
import 'package:tabryo/features/mcp_studio/domain/studio_project.dart';
import 'package:tabryo/features/mcp_studio/infrastructure/local_studio_storage.dart';
import 'package:tabryo/features/mcp_studio/presentation/mcp_studio_screen.dart';
import 'package:tabryo/features/mcp_studio/presentation/mcp_studio_view_model.dart';
import 'package:tabryo/features/terminals/domain/terminal_ports.dart';
import 'package:tabryo/core/preview_cache.dart';
import 'package:tabryo/features/editor/infrastructure/local_document_files.dart';
import 'package:tabryo/features/editor/presentation/editor_view_model.dart';
import 'package:tabryo/features/workspaces/presentation/workbench_view_model.dart';

import 'workbench_test.dart'
    show MemoryHost, MemoryLauncher, MemoryFiles, NoGit, MemoryPreferences;

Future<void> runCommand(LaunchSpec spec) async {
  final process = await Process.start(
    spec.executable,
    spec.arguments,
    workingDirectory: spec.workingDirectory,
  );
  final output = process.stdout.transform(utf8.decoder).join();
  final errors = process.stderr.transform(utf8.decoder).join();
  try {
    final code = await process.exitCode.timeout(const Duration(minutes: 4));
    final logs = '${await output}\n${await errors}';
    expect(code, 0, reason: '${spec.executable} ${spec.arguments}\n$logs');
  } finally {
    process.kill();
    await process.exitCode;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary;
  late String root;
  late McpStudio studio;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('tabryo-studio-');
    root = await temporary.resolveSymbolicLinks();
    studio = McpStudio(LocalStudioStorage());
  });
  tearDown(() async {
    expect(
      p.dirname(temporary.absolute.path),
      Directory.systemTemp.absolute.path,
    );
    for (var attempt = 0; attempt < 20; attempt++) {
      try {
        await temporary.delete(recursive: true);
        break;
      } on FileSystemException catch (error) {
        if (attempt == 19 || ![5, 32].contains(error.osError?.errorCode)) {
          rethrow;
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  test(
    'creation requires an immutable review and preserves existing folders',
    () async {
      final plan = await studio.prepare(
        root,
        'greeting',
        StudioLanguage.dart,
        '',
      );
      expect(await Directory(plan.path).exists(), isFalse);
      expect(
        () => plan.files['lib/server.dart'] = 'changed',
        throwsUnsupportedError,
      );
      final fabricated = StudioPlan(
        parent: plan.parent,
        path: plan.path,
        name: plan.name,
        language: plan.language,
        runtime: plan.runtime,
        files: plan.files,
      );
      await expectLater(
        studio.create(fabricated),
        throwsA(isA<StudioFailure>()),
      );
      await studio.create(plan);
      expect(
        await File(p.join(plan.path, 'lib/server.dart')).readAsString(),
        plan.files['lib/server.dart'],
      );
      final revised = await studio.prepare(
        root,
        'greeting',
        StudioLanguage.python,
        '',
      );
      await expectLater(studio.create(revised), throwsA(isA<StudioFailure>()));
      expect(
        await File(p.join(plan.path, 'lib/server.dart')).readAsString(),
        plan.files['lib/server.dart'],
      );
      expect(await File(p.join(plan.path, 'server.py')).exists(), isFalse);
      final empty = await Directory(p.join(root, 'empty')).create();
      final emptyPlan = await studio.prepare(
        root,
        'empty',
        StudioLanguage.dart,
        '',
      );
      await expectLater(
        studio.create(emptyPlan),
        throwsA(isA<StudioFailure>()),
      );
      expect(await empty.list().toList(), isEmpty);
    },
  );

  test('invalid names, unavailable runtimes and workspace link changes are refused', () async {
    for (final name in ['../escape', 'with space', 'con', 'a/b', 'ABC']) {
      await expectLater(
        studio.prepare(root, name, StudioLanguage.dart, ''),
        throwsA(isA<StudioFailure>()),
      );
    }
    final plan = await studio.prepare(
      root,
      'server',
      StudioLanguage.python,
      '',
    );
    await studio.create(plan);
    await expectLater(
      studio.prepareCommand(plan, 0),
      throwsA(isA<StudioFailure>()),
    );
    final outside = await Directory(p.join(root, 'outside')).create();
    final inner = await Directory(p.join(root, 'inner')).create();
    final moved = await studio.prepare(
      inner.path,
      'server',
      StudioLanguage.dart,
      '',
    );
    await inner.rename(p.join(root, 'old_inner'));
    await Link(inner.path).create(outside.path);
    await expectLater(studio.create(moved), throwsA(isA<StudioFailure>()));
    expect(await outside.list().toList(), isEmpty);
  });

  testWidgets(
    'the Studio creates only after reviewing, with no command launched',
    (tester) async {
      tester.view.physicalSize = const Size(700, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final model = McpStudioViewModel(studio)..selectWorkspace(root);
      var launches = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: McpStudioScreen(
            model: model,
            onOpen: (_) async {},
            onRegister: (_) async {},
            onRun: (_, _, _) async {
              launches++;
            },
          ),
        ),
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Project name'),
        'greeting',
      );
      await tester.runAsync(() async {
        await tester.tap(find.text('Review project'));
        while (model.busy) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();
      expect(model.preview, isNotNull);
      expect(Directory(p.join(root, 'greeting')).existsSync(), isFalse);
      await tester.scrollUntilVisible(
        find.text('Create reviewed project'),
        150,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('studio-content')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text('Create reviewed project'));
        while (model.busy) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();
      expect(model.selected, isNotNull);
      expect(launches, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await model.disposeAsync();
    },
  );

  test(
    'Studio serializes commands per project and refuses unsaved source',
    () async {
      final plan = await studio.prepare(
        root,
        'greeting',
        StudioLanguage.dart,
        '',
      );
      await studio.create(plan);
      final editor = EditorViewModel(LocalDocumentFiles(PreviewCache()));
      final host = MemoryHost();
      final git = NoGit();
      final model = WorkbenchViewModel(
        host: host,
        launcher: MemoryLauncher(),
        files: MemoryFiles(),
        gitReader: git,
        gitMutator: git,
        preferencesStore: MemoryPreferences(),
        editor: editor,
        studio: McpStudioViewModel(studio),
      );
      try {
        await model.openWorkspace(plan.path);
        await model.openFile(p.join(plan.path, 'lib', 'server.dart'));
        editor.active!.controller.text += '\n// edited\n';
        final command = MemoryLauncher().shell(plan.path);
        await expectLater(
          model.runStudioCommand(plan, command, 'Test'),
          throwsA(isA<StudioFailure>()),
        );
        expect(host.specs, isEmpty);
        expect(await editor.save(editor.active!), isTrue);
        final first = model.runStudioCommand(plan, command, 'Test');
        await expectLater(
          model.runStudioCommand(plan, command, 'Test'),
          throwsA(isA<StudioFailure>()),
        );
        await first;
        expect(host.specs.length, 1);
        await model.closeSession(model.activeSession!.id);
        await model.runStudioCommand(plan, command, 'Test');
        expect(host.specs.length, 2);
      } finally {
        await model.shutdown();
      }
    },
  );

  for (final language in StudioLanguage.values) {
    final runtime =
        Platform.environment[switch (language) {
          StudioLanguage.dart => 'TABRYO_TEST_DART',
          StudioLanguage.python => 'TABRYO_TEST_PYTHON',
          StudioLanguage.typescript => 'TABRYO_TEST_NODE',
        }];
    test(
      'generated ${language.name} project passes native tests and works through Codex',
      () async {
        final plan = await studio.prepare(
          root,
          'greeting_${language.name}',
          language,
          runtime!,
        );
        await studio.create(plan);
        for (var index = 0; index < studio.commands(plan).length; index++) {
          await runCommand(await studio.prepareCommand(plan, index));
        }
        final configHome = await Directory(p.join(root, 'codex_user')).create();
        // This fixture exercises MCP, not Codex's asynchronous marketplace sync.
        // Disable unrelated plugin downloads, which can outlive the App Server.
        await File(p.join(configHome.path, 'config.toml')).writeAsString(
          '[features]\nplugins = false\nremote_plugin = false\napps = false\n',
        );
        final hub = McpHub(
          LocalCodexConnection(
            executable: Platform.environment['TABRYO_TEST_CODEX'],
            environment: {'CODEX_HOME': configHome.path, 'RUST_LOG': 'off'},
          ),
        );
        try {
          await hub.connect(plan.path);
          final draft = await studio.registration(plan);
          await hub.apply(hub.configure(draft));
          final server = hub.servers.singleWhere(
            (server) => server.name == plan.name,
          );
          expect(server.tools, contains('greet'));
          expect(
            await hub.callTool(server, 'greet', {'name': 'Ada'}),
            contains('Hello, Ada!'),
          );
          expect(
            await hub.readResource(server, 'greeting://info'),
            contains('local greeting'),
          );
        } finally {
          await hub.close();
        }
      },
      skip: runtime == null || Platform.environment['TABRYO_TEST_CODEX'] == null
          ? 'Set TABRYO_TEST_CODEX and the language native runtime variable for generated-project integration.'
          : false,
      timeout: const Timeout(Duration(minutes: 8)),
    );
  }
}
