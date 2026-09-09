import 'package:flutter/material.dart';
import 'package:dartitect_flutter/dartitect_flutter.dart';
import 'package:multiview_desktop/multiview_desktop.dart';

import 'composition/dependencies.dart';
import 'composition/collaboration_service.dart';
import 'features/preferences/domain/preferences.dart';
import 'features/preferences/presentation/workbench_theme.dart';
import 'features/workspaces/presentation/workbench_view_model.dart';
import 'features/workspaces/presentation/workbench_screen.dart';
import 'features/workspaces/presentation/window_coordinator.dart';
import 'features/editor/presentation/monaco_editor.dart';

void main(List<String> arguments) {
  if (arguments.contains('--collaboration-service')) {
    runCollaborationService();
  } else {
    final windows = WindowCoordinator();
    runMultiApp(
      home: (_, _) => TabryoApp(windows: windows),
      config: MultiAppConfig(
        observers: [windows],
        generalParams: const MultiPlatformParams(enableDynamicAnchor: false),
        globalWindowOptions: const WindowOptions(
          title: 'Tabryo',
          size: Size(1280, 800),
          minimumSize: Size(680, 480),
        ),
      ),
    );
  }
}

final class TabryoApp extends StatelessWidget {
  const TabryoApp({this.createViewModel, this.windows, super.key});
  final WorkbenchViewModel Function()? createViewModel;
  final WindowCoordinator? windows;
  @override
  Widget build(BuildContext context) => ViewModelHost.create(
    create: () => (createViewModel ?? createWorkbench)()..initialize(),
    // MaterialApp uses the captured model's theme; this subtree is dynamic.
    // ignore: dartitect_dt3142
    builder: (_, model) => ListenableBuilder(
      listenable: model,
      builder: (_, _) => MaterialApp(
        title: 'Tabryo',
        debugShowCheckedModeBanner: false,
        navigatorObservers: [editorRoutes],
        themeMode: switch (model.displayPreferences.theme) {
          AppTheme.system => ThemeMode.system,
          AppTheme.dark => ThemeMode.dark,
          AppTheme.light => ThemeMode.light,
        },
        theme: workbenchTheme(
          model.displayPreferences.appearance,
          Brightness.light,
        ),
        darkTheme: workbenchTheme(
          model.displayPreferences.appearance,
          Brightness.dark,
        ),
        home: WorkbenchScreen(model: model, windows: windows),
      ),
    ),
  );
}
