import 'package:path/path.dart' as p;

import '../../projects/domain/project.dart';
import '../domain/debug_session.dart';

DebugConfiguration debugProfile({
  required DevelopmentProject project,
  required ToolchainSelection tools,
  required String program,
  String profile = 'Script',
  String? device,
  bool noDebug = false,
  int port = 8000,
  List<String> arguments = const [],
  List<String> toolArguments = const [],
  Map<String, String> environment = const {},
  String? workingDirectory,
  Uri? attachUri,
  int? attachPid,
  String? flavor,
  String flutterMode = 'debug',
  String? sharedConfigurationSource,
  Map<String, List<DebugBreakpoint>> breakpoints = const {},
}) {
  if (!['Script', 'Django', 'FastAPI'].contains(profile) ||
      (profile != 'Script' && project.kind != ProjectKind.python)) {
    throw const DebugFailure('Choose a profile supported by this project.');
  }
  if (project.kind == ProjectKind.flutter &&
      attachUri == null &&
      (device == null || device.isEmpty)) {
    throw const DebugFailure('Discover and choose a Flutter device first.');
  }
  if (port < 1 || port > 65535) {
    throw const DebugFailure('Choose a server port between 1 and 65535.');
  }
  String? module;
  var launchArgs = arguments;
  if (profile == 'FastAPI' && attachUri == null) {
    final relative = p.relative(
      program,
      from: workingDirectory ?? project.directory,
    );
    final name = p.withoutExtension(relative).split(p.separator);
    if (p.extension(program) != '.py' ||
        name.any((s) => !RegExp(r'^[A-Za-z_]\w*$').hasMatch(s))) {
      throw const DebugFailure(
        'FastAPI requires a project Python module, such as app/main.py, exporting app.',
      );
    }
    module = 'uvicorn';
    launchArgs = [
      '${name.join('.')}:app',
      '--host',
      '127.0.0.1',
      '--port',
      '$port',
      ...arguments,
    ];
  } else if (profile == 'Django' && attachUri == null) {
    launchArgs = ['runserver', '127.0.0.1:$port', '--noreload', ...arguments];
  }
  return DebugConfiguration(
    project: project,
    tools: tools,
    program: program,
    arguments: launchArgs,
    pythonModule: module,
    django: profile == 'Django',
    device: device,
    noDebug: noDebug,
    attachUri: attachUri,
    attachPid: attachPid,
    workingDirectory: workingDirectory,
    environment: environment,
    toolArguments: toolArguments,
    flavor: flavor,
    flutterMode: flutterMode,
    sharedConfigurationSource: sharedConfigurationSource,
    breakpoints: breakpoints,
  );
}
