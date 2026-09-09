import 'package:flutter/material.dart';

import '../../terminals/presentation/terminal_pane_view.dart';
import '../domain/workspace.dart';
import 'workbench_view_model.dart';

final class ExecutionPane extends StatelessWidget {
  const ExecutionPane({required this.model, required this.owner, super.key});
  final WorkbenchViewModel model;
  final Workspace owner;
  Future<void> _openTerminal({
    bool codex = false,
    bool resume = false,
    SplitDirection? split,
  }) async {
    final index = model.workspaces.indexOf(owner);
    if (index < 0) return;
    if (model.workspace != owner) await model.selectWorkspace(index);
    await model.openTerminal(codex: codex, resume: resume, split: split);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model,
    builder: (context, _) => Column(
      children: [
        _tabs(context),
        Expanded(
          child: owner.tabs.isEmpty
              ? const Center(child: Text('No terminals in this workspace.'))
              : IndexedStack(
                  index: owner.activeTab.clamp(0, owner.tabs.length - 1),
                  children: [
                    for (final (index, tab) in owner.tabs.indexed)
                      TickerMode(
                        enabled:
                            index == owner.activeTab &&
                            TickerMode.valuesOf(context).enabled,
                        child: ExcludeFocus(
                          excluding: index != owner.activeTab,
                          child: KeyedSubtree(
                            key: ValueKey(tab.id),
                            child: _panes(tab.panes),
                          ),
                        ),
                      ),
                  ],
                ),
        ),
      ],
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
              for (final (index, tab) in (owner.tabs).indexed)
                InkWell(
                  onTap: () => model.selectTab(index, owner: owner),
                  child: Container(
                    padding: const EdgeInsets.only(left: 14),
                    decoration: BoxDecoration(
                      border: Border(
                        bottom: BorderSide(
                          width: 2,
                          color: owner.activeTab == index
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
          onPressed: owner.selectedTab == null
              ? null
              : () => _openTerminal(split: SplitDirection.horizontal),
          icon: const Icon(Icons.vertical_split_outlined, size: 18),
        ),
        IconButton(
          tooltip: 'Split stacked',
          onPressed: owner.selectedTab == null
              ? null
              : () => _openTerminal(split: SplitDirection.vertical),
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
                      _openTerminal();
                    },
                    child: const Text('Start shell'),
                  ),
                  OutlinedButton(
                    onPressed: () {
                      model.focusSession(session);
                      _openTerminal(codex: true);
                    },
                    child: const Text('Start Codex'),
                  ),
                  OutlinedButton(
                    onPressed: () {
                      model.focusSession(session);
                      _openTerminal(codex: true, resume: true);
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
      readClipboard: model.readClipboard,
      writeClipboard: model.writeClipboard,
      key: ValueKey(session),
      session: model.sessions[session]!,
      preferences: model.displayPreferences,
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
}
