enum SplitDirection { horizontal, vertical }

sealed class PaneNode {
  const PaneNode();
  List<int> get sessions;
  PaneNode replace(int session, PaneNode replacement);
  PaneNode? remove(int session);
}

final class TerminalPane extends PaneNode {
  const TerminalPane(this.session);
  final int session;
  @override
  List<int> get sessions => [session];
  @override
  PaneNode replace(int session, PaneNode replacement) =>
      this.session == session ? replacement : this;
  @override
  PaneNode? remove(int session) => this.session == session ? null : this;
}

final class SplitPane extends PaneNode {
  const SplitPane(this.direction, this.first, this.second);
  final SplitDirection direction;
  final PaneNode first;
  final PaneNode second;
  @override
  List<int> get sessions => [...first.sessions, ...second.sessions];
  @override
  PaneNode replace(int session, PaneNode replacement) => SplitPane(
    direction,
    first.replace(session, replacement),
    second.replace(session, replacement),
  );
  @override
  PaneNode? remove(int session) {
    final a = first.remove(session);
    final b = second.remove(session);
    return a == null
        ? b
        : b == null
        ? a
        : SplitPane(direction, a, b);
  }
}

final class WorkspaceTab {
  WorkspaceTab(this.id, this.title, this.panes);
  final int id;
  final String title;
  PaneNode panes;
}

final class Workspace {
  Workspace(this.root);
  final String root;
  final tabs = <WorkspaceTab>[];
  int activeTab = 0;
  WorkspaceTab? get selectedTab =>
      tabs.isEmpty ? null : tabs[activeTab.clamp(0, tabs.length - 1)];
}
