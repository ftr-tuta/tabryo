import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tabryo/core/cancellation.dart';
import 'package:tabryo/core/preview_cache.dart';
import 'package:tabryo/features/git/domain/git_ports.dart';
import 'package:tabryo/features/git/infrastructure/local_git.dart';
import 'package:tabryo/features/git/presentation/git_review_panel.dart';
import 'package:tabryo/features/git/presentation/git_review_view_model.dart';
import 'package:tabryo/features/terminals/infrastructure/native_terminal.dart';

void main() {
  late Directory temporary;
  late Directory checkout;
  late Map<String, String> environment;
  late LocalGit git;
  final executable = findExecutable(['git.exe', 'git'])!;

  Future<ProcessResult> fixtureGit(
    List<String> args, {
    String? directory,
  }) async {
    final result = await Process.run(
      executable,
      args,
      workingDirectory: directory ?? checkout.path,
      environment: environment,
    );
    expect(result.exitCode, 0, reason: '${result.stderr}');
    return result;
  }

  Future<ProcessResult> execute(GitCommand command) async {
    try {
      return await Process.run(
        command.spec.executable,
        command.spec.arguments,
        workingDirectory: command.spec.workingDirectory,
        environment: command.spec.environment,
      );
    } finally {
      await command.finish();
    }
  }

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('tabryo-git-');
    checkout = await Directory(p.join(temporary.path, 'project ação')).create();
    final config = await File(p.join(temporary.path, 'gitconfig'))
        .writeAsString('');
    environment = {
      'GIT_CONFIG_NOSYSTEM': '1',
      'GIT_CONFIG_GLOBAL': config.path,
      'GIT_AUTHOR_NAME': 'Test Author',
      'GIT_AUTHOR_EMAIL': 'author@example.invalid',
      'GIT_COMMITTER_NAME': 'Test Author',
      'GIT_COMMITTER_EMAIL': 'author@example.invalid',
    };
    git = LocalGit(
      executable: executable,
      cache: PreviewCache(),
      environment: environment,
    );
    await fixtureGit(['init', '-b', 'main']);
    await fixtureGit(['config', 'user.name', 'Test Author']);
    await fixtureGit(['config', 'user.email', 'author@example.invalid']);
  });
  tearDown(() async {
    await temporary.delete(recursive: true);
  });

  testWidgets('Git history and details remain reachable in a small panel', (
    tester,
  ) async {
    final model = GitReviewViewModel(git, git, git)
      ..panelPage = 'History'
      ..query = const GitHistoryQuery(reference: 'refs/heads/removed')
      ..commit = const GitCommit(
        '123456789abcdef',
        'Test Author',
        '2026-09-09',
        'A merge with details',
        parents: ['abcdef123456789', '987654321abcdef'],
      )
      ..comparison = const GitComparison(
        target: '123456789abcdef',
        base: 'abcdef123456789',
        files: [
          GitFileChange('lib/main.dart', 'M', additions: 2, deletions: 1),
        ],
      );
    addTearDown(model.disposeAsync);
    String? root;
    Widget panel() => MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 320,
            height: 330,
            child: GitReviewPanel(
              model: model,
              root: root,
              commit: () {},
              fetch: () {},
              push: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpWidget(panel());
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('History filters'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Apply filters'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('A merge with details'));
    await tester.tap(find.text('A merge with details'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('lib/main.dart'));
    // Loading another workspace resets the form's old reference and filters.
    root = checkout.path;
    model.query = const GitHistoryQuery();
    await tester.pumpWidget(panel());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Compare').first);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Compare references'));
    await tester.pumpWidget(const SizedBox());
  });

  test(
    'structured review separates index and disk and detects stale contents',
    () async {
      final repo = await git.repository(checkout.path);
      final file = File(p.join(checkout.path, 'mixed.txt'));
      await file.writeAsString('base\n');
      await fixtureGit(['add', '.']);
      await fixtureGit(['commit', '-m', 'base']);
      await file.writeAsString('index\n');
      await fixtureGit(['add', '.']);
      await file.writeAsString('working\n');
      final change = (await git.status(repo)).single;
      final staged = await git.localDiff(repo, change, staged: true);
      final unstaged = await git.localDiff(repo, change, staged: false);
      expect(staged.original.text, 'base\n');
      expect(staged.modified.text, 'index\n');
      expect(unstaged.original.text, 'index\n');
      expect(unstaged.modified.text, 'working\n');
      await file.writeAsString('changed again\n');
      expect(
        (await git.localDiff(repo, change, staged: false)).identity,
        isNot(unstaged.identity),
      );
      expect(
        (await git.localDiff(repo, change, staged: true)).identity,
        staged.identity,
      );
    },
  );

  test(
    'revision review handles roots, renames, removals, binary and large files',
    () async {
      final repo = await git.repository(checkout.path);
      await File(p.join(checkout.path, 'old name.txt'))
          .writeAsString('hello\n');
      await File(p.join(checkout.path, 'binary.dat')).writeAsBytes([0, 1, 2]);
      await File(p.join(checkout.path, 'large.txt'))
          .writeAsString('x' * 600000);
      await fixtureGit(['add', '.']);
      await fixtureGit(['commit', '-m', 'root']);
      final root = await git.compare(repo, 'HEAD');
      expect(root.base, isNull);
      expect(root.files.length, 3);
      final initial = await git.revisionDiff(
        repo,
        root,
        root.files.singleWhere((f) => f.path == 'old name.txt'),
      );
      expect(initial.original.kind, GitContentKind.missing);
      expect(initial.modified.text, 'hello\n');
      expect(
        (await git.revisionDiff(
          repo,
          root,
          root.files.singleWhere((f) => f.path == 'binary.dat'),
        )).modified.kind,
        GitContentKind.binary,
      );
      expect(
        (await git.revisionDiff(
          repo,
          root,
          root.files.singleWhere((f) => f.path == 'large.txt'),
        )).modified.kind,
        GitContentKind.large,
      );
      await fixtureGit(['mv', 'old name.txt', 'new name.txt']);
      await fixtureGit(['commit', '-m', 'rename']);
      final renamed = await git.compare(repo, 'HEAD');
      expect(renamed.files.single.originalPath, 'old name.txt');
      final diff = await git.revisionDiff(repo, renamed, renamed.files.single);
      expect(diff.original.text, diff.modified.text);
      await fixtureGit(['rm', 'new name.txt']);
      await fixtureGit(['commit', '-m', 'delete']);
      final deleted = await git.compare(repo, 'HEAD');
      expect(
        (await git.revisionDiff(
          repo,
          deleted,
          deleted.files.single,
        )).modified.kind,
        GitContentKind.missing,
      );
      expect(
        (await git.revisionDiff(
          repo,
          renamed,
          renamed.files.single,
        )).modified.text,
        'hello\n',
      );
    },
  );

  test(
    'history pins pages while references move and exposes both merge parents',
    () async {
      final repo = await git.repository(checkout.path);
      await fixtureGit(['commit', '--allow-empty', '-m', 'root']);
      await fixtureGit(['checkout', '-b', 'topic']);
      await File(p.join(checkout.path, 'topic.txt')).writeAsString('topic');
      await fixtureGit(['add', '.']);
      await fixtureGit(['commit', '-m', 'topic']);
      await fixtureGit(['checkout', 'main']);
      await File(p.join(checkout.path, 'main.txt')).writeAsString('main');
      await fixtureGit(['add', '.']);
      await fixtureGit(['commit', '-m', 'main']);
      await fixtureGit(['merge', '--no-ff', 'topic', '-m', 'merge']);
      final merged = await git.historyPage(repo, const GitHistoryQuery());
      expect(merged.commits.first.parents, hasLength(2));
      expect(
        (await git.compare(repo, 'HEAD', parent: 0)).files.single.path,
        'topic.txt',
      );
      expect(
        (await git.compare(repo, 'HEAD', parent: 1)).files.single.path,
        'main.txt',
      );
      // Real commit objects, without external fixtures or synthetic runners.
      for (var i = 0; i < 99; i++) {
        await fixtureGit(['commit', '--allow-empty', '-m', 'change $i']);
      }
      final page = await git.historyPage(repo, const GitHistoryQuery());
      expect(page.commits, hasLength(100));
      expect(page.nextOffset, 100);
      await fixtureGit(['commit', '--allow-empty', '-m', 'new head']);
      final next = await git.historyPage(
        repo,
        const GitHistoryQuery(),
        anchors: page.anchors,
        offset: page.nextOffset!,
      );
      final all = [...page.commits, ...next.commits];
      expect(all.map((c) => c.hash).toSet(), hasLength(103));
      expect(all.any((c) => c.subject == 'new head'), isFalse);
      expect(next.nextOffset, isNull);
      expect(
        (await git.historyPage(
          repo,
          const GitHistoryQuery(message: 'topic'),
        )).commits.single.subject,
        'topic',
      );
    },
  );

  test('selected repository ignores inherited repository overrides', () async {
    final isolated = LocalGit(
      executable: executable,
      cache: PreviewCache(),
      environment: {
        ...environment,
        'GIT_DIR': p.join(temporary.path, 'missing.git'),
        if (Platform.isWindows) 'git_work_tree': temporary.path,
      },
    );
    final repo = await isolated.repository(checkout.path);
    await File(p.join(checkout.path, 'selected.txt')).writeAsString('selected');
    expect((await isolated.status(repo)).single.path, 'selected.txt');
  });

  test(
    'unborn repository, literal stage and unstage preserve every working file',
    () async {
      final repo = await git.repository(checkout.path);
      expect(await git.history(repo), isEmpty);
      const literal = '[a] ação & file.txt';
      await File(p.join(checkout.path, literal)).writeAsString('first\n');
      await File(p.join(checkout.path, 'a ação & file.txt'))
          .writeAsString('other\n');
      expect((await git.status(repo)).length, 2);
      await git.stage(repo, literal);
      var state = await git.status(repo);
      expect(state.singleWhere((c) => c.path == literal).staged, isTrue);
      expect(
        state.singleWhere((c) => c.path == 'a ação & file.txt').untracked,
        isTrue,
      );
      expect(
        await git.diff(
          repo,
          state.singleWhere((c) => c.path == literal),
          staged: true,
        ),
        contains('+first'),
      );
      await git.unstage(repo, literal);
      state = await git.status(repo);
      expect(state.every((c) => c.untracked), isTrue);
      expect(
        await File(p.join(checkout.path, literal)).readAsString(),
        'first\n',
      );
    },
  );

  test('commit and push to disposable remote preserve the exact message and identity', () async {
    final repo = await git.repository(checkout.path);
    await File(p.join(checkout.path, 'readme.txt')).writeAsString('hello\n');
    await git.stage(repo, 'readme.txt');
    const message = 'First commit\n\nLiteral \$HOME `echo bad` & unicode ação';
    final result = await execute(await git.commit(repo, message));
    expect(result.exitCode, 0, reason: '${result.stderr}');
    final history = await git.history(repo);
    expect(history.single.subject, 'First commit');
    expect(history.single.author, 'Test Author');
    expect(
      await git.commitDetails(repo, history.single.hash),
      contains('Literal \$HOME `echo bad` & unicode ação'),
    );
    final bare = p.join(temporary.path, 'remote.git');
    await fixtureGit(['init', '--bare', bare]);
    await fixtureGit(['remote', 'add', 'origin', bare]);
    await fixtureGit(['config', 'push.default', 'current']);
    expect(
      (await execute(await git.remoteCommand(repo, 'push', 'origin'))).exitCode,
      0,
    );
    final remote = await fixtureGit([
      'rev-parse',
      'refs/heads/main',
    ], directory: bare);
    expect('${remote.stdout}'.trim(), history.single.hash);
  });

  test('read operations do not execute configured diff, textconv, or fsmonitor helpers', () async {
    final repo = await git.repository(checkout.path);
    await File(p.join(checkout.path, 'test.txt')).writeAsString('old\n');
    await git.stage(repo, 'test.txt');
    expect((await execute(await git.commit(repo, 'Initial'))).exitCode, 0);
    await File(p.join(checkout.path, 'test.txt')).writeAsString('new\n');
    final marker = p.join(temporary.path, 'helper-ran');
    final helper = File(p.join(temporary.path, 'external.sh'));
    await helper.writeAsString(
      '#!/bin/sh\nprintf bad > "${marker.replaceAll('\\', '/')}"\nexit 1\n',
    );
    if (!Platform.isWindows) {
      expect((await Process.run('chmod', ['700', helper.path])).exitCode, 0);
    }
    await fixtureGit(['config', 'diff.external', helper.path]);
    await fixtureGit(['config', 'core.fsmonitor', helper.path]);
    await fixtureGit(['config', 'diff.custom.textconv', helper.path]);
    await File(p.join(checkout.path, '.gitattributes'))
        .writeAsString('*.txt diff=custom\n');
    final state = await git.status(repo);
    expect(
      await git.diff(
        repo,
        state.singleWhere((c) => c.path == 'test.txt'),
        staged: false,
      ),
      contains('+new'),
    );
    expect(await markerFileExists(marker), isFalse);
  });

  test('worktree removal refuses main, sessions, dirty, untracked, and ignored data', () async {
    final repo = await git.repository(checkout.path);
    await File(p.join(checkout.path, '.gitignore'))
        .writeAsString('ignored.txt\n');
    await git.stage(repo, '.gitignore');
    expect((await execute(await git.commit(repo, 'Initial'))).exitCode, 0);
    final destination = p.join(temporary.path, 'linked');
    final created = await execute(
      await git.createWorktree(repo, 'feature', 'HEAD', destination),
    );
    expect(created.exitCode, 0, reason: '${created.stderr}');
    final trees = await git.worktrees(repo);
    expect(trees.length, 2);
    final linked = trees.singleWhere((t) => !t.main);
    expect(
      (await git.repository(destination)).commonDirectory,
      repo.commonDirectory,
    );
    await expectLater(
      git.removeWorktree(repo, trees.first, []),
      throwsA(isA<GitFailure>()),
    );
    await expectLater(
      git.removeWorktree(repo, linked, [destination]),
      throwsA(isA<GitFailure>()),
    );
    await fixtureGit(['worktree', 'lock', destination]);
    await expectLater(
      git.removeWorktree(repo, linked, []),
      throwsA(isA<GitFailure>()),
    );
    expect(await Directory(destination).exists(), isTrue);
    await fixtureGit(['worktree', 'unlock', destination]);
    for (final name in ['ignored.txt', 'untracked.txt', '.gitignore']) {
      final file = File(p.join(destination, name));
      final existed = await file.exists();
      final old = existed ? await file.readAsString() : null;
      await file.writeAsString('do not delete');
      await expectLater(
        git.removeWorktree(repo, linked, []),
        throwsA(isA<GitFailure>()),
      );
      expect(await file.readAsString(), 'do not delete');
      if (existed) {
        await file.writeAsString(old!);
      } else {
        await file.delete();
      }
    }
    await git.removeWorktree(repo, linked, []);
    expect(await Directory(destination).exists(), isFalse);
  });

  test(
    'commit hooks are preserved and a failed hook releases the write lease',
    () async {
      final repo = await git.repository(checkout.path);
      await File(p.join(checkout.path, 'file.txt')).writeAsString('value');
      await git.stage(repo, 'file.txt');
      final hook = File(p.join(repo.gitDirectory, 'hooks', 'pre-commit'));
      await hook.writeAsString(
        '#!/bin/sh\necho "Hook rejected commit" >&2\nexit 1\n',
      );
      if (!Platform.isWindows) {
        expect((await Process.run('chmod', ['700', hook.path])).exitCode, 0);
      }
      expect(
        (await execute(await git.commit(repo, 'Must fail'))).exitCode,
        isNot(0),
      );
      expect(await git.history(repo), isEmpty);
      expect((await git.status(repo)).single.staged, isTrue);
      await hook.delete();
      expect((await execute(await git.commit(repo, 'Allowed'))).exitCode, 0);
    },
  );

  test('cancelled reads do not publish a result', () async {
    final cancellation = Cancellation()..cancel();
    await expectLater(
      git.repository(checkout.path, cancellation: cancellation),
      throwsA(isA<Cancelled>()),
    );
  });

  test('porcelain parser preserves rename paths and conflicted status', () {
    final changes = LocalGit.parseStatus(
      '2 R. N... 100644 100644 100644 abc def R100 new name\x00old name\x00u UU N... 100644 100644 100644 100644 a b c conflict file\x00',
    );
    expect(changes.first.path, 'new name');
    expect(changes.first.originalPath, 'old name');
    expect(changes.last.conflicted, isTrue);
  });
}

Future<bool> markerFileExists(String path) => File(path).exists();
