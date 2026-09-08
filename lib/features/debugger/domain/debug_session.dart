import '../../projects/domain/project.dart';
import '../../../core/cancellation.dart';

enum DebugStatus {
  idle,
  starting,
  running,
  paused,
  stopping,
  terminated,
  failed,
}

final class DebugFailure implements Exception {
  const DebugFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

final class DebugConfiguration {
  DebugConfiguration({
    required this.project,
    required this.tools,
    required this.program,
    this.device,
    this.noDebug = false,
    this.pythonModule,
    this.django = false,
    List<String> arguments = const [],
    Map<String, List<int>> breakpoints = const {},
  }) : arguments = List.unmodifiable(arguments),
       breakpoints = Map.unmodifiable(
         breakpoints.map(
           (path, lines) => MapEntry(path, List<int>.unmodifiable(lines)),
         ),
       );
  final DevelopmentProject project;
  final ToolchainSelection tools;
  final String program;
  final String? device;
  final bool noDebug;
  final String? pythonModule;
  final bool django;
  final List<String> arguments;
  final Map<String, List<int>> breakpoints;
}

abstract interface class DebugConnection {
  Stream<Map<String, dynamic>> get events;
  Future<Map<String, dynamic>> request(
    String command, [
    Map<String, Object?> arguments = const {},
  ]);
  Future<void> close();
}

final class FlutterDevice {
  const FlutterDevice(this.id, this.name, this.platform);
  final String id;
  final String name;
  final String platform;
}

abstract interface class DebugAdapters {
  Future<DebugConnection> start(DebugConfiguration configuration);
  Future<List<FlutterDevice>> devices(
    DevelopmentProject project,
    ToolchainSelection tools,
  );
  Future<DebugTools> devTools(
    DebugConfiguration configuration,
    Uri service,
    Cancellation cancellation,
  );
}

abstract interface class DebugTools {
  Uri get uri;
  Future<void> open();
  Future<void> close();
}
