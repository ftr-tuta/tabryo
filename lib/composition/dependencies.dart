import '../core/preview_cache.dart';
import '../features/files/infrastructure/local_workspace_files.dart';
import '../features/git/infrastructure/local_git.dart';
import '../features/preferences/infrastructure/local_preferences.dart';
import '../features/terminals/infrastructure/native_terminal.dart';
import '../features/workspaces/presentation/workbench_view_model.dart';

WorkbenchViewModel createWorkbench() {
  final cache = PreviewCache();
  final git = LocalGit(
    executable: findExecutable(['git.exe', 'git']) ?? 'git',
    cache: cache,
  );
  return WorkbenchViewModel(
    host: NativePtyHost(),
    launcher: LocalCodexLauncher(),
    files: LocalWorkspaceFiles(cache),
    gitReader: git,
    gitMutator: git,
    preferencesStore: LocalPreferencesStore.forUser(),
  );
}
