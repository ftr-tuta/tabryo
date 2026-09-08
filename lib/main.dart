import 'package:flutter/material.dart';
import 'package:dartitect_flutter/dartitect_flutter.dart';

import 'composition/dependencies.dart';
import 'composition/collaboration_service.dart';
import 'features/preferences/domain/preferences.dart';
import 'features/workspaces/presentation/workbench_view_model.dart';
import 'features/workspaces/presentation/workbench_screen.dart';
import 'features/editor/presentation/monaco_editor.dart';

void main(List<String> arguments) {
  if (arguments.contains('--collaboration-service')) {
    runCollaborationService();
  } else {
    runApp(const TabryoApp());
  }
}

final class TabryoApp extends StatelessWidget {
  const TabryoApp({this.createViewModel, super.key});
  final WorkbenchViewModel Function()? createViewModel;
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
        themeMode: switch (model.preferences.theme) {
          AppTheme.system => ThemeMode.system,
          AppTheme.dark => ThemeMode.dark,
          AppTheme.light => ThemeMode.light,
        },
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff347d70)),
          useMaterial3: true,
          visualDensity: VisualDensity.compact,
        ),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xff73d9b5),
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
          visualDensity: VisualDensity.compact,
        ),
        home: WorkbenchScreen(model: model),
      ),
    ),
  );
}
