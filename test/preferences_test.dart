import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tabryo/features/preferences/domain/preferences.dart';
import 'package:tabryo/features/preferences/infrastructure/local_preferences.dart';

void main() {
  test(
    'preferences are opt-in, revocable, atomic and corruption-safe',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'tabryo-preferences-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/preferences.json');
      final store = LocalPreferencesStore(file);
      expect((await store.load()).preferences.rememberPreferences, isFalse);
      expect(await file.exists(), isFalse);
      const saved = Preferences(
        rememberPreferences: true,
        rememberWorkspaces: true,
        restoreLayout: true,
        watchFiles: true,
        theme: AppTheme.dark,
        fontSize: 18,
        roots: ['/project'],
        layout: [
          {'root': '/project', 'tabs': []},
        ],
      );
      await store.save(saved);
      final loaded = (await store.load()).preferences;
      expect(loaded.theme, AppTheme.dark);
      expect(loaded.roots, ['/project']);
      expect(loaded.watchFiles, isTrue);
      await store.save(const Preferences());
      expect((await store.load()).preferences.roots, isEmpty);
      expect(await file.readAsString(), isNot(contains('/project')));
      expect(await File('${file.path}.tmp').exists(), isFalse);
      await file.writeAsString('{broken');
      final corrupt = await store.load();
      expect(corrupt.warning, isNotNull);
      expect(corrupt.preferences.watchFiles, isFalse);
      expect(corrupt.preferences.layout, isEmpty);
    },
  );
}
