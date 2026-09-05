import 'dart:io';
import 'dart:typed_data';

import 'package:terminal_host/terminal_host.dart';

import '../domain/terminal_ports.dart';

final class NativePtyHost implements PtyHost {
  @override
  PtyProcess start(LaunchSpec spec) => _NativeProcess(
    TerminalPty.start(
      TerminalLaunchSpec(
        executable: spec.executable,
        workingDirectory: spec.workingDirectory,
        arguments: spec.arguments,
        environment: spec.environment,
        unsetEnvironment: spec.unsetEnvironment,
      ),
    ),
  );
}

final class _NativeProcess implements PtyProcess {
  _NativeProcess(this.pty);
  final TerminalPty pty;
  @override
  Stream<Uint8List> get output => pty.output;
  @override
  Future<int> get exitCode => pty.exitCode;
  @override
  Future<void> get drained => pty.drained;
  @override
  int get pid => pty.pid;
  @override
  bool write(Uint8List bytes) => pty.write(bytes);
  @override
  void resize(int rows, int columns) => pty.resize(rows, columns);
  @override
  Future<void> close() => pty.close();
}

String? findExecutable(List<String> names) {
  for (var folder in (Platform.environment['PATH'] ?? '').split(
    Platform.isWindows ? ';' : ':',
  )) {
    if (folder.startsWith('"') && folder.endsWith('"')) {
      folder = folder.substring(1, folder.length - 1);
    }
    if (folder.isEmpty || !Directory(folder).isAbsolute) continue;
    for (final name in names) {
      final file = File('$folder${Platform.pathSeparator}$name');
      if (file.existsSync()) return file.absolute.path;
    }
  }
  return null;
}

final class LocalCodexLauncher implements CodexLauncher {
  @override
  LaunchSpec shell(String directory) => LaunchSpec(
    executable: Platform.isWindows
        ? (findExecutable(['pwsh.exe', 'powershell.exe']) ??
              '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}\\System32\\WindowsPowerShell\\v1.0\\powershell.exe')
        : (Platform.environment['SHELL'] ?? '/bin/sh'),
    arguments: Platform.isWindows ? const ['-NoLogo'] : const [],
    workingDirectory: directory,
  );

  @override
  LaunchSpec? codex(String directory, {bool resume = false}) {
    final executable = findExecutable(
      Platform.isWindows ? ['codex.exe', 'codex.cmd', 'codex.bat'] : ['codex'],
    );
    return executable == null
        ? null
        : LaunchSpec(
            executable: executable,
            arguments: resume ? const ['resume'] : const [],
            workingDirectory: directory,
          );
  }
}
