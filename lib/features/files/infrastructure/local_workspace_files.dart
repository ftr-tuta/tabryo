import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/cancellation.dart';
import '../../../core/preview_cache.dart';
import '../domain/workspace_files.dart';

final class LocalWorkspaceFiles implements WorkspaceFiles {
  LocalWorkspaceFiles(this.cache);
  final PreviewCache cache;
  static const pageSize = 200;
  static const previewLimit = 512 * 1024;

  @override
  Future<WorkspaceSearchResults> search(
    String root,
    WorkspaceSearchQuery query,
    Cancellation cancellation,
  ) async {
    cancellation.check();
    if (query.text.isEmpty ||
        query.text.length > 256 ||
        query.text.contains('\n') ||
        query.text.contains('\r') ||
        query.pathContains.length > 256 ||
        query.excludedDirectories.length > 64) {
      throw const FormatException(
        'Enter a single-line search of 1–256 characters.',
      );
    }
    if (!p.isAbsolute(root) || !p.equals(await authorizeRoot(root), root)) {
      throw const FileSystemException(
        'Reopen the workspace at its current location.',
      );
    }
    final excluded = {
      '.git',
      '.venv',
      'venv',
      'node_modules',
      '.dart_tool',
      'build',
      '.fvm',
      '__pycache__',
      '.pytest_cache',
      '.mypy_cache',
      '.ruff_cache',
      'coverage',
      ...query.excludedDirectories,
    };
    if (excluded.any(
      (v) =>
          v.isEmpty ||
          v.length > 256 ||
          v.contains('/') ||
          v.contains('\\') ||
          v == '..',
    )) {
      throw const FormatException(
        'Exclusions must be directory names, separated by commas.',
      );
    }
    final pattern = RegExp(
      RegExp.escape(query.text),
      caseSensitive: query.caseSensitive,
      unicode: true,
    );
    final matches = <WorkspaceMatch>[];
    final queue = [(root, 0)];
    var entries = 0, directories = 0, bytesRead = 0, skipped = 0;
    var limited = false;
    WorkspaceSearchResults result() => WorkspaceSearchResults(
      List.unmodifiable(matches),
      limited: limited,
      skipped: skipped,
    );
    while (queue.isNotEmpty) {
      cancellation.check();
      final (directory, depth) = queue.removeAt(0);
      if (++directories > 512) {
        limited = true;
        break;
      }
      try {
        if (!p.equals(
          await Directory(directory).resolveSymbolicLinks(),
          directory,
        )) {
          skipped++;
          continue;
        }
        await for (final entity in Directory(
          directory,
        ).list(followLinks: false)) {
          cancellation.check();
          if (++entries > 12000) {
            limited = true;
            return result();
          }
          if (entity is Directory) {
            if (!excluded.contains(p.basename(entity.path))) {
              if (depth < 6) {
                queue.add((entity.path, depth + 1));
              } else {
                limited = true;
              }
            }
            continue;
          }
          if (entity is! File ||
              !p
                  .relative(entity.path, from: root)
                  .toLowerCase()
                  .contains(query.pathContains.toLowerCase())) {
            continue;
          }
          try {
            if (!p.equals(await entity.resolveSymbolicLinks(), entity.path) ||
                await entity.length() > previewLimit) {
              skipped++;
              continue;
            }
            final handle = await entity.open();
            late List<int> bytes;
            try {
              bytes = await handle.read(previewLimit + 1);
            } finally {
              await handle.close();
            }
            cancellation.check();
            bytesRead += bytes.length;
            if (bytesRead > 32 * 1024 * 1024) {
              limited = true;
              return result();
            }
            if (bytes.length > previewLimit || bytes.contains(0)) {
              skipped++;
              continue;
            }
            final text = utf8.decode(bytes).replaceFirst(RegExp('^\uFEFF'), '');
            final lines = const LineSplitter().convert(text);
            for (var index = 0; index < lines.length; index++) {
              final line = lines[index];
              for (final match in pattern.allMatches(line)) {
                final start = (match.start - 60).clamp(0, line.length);
                final end = (match.end + 120).clamp(start, line.length);
                matches.add(
                  WorkspaceMatch(
                    path: entity.path,
                    line: index + 1,
                    column: match.start + 1,
                    text: match.group(0)!,
                    preview:
                        '${start > 0 ? '…' : ''}${line.substring(start, end)}${end < line.length ? '…' : ''}',
                  ),
                );
                if (matches.length >= 500) {
                  limited = true;
                  return result();
                }
              }
            }
          } on FileSystemException {
            skipped++;
          } on FormatException {
            skipped++;
          }
        }
      } on FileSystemException {
        skipped++;
      }
    }
    return result();
  }

  @override
  Future<String> authorizeRoot(String path) async {
    final root = await Directory(path).resolveSymbolicLinks();
    if (!await Directory(root).exists()) {
      throw FileSystemException('Choose an existing folder.', path);
    }
    return root;
  }

  Future<String> _resolve(String root, String path) async {
    final canonical = await File(path).resolveSymbolicLinks();
    if (!p.equals(root, canonical) && !p.isWithin(root, canonical)) {
      throw FileSystemException(
        'This link leaves the workspace. Open its destination as a separate workspace to authorize it.',
        path,
      );
    }
    return canonical;
  }

  @override
  Future<FilePage> list(
    String root,
    String directory, {
    int offset = 0,
    Cancellation? cancellation,
  }) async {
    final canonical = await _resolve(root, directory);
    final entries = <WorkspaceEntry>[];
    var seen = 0;
    var hasMore = false;
    await for (final entity in Directory(canonical).list(followLinks: false)) {
      cancellation?.check();
      if (seen++ < offset) continue;
      if (entries.length == pageSize) {
        hasMore = true;
        break;
      }
      entries.add(
        WorkspaceEntry(
          entity.path,
          p.basename(entity.path),
          directory: entity is Directory,
          link: entity is Link,
        ),
      );
    }
    entries.sort(
      (a, b) => a.directory != b.directory
          ? (a.directory ? -1 : 1)
          : a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
    return FilePage(entries, hasMore);
  }

  @override
  Future<FilePreview> preview(
    String root,
    String path, {
    Cancellation? cancellation,
  }) async {
    final canonical = await _resolve(root, path);
    cancellation?.check();
    final file = File(canonical);
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file) {
      throw FileSystemException('Select a regular file.', path);
    }
    final key =
        '$canonical:${stat.modified.microsecondsSinceEpoch}:${stat.size}';
    final cached = cache.get(key);
    if (cached != null) {
      return FilePreview(path, cached, truncated: stat.size > previewLimit);
    }
    final handle = await file.open();
    try {
      final bytes = await handle.read(previewLimit + 4);
      cancellation?.check();
      if (bytes.contains(0)) {
        return FilePreview(
          path,
          'Binary file — preview is unavailable (${stat.size} bytes).',
          binary: true,
        );
      }
      // Trim only a potentially incomplete UTF-8 code point at the byte limit.
      var length = bytes.length > previewLimit ? previewLimit : bytes.length;
      if (stat.size > length) {
        while (length > 0 &&
            length < bytes.length &&
            bytes[length] & 0xc0 == 0x80) {
          length--;
        }
      }
      try {
        final text = utf8.decode(bytes.sublist(0, length));
        cache.put(key, text);
        return FilePreview(path, text, truncated: stat.size > length);
      } on FormatException {
        return FilePreview(
          path,
          'This file is not valid UTF-8. No lossy preview was generated.',
          invalidUtf8: true,
        );
      }
    } finally {
      await handle.close();
    }
  }

  @override
  Stream<void> watch(String root) =>
      Directory(root).watch(recursive: false).map((_) {
        cache.clear();
      });
}
