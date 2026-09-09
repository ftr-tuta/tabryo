import 'package:flutter/material.dart';

import '../../preferences/presentation/workbench_theme.dart';
import '../domain/git_ports.dart';
import 'git_review_view_model.dart';

final class GitReviewPanel extends StatefulWidget {
  const GitReviewPanel({
    required this.model,
    required this.root,
    required this.commit,
    required this.fetch,
    required this.push,
    super.key,
  });
  final GitReviewViewModel model;
  final String? root;
  final VoidCallback commit, fetch, push;
  @override
  State<GitReviewPanel> createState() => _GitReviewPanelState();
}

final class _GitReviewPanelState extends State<GitReviewPanel> {
  GitReviewViewModel get model => widget.model;
  Set<String> get _expanded => model.expandedPaths;
  String get _page => model.panelPage;
  set _page(String value) => model.panelPage = value;
  bool get _tree => model.treeMode;
  set _tree(bool value) => model.treeMode = value;
  String _branch = 'HEAD',
      _author = '',
      _since = '',
      _until = '',
      _path = '',
      _message = '';
  String _base = 'HEAD~1', _target = 'HEAD';
  bool _all = false;
  void _readQuery() {
    final query = model.query;
    _branch = query.reference;
    _author = query.author;
    _since = query.since;
    _until = query.until;
    _path = query.path;
    _message = query.message;
    _all = query.allReferences;
  }

  @override
  void initState() {
    super.initState();
    _readQuery();
  }

  @override
  void didUpdateWidget(GitReviewPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.root != widget.root) {
      _readQuery();
    }
  }

  Color _status(String status, BuildContext context) => switch (status[0]) {
    'A' || '?' => WorkbenchColors.of(context).added,
    'D' => WorkbenchColors.of(context).removed,
    'U' => Theme.of(context).colorScheme.error,
    _ => WorkbenchColors.of(context).modified,
  };

  List<WidgetBuilder> _changes() {
    final rows = <WidgetBuilder>[];
    final groups = <String, List<GitChange>>{
      'Conflicts': model.changes.where((c) => c.conflicted).toList(),
      'Staged': model.changes.where((c) => c.staged && !c.conflicted).toList(),
      'Unstaged': model.changes
          .where((c) => c.unstaged && !c.untracked && !c.conflicted)
          .toList(),
      'Untracked': model.changes.where((c) => c.untracked).toList(),
    };
    for (final group in groups.entries) {
      rows.add(
        (_) => ListTile(
          dense: true,
          leading: Icon(
            _expanded.contains(group.key)
                ? Icons.expand_more
                : Icons.chevron_right,
          ),
          title: Text('${group.key} · ${group.value.length}'),
          trailing: group.key == 'Conflicts' && group.value.isNotEmpty
              ? Icon(Icons.error, color: Theme.of(context).colorScheme.error)
              : null,
          onTap: () => setState(() {
            if (!_expanded.remove(group.key)) _expanded.add(group.key);
          }),
        ),
      );
      if (!_expanded.contains(group.key)) continue;
      final folders = <String>{};
      for (final file
          in group.value..sort((a, b) => a.path.compareTo(b.path))) {
        final segments = file.path.split('/');
        var parentVisible = true;
        if (_tree) {
          for (var i = 1; i < segments.length; i++) {
            final folder = segments.take(i).join('/');
            final key = '${group.key}:$folder';
            if (folders.add(key) && parentVisible) {
              rows.add(
                (_) => Padding(
                  padding: EdgeInsets.only(left: i * 10.0),
                  child: ListTile(
                    dense: true,
                    leading: Icon(
                      _expanded.contains(key)
                          ? Icons.folder_open
                          : Icons.folder_outlined,
                    ),
                    title: Text(segments[i - 1]),
                    onTap: () => setState(() {
                      if (!_expanded.remove(key)) _expanded.add(key);
                    }),
                  ),
                ),
              );
            }
            if (!_expanded.contains(key)) parentVisible = false;
          }
        }
        if (!parentVisible) continue;
        final staged = group.key == 'Staged';
        final selected =
            model.localChange?.path == file.path && model.staged == staged;
        final status = file.conflicted
            ? 'U'
            : staged
            ? file.index
            : file.worktree;
        rows.add(
          (context) => _ChangeRow(
            key: ValueKey('${group.key}:${file.path}'),
            selected: selected,
            title: _tree ? segments.last : file.path,
            subtitle: file.originalPath == null
                ? null
                : '${file.originalPath} → ${file.path}',
            status: status == '?' ? '+ ?' : status,
            color: _status(status, context),
            onSelect: () => model.selectLocal(file, staged),
            action: file.conflicted ? null : () => model.stage(file, !staged),
            actionLabel: staged ? 'Unstage' : 'Stage',
          ),
        );
      }
    }
    return rows;
  }

  Widget _historyFilters() => ExpansionTile(
    title: const Text('History filters'),
    children: [
      DropdownButtonFormField<String>(
        isExpanded: true,
        initialValue: _branch,
        decoration: const InputDecoration(labelText: 'Branch / reference'),
        items: [
          const DropdownMenuItem(value: 'HEAD', child: Text('Current branch')),
          for (final reference in model.references)
            DropdownMenuItem(
              value: reference.name,
              child: Text(reference.name, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: (value) => _branch = value ?? 'HEAD',
      ),
      CheckboxListTile(
        value: _all,
        title: const Text('All known references'),
        onChanged: (value) => setState(() => _all = value == true),
      ),
      for (final field in <String, ValueChanged<String>>{
        'Author': (v) => _author = v,
        'Since (YYYY-MM-DD)': (v) => _since = v,
        'Until (YYYY-MM-DD)': (v) => _until = v,
        'Path': (v) => _path = v,
        'Message': (v) => _message = v,
      }.entries)
        TextFormField(
          initialValue: switch (field.key) {
            'Author' => _author,
            'Since (YYYY-MM-DD)' => _since,
            'Until (YYYY-MM-DD)' => _until,
            'Path' => _path,
            _ => _message,
          },
          decoration: InputDecoration(labelText: field.key),
          onChanged: field.value,
        ),
      TextButton(
        onPressed: () => model.history(
          GitHistoryQuery(
            reference: _branch,
            allReferences: _all,
            author: _author,
            since: _since,
            until: _until,
            path: _path,
            message: _message,
          ),
        ),
        child: const Text('Apply filters'),
      ),
    ],
  );

  Widget _commitFiles() {
    final comparison = model.comparison!;
    final commit = model.commit;
    return Column(
      children: [
        ExpansionTile(
          title: Text(commit?.subject ?? 'Reference comparison', maxLines: 2),
          subtitle: Text(
            '${comparison.files.length} files · +${comparison.files.fold<int>(0, (n, f) => n + (f.additions ?? 0))} / −${comparison.files.fold<int>(0, (n, f) => n + (f.deletions ?? 0))}',
          ),
          children: [
            SelectableText(
              '${comparison.base ?? 'Empty tree'}\n→ ${comparison.target}\n${commit?.author ?? ''} ${commit?.date ?? ''}',
            ),
          ],
        ),
        if (commit != null && commit.parents.length > 1)
          DropdownButton<int>(
            isExpanded: true,
            value: model.parent,
            items: [
              for (var i = 0; i < commit.parents.length; i++)
                DropdownMenuItem(
                  value: i,
                  child: Text(
                    'Parent ${i + 1} · ${commit.parents[i].substring(0, 8)}',
                  ),
                ),
            ],
            onChanged: (value) {
              if (value != null) model.selectCommit(commit, parentIndex: value);
            },
          ),
        SizedBox(
          height: 180,
          child: ListView.builder(
            itemCount: comparison.files.length,
            itemBuilder: (context, i) {
              final file = comparison.files[i];
              return ListTile(
                dense: true,
                selected: model.revisionFile?.path == file.path,
                leading: Text(
                  file.status,
                  style: TextStyle(color: _status(file.status, context)),
                ),
                title: Text(file.path),
                subtitle: file.originalPath == null
                    ? null
                    : Text('${file.originalPath} → ${file.path}'),
                trailing: Text(
                  file.additions == null
                      ? 'Binary'
                      : '+${file.additions} −${file.deletions}',
                ),
                onTap: () => model.selectFile(file),
              );
            },
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model,
    builder: (context, _) {
      final rows = _changes();
      final graphs = commitGraph(model.commits);
      return Column(
        children: [
          Wrap(
            spacing: 4,
            children: [
              for (final page in ['Changes', 'History', 'Compare'])
                ChoiceChip(
                  label: Text(page),
                  selected: _page == page,
                  onSelected: (_) => setState(() => _page = page),
                ),
              IconButton(
                tooltip: 'Refresh Git',
                onPressed: widget.root == null
                    ? null
                    : () => model.selectWorkspace(widget.root!),
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          Wrap(
            children: [
              TextButton(onPressed: widget.commit, child: const Text('Commit')),
              TextButton(onPressed: widget.fetch, child: const Text('Fetch')),
              TextButton(onPressed: widget.push, child: const Text('Push')),
            ],
          ),
          Expanded(
            child: Column(
              children: [
                if (model.loading) const LinearProgressIndicator(),
                if (model.error != null)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      model.error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                if (model.stale)
                  const Text('Comparison is outdated · reload to update'),
                if (_page == 'Changes') ...[
                  SwitchListTile(
                    dense: true,
                    title: const Text('Folder tree'),
                    value: _tree,
                    onChanged: (value) => setState(() => _tree = value),
                  ),
                  Expanded(
                    child: ListView.builder(
                      itemCount: rows.length,
                      itemBuilder: (context, i) => rows[i](context),
                    ),
                  ),
                ] else if (_page == 'History') ...[
                  Flexible(
                    flex: 2,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 300),
                      child: SingleChildScrollView(child: _historyFilters()),
                    ),
                  ),
                  Expanded(
                    flex: 3,
                    child: ListView.builder(
                      itemCount:
                          model.commits.length +
                          (model.nextOffset == null ? 0 : 1),
                      itemBuilder: (context, i) {
                        if (i == model.commits.length) {
                          return TextButton(
                            onPressed: model.loading
                                ? null
                                : () => model.history(model.query, more: true),
                            child: const Text('Load more commits'),
                          );
                        }
                        final commit = model.commits[i];
                        final graph = graphs[i];
                        return SizedBox(
                          height: 72,
                          child: Row(
                            children: [
                              Tooltip(
                                message: graph.outside
                                    ? 'Ancestry continues outside the loaded or filtered history'
                                    : 'Commit ancestry',
                                child: CustomPaint(
                                  size: Size(
                                    graph.width.clamp(1, 10) * 12.0 + 12,
                                    72,
                                  ),
                                  painter: _GraphPainter(
                                    graph,
                                    Theme.of(context).colorScheme,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: ListTile(
                                  selected: model.commit?.hash == commit.hash,
                                  title: Text(
                                    commit.subject,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: Text(
                                    '${commit.hash.substring(0, 8)} · ${commit.author}\n${commit.references.join(', ')}',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  onTap: () => model.selectCommit(commit),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ] else ...[
                  Flexible(
                    flex: 2,
                    child: SingleChildScrollView(
                      child: Column(
                        children: [
                          TextFormField(
                            initialValue: _base,
                            decoration: const InputDecoration(
                              labelText: 'Base reference',
                            ),
                            onChanged: (v) => _base = v,
                          ),
                          TextFormField(
                            initialValue: _target,
                            decoration: const InputDecoration(
                              labelText: 'Target reference',
                            ),
                            onChanged: (v) => _target = v,
                          ),
                          TextButton(
                            onPressed: model.repository == null
                                ? null
                                : () => model.compareReferences(_base, _target),
                            child: const Text('Compare references'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                if (model.comparison != null)
                  Flexible(
                    flex: 3,
                    child: SingleChildScrollView(child: _commitFiles()),
                  ),
              ],
            ),
          ),
        ],
      );
    },
  );
}

final class _ChangeRow extends StatefulWidget {
  const _ChangeRow({
    required this.title,
    required this.status,
    required this.color,
    required this.selected,
    required this.onSelect,
    required this.actionLabel,
    this.subtitle,
    this.action,
    super.key,
  });
  final String title, status, actionLabel;
  final String? subtitle;
  final Color color;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback? action;
  @override
  State<_ChangeRow> createState() => _ChangeRowState();
}

final class _ChangeRowState extends State<_ChangeRow> {
  bool focused = false;
  @override
  Widget build(BuildContext context) => FocusableActionDetector(
    onFocusChange: (value) => setState(() => focused = value),
    child: GestureDetector(
      onSecondaryTapDown: (event) async {
        final action = await showMenu<bool>(
          context: context,
          position: RelativeRect.fromLTRB(
            event.globalPosition.dx,
            event.globalPosition.dy,
            0,
            0,
          ),
          items: [
            const PopupMenuItem(value: false, child: Text('Compare')),
            if (widget.action != null)
              PopupMenuItem(value: true, child: Text(widget.actionLabel)),
          ],
        );
        if (action == true) {
          widget.action?.call();
        } else if (action == false) {
          widget.onSelect();
        }
      },
      child: ListTile(
        selected: widget.selected,
        dense: true,
        onTap: widget.onSelect,
        leading: Text(
          widget.status,
          style: TextStyle(color: widget.color, fontWeight: FontWeight.bold),
        ),
        title: Text(widget.title),
        subtitle: widget.subtitle == null ? null : Text(widget.subtitle!),
        trailing: (widget.selected || focused) && widget.action != null
            ? IconButton(
                tooltip: widget.actionLabel,
                onPressed: widget.action,
                icon: Icon(
                  widget.actionLabel == 'Stage' ? Icons.add : Icons.remove,
                ),
              )
            : null,
      ),
    ),
  );
}

final class CommitGraphRow {
  const CommitGraphRow(
    this.before,
    this.after,
    this.lane,
    this.parents,
    this.outside,
  );
  final List<String> before, after, parents;
  final int lane;
  final bool outside;
  int get width => (before.length > after.length ? before.length : after.length)
      .clamp(1, 10);
}

List<CommitGraphRow> commitGraph(List<GitCommit> commits) {
  final rows = <CommitGraphRow>[];
  final lanes = <String>[];
  final hashes = commits.map((c) => c.hash).toSet();
  for (final commit in commits) {
    if (!lanes.contains(commit.hash)) lanes.insert(0, commit.hash);
    final before = [...lanes];
    final lane = lanes.indexOf(commit.hash);
    lanes.removeAt(lane);
    var insertion = lane;
    for (final parent in commit.parents) {
      if (!lanes.contains(parent)) {
        lanes.insert((insertion++).clamp(0, lanes.length), parent);
      }
    }
    rows.add(
      CommitGraphRow(
        before,
        [...lanes],
        lane,
        commit.parents,
        commit.parents.any((p) => !hashes.contains(p)),
      ),
    );
  }
  return rows;
}

final class _GraphPainter extends CustomPainter {
  _GraphPainter(this.row, this.colors);
  final CommitGraphRow row;
  final ColorScheme colors;
  @override
  void paint(Canvas canvas, Size size) {
    double x(int lane) => lane.clamp(0, 9) * 12.0 + 6;
    final paint = Paint()
      ..color = colors.primary
      ..strokeWidth = 1.5;
    for (var i = 0; i < row.before.length; i++) {
      if (i == row.lane) {
        canvas.drawLine(Offset(x(i), 0), Offset(x(i), 36), paint);
        continue;
      }
      final next = row.after.indexOf(row.before[i]);
      if (next >= 0) {
        canvas.drawLine(Offset(x(i), 0), Offset(x(next), 72), paint);
      }
    }
    for (final parent in row.parents) {
      final next = row.after.indexOf(parent);
      canvas.drawLine(Offset(x(row.lane), 36), Offset(x(next), 72), paint);
    }
    canvas.drawCircle(Offset(x(row.lane), 36), 4, paint);
    if (row.outside) {
      canvas.drawCircle(
        Offset(x(row.lane), 36),
        7,
        Paint()
          ..color = colors.outline
          ..style = PaintingStyle.stroke,
      );
    }
  }

  @override
  bool shouldRepaint(_GraphPainter oldDelegate) =>
      oldDelegate.row != row || oldDelegate.colors != colors;
}
