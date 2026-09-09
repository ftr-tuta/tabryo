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
    this.attachUri,
    this.attachPid,
    this.workingDirectory,
    this.flavor,
    this.flutterMode = 'debug',
    this.sharedConfigurationSource,
    List<String> arguments = const [],
    List<String> toolArguments = const [],
    Map<String, String> environment = const {},
    Map<String, List<DebugBreakpoint>> breakpoints = const {},
  }) : arguments = List.unmodifiable(arguments),
       toolArguments = List.unmodifiable(toolArguments),
       environment = Map.unmodifiable(environment),
       breakpoints = Map.unmodifiable(
         breakpoints.map(
           (path, lines) =>
               MapEntry(path, List<DebugBreakpoint>.unmodifiable(lines)),
         ),
       );
  final DevelopmentProject project;
  final ToolchainSelection tools;
  final String program;
  final String? device;
  final bool noDebug;
  final String? pythonModule;
  final bool django;
  final Uri? attachUri;
  final int? attachPid;
  bool get isAttach => attachUri != null || attachPid != null;
  bool get codeLldb =>
      project.native &&
      tools[ProjectTool.lldbDap] == null &&
      tools[ProjectTool.codeLldb] != null;
  final String? workingDirectory;
  String get directory => workingDirectory ?? project.directory;
  final String? flavor;
  final String flutterMode;
  final String? sharedConfigurationSource;
  final List<String> arguments;
  final List<String> toolArguments;
  final Map<String, String> environment;
  final Map<String, List<DebugBreakpoint>> breakpoints;
}

final class DebugBreakpoint {
  const DebugBreakpoint(this.line, {this.condition});
  final int line;
  final String? condition;
  Map<String, Object?> toJson() => {
    'line': line,
    if (condition != null) 'condition': condition,
  };
}

final class DebugWatch {
  const DebugWatch(this.expression, {this.value, this.error});
  final String expression;
  final String? value;
  final String? error;
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

abstract interface class FlutterDeviceDiscovery {
  List<FlutterDevice> get devices;
  String? get error;
  Stream<void> get changes;
  Future<void> close();
}

abstract interface class DebugAdapters {
  Future<DebugConnection> start(DebugConfiguration configuration);
  Future<List<FlutterDevice>> devices(
    DevelopmentProject project,
    ToolchainSelection tools,
  );
  Future<FlutterDeviceDiscovery> watchDevices(
    DevelopmentProject project,
    ToolchainSelection tools,
    Cancellation cancellation,
  );
  Future<DebugTools> devTools(
    DebugConfiguration configuration,
    Uri service,
    Cancellation cancellation,
  );
}

abstract interface class DebugTools {
  Uri get uri;
  Uri get dtdUri;
  Stream<DebugSourceLocation> get sourceLocations;
  Future<void> selectWidget(bool enabled);
  Future<DebugSourceLocation> selectedWidgetSource();
  Future<void> open();
  Future<void> close();
}

final class DebugSourceLocation {
  const DebugSourceLocation(this.path, this.line, this.column);
  final String path;
  final int line;
  final int column;

  static DebugSourceLocation? fromInspector(Object? value) {
    if (value is! Map) return null;
    final file = value['fileUri'] ?? value['file'];
    final line = value['line'];
    final column = value['column'];
    if (file is! String ||
        file.length > 32768 ||
        !file.startsWith('file:///') ||
        line is! int ||
        line < 1 ||
        line > 10000000 ||
        column is! int ||
        column < 1 ||
        column > 10000000) {
      return null;
    }
    final uri = Uri.tryParse(file);
    if (uri == null ||
        uri.scheme != 'file' ||
        uri.host.isNotEmpty ||
        !uri.hasAbsolutePath ||
        uri.path.contains('\u0000') ||
        uri.hasQuery ||
        uri.hasFragment ||
        file.contains('\u0000')) {
      return null;
    }
    try {
      final path = uri.toFilePath();
      if (path.contains('\u0000')) return null;
      return DebugSourceLocation(path, line, column);
    } on UnsupportedError {
      return null;
    } on ArgumentError {
      return null;
    }
  }
}
