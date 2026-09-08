import 'package:dartitect_flutter/dartitect_flutter.dart';
import 'package:path/path.dart' as p;

import '../application/mcp_studio.dart';
import '../domain/studio_project.dart';

final class McpStudioViewModel extends DartitectViewModel {
  McpStudioViewModel(this.studio);
  final McpStudio studio;
  String? workspace;
  StudioPlan? preview;
  StudioPlan? selected;
  final _projects = <StudioPlan>[];
  List<StudioPlan> get projects => List.unmodifiable(_projects);
  String? message;
  bool busy = false;
  bool _closed = false;
  void _notify() {
    if (!_closed) notifyListeners();
  }

  void selectWorkspace(String root) {
    if (busy || _closed) return;
    workspace = root;
    preview = null;
    message = null;
    _notify();
  }

  void select(StudioPlan project) {
    if (!_projects.contains(project)) return;
    selected = project;
    _notify();
  }

  void invalidatePreview() {
    preview = null;
    _notify();
  }

  Future<bool> prepare(
    String name,
    StudioLanguage language,
    String runtime,
  ) async {
    if (busy || _closed || workspace == null) return false;
    busy = true;
    message = null;
    preview = null;
    _notify();
    try {
      preview = await studio.prepare(workspace!, name, language, runtime);
      return true;
    } catch (error) {
      message = '$error';
      return false;
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<bool> create() async {
    final plan = preview;
    if (plan == null || busy || _closed) return false;
    busy = true;
    message = null;
    _notify();
    try {
      final project = await studio.create(plan);
      _projects.add(project);
      selected = project;
      message = 'Project created. Open its source, then review and run the commands in order.';
      return true;
    } catch (error) {
      message = '$error';
      return false;
    } finally {
      preview = null;
      busy = false;
      _notify();
    }
  }

  Future<void> changeRuntime(String runtime) async {
    final project = selected;
    if (project == null || busy || _closed) return;
    busy = true;
    _notify();
    try {
      await studio.storage.validateExecutable(runtime);
      final updated = StudioPlan(
        parent: project.parent,
        path: project.path,
        name: project.name,
        language: project.language,
        runtime: runtime,
        files: project.files,
      );
      _projects[_projects.indexOf(project)] = updated;
      selected = updated;
      message =
          'Runtime updated for this session. Project files were preserved.';
    } catch (error) {
      message = '$error';
    } finally {
      busy = false;
      _notify();
    }
  }

  void forgetWorkspace(String root) {
    _projects.removeWhere(
      (project) =>
          p.equals(project.parent, root) || p.equals(project.path, root),
    );
    if (!_projects.contains(selected)) selected = _projects.lastOrNull;
    preview = null;
    if (p.equals(workspace ?? '', root)) workspace = null;
    _notify();
  }

  @override
  Future<void> disposeAsync() async {
    _closed = true;
    await super.disposeAsync();
  }
}
