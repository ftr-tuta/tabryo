import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:tabryo/features/preferences/domain/appearance.dart';
import 'package:tabryo/features/preferences/presentation/workbench_theme.dart';
import 'package:tabryo/features/workspaces/presentation/window_coordinator.dart';
import 'package:tabryo/features/preferences/domain/preferences.dart';
import 'package:tabryo/features/preferences/infrastructure/local_preferences.dart';

void main() {
  test(
    'appearance and layouts retain independent opt-in and legacy defaults',
    () {
      final old = Preferences.fromJson({
        'version': 1,
        'rememberPreferences': true,
        'theme': 'dark',
      });
      expect(old.theme, AppTheme.dark);
      expect(old.appearance.preset, ThemePreset.tabryo);
      const custom = Preferences(
        rememberPreferences: true,
        restoreLayout: false,
        appearance: Appearance(preset: ThemePreset.ocean, primary: 0xff004477),
        activityLayouts: {
          'review': {'navigationWidth': 340},
        },
        chatDrafts: {'thread': 'draft'},
      );
      final restored = Preferences.fromJson(custom.toJson());
      expect(restored.appearance.primary, 0xff004477);
      expect(restored.chatDrafts, {'thread': 'draft'});
      expect(restored.activityLayouts, isEmpty);
      final revoked = Preferences.fromJson(
        custom
            .copyWith(rememberPreferences: false, restoreLayout: true)
            .toJson(),
      );
      expect(revoked.appearance.primary, isNull);
      expect(revoked.chatDrafts, isEmpty);
      expect(revoked.activityLayouts['review']?['navigationWidth'], 340);
    },
  );
  test('contrast correction protects both modes and reachable windows retain title controls', () {
    const bad = Appearance(
      light: {'surface': 0xffffffff, 'text': 0xffffffff, 'border': 0xffffffff},
      dark: {'surface': 0xff000000, 'text': 0xff000000},
    );
    expect(contrastIssues(bad), isNotEmpty);
    final corrected = correctContrast(bad);
    expect(contrastIssues(corrected), isEmpty);
    expect(
      contrast(
        workbenchTheme(corrected, Brightness.light).colorScheme.surface,
        workbenchTheme(corrected, Brightness.light).colorScheme.onSurface,
      ),
      greaterThanOrEqualTo(4.5),
    );
    expect(
      WindowCoordinator.reachable(const Rect.fromLTWH(2000, 20, 800, 600), [
        const Rect.fromLTWH(0, 0, 1920, 1080),
      ]),
      isFalse,
    );
    expect(
      WindowCoordinator.reachable(const Rect.fromLTWH(-1600, 20, 800, 600), [
        const Rect.fromLTWH(-1920, 0, 1920, 1080),
      ]),
      isTrue,
    );
    // A removed 200% monitor cannot leave its window apparently visible on a
    // remaining 100% monitor merely because the logical rectangles overlap.
    for (final scale in [1.0, 1.5, 2.0]) {
      expect(
        WindowCoordinator.reachable(Rect.fromLTWH(1920 / scale, 20, 800, 600), [
          const Rect.fromLTWH(0, 0, 1920, 1080),
        ], scale: scale),
        isFalse,
      );
      expect(
        WindowCoordinator.reachable(const Rect.fromLTWH(40, 20, 800, 600), [
          const Rect.fromLTWH(0, 0, 1920, 1080),
        ], scale: scale),
        isTrue,
      );
    }
  });
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
        recoverDocuments: true,
        dartFormatters: {'/project': '/sdk/bin/dart'},
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
      expect(loaded.recoverDocuments, isTrue);
      expect(loaded.dartFormatters, {'/project': '/sdk/bin/dart'});
      await store.save(const Preferences());
      expect((await store.load()).preferences.roots, isEmpty);
      expect((await store.load()).preferences.recoverDocuments, isFalse);
      expect((await store.load()).preferences.dartFormatters, isEmpty);
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
