import 'dart:async';

import 'package:dartitect_flutter/dartitect_flutter.dart';
import 'package:path/path.dart' as p;

import '../../../core/cancellation.dart';
import '../../files/domain/workspace_files.dart';
import '../../git/domain/git_ports.dart';
import '../../preferences/domain/preferences.dart';
import '../../terminals/domain/terminal_ports.dart';
import '../../terminals/presentation/terminal_session.dart';
import '../domain/workspace.dart';

enum SidebarPage { files, changes, history, worktrees }

final class WorkbenchViewModel extends DartitectViewModel {
  WorkbenchViewModel({
    required this.host,
    required this.launcher,
    required this.files,
    required this.gitReader,
    required this.gitMutator,
    required this.preferencesStore,
  });
  final PtyHost host;
  final CodexLauncher launcher;
  final WorkspaceFiles files;
  final GitReader gitReader;
  final GitMutator gitMutator;
  final PreferencesStore preferencesStore;
  final workspaces = <Workspace>[];
  final sessions = <int, TerminalSession>{};
  Preferences preferences = const Preferences();
  int activeWorkspace = 0;
  int? focusedSession;
  SidebarPage sidebar = SidebarPage.files;
  String? message;
  String? previewTitle;
  String? previewText;
  String? fileDirectory;
  FilePage? filePage;
  int fileOffset = 0;
  GitRepository? repository;
  List<GitChange> changes = [];
  List<GitCommit> commits = [];
  List<GitWorktree> worktrees = [];
  int historyPage = 0;
  bool loading = false;
  bool busy = false;
  int _nextId = 0;
  Cancellation? _selection;
  Cancellation? _preview;
  StreamSubscription<void>? _watcher;
  Timer? _watchDebounce;
  bool _shutdown = false;
  Workspace? get workspace => workspaces.isEmpty
      ? null
      : workspaces[activeWorkspace.clamp(0, workspaces.length - 1)];
  WorkspaceTab? get tab => workspace?.selectedTab;
  TerminalSession? get activeSession => sessions[focusedSession];

  Future<void> initialize() async {
    final result = await preferencesStore.load();
    if (_shutdown) return;
    preferences = result.preferences;
    message = result.warning;
    // Restore only root metadata. Opening a project or starting a process
    // still requires a gesture, including after a corrupt preferences file.
    for (final root in preferences.roots) {
      if (p.isAbsolute(root) &&
          !workspaces.any((w) => p.equals(w.root, root))) {
        workspaces.add(Workspace(root));
      }
    }
    notifyListeners();
  }

  Future<void> guarded(Future<void> Function() operation) async {
    try {
      await operation();
    } on Cancelled {
      return;
    } catch (error) {
      if (!_shutdown) {
        message = '$error';
        notifyListeners();
      }
    }
  }

  Future<void> openWorkspace(String path) => guarded(() async {
    final root = await files.authorizeRoot(path);
    if (_shutdown) return;
    var index = workspaces.indexWhere((w) => p.equals(w.root, root));
    if (index < 0) {
      workspaces.add(Workspace(root));
      index = workspaces.length - 1;
    }
    await selectWorkspace(index);
    await _save();
  });

  Future<void> selectWorkspace(int index) async {
    activeWorkspace = index;
    fileDirectory = workspace?.root;
    fileOffset = 0;
    historyPage = 0;
    commits = [];
    previewTitle = null;
    previewText = null;
    focusedSession = tab?.panes.sessions.firstOrNull;
    _visibility();
    await _configureWatcher();
    await refresh();
  }

  Future<void> closeWorkspace() => guarded(() async {
    final current = workspace;
    if (current == null) return;
    for (final id in current.tabs.expand((t) => t.panes.sessions).toList()) {
      await closeSession(id);
    }
    workspaces.remove(current);
    activeWorkspace = activeWorkspace.clamp(
      0,
      workspaces.isEmpty ? 0 : workspaces.length - 1,
    );
    await _configureWatcher();
    await refresh();
    await _save();
  });

  Future<void> selectSidebar(SidebarPage page) async {
    sidebar = page;
    await refresh();
  }

  Future<void> refresh() => guarded(() async {
    _selection?.cancel();
    _preview?.cancel();
    final cancellation = _selection = Cancellation();
    final current = workspace;
    repository = null;
    changes = [];
    worktrees = [];
    filePage = null;
    message = null;
    if (current == null) {
      loading = false;
      notifyListeners();
      return;
    }
    loading = true;
    notifyListeners();
    try {
      if (sidebar == SidebarPage.files) {
        final page = await files.list(
          current.root,
          fileDirectory ?? current.root,
          offset: fileOffset,
          cancellation: cancellation,
        );
        cancellation.check();
        filePage = page;
      } else {
        final repo = await gitReader.repository(
          current.root,
          cancellation: cancellation,
        );
        cancellation.check();
        repository = repo;
        switch (sidebar) {
          case SidebarPage.changes:
            final result = await gitReader.status(
              repo,
              cancellation: cancellation,
            );
            cancellation.check();
            changes = result;
          case SidebarPage.history:
            final result = await gitReader.history(
              repo,
              page: historyPage,
              cancellation: cancellation,
            );
            cancellation.check();
            commits = result;
          case SidebarPage.worktrees:
            final result = await gitReader.worktrees(repo);
            cancellation.check();
            worktrees = result;
          case SidebarPage.files:
            break;
        }
      }
    } finally {
      if (identical(_selection, cancellation) && !_shutdown) {
        loading = false;
        notifyListeners();
      }
    }
  });

  Future<void> navigateFiles(String path, {int offset = 0}) async {
    fileDirectory = path;
    fileOffset = offset;
    await refresh();
  }

  Future<void> previewFile(String path) => guarded(() async {
    _preview?.cancel();
    final token = _preview = Cancellation();
    final root = workspace?.root;
    if (root == null) return;
    final result = await files.preview(root, path, cancellation: token);
    token.check();
    previewTitle = p.basename(path);
    previewText =
        '${result.text}${result.truncated ? '\n\n[Preview truncated at 512 KiB]' : ''}';
    notifyListeners();
  });

  Future<void> previewDiff(GitChange change, {required bool staged}) =>
      guarded(() async {
        if (change.untracked) {
          return previewFile(p.join(workspace!.root, change.path));
        }
        _preview?.cancel();
        final token = _preview = Cancellation();
        final repo = repository;
        if (repo == null) return;
        final text = await gitReader.diff(
          repo,
          change,
          staged: staged,
          cancellation: token,
        );
        token.check();
        previewTitle = '${staged ? 'Staged' : 'Working tree'} · ${change.path}';
        previewText = text.isEmpty ? 'No textual differences.' : text;
        notifyListeners();
      });

  Future<void> previewCommit(GitCommit commit) => guarded(() async {
    _preview?.cancel();
    final token = _preview = Cancellation();
    final repo = repository;
    if (repo == null) return;
    final text = await gitReader.commitDetails(
      repo,
      commit.hash,
      cancellation: token,
    );
    token.check();
    previewTitle = commit.subject;
    previewText = text;
    notifyListeners();
  });

  void dismissPreview() {
    _preview?.cancel();
    previewTitle = null;
    previewText = null;
    notifyListeners();
  }

  Future<void> openTerminal({
    bool codex = false,
    bool resume = false,
    SplitDirection? split,
  }) => guarded(() async {
    final current = workspace;
    if (current == null) {
      message = 'Open a workspace first.';
      notifyListeners();
      return;
    }
    final spec = codex
        ? launcher.codex(current.root, resume: resume)
        : launcher.shell(current.root);
    if (spec == null) {
      message = 'Codex was not found on PATH. Install the Codex CLI, then reopen Tabryo.';
      notifyListeners();
      return;
    }
    _start(
      current,
      spec,
      codex ? (resume ? 'Codex resume' : 'Codex') : 'Shell',
      split: split,
    );
    await _save();
  });

  void _start(
    Workspace owner,
    LaunchSpec spec,
    String title, {
    SplitDirection? split,
    Future<void> Function()? onFinished,
  }) {
    final session = TerminalSession(
      id: ++_nextId,
      title: title,
      spec: spec,
      host: host,
      onFinished: onFinished,
    );
    session.addListener(_sessionChanged);
    sessions[session.id] = session;
    final currentTab = owner.selectedTab;
    if (split != null &&
        currentTab != null &&
        currentTab.panes.sessions.length < 4) {
      final selected = currentTab.panes.sessions.contains(focusedSession)
          ? focusedSession!
          : currentTab.panes.sessions.first;
      currentTab.panes = currentTab.panes.replace(
        selected,
        SplitPane(split, TerminalPane(selected), TerminalPane(session.id)),
      );
    } else {
      owner.tabs.add(WorkspaceTab(session.id, title, TerminalPane(session.id)));
      owner.activeTab = owner.tabs.length - 1;
    }
    focusedSession = session.id;
    message = null;
    _visibility();
    notifyListeners();
  }

  void _sessionChanged() {
    if (!_shutdown) notifyListeners();
  }

  void _visibility() {
    final visible = tab?.panes.sessions ?? const <int>[];
    for (final entry in sessions.entries) {
      entry.value.markVisible(visible.contains(entry.key));
    }
  }

  void selectTab(int index) {
    workspace?.activeTab = index;
    focusedSession = tab?.panes.sessions.firstOrNull;
    _visibility();
    notifyListeners();
  }

  void cycleTab(int direction) {
    final w = workspace;
    if (w == null || w.tabs.isEmpty) return;
    selectTab((w.activeTab + direction) % w.tabs.length);
  }

  void focusSession(int id) {
    if (focusedSession == id) return;
    focusedSession = id;
    notifyListeners();
  }

  void cyclePane() {
    final ids = tab?.panes.sessions ?? [];
    if (ids.isNotEmpty) {
      focusedSession =
          ids[(ids.indexOf(focusedSession ?? -1) + 1) % ids.length];
      notifyListeners();
    }
  }

  Future<void> closeSession(int id) => guarded(() async {
    final session = sessions[id];
    if (session == null) return;
    await session.close();
    session.removeListener(_sessionChanged);
    session.dispose();
    sessions.remove(id);
    for (final w in workspaces) {
      for (final t in w.tabs.toList()) {
        final panes = t.panes.remove(id);
        if (panes == null) {
          w.tabs.remove(t);
        } else {
          t.panes = panes;
        }
      }
      w.activeTab = w.activeTab.clamp(
        0,
        w.tabs.isEmpty ? 0 : w.tabs.length - 1,
      );
    }
    focusedSession = tab?.panes.sessions.firstOrNull;
    _visibility();
    notifyListeners();
    await _save();
  });

  Future<void> closeTab(WorkspaceTab value) async {
    for (final id in value.panes.sessions.toList()) {
      await closeSession(id);
    }
  }

  Future<void> stage(GitChange change, {bool undo = false}) =>
      guarded(() async {
        final repo = repository;
        if (repo == null) return;
        busy = true;
        notifyListeners();
        try {
          if (undo) {
            await gitMutator.unstage(repo, change.path);
          } else {
            await gitMutator.stage(repo, change.path);
          }
          await refresh();
        } finally {
          busy = false;
          if (!_shutdown) notifyListeners();
        }
      });

  Future<GitRepository> selectedRepository() async =>
      repository ?? await gitReader.repository(workspace!.root);
  Future<void> runGitCommand(
    Future<GitCommand> Function(GitRepository) prepare,
    String title,
  ) => guarded(() async {
    final owner = workspace;
    if (owner == null) return;
    busy = true;
    notifyListeners();
    GitCommand? command;
    try {
      command = await prepare(await selectedRepository());
      if (_shutdown) {
        await command.finish();
        return;
      }
      final owned = command;
      _start(owner, owned.spec, title, onFinished: () async {
        await owned.finish();
        if (!_shutdown && workspace == owner) await refresh();
      });
    } catch (_) {
      await command?.finish();
      rethrow;
    } finally {
      busy = false;
      if (!_shutdown) notifyListeners();
    }
  });

  Future<void> removeWorktree(GitWorktree tree) => guarded(() async {
    final repo = await selectedRepository();
    busy = true;
    notifyListeners();
    try {
      await gitMutator.removeWorktree(
        repo,
        tree,
        sessions.values
            .where(
              (s) =>
                  s.status == SessionStatus.running ||
                  s.status == SessionStatus.closing,
            )
            .map((s) => s.spec.workingDirectory),
      );
      await refresh();
    } finally {
      busy = false;
      if (!_shutdown) notifyListeners();
    }
  });

  Future<void> updatePreferences(Preferences value) => guarded(() async {
    preferences = value;
    await _configureWatcher();
    await _save(force: true);
    notifyListeners();
  });

  Future<void> _configureWatcher() async {
    await _watcher?.cancel();
    _watcher = null;
    _watchDebounce?.cancel();
    if (preferences.watchFiles && workspace != null && !_shutdown) {
      _watcher = files
          .watch(workspace!.root)
          .listen(
            (_) {
              _watchDebounce?.cancel();
              _watchDebounce = Timer(
                const Duration(milliseconds: 500),
                refresh,
              );
            },
            onError: (Object error) {
              message = 'File monitoring stopped: $error';
              _watcher?.cancel();
              _watcher = null;
              notifyListeners();
            },
          );
    }
  }

  Future<void> _save({bool force = false}) async {
    if (!force &&
        !preferences.rememberPreferences &&
        !preferences.rememberWorkspaces &&
        !preferences.restoreLayout) {
      return;
    }
    preferences = preferences.copyWith(
      roots: workspaces.map((w) => w.root).toList(),
      layout: sessions.values
          .map(
            (s) => <String, Object?>{
              'root': s.spec.workingDirectory,
              'title': s.title,
            },
          )
          .toList(),
    );
    await preferencesStore.save(preferences);
  }

  Future<void>? _shutdownFuture;
  Future<void> shutdown() => _shutdownFuture ??= () async {
    _shutdown = true;
    _selection?.cancel();
    _preview?.cancel();
    _watchDebounce?.cancel();
    await _watcher?.cancel();
    for (final session in sessions.values) {
      await session.close();
      session.removeListener(_sessionChanged);
      session.dispose();
    }
    sessions.clear();
  }();
  @override
  Future<void> disposeAsync() async {
    await shutdown();
    await super.disposeAsync();
  }
}
