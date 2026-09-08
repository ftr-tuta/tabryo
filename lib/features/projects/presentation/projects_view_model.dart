import 'package:dartitect_flutter/dartitect_flutter.dart';
import 'package:path/path.dart' as p;

import '../../../core/cancellation.dart';
import '../domain/project.dart';

final class ProjectsViewModel extends DartitectViewModel {
  ProjectsViewModel(this.environment);
  final ProjectEnvironment environment;
  ProjectDiscovery discovery = const ProjectDiscovery([]);
  String? workspace;
  DevelopmentProject? selected;
  ToolchainHints hints = const ToolchainHints({});
  final selections = <String, ToolchainSelection>{};
  final activeProjects = <String, String>{};
  bool scanning = false;
  bool selecting = false;
  bool applying = false;
  String? message;
  Cancellation? _scan;
  int _selectionEpoch = 0;
  bool _closed = false;
  ToolchainSelection get selection =>
      selections[selected?.id] ?? ToolchainSelection();

  Future<void> scan(String root) async {
    _scan?.cancel();
    final cancellation = _scan = Cancellation();
    _selectionEpoch++;
    workspace = root;
    scanning = true;
    selected = null;
    hints = const ToolchainHints({});
    discovery = const ProjectDiscovery([]);
    message = null;
    notifyListeners();
    try {
      final result = await environment.discover(root, cancellation);
      cancellation.check();
      if (_closed) return;
      discovery = result;
      final project =
          discovery.projects
              .where((v) => v.id == activeProjects[root])
              .firstOrNull ??
          discovery.projects.firstOrNull;
      if (project != null) await select(project);
    } on Cancelled {
      return;
    } catch (error) {
      if (!_closed && !cancellation.isCancelled) message = '$error';
    } finally {
      if (!_closed && identical(cancellation, _scan)) {
        scanning = false;
        notifyListeners();
      }
    }
  }

  Future<void> select(DevelopmentProject project) async {
    if (_closed || !discovery.projects.contains(project)) return;
    final epoch = ++_selectionEpoch;
    selected = project;
    activeProjects[project.workspace] = project.id;
    hints = const ToolchainHints({});
    selecting = true;
    message = null;
    notifyListeners();
    try {
      final result = await environment.toolchains(project);
      if (!_closed && epoch == _selectionEpoch) hints = result;
    } catch (error) {
      if (!_closed && epoch == _selectionEpoch) message = '$error';
    } finally {
      if (!_closed && epoch == _selectionEpoch) {
        selecting = false;
        notifyListeners();
      }
    }
  }

  Future<ToolchainSelection?> apply(
    DevelopmentProject project,
    ToolchainSelection value,
  ) async {
    if (_closed || applying || !identical(project, selected)) return null;
    applying = true;
    final epoch = _selectionEpoch;
    notifyListeners();
    try {
      if (value[ProjectTool.flutter] case final flutter?
          when project.kind == ProjectKind.flutter) {
        value = value.withPath(
          ProjectTool.dart,
          p.join(
            flutter,
            'bin',
            'cache',
            'dart-sdk',
            'bin',
            environment.windows ? 'dart.exe' : 'dart',
          ),
        );
      } else if (project.kind == ProjectKind.flutter) {
        value = value.withPath(ProjectTool.dart, '');
      }
      await environment.validateProject(project);
      await environment.validateSelection(value);
      if (_closed || epoch != _selectionEpoch) return null;
      selections[project.id] = value;
      message =
          'Toolchains selected for ${project.name}. No process was started.';
      return value;
    } catch (error) {
      if (!_closed) message = '$error';
      return null;
    } finally {
      applying = false;
      if (!_closed) notifyListeners();
    }
  }

  void forgetWorkspace(String root) {
    if (workspace != root) return;
    _scan?.cancel();
    _selectionEpoch++;
    workspace = null;
    selected = null;
    discovery = const ProjectDiscovery([]);
    hints = const ToolchainHints({});
    scanning = false;
    selecting = false;
    notifyListeners();
  }

  @override
  Future<void> disposeAsync() async {
    _closed = true;
    _scan?.cancel();
    _selectionEpoch++;
    await super.disposeAsync();
  }
}
