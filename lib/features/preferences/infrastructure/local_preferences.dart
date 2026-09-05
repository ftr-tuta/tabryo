import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/cancellation.dart';
import '../domain/preferences.dart';

final class LocalPreferencesStore implements PreferencesStore {
  LocalPreferencesStore(this.file);
  final File file;
  final _writes = AsyncGate(1);

  factory LocalPreferencesStore.forUser() => LocalPreferencesStore(
    File(
      p.join(
        Platform.isWindows
            ? (Platform.environment['LOCALAPPDATA'] ??
                  Directory.systemTemp.path)
            : (Platform.environment['XDG_CONFIG_HOME'] ??
                  p.join(
                    Platform.environment['HOME'] ?? Directory.systemTemp.path,
                    '.config',
                  )),
        'Tabryo',
        'preferences.json',
      ),
    ),
  );

  @override
  Future<PreferencesLoad> load() async {
    try {
      if (!await file.exists()) return const PreferencesLoad(Preferences());
      if (await file.length() > 256 * 1024) {
        throw const FormatException('Preferences too large.');
      }
      return PreferencesLoad(
        Preferences.fromJson(
          jsonDecode(await file.readAsString()) as Map<String, dynamic>,
        ),
      );
    } catch (_) {
      return const PreferencesLoad(
        Preferences(),
        warning: 'Preferences could not be read. Safe defaults were loaded; no command was restored.',
      );
    }
  }

  @override
  Future<void> save(Preferences preferences) async {
    final release = await _writes.acquire();
    try {
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(
        const JsonEncoder.withIndent('  ').convert(preferences.toJson()),
        flush: true,
      );
      await temporary.rename(file.path);
    } finally {
      release();
    }
  }
}
