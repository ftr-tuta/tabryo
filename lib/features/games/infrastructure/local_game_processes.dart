import 'dart:io';

import '../../../core/owned_process.dart';
import '../../../core/tool_environment.dart';
import '../../terminals/domain/terminal_ports.dart';
import '../domain/game_workspace.dart';

final class LocalGameProcesses implements GameProcesses {
  @override
  Future<GameProcess> start(
    LaunchSpec spec, {
    String? environmentScript,
  }) async {
    final buildEnvironment = await nativeToolEnvironment(
      environmentScript,
      spec.workingDirectory,
    );
    var executable = spec.executable;
    var arguments = spec.arguments;
    if (Platform.isWindows &&
        (executable.toLowerCase().endsWith('.bat') ||
            executable.toLowerCase().endsWith('.cmd'))) {
      arguments = windowsBatchArguments(executable, arguments);
      executable =
          '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}\\System32\\cmd.exe';
    }
    final child = await OwnedProcess.start(
      executable,
      arguments,
      spec.workingDirectory,
      environment: {...buildEnvironment, ...spec.environment},
      excludedEnvironment: spec.unsetEnvironment.toSet(),
    );
    return _LocalGameProcess(child);
  }
}

final class _LocalGameProcess implements GameProcess {
  _LocalGameProcess(this.child);
  final OwnedProcess child;
  @override
  int get pid => child.process.pid;
  @override
  Stream<List<int>> get stdout => child.process.stdout;
  @override
  Stream<List<int>> get stderr => child.process.stderr;
  @override
  Future<int> get exitCode => child.process.exitCode;
  @override
  Future<void> input(String? text) async {
    if (text != null) child.process.stdin.write(text);
    await child.process.stdin.close();
  }

  @override
  Future<void> close() => child.close();
}
