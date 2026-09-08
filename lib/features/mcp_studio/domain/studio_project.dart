import '../../terminals/domain/terminal_ports.dart';

enum StudioLanguage { dart, python, typescript }

final class StudioPlan {
  StudioPlan({
    required this.parent,
    required this.path,
    required this.name,
    required this.language,
    required this.runtime,
    required Map<String, String> files,
  }) : files = Map.unmodifiable(files);
  final String parent;
  final String path;
  final String name;
  final StudioLanguage language;
  final String runtime;
  final Map<String, String> files;
}

final class StudioCommand {
  StudioCommand(this.title, this.spec, {this.installs = false});
  final String title;
  final LaunchSpec spec;
  final bool installs;
}

final class StudioFailure implements Exception {
  const StudioFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

abstract interface class StudioStorage {
  bool get windows;
  String? runtimeHint(StudioLanguage language);
  String? npmCli(String node);
  Future<void> validateParent(String parent);
  Future<void> publish(StudioPlan plan);
  Future<void> validateProject(StudioPlan plan);
  Future<void> validateExecutable(String path);
  Future<void> validateFile(String path);
}
