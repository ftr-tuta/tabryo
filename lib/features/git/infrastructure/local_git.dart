import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../../core/cancellation.dart';
import '../../../core/preview_cache.dart';
import '../../terminals/domain/terminal_ports.dart';
import '../domain/git_ports.dart';

final class GitFailure implements Exception {
  GitFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

final class _Result {
  _Result(this.code, this.output, this.error);
  final int code;
  final Uint8List output;
  final String error;
  String get text => utf8.decode(output);
}

final class LocalGit implements GitReader, GitMutator {
  LocalGit({
    required this.executable,
    required this.cache,
    this.environment = const {},
  });
  final String executable;
  final PreviewCache cache;
  final Map<String, String> environment;
  static final _reads = AsyncGate(2);
  static final _writes = <String, AsyncGate>{};
  static const _readPrefix = ['--no-pager', '-c', 'core.fsmonitor=false'];
  static const _readEnvironment = {
    'GIT_OPTIONAL_LOCKS': '0',
    'GIT_NO_LAZY_FETCH': '1',
    'GIT_LITERAL_PATHSPECS': '1',
    'GIT_TERMINAL_PROMPT': '0',
  };

  Map<String, String> _environment({required bool read}) =>
      {
        ...Platform.environment,
        // Ensure selection in the app, not inherited repository overrides,
        // determines the repository addressed by each command.
        'GIT_DIR': '', 'GIT_WORK_TREE': '', 'GIT_COMMON_DIR': '',
        ...environment,
        'GIT_LITERAL_PATHSPECS': '1',
        if (read) ..._readEnvironment,
      }..removeWhere(
        (key, value) => const [
          'GIT_DIR',
          'GIT_WORK_TREE',
          'GIT_COMMON_DIR',
          'GIT_INDEX_FILE',
          'GIT_OBJECT_DIRECTORY',
          'GIT_ALTERNATE_OBJECT_DIRECTORIES',
        ].contains(Platform.isWindows ? key.toUpperCase() : key),
      );

  Future<_Result> _run(
    String directory,
    List<String> args, {
    Cancellation? cancellation,
    bool read = true,
    bool allowFailure = false,
  }) async {
    final release = read ? await _reads.acquire() : () {};
    Process? process;
    Timer? timer;
    var limited = false;
    var timedOut = false;
    var completed = false;
    try {
      cancellation?.check();
      process = await Process.start(
        executable,
        [..._readPrefix, ...args],
        workingDirectory: directory,
        environment: _environment(read: read),
        includeParentEnvironment: false,
      );
      final running = process;
      cancellation?.whenCancelled.then((_) {
        if (!completed) running.kill();
      });
      timer = Timer(const Duration(seconds: 30), () {
        timedOut = true;
        running.kill();
      });
      final output = BytesBuilder(copy: false);
      final errors = BytesBuilder(copy: false);
      final stdoutDone = running.stdout.listen((chunk) {
        if (output.length + chunk.length > 2 * 1024 * 1024) {
          limited = true;
          running.kill();
        } else {
          output.add(chunk);
        }
      }).asFuture<void>();
      final stderrDone = running.stderr.listen((chunk) {
        if (errors.length + chunk.length <= 128 * 1024) {
          errors.add(chunk);
        } else {
          limited = true;
          running.kill();
        }
      }).asFuture<void>();
      final code = await running.exitCode;
      completed = true;
      await Future.wait([stdoutDone, stderrDone]);
      cancellation?.check();
      if (limited) {
        throw GitFailure(
          'Git output exceeded the preview limit. Narrow the selection.',
        );
      }
      if (timedOut) {
        throw GitFailure(
          'Git did not finish within 30 seconds. Use a terminal for this operation.',
        );
      }
      final result = _Result(
        code,
        output.takeBytes(),
        utf8.decode(errors.takeBytes(), allowMalformed: true),
      );
      if (code != 0 && !allowFailure) {
        throw GitFailure(
          result.error.trim().isEmpty
              ? 'Git failed (exit $code).'
              : result.error.trim(),
        );
      }
      return result;
    } finally {
      completed = true;
      timer?.cancel();
      release();
    }
  }

  String _line(String value) =>
      value.endsWith('\n') ? value.substring(0, value.length - 1) : value;
  Future<void Function()> _lock(GitRepository repo) => _writes
      .putIfAbsent(
        Platform.isWindows
            ? repo.commonDirectory.toLowerCase()
            : repo.commonDirectory,
        () => AsyncGate(1),
      )
      .acquire();
  void _literal(String value) {
    if (value.isEmpty || value.contains('\x00')) {
      throw ArgumentError('Empty or NUL-containing Git argument.');
    }
  }

  @override
  Future<GitRepository> repository(
    String directory, {
    Cancellation? cancellation,
  }) async {
    final root = _line(
      (await _run(directory, [
        'rev-parse',
        '--show-toplevel',
      ], cancellation: cancellation)).text,
    );
    final gitDirectory = _line(
      (await _run(root, [
        'rev-parse',
        '--absolute-git-dir',
      ], cancellation: cancellation)).text,
    );
    final commonDirectory = _line(
      (await _run(root, [
        'rev-parse',
        '--path-format=absolute',
        '--git-common-dir',
      ], cancellation: cancellation)).text,
    );
    return GitRepository(
      root: await Directory(root).resolveSymbolicLinks(),
      gitDirectory: await Directory(gitDirectory).resolveSymbolicLinks(),
      commonDirectory: await Directory(commonDirectory).resolveSymbolicLinks(),
    );
  }

  @override
  Future<List<GitChange>> status(
    GitRepository repo, {
    Cancellation? cancellation,
  }) async => parseStatus(
    (await _run(repo.root, [
      'status',
      '--porcelain=v2',
      '-z',
      '--untracked-files=all',
    ], cancellation: cancellation)).text,
  );

  static List<GitChange> parseStatus(String text) {
    final records = text.split('\x00');
    final result = <GitChange>[];
    for (var i = 0; i < records.length; i++) {
      final record = records[i];
      if (record.isEmpty || record.startsWith('#') || record.startsWith('!')) {
        continue;
      }
      if (record.startsWith('? ')) {
        result.add(
          GitChange(path: record.substring(2), index: '?', worktree: '?'),
        );
        continue;
      }
      final kind = record[0];
      final count = switch (kind) {
        '1' => 8,
        '2' => 9,
        'u' => 10,
        _ => throw GitFailure('Unsupported Git status record.'),
      };
      var position = 0;
      for (var field = 0; field < count; field++) {
        final next = record.indexOf(' ', position);
        if (next < 0) throw GitFailure('Incomplete Git status record.');
        position = next + 1;
      }
      result.add(
        GitChange(
          path: record.substring(position),
          index: record[2],
          worktree: record[3],
          originalPath: kind == '2' ? records[++i] : null,
          conflicted: kind == 'u',
        ),
      );
    }
    return result;
  }

  @override
  Future<String> diff(
    GitRepository repo,
    GitChange change, {
    required bool staged,
    Cancellation? cancellation,
  }) async {
    _literal(change.path);
    return (await _run(repo.root, [
      'diff',
      '--no-ext-diff',
      '--no-textconv',
      '--no-color',
      if (staged) '--cached',
      '--',
      change.path,
    ], cancellation: cancellation)).text;
  }

  @override
  Future<List<GitCommit>> history(
    GitRepository repo, {
    int page = 0,
    Cancellation? cancellation,
  }) async {
    final result = await _run(
      repo.root,
      [
        'log',
        '-z',
        '-n',
        '100',
        '--skip=${page * 100}',
        '--format=%H%x00%an%x00%aI%x00%s',
      ],
      cancellation: cancellation,
      allowFailure: true,
    );
    if (result.code != 0) {
      final head = await _run(
        repo.root,
        ['rev-parse', '--verify', 'HEAD'],
        allowFailure: true,
        cancellation: cancellation,
      );
      if (head.code != 0) return [];
      throw GitFailure(result.error);
    }
    final fields = result.text.split('\x00');
    final commits = <GitCommit>[];
    for (var i = 0; i + 3 < fields.length; i += 4) {
      commits.add(
        GitCommit(fields[i], fields[i + 1], fields[i + 2], fields[i + 3]),
      );
    }
    return commits;
  }

  @override
  Future<String> commitDetails(
    GitRepository repo,
    String hash, {
    Cancellation? cancellation,
  }) async {
    if (!RegExp(r'^[a-f0-9]{40,64}$').hasMatch(hash)) {
      throw ArgumentError('Invalid commit ID.');
    }
    final key = '${repo.commonDirectory}:commit:$hash';
    final cached = cache.get(key);
    if (cached != null) return cached;
    final text = (await _run(repo.root, [
      'show',
      '--no-ext-diff',
      '--no-textconv',
      '--no-color',
      '--format=fuller',
      '--stat',
      '--patch',
      hash,
      '--',
    ], cancellation: cancellation)).text;
    cache.put(key, text);
    return text;
  }

  @override
  Future<GitIdentity> identity(GitRepository repo) async {
    final author = await _run(repo.root, [
      'var',
      'GIT_AUTHOR_IDENT',
    ], allowFailure: true);
    final committer = await _run(repo.root, [
      'var',
      'GIT_COMMITTER_IDENT',
    ], allowFailure: true);
    final origins = await _run(repo.root, [
      'config',
      '--show-origin',
      '--get-regexp',
      r'^user\.(name|email)$',
    ], allowFailure: true);
    final parsed = RegExp(r'^(.+) <([^<>]+)> \d+ [+-]\d+')
        .firstMatch(author.text.trim());
    return GitIdentity(
      parsed?.group(1) ?? '',
      parsed?.group(2) ?? '',
      '${origins.text}\nEffective author: ${author.text.trim()}\nEffective committer: ${committer.text.trim()}',
    );
  }

  @override
  Future<List<String>> remotes(GitRepository repo) async => (await _run(
    repo.root,
    ['remote'],
  )).text.split('\n').where((s) => s.isNotEmpty).toList();

  @override
  Future<List<GitWorktree>> worktrees(GitRepository repo) async {
    final fields = (await _run(repo.root, [
      'worktree',
      'list',
      '--porcelain',
      '-z',
    ])).text.split('\x00');
    final trees = <GitWorktree>[];
    String? path;
    var branch = '';
    var locked = false;
    var prunable = false;
    for (final field in fields) {
      if (field.startsWith('worktree ')) {
        path = field.substring(9);
      } else if (field.startsWith('branch ')) {
        branch = field.substring(7).replaceFirst('refs/heads/', '');
      } else if (field == 'detached') {
        branch = '(detached)';
      } else if (field.startsWith('locked')) {
        locked = true;
      } else if (field.startsWith('prunable')) {
        prunable = true;
      } else if (field.isEmpty && path != null) {
        trees.add(
          GitWorktree(
            path,
            branch,
            main: trees.isEmpty,
            locked: locked,
            prunable: prunable,
          ),
        );
        path = null;
        branch = '';
        locked = false;
        prunable = false;
      }
    }
    return trees;
  }

  Future<void> _write(GitRepository repo, List<String> args) async {
    final release = await _lock(repo);
    try {
      await _run(repo.root, args, read: false);
      cache.clear();
    } finally {
      release();
    }
  }

  @override
  Future<void> stage(GitRepository repo, String path) {
    _literal(path);
    return _write(repo, ['add', '--', path]);
  }

  @override
  Future<void> unstage(GitRepository repo, String path) async {
    _literal(path);
    final release = await _lock(repo);
    try {
      final head = await _run(repo.root, [
        'rev-parse',
        '--verify',
        'HEAD',
      ], allowFailure: true);
      await _run(
        repo.root,
        head.code == 0
            ? ['restore', '--staged', '--', path]
            : ['rm', '--cached', '--ignore-unmatch', '--', path],
        read: false,
      );
      cache.clear();
    } finally {
      release();
    }
  }

  Future<GitCommand> _command(
    GitRepository repo,
    List<String> args, {
    Future<void> Function()? cleanup,
  }) async {
    final release = await _lock(repo);
    var done = false;
    return GitCommand(
      LaunchSpec(
        executable: executable,
        arguments: args,
        workingDirectory: repo.root,
        environment: environment,
        unsetEnvironment: const [
          'GIT_DIR',
          'GIT_WORK_TREE',
          'GIT_COMMON_DIR',
          'GIT_INDEX_FILE',
          'GIT_OBJECT_DIRECTORY',
          'GIT_ALTERNATE_OBJECT_DIRECTORIES',
        ],
      ),
      () async {
        if (done) return;
        done = true;
        try {
          await cleanup?.call();
          cache.clear();
        } finally {
          release();
        }
      },
    );
  }

  @override
  Future<GitCommand> commit(GitRepository repo, String message) async {
    if (message.trim().isEmpty || message.contains('\x00')) {
      throw ArgumentError('Enter a commit message.');
    }
    final author = await identity(repo);
    if (!author.valid) {
      throw GitFailure(
        'Configure an explicit Git name and email for this repository first.',
      );
    }
    final directory = await Directory.systemTemp.createTemp('tabryo-commit-');
    final file = File(p.join(directory.path, 'message.txt'));
    try {
      await file.writeAsString(message, flush: true);
      return await _command(
        repo,
        ['commit', '-F', file.path],
        cleanup: () async {
          await directory.delete(recursive: true);
        },
      );
    } catch (_) {
      await directory.delete(recursive: true);
      rethrow;
    }
  }

  @override
  Future<GitCommand> remoteCommand(
    GitRepository repo,
    String command,
    String remote,
  ) async {
    if (!const ['fetch', 'push'].contains(command) ||
        !(await remotes(repo)).contains(remote) ||
        remote.startsWith('-')) {
      throw ArgumentError(
        'Choose an existing remote and an explicit fetch or push.',
      );
    }
    return _command(repo, [command, remote]);
  }

  @override
  Future<GitCommand> createWorktree(
    GitRepository repo,
    String branch,
    String base,
    String destination,
  ) async {
    _literal(branch);
    _literal(base);
    _literal(destination);
    await _run(repo.root, ['check-ref-format', '--branch', branch]);
    final baseId = _line(
      (await _run(repo.root, [
        'rev-parse',
        '--verify',
        '--end-of-options',
        '$base^{commit}',
      ])).text,
    );
    if (!p.isAbsolute(destination) ||
        await FileSystemEntity.type(destination, followLinks: false) !=
            FileSystemEntityType.notFound) {
      throw GitFailure(
        'Choose an absolute destination that does not exist yet.',
      );
    }
    final parent = await Directory(p.dirname(destination))
        .resolveSymbolicLinks();
    final canonical = p.join(parent, p.basename(destination));
    return _command(repo, [
      'worktree',
      'add',
      '-b',
      branch,
      '--',
      canonical,
      baseId,
    ]);
  }

  @override
  Future<void> removeWorktree(
    GitRepository repo,
    GitWorktree worktree,
    Iterable<String> sessionDirectories,
  ) async {
    final release = await _lock(repo);
    try {
      final all = await worktrees(repo);
      final known = all.where((w) => p.equals(w.path, worktree.path)).toList();
      if (known.length != 1 ||
          known.single.main ||
          known.single.locked ||
          known.single.prunable) {
        throw GitFailure('This worktree cannot be safely removed.');
      }
      final canonical = await Directory(worktree.path).resolveSymbolicLinks();
      if (!p.equals(canonical, p.normalize(p.absolute(worktree.path)))) {
        throw GitFailure('Worktree path changed or is a link.');
      }
      for (final cwd in sessionDirectories) {
        String resolved;
        try {
          resolved = await Directory(cwd).resolveSymbolicLinks();
        } on FileSystemException {
          throw GitFailure(
            'An active session directory cannot be revalidated. Close that session first.',
          );
        }
        if (p.equals(canonical, resolved) || p.isWithin(canonical, resolved)) {
          throw GitFailure('Close all Tabryo sessions in this worktree first.');
        }
      }
      final state = await _run(canonical, [
        'status',
        '--porcelain=v2',
        '-z',
        '--untracked-files=all',
        '--ignored=matching',
      ]);
      if (state.output.isNotEmpty) {
        throw GitFailure(
          'Worktree contains changed, untracked, or ignored files. Preserve them before removal.',
        );
      }
      final checked = await repository(canonical);
      if (!p.equals(checked.commonDirectory, repo.commonDirectory)) {
        throw GitFailure('Worktree repository identity changed.');
      }
      await _run(all.first.path, [
        'worktree',
        'remove',
        '--',
        canonical,
      ], read: false);
    } finally {
      release();
    }
  }
}
