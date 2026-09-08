import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tabryo/features/editor/domain/document_files.dart';
import 'package:tabryo/features/editor/presentation/editor_pane.dart';
import 'package:tabryo/features/editor/presentation/editor_view_model.dart';
import 'package:tabryo/features/git/domain/git_ports.dart';
import 'package:tabryo/features/preferences/domain/preferences.dart';
import 'package:tabryo/features/workspaces/presentation/workbench_view_model.dart';
import 'package:tabryo/main.dart';

import 'workbench_test.dart'
    show MemoryHost, MemoryLauncher, MemoryFiles, NoGit, MemoryPreferences;

final class MemoryDocuments implements DocumentFiles {
  final content = <String, String>{};
  Completer<void>? saving;
  Object? failure;
  int writes = 0;
  @override
  Future<DocumentSnapshot> open(String root, String path) async =>
      DocumentSnapshot(
        root: root,
        path: path,
        text: content[path] ?? 'original',
        revision: Object(),
      );
  @override
  Future<DocumentSnapshot> save(DocumentSnapshot baseline, String text) async {
    writes++;
    await saving?.future;
    if (failure != null) throw failure!;
    content[baseline.path] = text;
    return open(baseline.root, baseline.path);
  }
}

void main() {
  final root = Platform.isWindows ? r'C:\project' : '/project';
  late MemoryDocuments files;
  late EditorViewModel editor;
  setUp(() {
    files = MemoryDocuments();
    editor = EditorViewModel(files)..selectWorkspace(root);
  });

  test(
    'failed and overlapping saves preserve buffers and edits made while saving',
    () async {
      await editor.open(root, p.join(root, 'server.dart'));
      final buffer = editor.active!;
      buffer.controller.text = 'first edit';
      files.saving = Completer<void>();
      final saving = editor.save(buffer);
      expect(await editor.save(buffer), isFalse);
      expect(editor.close(buffer, discard: true), isFalse);
      buffer.controller.text = 'later edit';
      files.saving!.complete();
      expect(await saving, isFalse);
      expect(buffer.baseline.text, 'first edit');
      expect(buffer.controller.text, 'later edit');
      expect(buffer.dirty, isTrue);
      files.failure = const DocumentConflict();
      expect(await editor.save(buffer), isFalse);
      expect(buffer.controller.text, 'later edit');
      expect(buffer.error, contains('changed on disk'));
      expect(editor.closeWorkspace(root), isFalse);
      files.failure = null;
      expect(await editor.save(buffer), isTrue);
      expect(buffer.dirty, isFalse);
      await editor.disposeAsync();
    },
  );

  testWidgets(
    'tabs preserve undo across workspace and activity switches, and close can cancel',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final git = NoGit();
      final model = WorkbenchViewModel(
        host: MemoryHost(),
        launcher: MemoryLauncher(),
        files: MemoryFiles(),
        gitReader: git,
        gitMutator: git,
        preferencesStore: MemoryPreferences(),
        editor: editor,
      );
      await tester.pumpWidget(TabryoApp(createViewModel: () => model));
      await tester.pumpAndSettle();
      await model.openWorkspace(root);
      await model.openFile(p.join(root, 'server.dart'));
      await tester.pumpAndSettle();
      final first = editor.active!;
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'edited');
      await tester.pump(const Duration(seconds: 1));
      expect(first.dirty, isTrue);
      expect(first.undo.value.canUndo, isTrue);
      await tester.enterText(
        find.byType(TextField),
        'é' * (DocumentFiles.byteLimit ~/ 2 + 1),
      );
      await tester.pumpAndSettle();
      expect(first.controller.text, 'edited');
      expect(first.error, contains('was not applied'));
      await model.openFile(p.join(root, 'server.py'));
      await tester.pumpAndSettle();
      model.cycleTab(-1);
      expect(editor.active, first);
      model.showEditor(false);
      await tester.pumpAndSettle();
      await model.openWorkspace(p.join(root, 'other'));
      await tester.pumpAndSettle();
      await model.selectWorkspace(0);
      model.showEditor(true);
      editor.select(first);
      await tester.pumpAndSettle();
      expect(first.controller.text, 'edited');
      await tester.tap(find.byTooltip('Undo (Ctrl+Z)'));
      await tester.pumpAndSettle();
      expect(first.controller.text, 'original');
      await tester.tap(find.byTooltip('Redo (Ctrl+Y)'));
      await tester.pumpAndSettle();
      expect(first.controller.text, 'edited');
      await tester.tap(find.byTooltip('Close server.dart'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(editor.buffers, contains(first));
      await tester.tap(find.byType(TextField));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(files.content[first.path], 'edited');
      expect(first.dirty, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  test('restored workspaces select their editor and open documents protect worktrees', () async {
    final git = NoGit();
    final preferences = MemoryPreferences()
      ..value = Preferences(rememberWorkspaces: true, roots: [root]);
    editor.selectWorkspace(null);
    final model = WorkbenchViewModel(
      host: MemoryHost(),
      launcher: MemoryLauncher(),
      files: MemoryFiles(),
      gitReader: git,
      gitMutator: git,
      preferencesStore: preferences,
      editor: editor,
    );
    try {
      await model.initialize();
      expect(editor.workspace, root);
      await model.openFile(p.join(root, 'server.dart'));
      await model.removeWorktree(GitWorktree(root, 'feature'));
      expect(git.calls, 0);
      expect(model.message, contains('Close editor documents'));
      expect(editor.buffers.length, 1);
    } finally {
      await model.shutdown();
    }
  });

  testWidgets(
    'reload and unsaved close require explicit choices and failed save stays open',
    (tester) async {
      await editor.open(root, p.join(root, 'server.ts'));
      final buffer = editor.active!;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: EditorPane(model: editor)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'my edit');
      files.content[buffer.path] = 'external';
      files.failure = const DocumentConflict();
      await tester.tap(find.byTooltip('Close server.ts'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save changes'));
      await tester.pumpAndSettle();
      expect(editor.buffers, contains(buffer));
      expect(buffer.controller.text, 'my edit');
      await tester.tap(find.byTooltip('Document actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Compare with disk'));
      await tester.pumpAndSettle();
      expect(find.text('external'), findsOneWidget);
      expect(buffer.controller.text, 'my edit');
      await tester.tap(find.byTooltip('Document actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reload from disk'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(buffer.controller.text, 'my edit');
      await tester.tap(find.byTooltip('Document actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reload from disk'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Reload'));
      await tester.pumpAndSettle();
      expect(buffer.controller.text, 'external');
      expect(buffer.dirty, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      await editor.disposeAsync();
    },
  );
}
