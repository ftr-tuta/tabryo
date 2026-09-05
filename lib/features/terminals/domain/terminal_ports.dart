import 'dart:typed_data';

final class LaunchSpec {
  const LaunchSpec({
    required this.executable,
    required this.workingDirectory,
    this.arguments = const [],
    this.environment = const {},
    this.unsetEnvironment = const [],
  });
  final String executable;
  final String workingDirectory;
  final List<String> arguments;
  final Map<String, String> environment;
  final List<String> unsetEnvironment;
}

abstract interface class PtyProcess {
  Stream<Uint8List> get output;
  Future<int> get exitCode;
  Future<void> get drained;
  int get pid;
  bool write(Uint8List bytes);
  void resize(int rows, int columns);
  Future<void> close();
}

abstract interface class PtyHost {
  PtyProcess start(LaunchSpec spec);
}

abstract interface class CodexLauncher {
  LaunchSpec shell(String directory);
  LaunchSpec? codex(String directory, {bool resume = false});
}
