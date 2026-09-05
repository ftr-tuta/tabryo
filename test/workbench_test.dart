import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabryo/core/cancellation.dart';
import 'package:tabryo/features/files/domain/workspace_files.dart';
import 'package:tabryo/features/git/domain/git_ports.dart';
import 'package:tabryo/features/preferences/domain/preferences.dart';
import 'package:tabryo/features/terminals/domain/terminal_ports.dart';
import 'package:tabryo/features/terminals/presentation/terminal_session.dart';
import 'package:tabryo/features/workspaces/domain/workspace.dart';
import 'package:tabryo/features/workspaces/presentation/workbench_view_model.dart';
import 'package:tabryo/main.dart';

final class MemoryPreferences implements PreferencesStore {
  Preferences value = const Preferences();
  int writes = 0;
  @override
  Future<PreferencesLoad> load() async => PreferencesLoad(value);
  @override
  Future<void> save(Preferences preferences) async {
    value = Preferences.fromJson(preferences.toJson());
    writes++;
  }
}

final class MemoryFiles implements WorkspaceFiles {
  int reads = 0, watchers = 0, cancellations = 0;
  @override
  Future<String> authorizeRoot(String path) async => path;
  @override
  Future<FilePage> list(
    String root,
    String directory, {
    int offset = 0,
    Cancellation? cancellation,
  }) async {
    reads++;
    return const FilePage([], false);
  }

  @override
  Future<FilePreview> preview(
    String root,
    String path, {
    Cancellation? cancellation,
  }) async => FilePreview(path, 'text');
  @override
  Stream<void> watch(String root) {
    watchers++;
    return StreamController<void>(
      onCancel: () {
        cancellations++;
      },
    ).stream;
  }
}

final class NoGit implements GitReader, GitMutator {
  int calls = 0;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls++;
    throw StateError('Unexpected Git call: ${invocation.memberName}');
  }
}

final class MemoryProcess implements PtyProcess {
  final controller = StreamController<Uint8List>();
  final exit = Completer<int>();
  final input = <int>[];
  int closes = 0;
  bool ended = false;
  @override
  int get pid => 42;
  @override
  Stream<Uint8List> get output => controller.stream;
  @override
  Future<int> get exitCode => exit.future;
  @override
  Future<void> get drained => controller.done;
  @override
  bool write(Uint8List bytes) {
    input.addAll(bytes);
    return !ended;
  }

  @override
  void resize(int rows, int columns) {}
  void emit(String text) =>
      controller.add(Uint8List.fromList(utf8.encode(text)));
  @override
  Future<void> close() async {
    if (ended) return;
    ended = true;
    closes++;
    if (!exit.isCompleted) exit.complete(0);
    await controller.close();
  }
}

final class MemoryHost implements PtyHost {
  final specs = <LaunchSpec>[];
  final processes = <MemoryProcess>[];
  @override
  PtyProcess start(LaunchSpec spec) {
    specs.add(spec);
    final process = MemoryProcess();
    processes.add(process);
    return process;
  }
}

final class MemoryLauncher implements CodexLauncher {
  @override
  LaunchSpec shell(String directory) =>
      LaunchSpec(executable: '/shell', workingDirectory: directory);
  @override
  LaunchSpec codex(String directory, {bool resume = false}) => LaunchSpec(
    executable: '/codex',
    workingDirectory: directory,
    arguments: resume ? ['resume'] : [],
  );
}

void main() {
  late MemoryHost host;
  late MemoryPreferences preferences;
  late MemoryFiles files;
  late NoGit git;
  late WorkbenchViewModel model;
  final root = Platform.isWindows ? r'C:\project' : '/project';
  WorkbenchViewModel create() => WorkbenchViewModel(
    host: host,
    launcher: MemoryLauncher(),
    files: files,
    gitReader: git,
    gitMutator: git,
    preferencesStore: preferences,
  );
  setUp(() {
    host = MemoryHost();
    preferences = MemoryPreferences();
    files = MemoryFiles();
    git = NoGit();
    model = create();
  });
  tearDown(() async {
    if (model.sessions.isNotEmpty) await model.shutdown();
  });

  test('boot and restored splits never start commands, Git, watchers or filesystem scans', () async {
    await model.initialize();
    expect(host.specs, isEmpty);
    expect(git.calls, 0);
    expect(files.reads, 0);
    await model.openWorkspace(root);
    await model.openTerminal(codex: true, resume: true);
    await model.openTerminal(split: SplitDirection.horizontal);
    await model.openTerminal(split: SplitDirection.vertical);
    final paneShape = model.tab!.panes;
    expect(paneShape.sessions.length, 3);
    await model.updatePreferences(
      model.preferences.copyWith(restoreLayout: true),
    );
    await model.shutdown();
    host = MemoryHost();
    files = MemoryFiles();
    model = create();
    await model.initialize();
    expect(model.tab!.panes, isA<SplitPane>());
    expect(model.restoredSessions.length, 3);
    expect(model.sessions, isEmpty);
    expect(host.specs, isEmpty);
    expect(git.calls, 0);
    expect(files.reads, 0);
    expect(files.watchers, 0);
    await model.openTerminal(codex: true, resume: true);
    expect(host.specs.single.arguments, ['resume']);
    expect(model.tab!.panes.sessions.length, 3);
    expect(model.restoredSessions.length, 2);
    expect(model.sessions.length, 1);
  });

  test('hidden tabs drain final output and close independently; revocation stops watchers', () async {
    await model.openWorkspace(root);
    await model.openTerminal();
    final first = model.activeSession!;
    await model.openTerminal();
    host.processes.first.emit('hidden final output\r\n');
    await Future<void>.delayed(Duration.zero);
    expect(first.unseenOutput, isTrue);
    expect(
      [
        for (var i = 0; i < first.terminal.buffer.lines.length; i++)
          first.terminal.buffer.lines[i].getText(),
      ].join(),
      contains('hidden final output'),
    );
    await model.closeSession(first.id);
    expect(model.sessions.length, 1);
    expect(host.processes.first.closes, 1);
    expect(host.processes.last.closes, 0);
    await model.updatePreferences(model.preferences.copyWith(watchFiles: true));
    expect(files.watchers, 1);
    await model.updatePreferences(
      model.preferences.copyWith(watchFiles: false),
    );
    expect(files.cancellations, 1);
  });

  test(
    'exit marker follows the final output, and terminal dimensions are bounded',
    () async {
      final session = TerminalSession(
        id: 1,
        title: 'Shell',
        spec: MemoryLauncher().shell(root),
        host: host,
      );
      final process = host.processes.single;
      process.exit.complete(7);
      process.emit('LAST FRAME');
      await process.close();
      await session.finished;
      final text = [
        for (var i = 0; i < session.terminal.buffer.lines.length; i++)
          session.terminal.buffer.lines[i].getText(),
      ].join();
      expect(
        text.indexOf('LAST FRAME'),
        lessThan(text.indexOf('[Process exited: 7]')),
      );
      session.terminal.resize(10000, 10000);
      expect(session.terminal.viewWidth, BoundedTerminal.maxColumns);
      expect(session.terminal.viewHeight, BoundedTerminal.maxRows);
      session.dispose();
    },
  );

  testWidgets('toolbar and keyboard create and split only after gestures', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(TabryoApp(createViewModel: () => model));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(host.specs, isEmpty);
    await model.openWorkspace(root);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.widgetWithText(TextButton, 'Shell'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(host.specs.length, 1);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(model.tab!.panes.sessions.length, 2);
    expect(tester.takeException(), isNull);
    final closing = model.shutdown();
    await tester.pump();
    await closing;
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
