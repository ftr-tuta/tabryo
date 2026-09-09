import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tabryo/core/preview_cache.dart';
import 'package:tabryo/features/editor/infrastructure/local_document_files.dart';
import 'package:tabryo/features/editor/presentation/editor_view_model.dart';
import 'package:tabryo/features/editor/presentation/editor_context_dialog.dart';
import 'package:tabryo/features/editor_context/application/editor_context_service.dart';
import 'package:tabryo/features/editor_context/domain/editor_context.dart';
import 'package:tabryo/features/editor_context/infrastructure/local_editor_context.dart';
import 'package:tabryo/features/projects/domain/project.dart';
import 'package:tabryo/features/projects/infrastructure/local_project_environment.dart';
import 'package:tabryo/features/projects/presentation/projects_view_model.dart';
import 'package:tabryo/features/tasks/domain/project_task.dart';
import 'package:tabryo/features/tasks/presentation/tasks_view_model.dart';
import 'package:tabryo/features/debugger/application/debug_service.dart';
import 'package:tabryo/features/debugger/domain/debug_session.dart';
import 'package:tabryo/features/workspaces/presentation/workbench_view_model.dart';

import 'editor_test.dart' show MemoryDocuments;
import 'tasks_test.dart' show MemoryTaskFiles;
import 'projects_test.dart' show installedProjectTools;
import 'debugger_test.dart' show MemoryAdapters;
import 'workbench_test.dart'
    show MemoryHost, MemoryLauncher, MemoryFiles, NoGit, MemoryPreferences;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'registered task requests are explicit, bounded and idempotent',
    () async {
      final path = p.absolute('main.dart');
      final project = DevelopmentProject(
        workspace: p.dirname(path),
        directory: p.dirname(path),
        name: 'project',
        kind: ProjectKind.dart,
      );
      final tools = ToolchainSelection({
        ProjectTool.dart: Platform.resolvedExecutable,
      });
      final documents = MemoryDocuments()..content[path] = 'void main() {}';
      final transport = MemoryContextTransport();
      final share = EditorContextService(transport);
      final editor = EditorViewModel(documents, contextSharing: share);
      addTearDown(editor.disposeAsync);
      editor.selectWorkspace(project.workspace);
      await editor.open(project.workspace, path);
      await editor.publishContext(
        await editor.prepareContext(wholeDocument: true),
        'Codex',
      );
      final listed = await transport.call!('tools/list', {});
      expect(jsonEncode(listed), isNot(contains('request_task_run')));
      await editor.revokeContext();
      editor.captureTaskCatalog = (_, _) async => EditorTaskCatalog(
        project,
        tools,
        const TaskConfiguration('reviewed', [
          SharedTask(name: 'Tests', kind: ProjectTaskKind.test),
          SharedTask(name: 'Analyze', kind: ProjectTaskKind.analyze),
        ]),
      );
      final snapshot = await editor.prepareContext(
        wholeDocument: true,
        includeTasks: true,
      );
      await editor.publishContext(snapshot, 'Codex');
      Future<Map<String, Object?>> request(
        String id, {
        String task = 'Tests',
        String? snapshotId,
        bool extra = false,
      }) => transport.call!('tools/call', {
        'name': 'request_task_run',
        'arguments': {
          'client_id': id,
          'snapshot_id': snapshotId ?? snapshot.id,
          'task': task,
          if (extra) 'arguments': ['--override'],
        },
      });
      expect((await request('first'))['isError'], isFalse);
      expect(share.taskRequests['first']!.status, 'pending');
      expect(share.taskRequests['first']!.task, isNull);
      expect((await request('first'))['isError'], isFalse);
      expect(share.taskRequests, hasLength(1));
      for (final invalid in [
        request('first', task: 'Analyze'),
        request('extra', extra: true),
        request('stale', snapshotId: 'old'),
        request('unknown', task: 'shell'),
        request('../bad'),
      ]) {
        expect((await invalid)['isError'], isTrue);
      }
      share.taskDecided(share.taskRequests['first']!, 'rejected');
      expect((await request('first'))['isError'], isFalse);
      expect(share.taskRequests['first']!.status, 'rejected');
      expect(
        () => share.taskDecided(share.taskRequests['first']!, 'reviewing'),
        throwsA(isA<EditorContextFailure>()),
      );
      for (var i = 0; i < 7; i++) {
        expect((await request('next$i'))['isError'], isFalse);
      }
      expect((await request('overflow'))['isError'], isTrue);
      final pending = share.taskRequests['next0']!;
      await editor.revokeContext();
      expect(share.ownsTaskRequest(pending), isFalse);
      expect(share.taskRequests, isEmpty);
    },
  );

  test('reviewed MCP task execution renews config, toolchain, saved-buffer and grant checks', () async {
    final directory = await Directory.systemTemp.createTemp('tabryo_context_');
    addTearDown(() => directory.delete(recursive: true));
    final root = await directory.resolveSymbolicLinks();
    final path = p.join(root, 'main.dart');
    await File(path).writeAsString('void main() {}');
    await File(p.join(root, 'pubspec.yaml'))
        .writeAsString('name: context_example\nenvironment:\n  sdk: ^3.13.0\n');
    final project = DevelopmentProject(
      workspace: root,
      directory: root,
      name: 'project',
      kind: ProjectKind.dart,
    );
    final tools = await installedProjectTools(root);
    final documents = MemoryDocuments()..content[path] = 'void main() {}';
    final transport = MemoryContextTransport();
    final share = EditorContextService(transport);
    final editor = EditorViewModel(documents, contextSharing: share);
    final taskFiles = MemoryTaskFiles()
      ..configuration = const TaskConfiguration('reviewed', [
        SharedTask(name: 'Run', kind: ProjectTaskKind.run, target: 'main.dart'),
      ]);
    final tasks = TasksViewModel(taskFiles, windows: Platform.isWindows);
    final projects = ProjectsViewModel(LocalProjectEnvironment());
    final host = MemoryHost();
    final git = NoGit();
    final workbench = WorkbenchViewModel(
      host: host,
      launcher: MemoryLauncher(),
      files: MemoryFiles(),
      gitReader: git,
      gitMutator: git,
      preferencesStore: MemoryPreferences(),
      editor: editor,
      projects: projects,
      tasks: tasks,
    );
    addTearDown(workbench.shutdown);
    await workbench.openWorkspace(root);
    projects.discovery = ProjectDiscovery([project]);
    projects.selections[project.id] = tools;
    await editor.open(root, path);
    var next = 0;
    Future<EditorTaskRequest> capture() async {
      final snapshot = await editor.prepareContext(
        wholeDocument: true,
        includeTasks: true,
      );
      await editor.publishContext(snapshot, 'Codex');
      final id = 'run${next++}';
      final result = await transport.call!('tools/call', {
        'name': 'request_task_run',
        'arguments': {
          'client_id': id,
          'snapshot_id': snapshot.id,
          'task': 'Run',
        },
      });
      expect(result['isError'], isFalse);
      final request = share.taskRequests[id]!;
      share.taskDecided(request, 'reviewing');
      return request;
    }

    final changed = await capture();
    taskFiles.configuration = const TaskConfiguration('modified', []);
    await expectLater(
      editor.prepareTaskRequest!(changed),
      throwsA(isA<ProjectFailure>()),
    );
    expect(host.specs, isEmpty);
    taskFiles.configuration = changed.snapshot.taskCatalog!.configuration;
    await editor.revokeContext();
    final request = await capture();
    final task = await editor.prepareTaskRequest!(request);
    editor.active!.controller.text = 'void main() { print(1); }';
    await expectLater(
      editor.runTaskRequest!(request, task),
      throwsA(isA<ProjectFailure>()),
    );
    editor.active!.controller.text = 'void main() {}';
    projects.selections[project.id] = ToolchainSelection({
      ProjectTool.dart: p.join(root, 'other-dart'),
    });
    await expectLater(
      editor.runTaskRequest!(request, task),
      throwsA(isA<ProjectFailure>()),
    );
    projects.selections[project.id] = tools;
    taskFiles.validation = Completer<void>();
    final running = editor.runTaskRequest!(request, task);
    final refused = expectLater(running, throwsA(isA<EditorContextFailure>()));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await editor.revokeContext();
    taskFiles.validation!.complete();
    await refused;
    await tasks.discard(task);
    expect(host.specs, isEmpty);
    final accepted = await capture();
    final reviewed = await editor.prepareTaskRequest!(accepted);
    await editor.runTaskRequest!(accepted, reviewed);
    expect(host.specs, hasLength(1));
    expect(accepted.status, 'running');
    final status = await transport.call!('tools/call', {
      'name': 'task_request_status',
      'arguments': {'client_id': accepted.id},
    });
    expect(jsonEncode(status), contains('running'));
    await expectLater(
      editor.runTaskRequest!(accepted, reviewed),
      throwsA(isA<ProjectFailure>()),
    );
    expect(host.specs, hasLength(1));
    await editor.revokeContext();
    expect(host.processes.single.closes, 0);
    await workbench.stopTask(reviewed);
    expect(reviewed.status, TaskStatus.cancelled);
  });

  test('project context is optional, bounded, immutable and scoped to the document project', () async {
    final root = p.absolute('context');
    final nested = p.join(root, 'nested');
    final path = p.join(nested, 'main.dart');
    final project = DevelopmentProject(
      workspace: root,
      directory: nested,
      name: 'nested',
      kind: ProjectKind.dart,
    );
    final parent = DevelopmentProject(
      workspace: root,
      directory: root,
      name: 'parent',
      kind: ProjectKind.dart,
    );
    final tools = ToolchainSelection({
      ProjectTool.dart: p.join(root, Platform.isWindows ? 'dart.exe' : 'dart'),
    });
    final files = MemoryDocuments()..content[path] = 'void main() {}';
    final transport = MemoryContextTransport();
    final share = EditorContextService(transport);
    final editor = EditorViewModel(files, contextSharing: share);
    final tasks = TasksViewModel(
      MemoryTaskFiles(),
      windows: Platform.isWindows,
    );
    final projects = ProjectsViewModel(
      LocalProjectEnvironment(environment: {}),
    );
    final debug = DebugService(MemoryAdapters());
    final git = NoGit();
    final workbench = WorkbenchViewModel(
      host: MemoryHost(),
      launcher: MemoryLauncher(),
      files: MemoryFiles(),
      gitReader: git,
      gitMutator: git,
      preferencesStore: MemoryPreferences(),
      editor: editor,
      projects: projects,
      tasks: tasks,
      debugger: debug,
    );
    addTearDown(workbench.shutdown);
    await workbench.openWorkspace(root);
    projects.discovery = ProjectDiscovery([parent, project]);
    await editor.open(root, path);
    final run = await tasks.prepare(project, tools, ProjectTaskKind.test);
    tasks.started(run, 1);
    final cases = [
      const TestCaseResult(name: 'works', outcome: TestOutcome.passed),
      TestCaseResult(
        name: 'fails',
        outcome: TestOutcome.failed,
        path: path,
        line: 1,
        details: '🌱' * 5000,
      ),
    ];
    run.results = TestResults(cases, complete: true, successful: false);
    run.status = TaskStatus.failed;
    run.exitCode = 1;
    for (var i = 0; i < 6; i++) {
      tasks.runs.add(
        ProjectTask(
            project: project,
            kind: ProjectTaskKind.test,
            command: run.command,
            tools: tools,
          )
          ..results = run.results
          ..status = TaskStatus.failed
          ..exitCode = 1,
      );
    }
    tasks.runs.add(
      ProjectTask(
          project: parent,
          kind: ProjectTaskKind.test,
          command: run.command,
          tools: tools,
        )
        ..results = const TestResults([
          TestCaseResult(name: 'PRIVATE_PARENT', outcome: TestOutcome.failed),
        ], complete: true)
        ..status = TaskStatus.failed,
    );
    debug.configuration = DebugConfiguration(
      project: project,
      tools: tools,
      program: path,
      environment: const {'SECRET': 'PRIVATE_ENVIRONMENT'},
    );
    debug.status = DebugStatus.running;
    debug.output = 'PRIVATE_CONSOLE';
    debug.vmService = Uri.parse('http://127.0.0.1:4321/PRIVATE_VM_CREDENTIAL/');
    expect(
      (await editor.prepareContext(wholeDocument: true)).toJson(),
      isNot(contains('project')),
    );
    final snapshot = await editor.prepareContext(
      wholeDocument: true,
      includeTests: true,
      includeSessions: true,
    );
    final context = snapshot.projectContext!;
    expect(context.root, nested);
    expect(context.tests, hasLength(5));
    expect(context.limited, isTrue);
    expect(context.tests.first.counts, {
      'passed': 1,
      'failed': 1,
      'skipped': 0,
      'incomplete': 0,
    });
    expect(context.tests.first.successful, isFalse);
    expect(context.sessions.single.status, 'running');
    final captured = jsonEncode(snapshot.toJson());
    expect(captured, isNot(contains('PRIVATE_')));
    cases.clear();
    debug.status = DebugStatus.terminated;
    run.status = TaskStatus.passed;
    expect(jsonEncode(snapshot.toJson()), captured);
    expect(() => context.tests.clear(), throwsUnsupportedError);
    expect(() => context.tests.first.counts.clear(), throwsUnsupportedError);
    await editor.publishContext(snapshot, 'Codex');
    final result = await transport.call!('tools/call', {
      'name': 'editor_context',
      'arguments': {},
    });
    expect(((result['content'] as List).single as Map)['text'], captured);
    expect(jsonEncode(snapshot.toJson()).contains('\uFFFD'), isFalse);
  });
  test('HTTP editor context authenticates an immutable excerpt and rejects stale replacements', () async {
    final directory = await Directory.systemTemp.createTemp(
      'tabryo_editor_context_',
    );
    final root = await directory.resolveSymbolicLinks();
    const original = 'private prefix\nação 🌱\nprivate suffix\n';
    final file = await File(p.join(root, 'main.dart')).writeAsString(original);
    final service = EditorContextService(LocalEditorContext());
    final editor = EditorViewModel(
      LocalDocumentFiles(PreviewCache()),
      contextSharing: service,
    );
    final client = NativeHttp().createHttpClient(null)
      ..findProxy = (_) => 'DIRECT';
    addTearDown(() async {
      client.close(force: true);
      await editor.disposeAsync();
      await directory.delete(recursive: true);
    });
    editor.selectWorkspace(root);
    await editor.open(root, file.path);
    final buffer = editor.active!;
    buffer.controller.selection = const TextSelection(
      baseOffset: 15,
      extentOffset: 22,
    );
    final stale = await editor.prepareContext(wholeDocument: false);
    buffer.controller.text += '// newer\n';
    await expectLater(
      editor.publishContext(stale, 'Codex'),
      throwsA(isA<EditorContextFailure>()),
    );
    expect(service.connection, isNull);
    buffer.controller.text = original;
    buffer.controller.selection = const TextSelection(
      baseOffset: 15,
      extentOffset: 22,
    );
    final snapshot = await editor.prepareContext(wholeDocument: false);
    expect(snapshot.text, 'ação 🌱');
    await editor.publishContext(snapshot, 'Codex');
    final connection = service.connection!;
    final initialized = await rpc(client, connection, 'initialize', {
      'protocolVersion': '2025-11-25',
    });
    expect(initialized['result']['protocolVersion'], '2025-11-25');
    final read = await rpc(client, connection, 'resources/read', {
      'uri': 'tabryo://editor/context',
    });
    final context = jsonDecode(read['result']['contents'][0]['text'] as String);
    expect(context['text'], 'ação 🌱');
    expect(jsonEncode(context), isNot(contains('private prefix')));
    expect(
      (await rpc(client, connection, 'resources/read', {
        'uri': 'file:///private',
      }))['error'],
      isNotNull,
    );
    for (final headers in [
      {'Authorization': 'Bearer wrong'},
      {'Origin': 'https://example.invalid'},
      {'Host': 'example.invalid'},
    ]) {
      final result = await rpc(client, connection, 'ping', {}, headers);
      expect(
        result['httpStatus'],
        headers.containsKey('Authorization') ? 401 : 403,
      );
    }
    final arguments = {
      'client_id': 'edit-1',
      'snapshot_id': snapshot.id,
      'text': 'nova ação',
    };
    final proposed = await rpc(client, connection, 'tools/call', {
      'name': 'propose_replacement',
      'arguments': arguments,
    });
    expect(proposed['result']['isError'], isFalse);
    await rpc(client, connection, 'tools/call', {
      'name': 'propose_replacement',
      'arguments': arguments,
    });
    expect(service.proposals, hasLength(1));
    expect(buffer.controller.text, original);
    expect(await file.readAsString(), original);
    final duplicate = await rpc(client, connection, 'tools/call', {
      'name': 'propose_replacement',
      'arguments': {...arguments, 'text': 'conflicting'},
    });
    expect(duplicate['result']['isError'], isTrue);
    buffer.controller.text += 'later typing';
    final frozen = await rpc(client, connection, 'tools/call', {
      'name': 'editor_context',
    });
    expect(
      jsonDecode(frozen['result']['content'][0]['text'] as String)['text'],
      snapshot.text,
    );
    await expectLater(
      editor.applyContextProposal(service.proposals['edit-1']!),
      throwsA(isA<EditorContextFailure>()),
    );
    expect(buffer.controller.text, endsWith('later typing'));
    editor.selectWorkspace(p.join(root, 'another'));
    expect(service.snapshot, isNull);
    expect(service.proposals, isEmpty);
    await editor.revokeContext();
    await expectLater(
      rpc(client, connection, 'ping'),
      throwsA(isA<IOException>()),
    );
  });

  test('review applies only the shared range, preserves disk, and rechecks revocation during reads', () async {
    final files = MemoryDocuments();
    final transport = MemoryContextTransport();
    final service = EditorContextService(transport);
    final editor = EditorViewModel(files, contextSharing: service);
    addTearDown(editor.disposeAsync);
    final root = p.absolute('context');
    final path = p.join(root, 'main.dart');
    files.content[path] = 'before old after';
    editor.selectWorkspace(root);
    await editor.open(root, path);
    editor.active!.controller.selection = const TextSelection(
      baseOffset: 7,
      extentOffset: 10,
    );
    final snapshot = await editor.prepareContext(wholeDocument: false);
    await editor.publishContext(snapshot, 'Codex');
    await transport.call!('tools/call', {
      'name': 'propose_replacement',
      'arguments': {
        'client_id': 'one',
        'snapshot_id': snapshot.id,
        'text': 'new',
      },
    });
    final proposal = service.proposals['one']!;
    await editor.applyContextProposal(proposal);
    expect(editor.active!.controller.text, 'before new after');
    expect(files.content[path], 'before old after');
    expect(files.writes, 0);
    expect(proposal.status, 'applied');
    await editor.revokeContext();
    final next = await editor.prepareContext(wholeDocument: true);
    await editor.publishContext(next, 'Codex');
    await transport.call!('tools/call', {
      'name': 'propose_replacement',
      'arguments': {'client_id': 'two', 'snapshot_id': next.id, 'text': 'bad'},
    });
    files.reading = Completer<void>();
    final applying = editor.applyContextProposal(service.proposals['two']!);
    final rejected = expectLater(
      applying,
      throwsA(isA<EditorContextFailure>()),
    );
    await Future<void>.delayed(Duration.zero);
    await editor.revokeContext();
    files.reading!.complete();
    await rejected;
    expect(editor.active!.controller.text, 'before new after');
    expect(files.writes, 0);
    await expectLater(
      transport.call!('ping', {}),
      throwsA(isA<EditorContextFailure>()),
    );
  });

  test('revoking pending startup drains the endpoint and prevents exposure after disposal', () async {
    final transport = MemoryContextTransport()..opening = Completer();
    final service = EditorContextService(transport);
    final snapshot = EditorContextSnapshot(
      id: 'pending',
      workspace: '/fixture',
      path: '/fixture/main.dart',
      version: 1,
      start: 0,
      end: 4,
      text: 'text',
      dirty: true,
      capturedAt: DateTime.now(),
    );
    final publishing = service.publish(snapshot, 'Codex');
    final revoking = service.revoke();
    expect(service.connection, isNull);
    await expectLater(
      transport.call!('ping', {}),
      throwsA(isA<EditorContextFailure>()),
    );
    final connection = MemoryContextConnection();
    transport.opening!.complete(connection);
    await Future.wait([publishing, revoking]);
    expect(connection.closed, isTrue);
    expect(service.snapshot, isNull);
    final disposal = service.dispose();
    await expectLater(
      service.publish(snapshot, 'Codex'),
      throwsA(isA<EditorContextFailure>()),
    );
    await disposal;
  });

  testWidgets('MCP task review cancellation and rejection execute nothing', (
    tester,
  ) async {
    final root = p.absolute('context_ui');
    final path = p.join(root, 'main.dart');
    final project = DevelopmentProject(
      workspace: root,
      directory: root,
      name: 'project',
      kind: ProjectKind.dart,
    );
    final tools = ToolchainSelection({
      ProjectTool.dart: Platform.resolvedExecutable,
    });
    final files = MemoryDocuments()..content[path] = 'original';
    final transport = MemoryContextTransport();
    final service = EditorContextService(transport);
    final editor = EditorViewModel(files, contextSharing: service);
    final taskFiles = MemoryTaskFiles()
      ..configuration = const TaskConfiguration('reviewed', [
        SharedTask(name: 'Tests', kind: ProjectTaskKind.test),
      ]);
    final tasks = TasksViewModel(taskFiles, windows: Platform.isWindows);
    editor.captureTaskCatalog = (_, _) async =>
        EditorTaskCatalog(project, tools, taskFiles.configuration);
    editor.prepareTaskRequest = (request) async =>
        request.task = await tasks.prepare(
          project,
          tools,
          ProjectTaskKind.test,
          configuration: taskFiles.configuration,
        );
    var runs = 0;
    editor.runTaskRequest = (request, task) async {
      runs++;
      tasks.started(task, 10);
      service.refreshTaskStatus();
    };
    editor.discardTaskRequest = tasks.discard;
    editor.selectWorkspace(root);
    await editor.open(root, path);
    final snapshot = await editor.prepareContext(
      wholeDocument: true,
      includeTasks: true,
    );
    await editor.publishContext(snapshot, 'Codex');
    Future<void> request(String id) async {
      await transport.call!('tools/call', {
        'name': 'request_task_run',
        'arguments': {
          'client_id': id,
          'snapshot_id': snapshot.id,
          'task': 'Tests',
        },
      });
      await tester.pumpAndSettle();
    }

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => EditorContextDialog(model: editor),
              ),
              child: const Text('Context'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Context'));
    await tester.pumpAndSettle();
    await request('cancel');
    await tester.ensureVisible(find.text('Review task request'));
    await tester.tap(find.text('Review task request'));
    await tester.pumpAndSettle();
    expect(find.text('Review project task'), findsOneWidget);
    expect(runs, 0);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(taskFiles.discarded, 1);
    expect(service.taskRequests['cancel']!.task, isNull);
    expect(service.taskRequests['cancel']!.status, 'pending');
    await tester.ensureVisible(find.text('Reject task request'));
    await tester.tap(find.text('Reject task request'));
    await tester.pumpAndSettle();
    expect(service.taskRequests['cancel']!.status, 'rejected');
    expect(runs, 0);
    await request('approve');
    await tester.ensureVisible(find.text('Review task request'));
    await tester.tap(find.text('Review task request'));
    await tester.pumpAndSettle();
    expect(runs, 0);
    await tester.tap(find.text('Run reviewed task'));
    await tester.pumpAndSettle();
    expect(runs, 1);
    expect(service.taskRequests['approve']!.status, 'running');
    expect(find.text('Review task request'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      await editor.disposeAsync();
      await tasks.disposeAsync();
    });
  });

  testWidgets('context sharing and replacements require native review', (
    tester,
  ) async {
    final files = MemoryDocuments();
    final transport = MemoryContextTransport();
    final service = EditorContextService(transport);
    final editor = EditorViewModel(files, contextSharing: service);
    final root = p.absolute('context_ui');
    final path = p.join(root, 'main.dart');
    files.content[path] = 'original';
    editor.selectWorkspace(root);
    await editor.open(root, path);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => EditorContextDialog(model: editor),
              ),
              child: const Text('Context'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Context'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Share the whole document'));
    await tester.tap(find.text('Review editor context'));
    await tester.pumpAndSettle();
    expect(transport.starts, 0);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(transport.starts, 0);
    await tester.tap(find.text('Review editor context'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Publish reviewed context'));
    await tester.pumpAndSettle();
    expect(transport.starts, 1);
    await transport.call!('tools/call', {
      'name': 'propose_replacement',
      'arguments': {
        'client_id': 'review',
        'snapshot_id': service.snapshot!.id,
        'text': 'reviewed',
      },
    });
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Review replacement'));
    await tester.tap(find.text('Review replacement'));
    await tester.pumpAndSettle();
    expect(editor.active!.controller.text, 'original');
    await tester.tap(find.text('Apply unsaved replacement'));
    await tester.pumpAndSettle();
    expect(editor.active!.controller.text, 'reviewed');
    expect(files.writes, 0);
    await tester.ensureVisible(find.text('Revoke editor context'));
    await tester.tap(find.text('Revoke editor context'));
    await tester.pumpAndSettle();
    expect(service.connection, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(editor.disposeAsync);
  });
}

final class NativeHttp extends HttpOverrides {}

Future<Map<String, dynamic>> rpc(
  HttpClient client,
  EditorContextConnection connection,
  String method, [
  Map<String, Object?> params = const {},
  Map<String, String> headers = const {},
]) async {
  final request = await client.postUrl(connection.endpoint);
  request.headers.contentType = ContentType.json;
  request.headers.set('Authorization', 'Bearer ${connection.token}');
  request.headers.set('Accept', 'application/json, text/event-stream');
  headers.forEach(request.headers.set);
  request.write(
    jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params}),
  );
  final response = await request.close();
  final text = await response.transform(utf8.decoder).join();
  if (response.statusCode != 200) return {'httpStatus': response.statusCode};
  return jsonDecode(text) as Map<String, dynamic>;
}

final class MemoryContextTransport implements EditorContextTransport {
  int starts = 0;
  Completer<EditorContextConnection>? opening;
  Future<Map<String, Object?>> Function(String, Map<String, Object?>)? call;
  @override
  Future<EditorContextConnection> start(
    Future<Map<String, Object?>> Function(String, Map<String, Object?>) call,
  ) async {
    starts++;
    this.call = call;
    return opening == null ? MemoryContextConnection() : await opening!.future;
  }
}

final class MemoryContextConnection implements EditorContextConnection {
  bool closed = false;
  @override
  Uri get endpoint => Uri.parse('http://127.0.0.1:1234/mcp');
  @override
  String get token => 'test-only';
  @override
  Future<void> close() async {
    closed = true;
  }
}
