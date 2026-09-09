import 'package:dartitect_flutter/dartitect_flutter.dart';

import '../../../core/cancellation.dart';
import '../domain/git_ports.dart';

final class GitReviewViewModel extends DartitectViewModel {
  GitReviewViewModel(this.reader, this.review, this.mutator);
  final GitReader reader;
  final GitReviewReader review;
  final GitMutator mutator;
  String panelPage = 'Changes';
  bool treeMode = true;
  final _expansions = <String, Set<String>>{};
  Set<String> get expandedPaths =>
      _expansions.putIfAbsent(repository?.root ?? '', () => {});
  GitRepository? repository;
  List<GitChange> changes = [];
  List<GitReference> references = [];
  List<GitCommit> commits = [];
  GitHistoryQuery query = const GitHistoryQuery();
  List<String>? _anchors;
  int? nextOffset;
  GitCommit? commit;
  GitComparison? comparison;
  GitFileDiff? diff;
  GitChange? localChange;
  GitFileChange? revisionFile;
  bool staged = false, stale = false, loading = false, sideBySide = true;
  int parent = 0, navigation = 0;
  String? error;
  String? _targetReference, _baseReference;
  Cancellation? _operation;
  bool _closed = false;
  String? _workspace;

  Future<void> _run(Future<void> Function(Cancellation token) action) async {
    _operation?.cancel();
    final token = _operation = Cancellation();
    loading = true;
    error = null;
    notifyListeners();
    try {
      await action(token);
      token.check();
    } on Cancelled {
      return;
    } catch (failure) {
      if (!token.isCancelled) error = '$failure';
    } finally {
      if (!_closed && identical(_operation, token)) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> selectWorkspace(String root) => _run((token) async {
    if (_workspace != root) {
      _workspace = root;
      if (_expansions.length > 30) _expansions.remove(_expansions.keys.first);
      repository = null;
      commits = [];
      _anchors = null;
      nextOffset = null;
      diff = null;
      comparison = null;
      commit = null;
      localChange = null;
      revisionFile = null;
      query = const GitHistoryQuery();
      changes = [];
      references = [];
      stale = false;
      _baseReference = null;
      _targetReference = null;
    }
    final repo = await reader.repository(root, cancellation: token);
    token.check();
    repository = repo;
    changes = await reader.status(repo, cancellation: token);
    token.check();
    references = await review.references(repo, cancellation: token);
    token.check();
    if (diff != null) await _freshness(token);
    if (_anchors == null) {
      final page = await review.historyPage(repo, query, cancellation: token);
      token.check();
      commits = page.commits;
      _anchors = page.anchors;
      nextOffset = page.nextOffset;
    }
  });

  Future<void> history(GitHistoryQuery value, {bool more = false}) =>
      _run((token) async {
        final repo = repository;
        if (repo == null) return;
        if (more && nextOffset == null) return;
        final page = await review.historyPage(
          repo,
          value,
          anchors: more ? _anchors : null,
          offset: more ? nextOffset! : 0,
          cancellation: token,
        );
        token.check();
        query = value;
        commits = more ? [...commits, ...page.commits] : page.commits;
        _anchors = page.anchors;
        nextOffset = commits.length >= 2000 ? null : page.nextOffset;
      });

  Future<void> selectLocal(GitChange change, bool prepared) =>
      _run((token) async {
        final loaded = await review.localDiff(
          repository!,
          change,
          staged: prepared,
          cancellation: token,
        );
        token.check();
        diff = loaded;
        localChange = change;
        staged = prepared;
        stale = false;
        comparison = null;
        revisionFile = null;
        commit = null;
      });

  Future<void> selectCommit(GitCommit value, {int parentIndex = 0}) =>
      _run((token) async {
        final result = await review.compare(
          repository!,
          value.hash,
          parent: parentIndex,
          cancellation: token,
        );
        token.check();
        commit = value;
        parent = parentIndex;
        comparison = result;
        diff = null;
        localChange = null;
        revisionFile = null;
        _targetReference = value.hash;
        _baseReference = null;
        stale = false;
      });

  Future<void> compareReferences(String base, String target) =>
      _run((token) async {
        final result = await review.compare(
          repository!,
          target,
          base: base,
          cancellation: token,
        );
        token.check();
        comparison = result;
        commit = null;
        diff = null;
        localChange = null;
        revisionFile = null;
        _targetReference = target;
        _baseReference = base;
        stale = false;
      });

  Future<void> selectFile(GitFileChange file) => _run((token) async {
    final result = await review.revisionDiff(
      repository!,
      comparison!,
      file,
      cancellation: token,
    );
    token.check();
    diff = result;
    revisionFile = file;
    localChange = null;
  });

  Future<void> _freshness(Cancellation token) async {
    if (localChange != null) {
      final current = await review.localDiff(
        repository!,
        localChange!,
        staged: staged,
        cancellation: token,
      );
      token.check();
      stale = current.identity != diff?.identity;
    } else if (_targetReference != null && comparison != null) {
      final current = await review.compare(
        repository!,
        _targetReference!,
        base: _baseReference,
        parent: parent,
        cancellation: token,
      );
      token.check();
      stale =
          current.base != comparison?.base ||
          current.target != comparison?.target;
    }
  }

  Future<void> reloadDiff() async {
    if (localChange != null) {
      await selectLocal(localChange!, staged);
    } else if (_targetReference != null) {
      final selectedPath = revisionFile?.path;
      if (_baseReference != null) {
        await compareReferences(_baseReference!, _targetReference!);
      } else if (commit != null) {
        await selectCommit(commit!, parentIndex: parent);
      }
      final file = comparison?.files
          .where((f) => f.path == selectedPath)
          .firstOrNull;
      if (file != null) await selectFile(file);
    }
  }

  Future<void> stage(GitChange change, bool prepare) async {
    final repo = repository;
    if (repo == null || loading) return;
    await _run((token) async {
      if (prepare) {
        await mutator.stage(repo, change.path);
      } else {
        await mutator.unstage(repo, change.path);
      }
      changes = await reader.status(repo, cancellation: token);
      token.check();
      if (diff != null) await _freshness(token);
    });
  }

  void setSideBySide(bool value) {
    sideBySide = value;
    notifyListeners();
  }

  void navigate(int direction) {
    navigation += direction;
    notifyListeners();
  }

  @override
  Future<void> disposeAsync() async {
    _closed = true;
    _operation?.cancel();
    await super.disposeAsync();
  }
}
