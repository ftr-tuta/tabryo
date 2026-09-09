import 'dart:io';

import 'package:path/path.dart' as p;

import '../../terminals/infrastructure/native_terminal.dart';
import '../domain/studio_project.dart';

final class LocalStudioStorage implements StudioStorage {
  @override
  bool get windows => Platform.isWindows;

  @override
  String? npmCli(String node) {
    final adjacent = p.join(
      p.dirname(node),
      windows ? 'node_modules' : '../lib/node_modules',
      'npm',
      'bin',
      'npm-cli.js',
    );
    if (File(adjacent).existsSync()) return p.normalize(adjacent);
    final npm = findExecutable(windows ? ['npm.cmd'] : ['npm']);
    if (npm == null) return null;
    final candidate = windows
        ? p.join(p.dirname(npm), 'node_modules', 'npm', 'bin', 'npm-cli.js')
        : npm;
    return File(candidate).existsSync() ? candidate : null;
  }

  @override
  String? runtimeHint(StudioLanguage language) {
    final executable = findExecutable(switch (language) {
      StudioLanguage.dart => windows ? ['dart.exe', 'dart.bat'] : ['dart'],
      StudioLanguage.python => windows ? ['python.exe'] : ['python3', 'python'],
      StudioLanguage.typescript => windows ? ['node.exe'] : ['node'],
    });
    if (executable == null) return null;
    if (language == StudioLanguage.dart) {
      final native = p.join(
        p.dirname(executable),
        'cache',
        'dart-sdk',
        'bin',
        windows ? 'dart.exe' : 'dart',
      );
      if (File(native).existsSync()) return native;
      return executable.endsWith('.bat') ? null : executable;
    }
    return executable;
  }

  @override
  Future<void> validateParent(String parent) async {
    if (!p.isAbsolute(parent) ||
        !p.equals(await Directory(parent).resolveSymbolicLinks(), parent)) {
      throw const StudioFailure(
        'The workspace moved. Open its current directory again.',
      );
    }
  }

  @override
  Future<void> validateProject(StudioPlan plan) async {
    await validateParent(plan.parent);
    if (!p.isWithin(plan.parent, plan.path) ||
        !p.equals(
          await Directory(plan.path).resolveSymbolicLinks(),
          plan.path,
        )) {
      throw const StudioFailure(
        'The project directory changed. Open the current workspace again.',
      );
    }
  }

  @override
  Future<void> validateExecutable(String path) async {
    if (!p.isAbsolute(path) ||
        !await File(path).exists() ||
        (windows && p.extension(path).toLowerCase() != '.exe')) {
      throw const StudioFailure(
        'Runtime unavailable. Select an installed native executable (not a shell script), then review the project again.',
      );
    }
  }

  @override
  Future<void> validateFile(String path) async {
    if (!p.isAbsolute(path) || !await File(path).exists()) {
      throw StudioFailure(
        'Required file unavailable: $path. Complete the preceding installation/build step.',
      );
    }
  }

  @override
  Future<void> publish(StudioPlan plan) async {
    await validateParent(plan.parent);
    if (!p.equals(p.dirname(plan.path), plan.parent) ||
        await FileSystemEntity.type(plan.path, followLinks: false) !=
            FileSystemEntityType.notFound) {
      throw const StudioFailure(
        'The destination already exists. Choose a new project folder.',
      );
    }
    final staging = await Directory(plan.parent).createTemp('.tabryo-project-');
    final files = <File>[];
    final directories = <Directory>[];
    var published = false;
    try {
      for (final entry in plan.files.entries) {
        final target = p.normalize(p.join(staging.path, entry.key));
        if (p.isAbsolute(entry.key) || !p.isWithin(staging.path, target)) {
          throw const StudioFailure(
            'The project contains an invalid file path.',
          );
        }
        final parent = Directory(p.dirname(target));
        if (!await parent.exists()) {
          await parent.create();
          directories.add(parent);
        }
        final file = await File(target).create(exclusive: true);
        files.add(file);
        await file.writeAsString(entry.value, flush: true);
      }
      await validateParent(plan.parent);
      if (await FileSystemEntity.type(plan.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw const StudioFailure(
          'The destination appeared during creation. Nothing was overwritten.',
        );
      }
      // Directory rename cannot replace a populated destination. Staging never
      // writes inside a directory that existed when the user reviewed the plan.
      await staging.rename(plan.path);
      published = true;
    } finally {
      if (!published) {
        for (final file in files.reversed) {
          if (await file.exists()) await file.delete();
        }
        for (final directory in directories.reversed) {
          await directory.delete();
        }
        await staging.delete();
      }
    }
  }
}
