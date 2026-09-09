import 'dart:async';
import 'dart:convert';

import 'package:dartitect_flutter/dartitect_flutter.dart';
import 'package:path/path.dart' as p;

import '../../../core/cancellation.dart';
import '../../collaboration/presentation/collaboration_view_model.dart';
import '../../collaboration/domain/collaboration.dart';
import '../../editor/presentation/editor_view_model.dart';
import '../../editor/domain/document_files.dart';
import '../../editor_context/domain/editor_context.dart';
import '../../mcp_studio/domain/studio_project.dart';
import '../../mcp_studio/presentation/mcp_studio_view_model.dart';
import '../../files/domain/workspace_files.dart';
import '../../git/domain/git_ports.dart';
import '../../preferences/domain/preferences.dart';
import '../../projects/domain/project.dart';
import '../../projects/presentation/projects_view_model.dart';
import '../../tasks/domain/project_task.dart';
import '../../tasks/presentation/tasks_view_model.dart';
import '../../debugger/application/debug_service.dart';
import '../../debugger/domain/debug_session.dart';
import '../../language/domain/language_server.dart';
import '../../mcp/presentation/mcp_hub_view_model.dart';
import '../../mcp/domain/mcp_server.dart';
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
    this.mcpHub,
    this.editor,
    this.studio,
    this.collaboration,
    this.clipboard,
    this.projects,
    this.tasks,
    this.debugger,
    this.devToolsProfileDirectory,
  }) {
    editor?.captureProjectContext = _captureProjectContext;
    editor?.captureTaskCatalog = _captureTaskCatalog;
    editor?.prepareTaskRequest = _prepareTaskRequest;
    editor?.runTaskRequest = (request, task) => runTask(task, request: request);
    editor?.discardTaskRequest = (task) async => tasks?.discard(task);
    tasks?.addListener(_taskContextChanged);
    debugger?.onInspectorSource = (location) =>
        openDebugSource(location.path, location.line, location.column);
    editor?.addListener(_editorChanged);
    editor?.onSaved = (saved) {
      final service = debugger;
      final config = service?.configuration;
      if (_shutdown ||
          config == null ||
          config.project.kind != ProjectKind.flutter ||
          saved.root != config.project.workspace ||
          !p.isWithin(config.project.directory, saved.path) ||
          p.extension(saved.path) != '.dart' ||
          projects?.discovery.projects.any(
                (other) =>
                    other.id != config.project.id &&
                    p.isWithin(config.project.directory, other.directory) &&
                    p.isWithin(other.directory, saved.path),
              ) ==
              true) {
        return;
      }
      service!.scheduleReloadAfterSave(() async {
        if (_shutdown || !identical(service.configuration, config)) {
          return false;
        }
        await _checkProjectDocuments(config.project.directory);
        return !_shutdown && identical(service.configuration, config);
      });
    };
    _debugChanges = debugger?.changes.listen((_) {
      if (!_startingDebugger &&
          debugger?.active != true &&
          _debugProject != null) {
        _projectRuns.remove(_debugProject);
        _debugProject = null;
        devToolsVisible = false;
      }
      if (!_shutdown) notifyListeners();
    });
  }
  final PtyHost host;
  final ProjectsViewModel? projects;
  final TasksViewModel? tasks;
  final DebugService? debugger;
  final String? devToolsProfileDirectory;
  void _taskContextChanged() {
    if (!_shutdown) editor?.contextSharing?.refreshTaskStatus();
  }

  Future<EditorTaskCatalog> _captureTaskCatalog(
    String root,
    String path,
  ) async {
    final projectRoot = _captureProjectContext(
      root,
      path,
      tests: false,
      sessions: false,
    ).root;
    final project = projects!.discovery.projects
        .where(
          (project) =>
              project.directory == projectRoot && project.workspace == root,
        )
        .firstOrNull;
    final tools = projects!.selections[project?.id];
    if (project == null || tools == null || tasks == null) {
      throw const EditorContextFailure(
        'Apply the owning project toolchain before sharing its registered tasks.',
      );
    }
    await projects!.environment.validateProject(project);
    final config = await tasks!.files.readConfiguration(project);
    if (config.tasks.isEmpty) {
      throw const EditorContextFailure(
        'Register at least one task in .tabryo/project.json before sharing task requests.',
      );
    }
    if (_shutdown ||
        workspace?.root != root ||
        !identical(tools, projects!.selections[project.id])) {
      throw const EditorContextFailure(
        'The workspace or toolchain changed. Capture tasks again.',
      );
    }
    return EditorTaskCatalog(project, tools, config);
  }

  bool _ownsTaskRequest(EditorTaskRequest request) =>
      !_shutdown &&
      editor?.contextSharing?.ownsTaskRequest(request) == true &&
      request.decision == 'reviewing' &&
      workspace?.root == request.snapshot.workspace;

  Future<ProjectTask> _prepareTaskRequest(EditorTaskRequest request) async {
    if (!_ownsTaskRequest(request) || request.task != null || tasks == null) {
      throw const EditorContextFailure(
        'This registered task request is no longer available.',
      );
    }
    final catalog = request.snapshot.taskCatalog!;
    final preset = catalog.configuration.tasks.singleWhere(
      (task) => task.name == request.name,
    );
    final task = await tasks!.prepare(
      catalog.project,
      catalog.tools,
      preset.kind,
      target: preset.target == null
          ? null
          : p.joinAll([
              catalog.project.directory,
              ...preset.target!.split('/'),
            ]),
      filter: preset.filter,
      buildTarget: preset.buildTarget,
      arguments: preset.arguments,
      coverage: preset.coverage,
      configuration: catalog.configuration,
    );
    if (!_ownsTaskRequest(request)) {
      await tasks!.discard(task);
      throw const EditorContextFailure(
        'The task grant was revoked during preparation.',
      );
    }
    request.task = task;
    return task;
  }

  EditorProjectContext _captureProjectContext(
    String root,
    String path, {
    required bool tests,
    required bool sessions,
  }) {
    if (_shutdown || workspace?.root != root) {
      throw const EditorContextFailure('The workspace changed.');
    }
    final config = debugger?.configuration;
    final candidates =
        [...?projects?.discovery.projects, if (config != null) config.project]
            .where(
              (project) =>
                  project.workspace == root &&
                  p.isWithin(project.directory, path),
            )
            .toList()
          ..sort((a, b) => b.directory.length.compareTo(a.directory.length));
    final project = candidates.firstOrNull;
    if (project == null) {
      throw const EditorContextFailure(
        'Scan the project owning this document before including test or session context.',
      );
    }
    final runs =
        tasks?.runs
            .where(
              (run) =>
                  run.project.id == project.id && run.project.workspace == root,
            )
            .toList() ??
        <ProjectTask>[];
    var limited = false;
    var bytes = 0;
    final testRuns = <EditorTestContext>[];
    if (tests) {
      for (final run in runs.reversed.where(
        (run) =>
            run.kind == ProjectTaskKind.test &&
            run.status != TaskStatus.prepared,
      )) {
        if (testRuns.length == 5) {
          limited = true;
          break;
        }
        final counts = {
          for (final outcome in TestOutcome.values) outcome.name: 0,
        };
        final failures = <EditorTestFailure>[];
        for (final item in run.results?.cases ?? <TestCaseResult>[]) {
          counts[item.outcome.name] = counts[item.outcome.name]! + 1;
          if (item.outcome != TestOutcome.failed &&
              item.outcome != TestOutcome.incomplete) {
            continue;
          }
          final failure = EditorTestFailure(
            name: String.fromCharCodes(item.name.runes.take(512)),
            outcome: item.outcome.name,
            details: String.fromCharCodes(item.details.runes.take(4096)),
            path: item.path != null && p.isWithin(project.directory, item.path!)
                ? item.path
                : null,
            line: item.line,
          );
          final size = utf8.encode(jsonEncode(failure.toJson())).length;
          if (failures.length == 20 || bytes + size > 64 * 1024) {
            limited = true;
            continue;
          }
          bytes += size;
          if (failure.name != item.name || failure.details != item.details) {
            limited = true;
          }
          failures.add(failure);
        }
        testRuns.add(
          EditorTestContext(
            status: run.status.name,
            complete: run.results?.complete == true,
            successful:
                run.status == TaskStatus.passed &&
                run.results?.successful == true &&
                run.results?.complete == true &&
                run.exitCode == 0,
            target: run.target,
            exitCode: run.exitCode,
            error: run.error == null
                ? null
                : String.fromCharCodes(run.error!.runes.take(2048)),
            counts: counts,
            failures: failures,
          ),
        );
      }
    }
    final running = <EditorSessionContext>[];
    if (sessions) {
      if (config?.project.id == project.id && debugger?.active == true) {
        running.add(
          EditorSessionContext(
            kind: config!.project.kind.name,
            status: debugger!.status.name,
            program: config.program,
            attach: config.isAttach,
            noDebug: config.noDebug,
          ),
        );
      }
      for (final run in runs.where((run) => run.status == TaskStatus.running)) {
        if (running.length == 8) {
          limited = true;
          break;
        }
        running.add(
          EditorSessionContext(
            kind: 'task.${run.kind.name}',
            status: run.status.name,
            program: run.target ?? run.command.title,
            attach: false,
            noDebug: true,
          ),
        );
      }
    }
    return EditorProjectContext(
      root: project.directory,
      includesTests: tests,
      includesSessions: sessions,
      limited: limited,
      tests: testRuns,
      sessions: running,
    );
  }

  Future<McpServerDraft> dartFlutterMcpDraft() async {
    final manager = projects;
    final config = debugger?.active == true ? debugger?.configuration : null;
    final project = config?.project ?? manager?.selected;
    final tools = config?.tools ?? manager?.selections[project?.id];
    if (manager == null ||
        project == null ||
        tools == null ||
        project.kind == ProjectKind.python ||
        workspace?.root != project.workspace) {
      throw const ProjectFailure(
        'Select a Dart or Flutter project and apply its SDK first.',
      );
    }
    final flutter = tools[ProjectTool.flutter];
    final dart = project.kind == ProjectKind.flutter && flutter != null
        ? p.join(
            flutter,
            'bin',
            'cache',
            'dart-sdk',
            'bin',
            manager.environment.windows ? 'dart.exe' : 'dart',
          )
        : tools[ProjectTool.dart];
    if (dart == null) {
      throw const ProjectFailure('Select the project Dart SDK first.');
    }
    await manager.environment.validateProject(project);
    await manager.environment.validateSelection(
      ToolchainSelection({
        ProjectTool.dart: dart,
        ProjectTool.flutter: ?flutter,
      }),
    );
    if (_shutdown ||
        workspace?.root != project.workspace ||
        (config != null && !identical(config, debugger?.configuration)) ||
        (config == null &&
            (manager.selected != project ||
                manager.selections[project.id] != tools))) {
      throw const ProjectFailure(
        'The project or SDK changed. Review its selection again.',
      );
    }
    return McpServerDraft(
      name: 'dart_flutter',
      transport: McpTransport.stdio,
      command: dart,
      arguments: [
        'mcp-server',
        '--dart-sdk',
        p.dirname(p.dirname(dart)),
        if (flutter != null) ...['--flutter-sdk', flutter],
      ],
      workingDirectory: project.directory,
    );
  }

  bool devToolsVisible = false;
  Future<void> openDevToolsPane() async {
    final service = debugger;
    final config = service?.configuration;
    if (service == null ||
        config == null ||
        devToolsProfileDirectory == null ||
        workspace?.root != config.project.workspace) {
      throw const DebugFailure('Open the workspace owning this debug session.');
    }
    await service.openDevTools(external: false);
    if (_shutdown ||
        !identical(config, service.configuration) ||
        service.devToolsUri == null ||
        workspace?.root != config.project.workspace) {
      return;
    }
    devToolsVisible = true;
    notifyListeners();
  }

  void hideDevToolsPane() {
    devToolsVisible = false;
    notifyListeners();
  }

  StreamSubscription<void>? _debugChanges;
  String? _debugProject;
  bool _startingDebugger = false;
  final TextClipboard? clipboard;
  Future<String?> readClipboard() async => clipboard?.readText();
  Future<void> writeClipboard(String text) async => clipboard?.writeText(text);
  final CodexLauncher launcher;
  final WorkspaceFiles files;
  final GitReader gitReader;
  final GitMutator gitMutator;
  final PreferencesStore preferencesStore;
  final McpHubViewModel? mcpHub;
  final EditorViewModel? editor;
  final McpStudioViewModel? studio;
  final CollaborationViewModel? collaboration;
  bool editing = false;
  final _studioRuns = <String, int>{};
  final _projectRuns = <String, int>{};
  void _editorChanged() {
    if (!_shutdown) notifyListeners();
  }

  void showEditor(bool value) {
    editing = value;
    _visibility();
    notifyListeners();
  }

  final workspaces = <Workspace>[];
  final sessions = <int, TerminalSession>{};
  final restoredSessions = <int, String>{};
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
    projects?.selections.addAll(preferences.projectToolchains);
    await editor?.configureRecovery(preferences.recoverDocuments);
    editor?.dartFormatters = preferences.dartFormatters;
    _configureBlack();
    editor?.monitorExternalChanges(preferences.watchFiles);
    message = result.warning;
    // Restore only root metadata. Opening a project or starting a process
    // still requires a gesture, including after a corrupt preferences file.
    for (final root in preferences.roots) {
      if (p.isAbsolute(root) &&
          !workspaces.any((w) => p.equals(w.root, root))) {
        workspaces.add(Workspace(root));
      }
    }
    if (preferences.restoreLayout) {
      for (final item in preferences.layout) {
        final root = item['root'];
        if (root is! String || !p.isAbsolute(root)) continue;
        var owner = workspaces.where((w) => p.equals(w.root, root)).firstOrNull;
        if (owner == null) {
          owner = Workspace(root);
          workspaces.add(owner);
        }
        for (final saved
            in (item['tabs'] is List ? item['tabs'] as List : []).take(30)) {
          if (saved is! Map) continue;
          var pane = _restorePane(saved['panes'], 0);
          if (pane == null) continue;
          for (final extra in pane.sessions.skip(4).toList()) {
            pane = pane!.remove(extra);
            restoredSessions.remove(extra);
          }
          final title = saved['title'] is String
              ? saved['title'] as String
              : 'Restored terminal';
          owner.tabs.add(
            WorkspaceTab(
              ++_nextId,
              title.substring(0, title.length.clamp(0, 80)),
              pane!,
            ),
          );
        }
        owner.activeTab =
            (item['activeTab'] is int ? item['activeTab'] as int : 0).clamp(
              0,
              owner.tabs.isEmpty ? 0 : owner.tabs.length - 1,
            );
        if (item['active'] == true) activeWorkspace = workspaces.indexOf(owner);
      }
      focusedSession = tab?.panes.sessions.firstOrNull;
    }
    editor?.selectWorkspace(workspace?.root);
    notifyListeners();
  }

  PaneNode? _restorePane(Object? value, int depth) {
    if (value is! Map || depth > 3) return null;
    if (value['direction'] case final String direction) {
      final first = _restorePane(value['first'], depth + 1);
      final second = _restorePane(value['second'], depth + 1);
      if (first == null || second == null) return first ?? second;
      return SplitPane(
        direction == 'vertical'
            ? SplitDirection.vertical
            : SplitDirection.horizontal,
        first,
        second,
      );
    }
    final title = value['title'] is String ? value['title'] as String : 'Shell';
    final id = ++_nextId;
    restoredSessions[id] = title.length > 80 ? title.substring(0, 80) : title;
    return TerminalPane(id);
  }

  Map<String, Object?> _savePane(PaneNode node) => switch (node) {
    TerminalPane(:final session) => {
      'title': sessions[session]?.title ?? restoredSessions[session] ?? 'Shell',
    },
    SplitPane(:final direction, :final first, :final second) => {
      'direction': direction.name,
      'first': _savePane(first),
      'second': _savePane(second),
    },
  };

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
    editor?.selectWorkspace(workspace?.root);
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

  Future<void> closeWorkspace({bool discardEdits = false}) => guarded(() async {
    final current = workspace;
    if (current == null) return;
    if (editor?.closeWorkspace(current.root, discard: discardEdits) == false) {
      message = 'Save or discard the workspace documents before closing.';
      notifyListeners();
      return;
    }
    if (debugger?.configuration?.project.workspace == current.root) {
      await debugger?.stop();
    }
    for (final id in current.tabs.expand((t) => t.panes.sessions).toList()) {
      await closeSession(id);
    }
    workspaces.remove(current);
    studio?.forgetWorkspace(current.root);
    projects?.forgetWorkspace(current.root);
    activeWorkspace = activeWorkspace.clamp(
      0,
      workspaces.isEmpty ? 0 : workspaces.length - 1,
    );
    editor?.selectWorkspace(workspace?.root);
    fileDirectory = workspace?.root;
    previewTitle = null;
    previewText = null;
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
      await editor?.refreshOpenFiles();
      cancellation.check();
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

  Future<void> openFile(String path) => guarded(() async {
    if (busy) {
      throw const DocumentFailure(
        'Wait for the active workspace operation before opening a document.',
      );
    }
    final root = workspace?.root;
    if (root == null) return;
    final editable = editor != null && await editor!.open(root, path);
    if (_shutdown) return;
    if (!editable) {
      if (workspace?.root != root) return;
      await previewFile(path);
      if (editor?.message != null) message = editor!.message;
    } else if (workspace?.root == root) {
      editing = true;
      _visibility();
      dismissPreview();
    }
    if (!_shutdown) notifyListeners();
  });

  Future<void> openStudioProject(StudioPlan project) async {
    await studio!.studio.storage.validateProject(project);
    await openWorkspace(project.path);
    await openFile(p.join(project.path, studio!.studio.entryFile(project)));
  }

  void _reserveProjectCommand(String directory) {
    if ([..._projectRuns.keys, ..._studioRuns.keys].any(
      (path) =>
          p.equals(path, directory) ||
          p.isWithin(path, directory) ||
          p.isWithin(directory, path),
    )) {
      throw const ProjectFailure(
        'A project command or debugger is already running here. Stop it before starting another.',
      );
    }
    _projectRuns[directory] = -1;
  }

  Future<void> _checkProjectDocuments(String directory) async {
    if (editor?.opening == true) {
      throw const ProjectFailure('Wait for pending documents to open.');
    }
    final buffers =
        editor?.buffers.where((b) => p.isWithin(directory, b.path)).toList() ??
        [];
    for (final buffer in buffers) {
      if (!await editor!.synchronizeBuffer(buffer)) {
        throw const ProjectFailure(
          'Reconnect the editor before running setup.',
        );
      }
    }
    if (buffers.any((b) => b.dirty || b.saving || b.reviewRequired)) {
      throw const ProjectFailure(
        'Save project documents before running setup.',
      );
    }
  }

  Future<void> runProjectCommand(
    DevelopmentProject project,
    ProjectCommand command,
  ) async {
    final owner = workspace;
    if (_shutdown ||
        projects == null ||
        owner == null ||
        !p.equals(owner.root, project.workspace)) {
      throw const ProjectFailure(
        'Open the owning workspace before running setup.',
      );
    }
    _reserveProjectCommand(project.directory);
    try {
      await projects!.environment.validateCommand(project, command);
      await _checkProjectDocuments(project.directory);
      if (_shutdown || !workspaces.contains(owner)) {
        throw const ProjectFailure('The workspace closed.');
      }
      final session = _start(
        owner,
        command.spec,
        command.title,
        onFinished: () async {
          _projectRuns.remove(project.directory);
          if (!_shutdown && projects?.workspace == owner.root) {
            await projects!.scan(owner.root);
          }
        },
      );
      _projectRuns[project.directory] = session.id;
    } finally {
      if (_projectRuns[project.directory] == -1) {
        _projectRuns.remove(project.directory);
      }
    }
  }

  Future<void> runTask(ProjectTask task, {EditorTaskRequest? request}) async {
    void checkGrant() {
      if (request != null &&
          (!_ownsTaskRequest(request) || !identical(request.task, task))) {
        throw const EditorContextFailure(
          'This task grant was revoked or replaced before execution.',
        );
      }
    }

    checkGrant();
    final owner = workspace;
    final project = task.project;
    if (_shutdown ||
        owner == null ||
        projects == null ||
        tasks?.isPrepared(task) != true ||
        !p.equals(owner.root, project.workspace)) {
      throw const ProjectFailure(
        'Open the owning workspace and review this task again.',
      );
    }
    final chosen = projects!.selections[project.id];
    if (task.target != null &&
        projects!.discovery.projects.any(
          (nested) =>
              p.isWithin(project.directory, nested.directory) &&
              p.isWithin(nested.directory, task.target!),
        )) {
      throw const ProjectFailure(
        'Select the nested project before running its file.',
      );
    }
    if (chosen == null ||
        chosen.paths.length != task.tools.paths.length ||
        chosen.paths.entries.any((e) => task.tools[e.key] != e.value)) {
      throw const ProjectFailure(
        'Toolchains changed after task review. Prepare a new task.',
      );
    }
    if (tasks!.runs.where((t) => t.status == TaskStatus.running).length >= 4) {
      throw const ProjectFailure(
        'Stop a running task before starting more (limit: 4).',
      );
    }
    _reserveProjectCommand(project.directory);
    try {
      await projects!.environment.validateCommand(project, task.command);
      if (task.target != null) {
        await tasks!.files.validateTarget(project, task.target!);
      }
      await _checkProjectDocuments(project.directory);
      // Synchronizing the editor can await native input. Renew path checks
      // after it before starting the reviewed command.
      await projects!.environment.validateCommand(project, task.command);
      if (task.target != null) {
        await tasks!.files.validateTarget(project, task.target!);
      }
      if (_shutdown ||
          !workspaces.contains(owner) ||
          tasks?.isPrepared(task) != true ||
          !identical(chosen, projects!.selections[project.id])) {
        throw const ProjectFailure(
          'The workspace or tool selection changed. Review again.',
        );
      }
      // Other projects may have started while path and buffer checks awaited.
      await tasks!.validateConfiguration(task);
      if (_shutdown ||
          !workspaces.contains(owner) ||
          tasks?.isPrepared(task) != true ||
          !identical(chosen, projects!.selections[project.id])) {
        throw const ProjectFailure('Task ownership changed. Review again.');
      }
      // Admission and started() must share this synchronous boundary.
      if (tasks!.runs.where((t) => t.status == TaskStatus.running).length >=
          4) {
        throw const ProjectFailure(
          'Stop a running task before starting more (limit: 4).',
        );
      }
      checkGrant();
      late final TerminalSession session;
      session = _start(
        owner,
        task.command.spec,
        task.command.title,
        onFinished: () async {
          try {
            await tasks!.finished(task, session.exitCode);
          } finally {
            _projectRuns.remove(project.directory);
          }
        },
      );
      _projectRuns[project.directory] = session.id;
      tasks!.started(task, session.id);
    } finally {
      if (_projectRuns[project.directory] == -1) {
        _projectRuns.remove(project.directory);
      }
    }
  }

  Future<void> stopTask(ProjectTask task) async {
    if (task.status != TaskStatus.running) return;
    tasks?.stopping(task);
    await sessions[task.sessionId]?.close();
  }

  Future<void> startDebugger(DebugConfiguration config) async {
    final owner = workspace;
    final service = debugger;
    if (_shutdown ||
        service == null ||
        service.active ||
        _startingDebugger ||
        owner == null ||
        owner.root != config.project.workspace ||
        projects == null) {
      throw const DebugFailure(
        'Open the project and stop the active debugger before starting.',
      );
    }
    final chosen = projects!.selections[config.project.id];
    if (!identical(chosen, config.tools)) {
      throw const DebugFailure(
        'Apply and review the selected toolchain first.',
      );
    }
    _reserveProjectCommand(config.project.directory);
    _startingDebugger = true;
    _debugProject = config.project.directory;
    try {
      await projects!.environment.validateProject(config.project);
      await projects!.environment.validateSelection(config.tools);
      await _checkProjectDocuments(config.project.directory);
      if (_shutdown ||
          !workspaces.contains(owner) ||
          !identical(chosen, projects!.selections[config.project.id])) {
        throw const DebugFailure(
          'Project ownership or tools changed. Review the debug session again.',
        );
      }
      await service.start(config);
    } finally {
      _startingDebugger = false;
      if (!service.active) {
        _projectRuns.remove(config.project.directory);
        _debugProject = null;
      }
      if (!_shutdown) notifyListeners();
    }
  }

  Future<void> controlDebugger(String command) async {
    final service = debugger;
    if (service == null) return;
    if (command == 'hotReload' || command == 'hotRestart') {
      await _checkProjectDocuments(service.configuration!.project.directory);
    }
    await service.control(command);
  }

  Future<void> openDebugSource(String path, int line, int column) async {
    final config = debugger?.configuration;
    if (config == null ||
        workspace?.root != config.project.workspace ||
        editor == null) {
      return;
    }
    await _checkProjectDocuments(config.project.directory);
    final root = config.project.workspace;
    if (_shutdown ||
        !identical(config, debugger?.configuration) ||
        workspace?.root != root) {
      return;
    }
    final python = config.project.kind == ProjectKind.python;
    if (p.isWithin(root, path)) {
      await openFile(path);
    } else {
      final executable =
          config.tools[python ? ProjectTool.python : ProjectTool.dart];
      if (executable == null) {
        throw const DebugFailure(
          'Select the SDK before opening dependency source.',
        );
      }
      await editor!.open(
        root,
        path,
        sourceSpec: LanguageServerSpec(
          kind: python ? LanguageServerKind.pyright : LanguageServerKind.dart,
          workspace: root,
          root: config.project.directory,
          executable: executable,
          python: python ? executable : null,
        ),
      );
    }
    final buffer = editor!.active;
    if (buffer == null ||
        !p.equals(buffer.path, path) ||
        _shutdown ||
        !identical(config, debugger?.configuration) ||
        workspace?.root != root) {
      return;
    }
    final offset = languageOffset(buffer.controller.text, {
      'line': line - 1,
      'character': column - 1,
    });
    editor!.applyWebEdit(
      buffer,
      buffer.controller.text,
      offset,
      offset,
      buffer.webCanUndo,
      buffer.webCanRedo,
    );
    editor!.webCommand?.call('reveal');
    showEditor(true);
  }

  void showTaskTerminal(ProjectTask task) {
    final owner = workspace;
    if (owner == null || !p.equals(owner.root, task.project.workspace)) return;
    final index = owner.tabs.indexWhere(
      (t) => t.panes.sessions.contains(task.sessionId),
    );
    if (index < 0) return;
    showEditor(false);
    selectTab(index);
    focusSession(task.sessionId!);
  }

  Future<void> openSearchResult(String root, WorkspaceMatch match) =>
      guarded(() async {
        if (workspace?.root != root || !p.isWithin(root, match.path)) return;
        await openFile(match.path);
        if (workspace?.root != root) return;
        final buffer = editor?.active;
        if (buffer == null || buffer.path != match.path) return;
        final lines = buffer.controller.text.split('\n');
        final row = match.line - 1, column = match.column - 1;
        if (row < 0 ||
            row >= lines.length ||
            column < 0 ||
            column + match.text.length > lines[row].length ||
            lines[row].substring(column, column + match.text.length) !=
                match.text) {
          message = 'This result changed since the search. Search again; local edits were preserved.';
          notifyListeners();
          return;
        }
        await editor!.navigateLanguage(
          buffer,
          Uri.file(match.path).toString(),
          {'line': row, 'character': column},
        );
      });

  Future<void> openTestResult(ProjectTask task, TestCaseResult result) async {
    if (result.path == null || workspace?.root != task.project.workspace) {
      return;
    }
    await tasks!.files.validateTarget(task.project, result.path!);
    await openFile(result.path!);
    final buffer = editor?.active;
    if (buffer != null && buffer.path == result.path && result.line != null) {
      await editor!.navigateLanguage(
        buffer,
        Uri.file(result.path!).toString(),
        {
          'line': (result.line! - 1).clamp(
            0,
            buffer.controller.text.split('\n').length - 1,
          ),
          'character': 0,
        },
      );
    }
  }

  Future<void> runProjectCreation(ProjectCreation creation) async {
    final owner = workspace;
    if (_shutdown ||
        projects == null ||
        owner == null ||
        !p.equals(owner.root, creation.target.workspace)) {
      throw const ProjectFailure(
        'Open the owning workspace before creating the project.',
      );
    }
    final key = creation.target.destination;
    _reserveProjectCommand(key);
    try {
      await projects!.environment.validateProject(
        DevelopmentProject(
          workspace: owner.root,
          directory: creation.target.staging,
          name: 'creation',
          kind: creation.kind,
        ),
      );
      if (_shutdown || !workspaces.contains(owner)) {
        throw const ProjectFailure('The workspace closed.');
      }
      late final TerminalSession session;
      session = _start(
        owner,
        creation.command.spec,
        creation.command.title,
        onFinished: () async {
          try {
            final succeeded =
                session.exitCode == 0 && session.status == SessionStatus.exited;
            await projects!.environment.finishCreation(
              creation,
              publish: succeeded,
            );
            if (!_shutdown) {
              message = succeeded
                  ? 'Project created at $key. Open it from Projects and toolchains.'
                  : 'Project creation stopped before completion.';
              if (projects?.workspace == owner.root) {
                await projects!.scan(owner.root);
              }
            }
          } finally {
            _projectRuns.remove(key);
          }
        },
      );
      _projectRuns[key] = session.id;
    } finally {
      if (_projectRuns[key] == -1) _projectRuns.remove(key);
    }
  }

  Future<void> runStudioCommand(
    StudioPlan project,
    LaunchSpec spec,
    String title,
  ) async {
    if (_shutdown) throw const StudioFailure('The application is closing.');
    if ([..._studioRuns.keys, ..._projectRuns.keys].any(
      (path) =>
          p.equals(path, project.path) ||
          p.isWithin(path, project.path) ||
          p.isWithin(project.path, path),
    )) {
      throw const StudioFailure(
        'A Studio command is still running in this project. Wait for it to finish or close its terminal.',
      );
    }
    _studioRuns[project.path] = -1;
    try {
      // Reserve before filesystem awaits so a later gesture cannot overtake the
      // first command while its project is being validated.
      await studio!.studio.storage.validateProject(project);
      try {
        await _checkProjectDocuments(project.path);
      } on ProjectFailure catch (failure) {
        throw StudioFailure(failure.message);
      }
      await openWorkspace(project.path);
      if (_shutdown) throw const StudioFailure('The application is closing.');
      checkStudioBuffers(project);
      final owner = workspace;
      if (owner == null || !p.equals(owner.root, project.path)) {
        throw const StudioFailure(
          'Open the project workspace before running commands.',
        );
      }
      final session = _start(
        owner,
        spec,
        title,
        onFinished: () async {
          _studioRuns.remove(project.path);
        },
      );
      _studioRuns[project.path] = session.id;
      await _save();
    } finally {
      if (_studioRuns[project.path] == -1) _studioRuns.remove(project.path);
    }
  }

  void checkStudioBuffers(StudioPlan project) {
    if (editor?.buffers.any(
          (b) =>
              (b.dirty || b.saving) &&
              (p.equals(b.root, project.path) ||
                  p.isWithin(project.path, b.path)),
        ) ==
        true) {
      throw const StudioFailure(
        'Save the project documents before running this command.',
      );
    }
  }

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
    if (codex && collaboration != null) {
      final reservations = await collaboration!.reservations();
      if (reservations.any(
        (row) =>
            row['writer'] == 1 &&
            (p.equals(row['root'] as String, current.root) ||
                p.equals(
                  row['repository'] as String,
                  repository?.commonDirectory ?? '',
                )),
      )) {
        throw const CollaborationFailure(
          'This repository has a collaboration writer. Open its terminal from Collaboration.',
        );
      }
    }
    if (_shutdown) return;
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

  Future<void> openCollaborationTerminal(Json launch) async {
    final root = launch['root'] as String;
    await openWorkspace(root);
    final owner = workspace;
    if (_shutdown || owner == null || !p.equals(owner.root, root)) {
      throw const CollaborationFailure('Open the participant project first.');
    }
    _start(
      owner,
      LaunchSpec(
        executable: launch['executable'] as String,
        workingDirectory: root,
        arguments: (launch['arguments'] as List).cast<String>(),
        environment: Map<String, String>.from(launch['environment'] as Map),
        unsetEnvironment: (launch['unsetEnvironment'] as List).cast<String>(),
      ),
      'Codex collaboration',
    );
    await _save();
  }

  TerminalSession _start(
    Workspace owner,
    LaunchSpec spec,
    String title, {
    SplitDirection? split,
    Future<void> Function()? onFinished,
  }) {
    editing = false;
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
    if (split == null &&
        currentTab != null &&
        restoredSessions.containsKey(focusedSession)) {
      currentTab.panes = currentTab.panes.replace(
        focusedSession!,
        TerminalPane(session.id),
      );
      restoredSessions.remove(focusedSession);
    } else if (split != null &&
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
    return session;
  }

  void _sessionChanged() {
    if (!_shutdown) notifyListeners();
  }

  void _visibility() {
    final visible = editing
        ? const <int>[]
        : tab?.panes.sessions ?? const <int>[];
    for (final entry in sessions.entries) {
      entry.value.markVisible(visible.contains(entry.key));
    }
  }

  void selectTab(int index) {
    workspace?.activeTab = index;
    focusedSession = tab?.panes.sessions.firstOrNull;
    _visibility();
    notifyListeners();
    unawaited(guarded(_save));
  }

  void cycleTab(int direction) {
    if (editing && editor != null) {
      editor!.cycle(direction);
      return;
    }
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
    if (session == null && !restoredSessions.containsKey(id)) return;
    if (session != null) {
      for (final task in tasks?.runs ?? <ProjectTask>[]) {
        if (task.sessionId == id && task.status == TaskStatus.running) {
          tasks?.stopping(task);
        }
      }
      await session.close();
      session.removeListener(_sessionChanged);
      session.dispose();
      sessions.remove(id);
    }
    restoredSessions.remove(id);
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
      _start(
        owner,
        owned.spec,
        title,
        onFinished: () async {
          await owned.finish();
          if (!_shutdown && workspace == owner) await refresh();
        },
      );
    } catch (_) {
      await command?.finish();
      rethrow;
    } finally {
      busy = false;
      if (!_shutdown) notifyListeners();
    }
  });

  Future<void> removeWorktree(GitWorktree tree) => guarded(() async {
    if (busy) {
      throw const DocumentFailure('Wait for the active workspace operation.');
    }
    busy = true;
    notifyListeners();
    try {
      if (editor?.opening == true ||
          editor?.buffers.any(
                (buffer) =>
                    p.equals(buffer.root, tree.path) ||
                    p.isWithin(tree.path, buffer.path),
              ) ==
              true) {
        throw const DocumentFailure(
          'Close editor documents in this worktree and finish pending file opens before removing it.',
        );
      }
      final repo = await selectedRepository();
      await gitMutator.removeWorktree(repo, tree, [
        ?_debugProject,
        ...(await collaboration?.reservations() ?? const <Json>[]).map(
          (row) => row['root'] as String,
        ),
        ...sessions.values
            .where(
              (s) =>
                  s.status == SessionStatus.running ||
                  s.status == SessionStatus.closing,
            )
            .map((s) => s.spec.workingDirectory),
      ]);
      await refresh();
    } finally {
      busy = false;
      if (!_shutdown) notifyListeners();
    }
  });

  Future<void> updatePreferences(Preferences value) => guarded(() async {
    preferences = value;
    await editor?.configureRecovery(value.recoverDocuments);
    await _configureWatcher();
    await _save(force: true);
    notifyListeners();
  });

  Future<void> applyProjectToolchains(
    DevelopmentProject project,
    ToolchainSelection value,
  ) async {
    final selected = await projects?.apply(project, value);
    if (selected == null) return;
    for (final session in editor?.language?.sessions.values.toList() ?? []) {
      if (p.equals(session.spec.root, project.directory) &&
          p.equals(session.spec.workspace, project.workspace)) {
        await editor?.language?.stop(session.spec.id);
      }
    }
    final formatters = {...preferences.dartFormatters};
    if (project.kind != ProjectKind.python) {
      final dart = selected[ProjectTool.dart];
      // An explicit empty choice also suppresses an ancestor workspace default.
      formatters[project.directory] = dart ?? '';
    }
    await updatePreferences(
      preferences.copyWith(
        dartFormatters: formatters,
        projectToolchains: {
          ...preferences.projectToolchains,
          project.id: selected,
        },
      ),
    );
  }

  void _configureBlack() {
    editor?.blackFormatters = {
      for (final entry in preferences.projectToolchains.entries)
        if (entry.key.startsWith('python:'))
          entry.key.substring('python:'.length):
              entry.value[ProjectTool.black] ?? '',
    };
  }

  Future<void> _configureWatcher() async {
    editor?.dartFormatters = preferences.dartFormatters;
    _configureBlack();
    editor?.monitorExternalChanges(preferences.watchFiles);
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
      layout: workspaces
          .map(
            (w) => <String, Object?>{
              'root': w.root,
              'active': w == workspace,
              'activeTab': w.activeTab,
              'tabs': w.tabs
                  .map((t) => {'title': t.title, 'panes': _savePane(t.panes)})
                  .toList(),
            },
          )
          .toList(),
    );
    await preferencesStore.save(preferences);
  }

  Future<void>? _shutdownFuture;
  Future<void> shutdown() => _shutdownFuture ??= () async {
    _shutdown = true;
    tasks?.removeListener(_taskContextChanged);
    editor?.onSaved = null;
    editor?.captureProjectContext = null;
    editor?.captureTaskCatalog = null;
    editor?.prepareTaskRequest = null;
    editor?.runTaskRequest = null;
    editor?.discardTaskRequest = null;
    debugger?.onInspectorSource = null;
    await debugger?.dispose();
    await _debugChanges?.cancel();
    _selection?.cancel();
    _preview?.cancel();
    _watchDebounce?.cancel();
    await _watcher?.cancel();
    for (final session in sessions.values) {
      for (final task in tasks?.runs ?? <ProjectTask>[]) {
        if (task.sessionId == session.id && task.status == TaskStatus.running) {
          tasks?.stopping(task);
        }
      }
      await session.close();
      session.removeListener(_sessionChanged);
      session.dispose();
    }
    sessions.clear();
    await mcpHub?.disposeAsync();
    editor?.removeListener(_editorChanged);
    await editor?.disposeAsync();
    await studio?.disposeAsync();
    await projects?.disposeAsync();
    await tasks?.disposeAsync();
    await collaboration?.disposeAsync();
  }();
  @override
  Future<void> disposeAsync() async {
    await shutdown();
    await super.disposeAsync();
  }
}
