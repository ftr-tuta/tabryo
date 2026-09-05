import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../terminals/presentation/terminal_pane_view.dart';
import '../domain/workspace.dart';
import 'workbench_dialogs.dart';
import 'workbench_view_model.dart';

final class WorkbenchScreen extends StatefulWidget {
  const WorkbenchScreen({required this.model, super.key});
  final WorkbenchViewModel model;
  @override
  State<WorkbenchScreen> createState() => _WorkbenchScreenState();
}

final class _WorkbenchScreenState extends State<WorkbenchScreen> {
  WorkbenchViewModel get model => widget.model;
  WorkbenchDialogs get dialogs => WorkbenchDialogs(context, model);
  late final AppLifecycleListener _lifecycle;
  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        await model.shutdown();
        return AppExitResponse.exit;
      },
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  List<(String, String, VoidCallback)> get _commands => [
    ('Open workspace', 'Ctrl+O', dialogs.openWorkspace),
    ('New shell', 'Ctrl+Shift+T', () => model.openTerminal()),
    ('Open Codex', '', () => model.openTerminal(codex: true)),
    ('Resume Codex', '', () => model.openTerminal(codex: true, resume: true)),
    (
      'Split side by side',
      'Ctrl+Shift+D',
      () => model.openTerminal(split: SplitDirection.horizontal),
    ),
    (
      'Split stacked',
      'Ctrl+Shift+E',
      () => model.openTerminal(split: SplitDirection.vertical),
    ),
    ('Next pane', 'Ctrl+Shift+J', model.cyclePane),
    ('Refresh', 'F5', model.refresh),
    ('Files', '', () => model.selectSidebar(SidebarPage.files)),
    ('Changes', '', () => model.selectSidebar(SidebarPage.changes)),
    ('History', '', () => model.selectSidebar(SidebarPage.history)),
    ('Worktrees', '', () => model.selectSidebar(SidebarPage.worktrees)),
    ('Create worktree', '', dialogs.createWorktree),
    ('Commit', '', dialogs.commit),
    ('Fetch', '', () => dialogs.remote('fetch')),
    ('Push', '', () => dialogs.remote('push')),
    ('Preferences', '', dialogs.preferences),
  ];

  Future<void> _palette() async {
    var query = '';
    final action = await showDialog<VoidCallback>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('Command palette'),
          content: SizedBox(
            width: 580,
            height: 480,
            child: Column(
              children: [
                TextField(
                  autofocus: true,
                  decoration: const InputDecoration(hintText: 'Type a command'),
                  onChanged: (value) => update(() => query = value),
                ),
                Expanded(
                  child: ListView(
                    children: _commands
                        .where(
                          (c) =>
                              c.$1.toLowerCase().contains(query.toLowerCase()),
                        )
                        .map(
                          (c) => ListTile(
                            title: Text(c.$1),
                            trailing: Text(c.$2),
                            onTap: () => Navigator.pop(context, c.$3),
                          ),
                        )
                        .toList(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    action?.call();
  }

  KeyEventResult _key(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    final key = event.logicalKey;
    if (keys.isControlPressed && keys.isShiftPressed) {
      final action = switch (key) {
        LogicalKeyboardKey.keyP => _palette,
        LogicalKeyboardKey.keyT => () => model.openTerminal(),
        LogicalKeyboardKey.keyD => () => model.openTerminal(
          split: SplitDirection.horizontal,
        ),
        LogicalKeyboardKey.keyE => () => model.openTerminal(
          split: SplitDirection.vertical,
        ),
        LogicalKeyboardKey.keyJ => model.cyclePane,
        LogicalKeyboardKey.keyW => () {
          if (model.focusedSession != null) {
            model.closeSession(model.focusedSession!);
          }
        },
        _ => null,
      };
      if (action != null) {
        action();
        return KeyEventResult.handled;
      }
    }
    if (keys.isControlPressed && key == LogicalKeyboardKey.keyO) {
      dialogs.openWorkspace();
      return KeyEventResult.handled;
    }
    if (keys.isControlPressed && key == LogicalKeyboardKey.tab) {
      model.cycleTab(keys.isShiftPressed ? -1 : 1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.f5) {
      model.refresh();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) => Focus(
    onKeyEvent: _key,
    child: Scaffold(
      appBar: AppBar(
        title: const Text(
          'Tabryo',
          style: TextStyle(fontWeight: FontWeight.w700, letterSpacing: -.5),
        ),
        actions: [
          TextButton.icon(
            onPressed: dialogs.openWorkspace,
            icon: const Icon(Icons.create_new_folder_outlined),
            label: const Text('Open workspace'),
          ),
          TextButton.icon(
            onPressed: model.workspace == null
                ? null
                : () => model.openTerminal(),
            icon: const Icon(Icons.terminal),
            label: const Text('Shell'),
          ),
          TextButton(
            onPressed: model.workspace == null
                ? null
                : () => model.openTerminal(codex: true),
            child: const Text('Codex'),
          ),
          TextButton(
            onPressed: model.workspace == null
                ? null
                : () => model.openTerminal(codex: true, resume: true),
            child: const Text('Resume'),
          ),
          IconButton(
            tooltip: 'Command palette (Ctrl+Shift+P)',
            onPressed: _palette,
            icon: const Icon(Icons.search),
          ),
          IconButton(
            tooltip: 'Preferences',
            onPressed: dialogs.preferences,
            icon: const Icon(Icons.settings_outlined),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          if (model.loading || model.busy)
            const LinearProgressIndicator(minHeight: 2),
          if (model.message != null)
            MaterialBanner(
              content: Text(model.message!),
              actions: [
                TextButton(
                  onPressed: () {
                    model.message = null;
                    setState(() {});
                  },
                  child: const Text('Dismiss'),
                ),
              ],
            ),
          Expanded(
            child: Row(
              children: [
                _sidebar(context),
                const VerticalDivider(width: 1),
                Expanded(
                  child: Column(
                    children: [
                      _tabs(context),
                      Expanded(
                        child: model.tab == null
                            ? _welcome(context)
                            : _panes(model.tab!.panes),
                      ),
                    ],
                  ),
                ),
                if (model.previewText != null) ...[
                  const VerticalDivider(width: 1),
                  SizedBox(
                    width: MediaQuery.sizeOf(context).width * .38,
                    child: Column(
                      children: [
                        ListTile(
                          dense: true,
                          title: Text(
                            model.previewTitle ?? 'Preview',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: IconButton(
                            tooltip: 'Close preview',
                            onPressed: model.dismissPreview,
                            icon: const Icon(Icons.close),
                          ),
                        ),
                        const Divider(height: 1),
                        Expanded(
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.all(16),
                            child: SelectionArea(
                              child: Text(
                                model.previewText!,
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          Container(
            height: 28,
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    model.workspace?.root ??
                        'Local workspace · No process is running',
                    style: Theme.of(context).textTheme.labelSmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  '${model.sessions.length} sessions',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
                const SizedBox(width: 20),
                const Text('0.1.0', style: TextStyle(fontSize: 11)),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  Widget _welcome(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 510),
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.terminal,
                size: 48,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 22),
              Text(
                model.workspace == null
                    ? 'Your projects. Your terminal.'
                    : 'Ready when you are.',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 14),
              const Text(
                'No process is running. Open a shell or Codex explicitly.',
              ),
              const SizedBox(height: 22),
              FilledButton.icon(
                onPressed: model.workspace == null
                    ? dialogs.openWorkspace
                    : () => model.openTerminal(),
                icon: Icon(
                  model.workspace == null ? Icons.folder_open : Icons.terminal,
                ),
                label: Text(
                  model.workspace == null ? 'Open a workspace' : 'Open shell',
                ),
              ),
              if (model.preferences.restoreLayout &&
                  model.preferences.layout.isNotEmpty) ...[
                const SizedBox(height: 20),
                const Text('Previous sessions — start explicitly:'),
                ...model.preferences.layout
                    .take(6)
                    .map(
                      (item) => ListTile(
                        dense: true,
                        title: Text('${item['title'] ?? 'Terminal'}'),
                        subtitle: Text(
                          '${item['root'] ?? ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: const Icon(Icons.play_arrow),
                        onTap: () async {
                          final root = item['root'];
                          if (root is String) {
                            await model.openWorkspace(root);
                            await model.openTerminal(
                              codex: '${item['title']}'.startsWith('Codex'),
                              resume: '${item['title']}'.contains('resume'),
                            );
                          }
                        },
                      ),
                    ),
              ],
              const SizedBox(height: 24),
              Text(
                'Ctrl+Shift+P  Command palette',
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _tabs(BuildContext context) => Container(
    height: 42,
    color: Theme.of(context).colorScheme.surfaceContainerLow,
    child: Row(
      children: [
        Expanded(
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              for (final (index, tab)
                  in (model.workspace?.tabs ?? <WorkspaceTab>[]).indexed)
                InkWell(
                  onTap: () => model.selectTab(index),
                  child: Container(
                    padding: const EdgeInsets.only(left: 14),
                    decoration: BoxDecoration(
                      border: Border(
                        bottom: BorderSide(
                          width: 2,
                          color: model.workspace!.activeTab == index
                              ? Theme.of(context).colorScheme.primary
                              : Colors.transparent,
                        ),
                      ),
                    ),
                    child: Row(
                      children: [
                        if (tab.panes.sessions.any(
                          (id) => model.sessions[id]?.unseenOutput ?? false,
                        ))
                          const Padding(
                            padding: EdgeInsets.only(right: 7),
                            child: Icon(Icons.circle, size: 7),
                          ),
                        Text(tab.title),
                        IconButton(
                          tooltip: 'Close tab',
                          onPressed: () => model.closeTab(tab),
                          icon: const Icon(Icons.close, size: 15),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        IconButton(
          tooltip: 'Split side by side',
          onPressed: model.tab == null
              ? null
              : () => model.openTerminal(split: SplitDirection.horizontal),
          icon: const Icon(Icons.vertical_split_outlined, size: 18),
        ),
        IconButton(
          tooltip: 'Split stacked',
          onPressed: model.tab == null
              ? null
              : () => model.openTerminal(split: SplitDirection.vertical),
          icon: const Icon(Icons.horizontal_split_outlined, size: 18),
        ),
      ],
    ),
  );

  Widget _panes(PaneNode node) => switch (node) {
    TerminalPane(:final session)
        when model.restoredSessions.containsKey(session) =>
      InkWell(
        onTap: () => model.focusSession(session),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(model.restoredSessions[session]!),
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text('Restored layout · no process is running.'),
              ),
              Wrap(
                spacing: 8,
                children: [
                  FilledButton(
                    onPressed: () {
                      model.focusSession(session);
                      model.openTerminal();
                    },
                    child: const Text('Start shell'),
                  ),
                  OutlinedButton(
                    onPressed: () {
                      model.focusSession(session);
                      model.openTerminal(codex: true);
                    },
                    child: const Text('Start Codex'),
                  ),
                  OutlinedButton(
                    onPressed: () {
                      model.focusSession(session);
                      model.openTerminal(codex: true, resume: true);
                    },
                    child: const Text('Resume Codex'),
                  ),
                  IconButton(
                    tooltip: 'Close restored pane',
                    onPressed: () => model.closeSession(session),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    TerminalPane(:final session) => TerminalPaneView(
      key: ValueKey(session),
      session: model.sessions[session]!,
      preferences: model.preferences,
      focused: model.focusedSession == session,
      onFocus: () => model.focusSession(session),
      onClose: () => model.closeSession(session),
    ),
    SplitPane(:final direction, :final first, :final second) => Flex(
      direction: direction == SplitDirection.horizontal
          ? Axis.horizontal
          : Axis.vertical,
      children: [
        Expanded(child: _panes(first)),
        Expanded(child: _panes(second)),
      ],
    ),
  };

  Widget _sidebar(BuildContext context) => SizedBox(
    width: 272,
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              Expanded(
                child: DropdownButton<int>(
                  isExpanded: true,
                  value: model.workspaces.isEmpty
                      ? null
                      : model.activeWorkspace,
                  hint: const Text('Workspace'),
                  items: [
                    for (final (index, w) in model.workspaces.indexed)
                      DropdownMenuItem(
                        value: index,
                        child: Text(
                          p.basename(w.root),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (index) {
                    if (index != null) model.selectWorkspace(index);
                  },
                ),
              ),
              IconButton(
                tooltip: 'Close workspace',
                onPressed: model.workspace == null
                    ? null
                    : () async {
                        if (await dialogs.confirm(
                          'Close workspace?',
                          'Its terminal sessions will be closed. Project files and worktrees remain on disk.',
                          'Close',
                        )) {
                          await model.closeWorkspace();
                        }
                      },
                icon: const Icon(Icons.close, size: 18),
              ),
            ],
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            for (final (page, icon, label) in [
              (SidebarPage.files, Icons.folder_outlined, 'Files'),
              (SidebarPage.changes, Icons.difference_outlined, 'Changes'),
              (SidebarPage.history, Icons.history, 'History'),
              (SidebarPage.worktrees, Icons.account_tree_outlined, 'Worktrees'),
            ])
              IconButton(
                tooltip: label,
                isSelected: model.sidebar == page,
                onPressed: () => model.selectSidebar(page),
                icon: Icon(icon, size: 21),
              ),
          ],
        ),
        const Divider(height: 1),
        ListTile(
          dense: true,
          title: Text(
            model.sidebar.name.toUpperCase(),
            style: Theme.of(context).textTheme.labelSmall,
          ),
          trailing: IconButton(
            tooltip: 'Refresh (F5)',
            onPressed: model.refresh,
            icon: const Icon(Icons.refresh, size: 18),
          ),
        ),
        Expanded(
          child: switch (model.sidebar) {
            SidebarPage.files => _files(),
            SidebarPage.changes => _changes(),
            SidebarPage.history => _history(),
            SidebarPage.worktrees => _worktrees(),
          },
        ),
      ],
    ),
  );

  Widget _files() => Column(
    children: [
      if (model.workspace != null &&
          model.fileDirectory != null &&
          !p.equals(model.workspace!.root, model.fileDirectory!))
        ListTile(
          dense: true,
          leading: const Icon(Icons.arrow_upward, size: 18),
          title: const Text('Parent folder'),
          onTap: () => model.navigateFiles(p.dirname(model.fileDirectory!)),
        ),
      Expanded(
        child: ListView(
          children: [
            for (final entry in model.filePage?.entries ?? [])
              ListTile(
                dense: true,
                leading: Icon(
                  entry.link
                      ? Icons.link
                      : entry.directory
                      ? Icons.folder_outlined
                      : Icons.insert_drive_file_outlined,
                  size: 18,
                ),
                title: Text(
                  entry.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => entry.directory
                    ? model.navigateFiles(entry.path)
                    : model.previewFile(entry.path),
              ),
          ],
        ),
      ),
      if (model.fileOffset > 0 || model.filePage?.hasMore == true)
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            TextButton(
              onPressed: model.fileOffset == 0
                  ? null
                  : () => model.navigateFiles(
                      model.fileDirectory!,
                      offset: model.fileOffset - 200,
                    ),
              child: const Text('Previous'),
            ),
            TextButton(
              onPressed: model.filePage?.hasMore == true
                  ? () => model.navigateFiles(
                      model.fileDirectory!,
                      offset: model.fileOffset + 200,
                    )
                  : null,
              child: const Text('Next'),
            ),
          ],
        ),
    ],
  );

  Widget _changes() => Column(
    children: [
      Wrap(
        spacing: 4,
        children: [
          TextButton(
            onPressed: model.repository == null || model.busy
                ? null
                : dialogs.commit,
            child: const Text('Commit'),
          ),
          TextButton(
            onPressed: model.repository == null || model.busy
                ? null
                : () => dialogs.remote('fetch'),
            child: const Text('Fetch'),
          ),
          TextButton(
            onPressed: model.repository == null || model.busy
                ? null
                : () => dialogs.remote('push'),
            child: const Text('Push'),
          ),
        ],
      ),
      Expanded(
        child: model.changes.isEmpty
            ? const Center(child: Text('No changes to display.'))
            : ListView(
                children: [
                  for (final change in model.changes)
                    Column(
                      children: [
                        ListTile(
                          dense: true,
                          leading: Text(
                            '${change.index}${change.worktree}',
                            style: TextStyle(
                              fontFamily: 'monospace',
                              color: change.conflicted
                                  ? Theme.of(context).colorScheme.error
                                  : null,
                            ),
                          ),
                          title: Text(
                            change.path,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () =>
                              model.previewDiff(change, staged: change.staged),
                          subtitle: change.conflicted
                              ? const Text('Conflict — resolve in a terminal')
                              : null,
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            if (change.staged)
                              TextButton(
                                onPressed: () =>
                                    model.previewDiff(change, staged: true),
                                child: const Text('Staged diff'),
                              ),
                            if (change.unstaged && !change.untracked)
                              TextButton(
                                onPressed: () =>
                                    model.previewDiff(change, staged: false),
                                child: const Text('Diff'),
                              ),
                            if (change.staged)
                              IconButton(
                                tooltip: 'Unstage file',
                                onPressed: model.busy
                                    ? null
                                    : () => model.stage(change, undo: true),
                                icon: const Icon(Icons.remove, size: 18),
                              ),
                            if (change.unstaged)
                              IconButton(
                                tooltip: 'Stage file',
                                onPressed: model.busy
                                    ? null
                                    : () => model.stage(change),
                                icon: const Icon(Icons.add, size: 18),
                              ),
                          ],
                        ),
                      ],
                    ),
                ],
              ),
      ),
    ],
  );

  Widget _history() => Column(
    children: [
      Expanded(
        child: ListView(
          children: [
            for (final commit in model.commits)
              ListTile(
                dense: true,
                title: Text(
                  commit.subject,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${commit.hash.substring(0, 8)} · ${commit.author}\n${commit.date}',
                  maxLines: 2,
                ),
                onTap: () => model.previewCommit(commit),
              ),
          ],
        ),
      ),
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          TextButton(
            onPressed: model.historyPage == 0
                ? null
                : () {
                    model.historyPage--;
                    model.refresh();
                  },
            child: const Text('Previous'),
          ),
          Text('${model.historyPage + 1}'),
          TextButton(
            onPressed: model.commits.length < 100
                ? null
                : () {
                    model.historyPage++;
                    model.refresh();
                  },
            child: const Text('Next'),
          ),
        ],
      ),
    ],
  );

  Widget _worktrees() => Column(
    children: [
      TextButton.icon(
        onPressed: model.repository == null || model.busy
            ? null
            : dialogs.createWorktree,
        icon: const Icon(Icons.add),
        label: const Text('Create worktree'),
      ),
      Expanded(
        child: ListView(
          children: [
            for (final tree in model.worktrees)
              ListTile(
                dense: true,
                title: Text(tree.branch),
                subtitle: Text(
                  tree.path,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => model.openWorkspace(tree.path),
                trailing: tree.main
                    ? const Tooltip(
                        message: 'Main worktree',
                        child: Icon(Icons.home_outlined, size: 18),
                      )
                    : IconButton(
                        tooltip: 'Remove worktree',
                        icon: const Icon(Icons.delete_outline, size: 18),
                        onPressed: model.busy
                            ? null
                            : () async {
                                if (await dialogs.confirm(
                                  'Remove worktree?',
                                  '${tree.path}\n\nTabryo will recheck the path, files (including ignored files), and its sessions. External processes cannot be detected reliably; close them before removal.',
                                  'Remove',
                                )) {
                                  await model.removeWorktree(tree);
                                }
                              },
                      ),
              ),
          ],
        ),
      ),
    ],
  );
}
