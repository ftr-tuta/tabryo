import '../../../core/cancellation.dart';
import '../../terminals/domain/terminal_ports.dart';

final class GitRepository {
  const GitRepository({
    required this.root,
    required this.gitDirectory,
    required this.commonDirectory,
  });
  final String root;
  final String gitDirectory;
  final String commonDirectory;
}

final class GitChange {
  const GitChange({
    required this.path,
    required this.index,
    required this.worktree,
    this.originalPath,
    this.conflicted = false,
  });
  final String path;
  final String index;
  final String worktree;
  final String? originalPath;
  final bool conflicted;
  bool get untracked => index == '?';
  bool get staged => !untracked && index != '.';
  bool get unstaged => untracked || worktree != '.';
}

final class GitCommit {
  const GitCommit(
    this.hash,
    this.author,
    this.date,
    this.subject, {
    this.parents = const [],
    this.references = const [],
  });
  final String hash;
  final String author;
  final String date;
  final String subject;
  final List<String> parents;
  final List<String> references;
}

final class GitReference {
  const GitReference(this.name, this.hash);
  final String name, hash;
}

final class GitHistoryQuery {
  const GitHistoryQuery({
    this.reference = 'HEAD',
    this.allReferences = false,
    this.author = '',
    this.since = '',
    this.until = '',
    this.path = '',
    this.message = '',
  });
  final String reference, author, since, until, path, message;
  final bool allReferences;
}

final class GitHistoryPage {
  const GitHistoryPage(this.commits, this.anchors, this.nextOffset);
  final List<GitCommit> commits;
  final List<String> anchors;
  final int? nextOffset;
}

final class GitFileChange {
  const GitFileChange(
    this.path,
    this.status, {
    this.originalPath,
    this.additions,
    this.deletions,
  });
  final String path, status;
  final String? originalPath;
  final int? additions, deletions;
}

final class GitComparison {
  const GitComparison({required this.target, required this.files, this.base});
  final String? base;
  final String target;
  final List<GitFileChange> files;
}

enum GitContentKind { text, binary, large, missing, unavailable }

final class GitContent {
  const GitContent(this.kind, this.identity, {this.text = '', this.bytes = 0});
  final GitContentKind kind;
  final String identity, text;
  final int bytes;
}

final class GitFileDiff {
  const GitFileDiff(
    this.path,
    this.original,
    this.modified, {
    this.originalPath,
  });
  final String path;
  final String? originalPath;
  final GitContent original, modified;
  bool get textual => [original, modified].every(
    (c) => c.kind == GitContentKind.text || c.kind == GitContentKind.missing,
  );
  String get identity => '${original.identity}:${modified.identity}';
}

/// Structured, bounded review queries; all revision comparisons pin object IDs.
abstract interface class GitReviewReader {
  Future<List<GitReference>> references(
    GitRepository repo, {
    Cancellation? cancellation,
  });
  Future<GitHistoryPage> historyPage(
    GitRepository repo,
    GitHistoryQuery query, {
    List<String>? anchors,
    int offset = 0,
    Cancellation? cancellation,
  });
  Future<GitComparison> compare(
    GitRepository repo,
    String target, {
    String? base,
    int parent = 0,
    Cancellation? cancellation,
  });
  Future<GitFileDiff> revisionDiff(
    GitRepository repo,
    GitComparison comparison,
    GitFileChange file, {
    Cancellation? cancellation,
  });
  Future<GitFileDiff> localDiff(
    GitRepository repo,
    GitChange change, {
    required bool staged,
    Cancellation? cancellation,
  });
}

final class GitIdentity {
  const GitIdentity(this.name, this.email, this.origins);
  final String name;
  final String email;
  final String origins;
  bool get valid => name.trim().isNotEmpty && email.trim().isNotEmpty;
}

final class GitWorktree {
  const GitWorktree(
    this.path,
    this.branch, {
    this.main = false,
    this.locked = false,
    this.prunable = false,
  });
  final String path;
  final String branch;
  final bool main;
  final bool locked;
  final bool prunable;
}

final class GitCommand {
  GitCommand(this.spec, this.finish);
  final LaunchSpec spec;
  final Future<void> Function() finish;
}

abstract interface class GitReader {
  Future<GitRepository> repository(
    String directory, {
    Cancellation? cancellation,
  });
  Future<List<GitChange>> status(
    GitRepository repo, {
    Cancellation? cancellation,
  });
  Future<String> diff(
    GitRepository repo,
    GitChange change, {
    required bool staged,
    Cancellation? cancellation,
  });
  Future<List<GitCommit>> history(
    GitRepository repo, {
    int page = 0,
    Cancellation? cancellation,
  });
  Future<String> commitDetails(
    GitRepository repo,
    String hash, {
    Cancellation? cancellation,
  });
  Future<GitIdentity> identity(GitRepository repo);
  Future<List<GitWorktree>> worktrees(GitRepository repo);
  Future<List<String>> remotes(GitRepository repo);
}

abstract interface class GitMutator {
  Future<void> stage(GitRepository repo, String path);
  Future<void> unstage(GitRepository repo, String path);
  Future<GitCommand> commit(GitRepository repo, String message);
  Future<GitCommand> remoteCommand(
    GitRepository repo,
    String command,
    String remote,
  );
  Future<GitCommand> createWorktree(
    GitRepository repo,
    String branch,
    String base,
    String destination,
  );
  Future<void> removeWorktree(
    GitRepository repo,
    GitWorktree worktree,
    Iterable<String> sessionDirectories,
  );
}
