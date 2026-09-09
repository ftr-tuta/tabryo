import 'dart:io';

import '../features/collaboration/infrastructure/local_collaboration_client.dart';
import '../features/collaboration/infrastructure/local_collaboration_service.dart';
import '../features/terminals/infrastructure/native_terminal.dart';

Future<void> runCollaborationService() async {
  try {
    final service = await LocalCollaborationService.start(
      directory: collaborationDirectory(),
      codexExecutable: findExecutable(['codex.exe', 'codex']) ?? 'codex',
      gitExecutable: findExecutable(['git.exe', 'git']) ?? 'git',
    );
    await service.done;
    exit(0);
  } catch (_) {
    // Discovery reports startup failure. Do not print configuration or tokens.
    exit(1);
  }
}
