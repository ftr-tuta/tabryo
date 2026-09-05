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
  const GitCommit(this.hash, this.author, this.date, this.subject);
  final String hash;
  final String author;
  final String date;
  final String subject;
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
