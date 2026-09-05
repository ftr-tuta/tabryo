import 'package:flutter/material.dart';
import 'package:dartitect_flutter/dartitect_flutter.dart';

import 'composition/dependencies.dart';
import 'features/preferences/domain/preferences.dart';
import 'features/workspaces/presentation/workbench_view_model.dart';
import 'features/workspaces/presentation/workbench_screen.dart';

void main() => runApp(const TabryoApp());

final class TabryoApp extends StatelessWidget {
  const TabryoApp({this.createViewModel, super.key});
  final WorkbenchViewModel Function()? createViewModel;
  @override
  Widget build(BuildContext context) => ViewModelHost.create(
    create: () => (createViewModel ?? createWorkbench)()..initialize(),
    builder: (_, model) => ListenableBuilder(
      listenable: model,
      builder: (_, _) => MaterialApp(
        title: 'Tabryo',
        debugShowCheckedModeBanner: false,
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
