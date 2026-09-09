import 'dart:ui' show AppExitResponse;

// Dartitect 1.1.0 classifies Flutter HardwareKeyboard as infrastructure because
// its SDK source lives under services/. It is presentation input state.
// ignore_for_file: dartitect_dt3121

import 'dart:async';

import '../../games/presentation/game_panel.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../editor/presentation/editor_pane.dart';
import '../../files/domain/workspace_files.dart';
import '../../files/presentation/workspace_search_panel.dart';
import '../../editor/presentation/monaco_editor.dart';
import '../../collaboration/presentation/collaboration_screen.dart';
import '../../mcp_studio/presentation/mcp_studio_screen.dart';
import '../../projects/presentation/projects_screen.dart';
import '../../tasks/presentation/tasks_panel.dart';
import '../../mcp_studio/domain/studio_project.dart';
import 'execution_pane.dart';
import 'window_coordinator.dart';

import 'package:multiview_desktop/multiview_desktop.dart';

import '../../mcp/presentation/mcp_hub_screen.dart';
import '../domain/workspace.dart';
import 'workbench_dialogs.dart';
import 'workbench_view_model.dart';
import '../../debugger/presentation/debug_panel.dart';
import '../../debugger/application/debug_profiles.dart';
import '../../debugger/presentation/devtools_pane.dart';
import '../../preferences/presentation/settings_pane.dart';
import '../../codex/presentation/conversation_pane.dart';
import '../../git/presentation/git_review_panel.dart';
import '../../preferences/domain/preferences.dart';
import '../../preferences/presentation/workbench_theme.dart';

final class WorkbenchScreen extends StatefulWidget {
  const WorkbenchScreen({required this.model, this.windows, super.key});
  final WorkbenchViewModel model;
  final WindowCoordinator? windows;
  @override
  State<WorkbenchScreen> createState() => _WorkbenchScreenState();
}

final class _WorkbenchScreenState extends State<WorkbenchScreen> {
  WorkbenchViewModel get model => widget.model;
  WorkbenchDialogs get dialogs => WorkbenchDialogs(context, model);
  late final AppLifecycleListener _lifecycle;
  double get _devToolsWidth =>
      ((model.activityLayout['toolWidth'] as num?)?.toDouble() ?? .48).clamp(
        .25,
        .55,
      );
  bool _windowsInitialized = false;
  ToolPresentation? _execution, _devTools, _preview;
  Uri? _previewUri;
  String? _previewOwner;
  bool _previewVisible = false;
  bool _auxiliaryTab = false;
  final _executionRecords = <String, ToolPresentation>{};
  final _executionKeys = <String, GlobalKey>{};
  bool get _auxiliaryVisible =>
      !model.settingsOpen &&
      model.activity == WorkbenchActivity.develop &&
      model.activityLayout['maximized'] != true &&
      (_previewVisible || model.devToolsVisible);

  Future<void> _openChatLink(String href) async {
    final uri = Uri.tryParse(href);
    final root = model.workspace?.root;
    if (root == null) return;
    if (uri?.scheme == 'file' || uri?.scheme.isEmpty == true) {
      final path = uri?.scheme == 'file'
          ? uri!.toFilePath()
          : p.normalize(p.join(root, href));
      if (p.isWithin(root, path)) await model.openFile(path);
    } else {
      await model.writeClipboard(href);
    }
  }

  Future<String?> _captureChatContext() async {
    final buffer = model.editor?.active;
    final diff = model.review?.diff;
    if (buffer == null && diff?.textual != true) {
      setState(
        () => model.message =
            'Open a text file or select a text Git diff to attach context.',
      );
      return null;
    }
    final source = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Choose context'),
        children: [
          if (buffer != null)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, 'file'),
              child: Text(
                'File or selected excerpt · ${p.basename(buffer.path)}',
              ),
            ),
          if (diff?.textual == true)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, 'diff'),
              child: Text('Selected Git comparison · ${diff!.path}'),
            ),
        ],
      ),
    );
    if (!mounted || source == null) return null;
    String captured;
    if (source == 'diff') {
      captured =
          'Git comparison: ${diff!.path}\n'
          'Original (${diff.original.identity}):\n${diff.original.text}\n'
          'Modified (${diff.modified.identity}):\n${diff.modified.text}';
    } else {
      if (!await model.editor!.synchronizeBuffer(buffer!)) return null;
      final selection = buffer.controller.selection;
      final text = selection.isValid && !selection.isCollapsed
          ? selection.textInside(buffer.controller.text)
          : buffer.controller.text;
      captured = '${buffer.path}\n$text';
    }
    if (captured.length > 16384) {
      setState(() => model.message = 'Select a smaller excerpt within 16 KiB.');
      return null;
    }
    return captured;
  }

  Future<void> _openLocalPreview() async {
    final owner = model.workspace?.root;
    if (owner == null || model.devToolsProfileDirectory == null) {
      return;
    }
    var input = _previewUri?.toString() ?? 'http://localhost:';
    final uri = await showDialog<Uri>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) {
          final value = Uri.tryParse(input);
          final valid =
              value != null &&
              ['http', 'https'].contains(value.scheme) &&
              ['localhost', '127.0.0.1', '::1', '[::1]'].contains(value.host) &&
              value.userInfo.isEmpty &&
              value.hasPort &&
              value.port > 0;
          return AlertDialog(
            title: const Text('Open local web preview'),
            content: SizedBox(
              width: 480,
              child: TextFormField(
                initialValue: input,
                autofocus: true,
                onChanged: (value) => update(() => input = value),
                decoration: const InputDecoration(
                  labelText: 'Local URL with port',
                  helperText: 'Choose the running app to display.',
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: valid ? () => Navigator.pop(context, value) : null,
                child: const Text('Open'),
              ),
            ],
          );
        },
      ),
    );
    if (!mounted || uri == null || model.workspace?.root != owner) return;
    if (_preview?.window != null) await widget.windows!.reattach(_preview!);
    if (!mounted || model.workspace?.root != owner) return;
    setState(() {
      _previewUri = uri;
      _previewOwner = owner;
      _previewVisible = true;
      _auxiliaryTab = true;
    });
  }

  Widget _toolTheme(Widget child) => ListenableBuilder(
    listenable: model,
    builder: (context, _) => Theme(
      data: workbenchTheme(
        model.displayPreferences.appearance,
        switch (model.displayPreferences.theme) {
          AppTheme.light => Brightness.light,
          AppTheme.dark => Brightness.dark,
          AppTheme.system => MediaQuery.platformBrightnessOf(context),
        },
      ),
      child: child,
    ),
  );

  void _preparePresentations() {
    final windows = widget.windows;
    if (windows == null) return;
    final roots = model.workspaces.map((owner) => owner.root).toSet();
    _executionRecords.removeWhere((root, _) => !roots.contains(root));
    _executionKeys.removeWhere((root, _) => !roots.contains(root));
    for (final owner in model.workspaces) {
      _executionRecords[owner.root] = windows.presentation(
        ToolWindow.execution,
        owner.root,
        'Execution · ${p.basename(owner.root)}',
        (_) => _toolTheme(ExecutionPane(model: model, owner: owner)),
      );
    }
    _execution = _executionRecords[model.workspace?.root];
    final uri = model.debugger?.devToolsUri;
    final project = model.debugger?.configuration?.project;
    if (uri != null &&
        project != null &&
        model.devToolsProfileDirectory != null) {
      _devTools = windows.presentation(
        ToolWindow.devTools,
        '${project.workspace} · $uri',
        'DevTools · ${project.name}',
        (_) => _toolTheme(
          ListenableBuilder(
            listenable: model,
            builder: (_, _) => model.debugger?.devToolsUri != uri
                ? const Center(child: Text('The debug session has ended.'))
                : DevToolsPane(
                    uri: uri,
                    profileDirectory: model.devToolsProfileDirectory!,
                  ),
          ),
        ),
      );
    } else {
      _devTools = null;
    }
    if (_previewUri case final preview?) {
      _preview = windows.presentation(
        ToolWindow.preview,
        _previewOwner!,
        'Preview · $preview',
        (_) => _toolTheme(
          DevToolsPane(
            uri: preview,
            preview: true,
            profileDirectory: p.join(
              model.devToolsProfileDirectory!,
              'preview',
            ),
          ),
        ),
      );
    }
    windows.retainPresentations({
      ..._executionRecords.values,
      ?_devTools,
      ?_preview,
    });
  }

  Widget _executionArea(BuildContext context) {
    if (model.workspaces.isEmpty) return _welcome(context);
    final visible =
        !model.editing &&
        model.activity == WorkbenchActivity.develop &&
        !model.settingsOpen;
    return Column(
      children: [
        if (widget.windows != null && _execution != null)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => widget.windows!.detach(_execution!),
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('Open execution in window'),
            ),
          ),
        Expanded(
          child: IndexedStack(
            index: model.activeWorkspace.clamp(0, model.workspaces.length - 1),
            children: [
              for (final owner in model.workspaces)
                if (widget.windows != null)
                  widget.windows!.slot(
                    _executionRecords[owner.root]!,
                    visible: visible && owner == model.workspace,
                  )
                else
                  TickerMode(
                    enabled: visible && owner == model.workspace,
                    child: ExcludeFocus(
                      excluding: !visible || owner != model.workspace,
                      child: ExecutionPane(
                        key: _executionKeys.putIfAbsent(
                          owner.root,
                          GlobalKey.new,
                        ),
                        model: model,
                        owner: owner,
                      ),
                    ),
                  ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _auxiliaryArea(BuildContext context) {
    final preview = _previewVisible;
    final record = preview ? _preview : _devTools;
    return Column(
      children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (_devTools != null || model.debugger?.devToolsUri != null)
              TextButton(
                onPressed: () => setState(() {
                  _previewVisible = false;
                  model.devToolsVisible = true;
                }),
                child: const Text('DevTools'),
              ),
            if (_previewUri != null)
              TextButton(
                onPressed: () => setState(() => _previewVisible = true),
                child: const Text('Preview'),
              ),
            if (record != null && widget.windows != null)
              IconButton(
                tooltip: 'Open in window',
                onPressed: () => widget.windows!.detach(record),
                icon: const Icon(Icons.open_in_new, size: 18),
              ),
            IconButton(
              tooltip: 'Hide tool panel',
              onPressed: () => setState(() {
                model.hideDevToolsPane();
                _previewVisible = false;
                _auxiliaryTab = false;
              }),
              icon: const Icon(Icons.close, size: 18),
            ),
          ],
        ),
        Expanded(
          child: IndexedStack(
            index: preview ? 1 : 0,
            children: [
              if (_devTools != null && widget.windows != null)
                widget.windows!.slot(
                  _devTools!,
                  visible: !preview && _auxiliaryVisible,
                )
              else if (model.debugger?.devToolsUri != null &&
                  model.devToolsProfileDirectory != null)
                DevToolsPane(
                  uri: model.debugger!.devToolsUri!,
                  profileDirectory: model.devToolsProfileDirectory!,
                  visible: !preview && _auxiliaryVisible,
                )
              else
                const SizedBox.shrink(),
              if (_preview != null && widget.windows != null)
                widget.windows!.slot(
                  _preview!,
                  visible: preview && _auxiliaryVisible,
                )
              else if (_previewUri != null)
                DevToolsPane(
                  uri: _previewUri!,
                  profileDirectory: p.join(
                    model.devToolsProfileDirectory!,
                    'preview',
                  ),
                  preview: true,
                  visible: preview && _auxiliaryVisible,
                )
              else
                const SizedBox.shrink(),
            ],
          ),
        ),
      ],
    );
  }

  Future<bool> _requestExit() async {
    if (model.studio?.busy == true) return false;
    final editor = model.editor;
    if (editor != null &&
        !await confirmDocumentClose(context, editor, editor.buffers)) {
      model.showEditor(true);
      return false;
    }
    await editor?.finishRecoverySession();
    await model.shutdown();
    return true;
  }

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onExitRequested: () async =>
          await _requestExit() ? AppExitResponse.exit : AppExitResponse.cancel,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final windows = widget.windows;
    if (!_windowsInitialized && windows != null) {
      _windowsInitialized = true;
      windows.requestExit = _requestExit;
      windows.frameBuilder = _toolTheme;
      windows.readLayout = (category) => model.preferences.restoreLayout
          ? model.preferences.activityLayouts['window.${category.name}'] ?? {}
          : {};
      windows.saveLayout = (category, layout) =>
          model.updateWindowLayout(category.name, layout);
      windows.onError = (error) {
        if (mounted) {
          setState(() => model.message = 'Window could not move: $error');
        }
      };
      windows.presentationChanged = () {
        if (mounted) setState(() {});
      };
      unawaited(windows.initialize(MultiViewDesktop.getIdByContext(context)));
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    widget.windows?.presentationChanged = null;
    widget.windows?.requestExit = null;
    widget.windows?.dispose();
    super.dispose();
  }

  List<(String, String, VoidCallback)> get _commands => [
    (
      'Execution: open in window',
      '',
      () {
        if (_execution != null) widget.windows?.detach(_execution!);
      },
    ),
    (
      'DevTools: open in window',
      '',
      () {
        if (_devTools != null) widget.windows?.detach(_devTools!);
      },
    ),
    ('Open local web preview', '', _openLocalPreview),
    ('Open workspace', 'Ctrl+O', dialogs.openWorkspace),
    ('New shell', 'Ctrl+Shift+T', () => model.openTerminal()),
    ('Open Codex', '', () => model.openTerminal(codex: true)),
    ('Resume Codex', '', () => model.openTerminal(codex: true, resume: true)),
    ('MCP Hub', '', _openMcpHub),
    ('MCP Studio', '', _openMcpStudio),
    ('Collaboration', '', _openCollaboration),
    ('Editor', '', () => model.showEditor(true)),
    ('Terminals', '', () => model.showEditor(false)),
    (
      'Save document',
      'Ctrl+S',
      () {
        final buffer = model.editor?.active;
        if (buffer != null) model.editor!.save(buffer);
      },
    ),
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
    ('Search workspace', '', _openSearch),
    ('Changes', '', () => model.selectSidebar(SidebarPage.changes)),
    ('History', '', () => model.selectSidebar(SidebarPage.history)),
    ('Worktrees', '', () => model.selectSidebar(SidebarPage.worktrees)),
    ('Create worktree', '', dialogs.createWorktree),
    ('Commit', '', dialogs.commit),
    ('Fetch', '', () => dialogs.remote('fetch')),
    ('Push', '', () => dialogs.remote('push')),
    ('Preferences', '', () => model.showSettings(true)),
    ('Settings', '', () => model.showSettings(true)),
    (
      'Develop',
      'Ctrl+Alt+1',
      () => model.selectActivity(WorkbenchActivity.develop),
    ),
    (
      'Converse',
      'Ctrl+Alt+2',
      () => model.selectActivity(WorkbenchActivity.converse),
    ),
    (
      'Review',
      'Ctrl+Alt+3',
      () => model.selectActivity(WorkbenchActivity.review),
    ),
    (
      'Toggle navigation',
      'Ctrl+B',
      () => model.updateActivityLayout({
        'navigation': model.activityLayout['navigation'] == false,
      }),
    ),
    (
      'Maximize main area',
      'Ctrl+Alt+M',
      () => model.updateActivityLayout({
        'maximized': model.activityLayout['maximized'] != true,
      }),
    ),
    (
      'Restore activity layout',
      '',
      () => model.updateActivityLayout({
        'navigation': true,
        'maximized': false,
        'navigationWidth': 272.0,
        'toolWidth': .48,
      }),
    ),
    ('Projects and toolchains', '', _openProjects),
    ('Game development · Unreal / C++', '', _openProjects),
    ('Recover documents', '', dialogs.recoverDocuments),
  ];

  Future<void> _openSearch() async {
    final root = model.workspace?.root;
    if (root == null) return;
    final match = await showDialog<WorkspaceMatch>(
      context: context,
      builder: (_) => WorkspaceSearchPanel(
        root: root,
        search: (query, cancellation) =>
            model.files.search(root, query, cancellation),
      ),
    );
    if (match != null && mounted) await model.openSearchResult(root, match);
  }

  Future<void> _openMcpHub() async {
    final hub = model.mcpHub;
    final root = model.workspace?.root;
    if (hub == null || root == null) return;
    await hub.selectWorkspace(root);
    if (!mounted) return;
    try {
      await showDialog<void>(
        context: context,
        useSafeArea: false,
        builder: (_) => Dialog.fullscreen(
          child: McpHubScreen(
            model: hub,
            dartFlutterServer: model.dartFlutterMcpDraft,
            connectDartSession: _connectDartMcpSession,
          ),
        ),
      );
    } finally {
      await hub.disconnect();
    }
  }

  Future<void> _connectDartMcpSession() async {
    final hub = model.mcpHub!;
    final service = model.debugger;
    final config = service?.configuration;
    if (service == null ||
        config == null ||
        !service.active ||
        model.workspace?.root != config.project.workspace) {
      throw const StudioFailure(
        'Start a Dart or Flutter debug session in this workspace first.',
      );
    }
    final sdk = await model.dartFlutterMcpDraft();
    if (!mounted ||
        !hub.connected ||
        !identical(service.configuration, config)) {
      throw const StudioFailure('The session or Hub connection changed.');
    }
    await service.openDevTools(external: false);
    final uri = service.dtdUri;
    bool current() =>
        mounted &&
        hub.connected &&
        service.active &&
        identical(service.configuration, config) &&
        service.dtdUri == uri &&
        model.workspace?.root == config.project.workspace;
    if (uri == null || !current()) {
      throw const StudioFailure('The debug session changed.');
    }
    if (!await dialogs.confirm(
      'Connect ${config.project.name} to Dart/Flutter MCP?',
      'The SDK server can inspect and control this running application, including VM evaluation and reload.\n\n'
          'Project: ${config.project.directory}\nSDK: ${sdk.command}\nSession: $uri\n\n'
          'Stopping the debugger closes this session connection. Its address is not saved in configuration.',
      'Connect session',
    )) {
      return;
    }
    if (!await hub.connectDartSession(sdk, uri, current)) {
      throw StudioFailure(hub.message ?? 'Session connection failed.');
    }
  }

  Future<void> _openProjects() async {
    final projects = model.projects;
    final root = model.workspace?.root;
    if (projects == null || root == null) return;
    unawaited(projects.scan(root));
    await showDialog<void>(
      context: context,
      useSafeArea: false,
      builder: (dialogContext) => Dialog.fullscreen(
        child: ProjectsScreen(
          language: model.editor?.language,
          model: projects,
          onApply: model.applyProjectToolchains,
          taskPanel: model.tasks == null
              ? null
              : (project, selection) => Column(
                  children: [
                    if (project.native && model.games != null)
                      GamePanel(
                        key: ValueKey('games:${project.id}'),
                        service: model.games!,
                        project: project,
                        tools: selection,
                        windows: projects.environment.windows,
                        onRun: model.runGamePlan,
                        onAttach: model.debugger == null
                            ? null
                            : (executable, pid) => model.startDebugger(
                                debugProfile(
                                  project: project,
                                  tools: selection,
                                  program: executable,
                                  attachPid: pid,
                                ),
                              ),
                        onOpen: (path, line) async {
                          await model.openGameSource(path, line);
                          if (dialogContext.mounted) {
                            Navigator.pop(dialogContext);
                          }
                        },
                      ),
                    if (model.debugger != null)
                      DebugPanel(
                        key: ValueKey('debug:${project.id}'),
                        service: model.debugger!,
                        project: project,
                        tools: selection,
                        onLoadProfiles: () =>
                            model.tasks!.files.readConfiguration(project),
                        onStart: model.startDebugger,
                        onStop: model.debugger!.stop,
                        onControl: model.controlDebugger,
                        onDevTools: () async {
                          await model.openDevToolsPane();
                          if (dialogContext.mounted && model.devToolsVisible) {
                            Navigator.pop(dialogContext);
                          }
                        },
                        onSource: (path, line, column) async {
                          await model.openDebugSource(path, line, column);
                          if (dialogContext.mounted) {
                            Navigator.pop(dialogContext);
                          }
                        },
                      ),
                    if (!project.native)
                      TasksPanel(
                        key: ValueKey(project.id),
                        model: model.tasks!,
                        project: project,
                        projects: projects.discovery.projects,
                        selection: selection,
                        onRun: model.runTask,
                        onOpenConfiguration: () async {
                          await model.openFile(
                            p.join(
                              project.directory,
                              '.tabryo',
                              'project.json',
                            ),
                          );
                          if (dialogContext.mounted) {
                            Navigator.pop(dialogContext);
                          }
                        },
                        onStop: model.stopTask,
                        onTerminal: (task) {
                          model.showTaskTerminal(task);
                          if (dialogContext.mounted) {
                            Navigator.pop(dialogContext);
                          }
                        },
                        onOpen: (task, result) async {
                          await model.openTestResult(task, result);
                          if (dialogContext.mounted) {
                            Navigator.pop(dialogContext);
                          }
                        },
                      ),
                  ],
                ),
          onRun: (project, command) async {
            await model.runProjectCommand(project, command);
            if (dialogContext.mounted) Navigator.pop(dialogContext);
          },
          onCreate: model.runProjectCreation,
        ),
      ),
    );
  }

  Future<void> _openCollaboration() async {
    final collaboration = model.collaboration;
    if (collaboration == null) return;
    await showDialog<void>(
      context: context,
      useSafeArea: false,
      builder: (dialogContext) => Dialog.fullscreen(
        child: CollaborationScreen(
          model: collaboration,
          root: model.workspace?.root,
          onOpenTerminal: (launch) async {
            await model.openCollaborationTerminal(launch);
            if (dialogContext.mounted) Navigator.pop(dialogContext);
          },
        ),
      ),
    );
  }

  Future<void> _openMcpStudio() async {
    final studio = model.studio;
    final root = model.workspace?.root;
    if (studio == null || root == null) return;
    studio.selectWorkspace(root);
    await showDialog<void>(
      context: context,
      useSafeArea: false,
      barrierDismissible: false,
      builder: (dialogContext) => Dialog.fullscreen(
        child: McpStudioScreen(
          model: studio,
          onOpen: (project) async {
            await model.openStudioProject(project);
            if (dialogContext.mounted) Navigator.pop(dialogContext);
          },
          onRun: (project, spec, title) async {
            await model.runStudioCommand(project, spec, title);
            if (dialogContext.mounted) Navigator.pop(dialogContext);
          },
          onRegister: _registerStudioProject,
        ),
      ),
    );
  }

  Future<void> _registerStudioProject(StudioPlan project) async {
    final hub = model.mcpHub;
    if (hub == null) throw const StudioFailure('MCP Hub is unavailable.');
    model.checkStudioBuffers(project);
    final draft = await model.studio!.studio.registration(project);
    if (!mounted) return;
    if (!await dialogs.confirm(
      'Connect Codex?',
      'Starts Codex and the MCP servers enabled in its trusted configuration. '
          'You will review the new entry before saving it.',
      'Connect',
    )) {
      return;
    }
    await hub.selectWorkspace(project.path);
    try {
      if (!await hub.connect()) {
        throw StudioFailure(hub.message ?? 'Codex could not connect.');
      }
      final change = hub.prepare(draft);
      if (!mounted) return;
      if (!await dialogs.confirm(
        'Register ${project.name}?',
        '${change.filePath}\n\n${change.preview}\n\nSaving reconnects this Hub and starts the server.',
        'Save and reconnect',
      )) {
        return;
      }
      if (!await hub.apply(change)) {
        throw StudioFailure(hub.message ?? 'Registration failed.');
      }
      hub.select(project.name);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        useSafeArea: false,
        builder: (_) => Dialog.fullscreen(
          child: McpHubScreen(
            model: hub,
            dartFlutterServer: model.dartFlutterMcpDraft,
            connectDartSession: _connectDartMcpSession,
          ),
        ),
      );
    } finally {
      await hub.disconnect();
    }
  }

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
    if (keys.isControlPressed && keys.isAltPressed) {
      final activity = switch (key) {
        LogicalKeyboardKey.digit1 => WorkbenchActivity.develop,
        LogicalKeyboardKey.digit2 => WorkbenchActivity.converse,
        LogicalKeyboardKey.digit3 => WorkbenchActivity.review,
        _ => null,
      };
      if (activity != null) {
        model.selectActivity(activity);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyM) {
        model.updateActivityLayout({
          'maximized': model.activityLayout['maximized'] != true,
        });
        return KeyEventResult.handled;
      }
    }
    if (keys.isControlPressed && key == LogicalKeyboardKey.keyB) {
      model.updateActivityLayout({
        'navigation': model.activityLayout['navigation'] == false,
      });
      return KeyEventResult.handled;
    }
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
  Widget build(BuildContext context) {
    _preparePresentations();
    return Actions(
      actions: {
        EditorShortcutIntent: CallbackAction<EditorShortcutIntent>(
          onInvoke: (intent) {
            switch (intent.command) {
              case 'palette':
                unawaited(_palette());
              case 'open':
                unawaited(dialogs.openWorkspace());
              case 'nextTab':
                model.editor?.cycle(1);
              case 'previousTab':
                model.editor?.cycle(-1);
            }
            return null;
          },
        ),
      },
      child: Focus(
        onKeyEvent: _key,
        child: Scaffold(
          appBar: AppBar(
            title: const Text(
              'Tabryo',
              style: TextStyle(fontWeight: FontWeight.w700, letterSpacing: -.5),
            ),
            actions: [
              SizedBox(
                width: (MediaQuery.sizeOf(context).width - 140).clamp(0, 850),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
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
                            : () =>
                                  model.openTerminal(codex: true, resume: true),
                        child: const Text('Resume'),
                      ),
                      IconButton(
                        tooltip: 'MCP Hub',
                        onPressed:
                            model.workspace == null || model.mcpHub == null
                            ? null
                            : _openMcpHub,
                        icon: const Icon(Icons.hub_outlined),
                      ),
                      IconButton(
                        tooltip: 'MCP Studio',
                        onPressed:
                            model.workspace == null || model.studio == null
                            ? null
                            : _openMcpStudio,
                        icon: const Icon(Icons.construction_outlined),
                      ),
                      IconButton(
                        tooltip: 'Projects and toolchains',
                        onPressed:
                            model.workspace == null || model.projects == null
                            ? null
                            : _openProjects,
                        icon: const Icon(Icons.inventory_2_outlined),
                      ),
                      IconButton(
                        tooltip: 'Command palette (Ctrl+Shift+P)',
                        onPressed: _palette,
                        icon: const Icon(Icons.search),
                      ),
                      IconButton(
                        tooltip: 'Collaboration',
                        onPressed: model.collaboration == null
                            ? null
                            : _openCollaboration,
                        icon: const Icon(Icons.groups_outlined),
                      ),
                      IconButton(
                        tooltip: 'Preferences',
                        onPressed: () => model.showSettings(true),
                        icon: const Icon(Icons.settings_outlined),
                      ),
                      const SizedBox(width: 8),
                    ],
                  ),
                ),
              ),
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
              if (model.editor?.recoveries.isNotEmpty == true ||
                  model.editor?.recoveryError != null)
                MaterialBanner(
                  content: Text(
                    model.editor!.recoveryError ??
                        'Unsaved document copies are available for recovery.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: dialogs.recoverDocuments,
                      child: const Text('Review copies'),
                    ),
                  ],
                ),
              Expanded(
                child: Row(
                  children: [
                    if (model.activityLayout['navigation'] != false &&
                        model.activityLayout['maximized'] != true &&
                        model.activity != WorkbenchActivity.converse &&
                        MediaQuery.sizeOf(context).width >= 950) ...[
                      SizedBox(
                        width:
                            ((model.activityLayout['navigationWidth'] as num?)
                                        ?.toDouble() ??
                                    (model.activity == WorkbenchActivity.review
                                        ? 360
                                        : 272))
                                .clamp(220, 460),
                        child:
                            model.activity == WorkbenchActivity.review &&
                                model.review != null
                            ? GitReviewPanel(
                                model: model.review!,
                                root: model.workspace?.root,
                                commit: dialogs.commit,
                                fetch: () => dialogs.remote('fetch'),
                                push: () => dialogs.remote('push'),
                              )
                            : _sidebar(context),
                      ),
                      MouseRegion(
                        cursor: SystemMouseCursors.resizeLeftRight,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onHorizontalDragUpdate: (details) =>
                              model.updateActivityLayout({
                                'navigationWidth':
                                    (((model.activityLayout['navigationWidth']
                                                        as num?)
                                                    ?.toDouble() ??
                                                272) +
                                            details.delta.dx)
                                        .clamp(220, 460),
                              }),
                          child: const SizedBox(
                            width: 7,
                            height: double.infinity,
                          ),
                        ),
                      ),
                    ],
                    const VerticalDivider(width: 1),
                    Expanded(
                      child: Column(
                        children: [
                          Wrap(
                            spacing: 6,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              for (final activity in WorkbenchActivity.values)
                                ChoiceChip(
                                  label: Text(switch (activity) {
                                    WorkbenchActivity.develop => 'Develop',
                                    WorkbenchActivity.converse =>
                                      model.chatPending > 0
                                          ? 'Converse · ${model.chatPending} pending'
                                          : 'Converse',
                                    WorkbenchActivity.review => 'Review',
                                  }),
                                  selected:
                                      model.activity == activity &&
                                      !model.settingsOpen,
                                  onSelected: (_) =>
                                      model.selectActivity(activity),
                                ),
                              IconButton(
                                tooltip: 'Toggle navigation',
                                onPressed: () {
                                  if (MediaQuery.sizeOf(context).width < 950) {
                                    showDialog<void>(
                                      context: context,
                                      builder: (context) => Dialog(
                                        child: SizedBox(
                                          width: 380,
                                          child:
                                              model.activity ==
                                                      WorkbenchActivity
                                                          .review &&
                                                  model.review != null
                                              ? GitReviewPanel(
                                                  model: model.review!,
                                                  root: model.workspace?.root,
                                                  commit: dialogs.commit,
                                                  fetch: () =>
                                                      dialogs.remote('fetch'),
                                                  push: () =>
                                                      dialogs.remote('push'),
                                                )
                                              : _sidebar(context),
                                        ),
                                      ),
                                    );
                                  } else {
                                    model.updateActivityLayout({
                                      'navigation':
                                          model.activityLayout['navigation'] ==
                                          false,
                                    });
                                  }
                                },
                                icon: const Icon(Icons.view_sidebar_outlined),
                              ),
                              IconButton(
                                tooltip: 'Maximize main area',
                                onPressed: () => model.updateActivityLayout({
                                  'maximized':
                                      model.activityLayout['maximized'] != true,
                                }),
                                icon: const Icon(Icons.open_in_full),
                              ),
                              if (model.settingsOpen)
                                const Chip(label: Text('Settings')),
                            ],
                          ),
                          if (model.editor != null)
                            Wrap(
                              children: [
                                TextButton.icon(
                                  onPressed: () {
                                    setState(() => _auxiliaryTab = false);
                                    model.showEditor(true);
                                  },
                                  icon: const Icon(Icons.edit_note),
                                  label: Text(
                                    'Editor${model.editor!.hasDirty ? ' ●' : ''}',
                                  ),
                                ),
                                TextButton.icon(
                                  onPressed: () {
                                    setState(() => _auxiliaryTab = false);
                                    model.showEditor(false);
                                  },
                                  icon: const Icon(Icons.terminal),
                                  label: const Text('Terminals'),
                                ),
                                if (model.debugger?.vmService != null &&
                                    model.devToolsProfileDirectory != null)
                                  TextButton.icon(
                                    onPressed: () {
                                      setState(() {
                                        _auxiliaryTab = true;
                                        _previewVisible = false;
                                      });
                                      model.guarded(model.openDevToolsPane);
                                    },
                                    icon: const Icon(Icons.developer_mode),
                                    label: const Text('DevTools'),
                                  ),
                                TextButton.icon(
                                  onPressed: _openLocalPreview,
                                  icon: const Icon(Icons.web),
                                  label: const Text('Web preview'),
                                ),
                              ],
                            ),
                          Expanded(
                            child: IndexedStack(
                              index: model.settingsOpen
                                  ? 3
                                  : MediaQuery.sizeOf(context).width < 1150 &&
                                        _auxiliaryTab &&
                                        _auxiliaryVisible
                                  ? 4
                                  : model.activity == WorkbenchActivity.converse
                                  ? 1
                                  : (model.editing ||
                                            model.activity ==
                                                WorkbenchActivity.review) &&
                                        model.editor != null
                                  ? 0
                                  : 2,
                              children: [
                                if (model.editor != null)
                                  ExcludeFocus(
                                    excluding:
                                        (!model.editing &&
                                            model.activity !=
                                                WorkbenchActivity.review) ||
                                        model.activity ==
                                            WorkbenchActivity.converse ||
                                        model.settingsOpen,
                                    child: EditorPane(
                                      model: model.editor!,
                                      review:
                                          model.activity ==
                                              WorkbenchActivity.review
                                          ? model.review
                                          : null,
                                      visible:
                                          (model.editing ||
                                              model.activity ==
                                                  WorkbenchActivity.review) &&
                                          model.activity !=
                                              WorkbenchActivity.converse &&
                                          !model.settingsOpen &&
                                          !(MediaQuery.sizeOf(context).width <
                                                  1150 &&
                                              _auxiliaryTab &&
                                              _auxiliaryVisible),
                                    ),
                                  )
                                else
                                  const SizedBox.shrink(),
                                if (model.chat != null)
                                  ConversationPane(
                                    visible:
                                        model.activity ==
                                            WorkbenchActivity.converse &&
                                        !model.settingsOpen,
                                    service: model.chat!,
                                    workspace: model.workspace?.root,
                                    copy: model.writeClipboard,
                                    saveDrafts: model.saveChatDrafts,
                                    openLink: _openChatLink,
                                    captureContext: _captureChatContext,
                                  )
                                else
                                  const Center(
                                    child: Text('Codex chat is unavailable.'),
                                  ),
                                _executionArea(context),
                                if (model.settingsOpen)
                                  SettingsPane(
                                    preferences: model.preferences,
                                    workspace: model.workspace?.root,
                                    onPreview: model.previewPreferences,
                                    onApply: model.updatePreferences,
                                    onClose: () => model.showSettings(false),
                                  )
                                else
                                  const SizedBox.shrink(),
                                if (MediaQuery.sizeOf(context).width < 1150)
                                  TickerMode(
                                    enabled: _auxiliaryTab && _auxiliaryVisible,
                                    child: _auxiliaryArea(context),
                                  )
                                else
                                  const SizedBox.shrink(),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (MediaQuery.sizeOf(context).width >= 1150)
                      Offstage(
                        offstage: !_auxiliaryVisible,
                        child: Row(
                          children: [
                            MouseRegion(
                              cursor: SystemMouseCursors.resizeLeftRight,
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onHorizontalDragUpdate: (details) =>
                                    setState(() {
                                      final width =
                                          (_devToolsWidth -
                                                  details.delta.dx /
                                                      MediaQuery.sizeOf(context)
                                                          .width)
                                              .clamp(.25, .55);
                                      model.updateActivityLayout({
                                        'toolWidth': width,
                                      });
                                    }),
                                child: const SizedBox(
                                  width: 8,
                                  height: double.infinity,
                                ),
                              ),
                            ),
                            SizedBox(
                              width:
                                  MediaQuery.sizeOf(context).width *
                                  _devToolsWidth,
                              child: TickerMode(
                                enabled: _auxiliaryVisible,
                                child: _auxiliaryArea(context),
                              ),
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
      ),
    );
  }

  Widget _welcome(BuildContext context) {
    final labelStyle = Theme.of(context).textTheme.labelMedium;
    return Center(
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
                    model.workspace == null
                        ? Icons.folder_open
                        : Icons.terminal,
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
                Text('Ctrl+Shift+P  Command palette', style: labelStyle),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _sidebar(BuildContext context) => SizedBox(
    width:
        ((model.activityLayout['navigationWidth'] as num?)?.toDouble() ?? 272)
            .clamp(220, 420),
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
                onPressed: model.workspace == null ? null : _closeWorkspace,
                icon: const Icon(Icons.close, size: 18),
              ),
            ],
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            IconButton(
              tooltip: 'Search workspace',
              onPressed: model.workspace == null ? null : _openSearch,
              icon: const Icon(Icons.search, size: 21),
            ),
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

  Future<void> _closeWorkspace() async {
    final root = model.workspace?.root;
    if (root == null) return;
    if (!await dialogs.confirm(
      'Close workspace?',
      'Its terminal sessions will be closed. Project files and worktrees remain on disk.',
      'Close',
    )) {
      return;
    }
    if (!mounted) return;
    if (model.workspace?.root != root) return;
    final editor = model.editor;
    if (editor != null &&
        !await confirmDocumentClose(
          context,
          editor,
          editor.inWorkspace(root),
        )) {
      return;
    }
    if (!mounted) return;
    if (model.workspace?.root != root) return;
    await model.closeWorkspace(discardEdits: true);
  }

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
                    : model.openFile(entry.path),
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
