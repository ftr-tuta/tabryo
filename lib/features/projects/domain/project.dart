import '../../../core/cancellation.dart';
import '../../terminals/domain/terminal_ports.dart';

enum ProjectKind { dart, flutter, python }

enum PythonManager { uv, poetry, pip }

enum ProjectTool { dart, flutter, python, uv, poetry, pyenv }

final class DevelopmentProject {
  const DevelopmentProject({
    required this.workspace,
    required this.directory,
    required this.name,
    required this.kind,
    this.manager = PythonManager.uv,
    this.manifests = const [],
    this.versionHint,
  });
  final String workspace;
  final String directory;
  final String name;
  final ProjectKind kind;
  final PythonManager manager;
  final List<String> manifests;
  final String? versionHint;
  String get id => '${kind.name}:$directory';
}

final class ProjectDiscovery {
  const ProjectDiscovery(
    this.projects, {
    this.limited = false,
    this.warnings = const [],
  });
  final List<DevelopmentProject> projects;
  final bool limited;
  final List<String> warnings;
}

final class ToolchainSelection {
  ToolchainSelection([Map<ProjectTool, String> paths = const {}])
    : paths = Map.unmodifiable(paths);
  final Map<ProjectTool, String> paths;
  String? operator [](ProjectTool tool) => paths[tool];
  ToolchainSelection withPath(ProjectTool tool, String path) {
    final updated = {...paths};
    if (path.trim().isEmpty) {
      updated.remove(tool);
    } else {
      updated[tool] = path.trim();
    }
    return ToolchainSelection(updated);
  }

  Map<String, String> toJson() => {
    for (final entry in paths.entries) entry.key.name: entry.value,
  };
  factory ToolchainSelection.fromJson(Map json) => ToolchainSelection({
    for (final tool in ProjectTool.values)
      if (json[tool.name] case final String value when value.isNotEmpty)
        tool: value,
  });
}

final class ToolchainCandidate {
  const ToolchainCandidate(this.path, this.source);
  final String path;
  final String source;
}

final class ToolchainHints {
  const ToolchainHints(this.candidates);
  final Map<ProjectTool, List<ToolchainCandidate>> candidates;
}

final class ProjectCommand {
  const ProjectCommand({
    required this.title,
    required this.description,
    required this.spec,
    this.requiresEnvironment = false,
    this.createsEnvironment = false,
  });
  final String title;
  final String description;
  final LaunchSpec spec;
  final bool requiresEnvironment;
  final bool createsEnvironment;
}

final class ProjectFailure implements Exception {
  const ProjectFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

abstract interface class ProjectEnvironment {
  bool get windows;
  Future<ProjectDiscovery> discover(String root, Cancellation cancellation);
  Future<ToolchainHints> toolchains(DevelopmentProject project);
  Future<void> validateProject(DevelopmentProject project);
  Future<void> validateSelection(ToolchainSelection selection);
  Future<void> validateCommand(
    DevelopmentProject project,
    ProjectCommand command,
  );
}
