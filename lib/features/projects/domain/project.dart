import '../../../core/cancellation.dart';
import '../../terminals/domain/terminal_ports.dart';

enum ProjectKind { dart, flutter, python }

enum PythonManager { uv, poetry, pip }

enum ProjectTool {
  dart,
  flutter,
  python,
  uv,
  poetry,
  pyenv,
  node,
  pyright,
  ruff,
  black,
}

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

/// Portable launch choices. SDK paths, device IDs and secrets stay local.
final class ProjectLaunchProfile {
  const ProjectLaunchProfile({
    required this.name,
    required this.program,
    this.profile = 'Script',
    this.directory = '.',
    this.arguments = const [],
    this.toolArguments = const [],
    this.flavor,
    this.flutterMode = 'debug',
    this.noDebug = false,
    this.port = 8000,
  });
  final String name;
  final String program;
  final String profile;
  final String directory;
  final List<String> arguments;
  final List<String> toolArguments;
  final String? flavor;
  final String flutterMode;
  final bool noDebug;
  final int port;
}

final class ProjectFailure implements Exception {
  const ProjectFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

final class ProjectDestination {
  const ProjectDestination({
    required this.workspace,
    required this.staging,
    required this.source,
    required this.destination,
  });
  final String workspace;
  final String staging;
  final String source;
  final String destination;
}

final class ProjectCreation {
  const ProjectCreation(this.target, this.kind, this.command);
  final ProjectDestination target;
  final ProjectKind kind;
  final ProjectCommand command;
}

abstract interface class ProjectEnvironment {
  Future<ProjectDestination> reserveDestination(String workspace, String name);
  Future<void> finishCreation(
    ProjectCreation creation, {
    required bool publish,
  });
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
