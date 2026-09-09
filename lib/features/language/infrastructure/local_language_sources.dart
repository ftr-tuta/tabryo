import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../editor/domain/document_files.dart';
import '../domain/language_server.dart';

/// Source browsing follows only the selected SDK/environment and declared Dart
/// package library roots. It never runs a package or interpreter for discovery.
final class LocalLanguageSources implements LanguageSources {
  LocalLanguageSources(this.files);
  final DocumentFiles files;

  Future<String?> _text(String path) async {
    final file = File(path);
    if (!await file.exists()) return null;
    if ((await file.stat()).size > DocumentFiles.byteLimit) {
      throw const LanguageFailure('Dependency configuration is too large.');
    }
    final handle = await file.open();
    try {
      final bytes = await handle.read(DocumentFiles.byteLimit + 1);
      if (bytes.length > DocumentFiles.byteLimit) {
        throw const LanguageFailure('Dependency configuration is too large.');
      }
      return utf8.decode(bytes);
    } finally {
      await handle.close();
    }
  }

  @override
  Future<DocumentSnapshot> open(LanguageServerSpec spec, String path) async {
    if (!p.equals(
          await Directory(spec.workspace).resolveSymbolicLinks(),
          spec.workspace,
        ) ||
        !p.equals(
          await Directory(spec.root).resolveSymbolicLinks(),
          spec.root,
        )) {
      throw const LanguageFailure('The language project moved. Open it again.');
    }
    if (!p.isAbsolute(path) ||
        !p.isAbsolute(spec.executable) ||
        !(spec.kind == LanguageServerKind.clangd
            ? spec.supportsPath(path)
            : [
                '.dart',
                '.py',
                '.pyi',
              ].contains(p.extension(path).toLowerCase()))) {
      throw const LanguageFailure('Select a supported dependency source file.');
    }
    final roots = <String>[];
    if (spec.kind == LanguageServerKind.clangd) {
      if (spec.sourceRoots.length > 8 ||
          spec.sourceRoots.any((r) => !p.isAbsolute(r))) {
        throw const LanguageFailure('Invalid native dependency roots.');
      }
      roots.addAll(spec.sourceRoots);
    } else if (spec.kind == LanguageServerKind.dart) {
      roots.add(p.join(p.dirname(p.dirname(spec.executable)), 'lib'));
      final config = p.join(spec.root, '.dart_tool', 'package_config.json');
      final text = await _text(config);
      if (text != null) {
        final value = jsonDecode(text);
        if (value is! Map ||
            value['configVersion'] != 2 ||
            value['packages'] is! List ||
            (value['packages'] as List).length > 2000) {
          throw const LanguageFailure('Invalid Dart package configuration.');
        }
        for (final package in value['packages'] as List) {
          if (package is! Map || package['rootUri'] is! String) continue;
          final base = Uri.file(config).resolve(package['rootUri'] as String);
          final library = base.resolve(
            package['packageUri'] as String? ?? 'lib/',
          );
          if (library.scheme == 'file' &&
              !library.hasQuery &&
              !library.hasFragment &&
              (library.host.isEmpty || library.host == 'localhost')) {
            roots.add(library.toFilePath());
          }
        }
      }
    } else {
      if (spec.module != null) {
        roots.add(p.join(p.dirname(spec.module!), 'typeshed-fallback'));
        roots.add(p.join(p.dirname(spec.module!), 'dist', 'typeshed-fallback'));
      }
      final python = spec.python ?? spec.executable;
      final bin = p.dirname(python);
      final home = ['scripts', 'bin'].contains(p.basename(bin).toLowerCase())
          ? p.dirname(bin)
          : bin;
      final homes = [home];
      final config = await _text(p.join(home, 'pyvenv.cfg'));
      if (config != null) {
        final match = RegExp(
          r'^home\s*=\s*(.+)$',
          multiLine: true,
        ).firstMatch(config);
        if (match != null && p.isAbsolute(match.group(1)!.trim())) {
          final base = match.group(1)!.trim();
          homes.add(p.basename(base) == 'bin' ? p.dirname(base) : base);
        }
      }
      for (final home in homes) {
        roots.add(p.join(home, 'Lib'));
        final lib = Directory(p.join(home, 'lib'));
        if (await lib.exists()) {
          await for (final entry in lib.list(followLinks: false).take(128)) {
            if (entry is Directory &&
                RegExp(r'^python3\.\d+$').hasMatch(p.basename(entry.path))) {
              roots.add(entry.path);
            }
          }
        }
      }
    }
    final canonical = await File(path).resolveSymbolicLinks();
    for (final root in roots) {
      final directory = Directory(root);
      if (!await directory.exists()) continue;
      final allowed = await directory.resolveSymbolicLinks();
      if (!p.isWithin(allowed, canonical)) continue;
      final snapshot = await files.open(allowed, canonical);
      return DocumentSnapshot(
        root: spec.workspace,
        path: snapshot.path,
        text: snapshot.text,
        revision: snapshot.revision,
        newline: snapshot.newline,
        bom: snapshot.bom,
      );
    }
    throw const LanguageFailure(
      'This source is outside the selected SDK and declared dependencies.',
    );
  }
}
