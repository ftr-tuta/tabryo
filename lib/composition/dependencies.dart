import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../core/preview_cache.dart';
import '../features/collaboration/infrastructure/local_collaboration_client.dart';
import '../features/collaboration/presentation/collaboration_view_model.dart';
import '../features/editor/infrastructure/local_document_files.dart';
import '../features/editor/infrastructure/local_document_recovery.dart';
import '../features/editor/infrastructure/local_dart_formatter.dart';
import '../features/editor/infrastructure/bundled_editor_assets.dart';
import '../features/editor/presentation/editor_view_model.dart';
import '../features/mcp_studio/application/mcp_studio.dart';
import '../features/mcp_studio/infrastructure/local_studio_storage.dart';
import '../features/mcp_studio/presentation/mcp_studio_view_model.dart';
import '../features/files/infrastructure/local_workspace_files.dart';
import '../features/git/infrastructure/local_git.dart';
import '../features/preferences/infrastructure/local_preferences.dart';
import '../features/projects/infrastructure/local_project_environment.dart';
import '../features/projects/presentation/projects_view_model.dart';
import '../features/terminals/infrastructure/native_terminal.dart';
import '../features/terminals/infrastructure/local_text_clipboard.dart';
import '../features/workspaces/presentation/workbench_view_model.dart';
import '../features/codex/infrastructure/local_codex_connection.dart';
import '../features/mcp/application/mcp_hub.dart';
import '../features/mcp/presentation/mcp_hub_view_model.dart';

WorkbenchViewModel createWorkbench() {
  final cache = PreviewCache();
  final git = LocalGit(
    executable: findExecutable(['git.exe', 'git']) ?? 'git',
    cache: cache,
  );
  return WorkbenchViewModel(
    projects: ProjectsViewModel(LocalProjectEnvironment()),
    collaboration: Platform.isWindows
        ? CollaborationViewModel(LocalCollaborationClient())
        : null,
    host: NativePtyHost(),
    clipboard: LocalTextClipboard(),
    launcher: LocalCodexLauncher(),
    files: LocalWorkspaceFiles(cache),
    editor: EditorViewModel(
      LocalDocumentFiles(cache),
      recovery: LocalDocumentRecovery.forUser(),
      formatter: LocalDartFormatter(),
      webAssets: BundledEditorAssets(
        load: (name) async {
          final data = await rootBundle.load(name);
          return data.buffer.asUint8List(
            data.offsetInBytes,
            data.lengthInBytes,
          );
        },
        list: () async =>
            (await AssetManifest.loadFromAssetBundle(rootBundle)).listAssets(),
        profileDirectory: p.join(
          Platform.isWindows
              ? Platform.environment['LOCALAPPDATA']!
              : (Platform.environment['XDG_CACHE_HOME'] ??
                    p.join(Platform.environment['HOME']!, '.cache')),
          'Tabryo',
          'editor-webview',
        ),
      ),
    ),
    studio: McpStudioViewModel(McpStudio(LocalStudioStorage())),
    gitReader: git,
    gitMutator: git,
    preferencesStore: LocalPreferencesStore.forUser(),
    mcpHub: McpHubViewModel(
      McpHub(
        LocalCodexConnection(
          executable: findExecutable(['codex.exe', 'codex']),
        ),
      ),
    ),
  );
}
