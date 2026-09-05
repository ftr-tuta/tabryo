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
