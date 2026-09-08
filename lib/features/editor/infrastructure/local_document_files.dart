import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/preview_cache.dart';
import '../domain/document_files.dart';

final class _Revision {
  _Revision(List<int> bytes, this.modified, this.mode)
    : bytes = List<int>.unmodifiable(bytes);
  final List<int> bytes;
  final DateTime modified;
  final int mode;
}

/// Optimistic saves: stage and flush a replacement in the same filesystem,
/// then recheck the original. Never truncate the user's file in place.
/// Filesystem rename is not a compare-and-swap against non-cooperating writers.
final class LocalDocumentFiles implements DocumentFiles {
  LocalDocumentFiles(this.cache);
  final PreviewCache cache;
  final _writers = <String>{};

  Future<String> _resolve(String root, String path) async {
    if (!p.isAbsolute(root) ||
        !p.isAbsolute(path) ||
        !p.equals(await Directory(root).resolveSymbolicLinks(), root)) {
      throw const DocumentFailure(
        'The authorized workspace moved. Open it again.',
      );
    }
    final canonical = await File(path).resolveSymbolicLinks();
    if (!p.isWithin(root, canonical)) {
      throw const DocumentFailure('The file leaves the authorized workspace.');
    }
    return canonical;
  }

  Future<_Revision> _read(String path) async {
    final file = File(path);
    final before = await file.stat();
    if (before.type != FileSystemEntityType.file) {
      throw const DocumentFailure('Select a regular file.');
    }
    if (before.size > DocumentFiles.byteLimit) {
      throw const DocumentReadOnly(
        'Files larger than 512 KiB use a read-only preview.',
      );
    }
    final handle = await file.open();
    late List<int> bytes;
    try {
      bytes = await handle.read(DocumentFiles.byteLimit + 1);
    } finally {
      await handle.close();
    }
    final after = await file.stat();
    if (before.modified != after.modified ||
        before.size != after.size ||
        before.mode != after.mode ||
        bytes.length != after.size) {
      throw const DocumentConflict();
    }
    return _Revision(bytes, after.modified, after.mode);
  }

  @override
  Future<DocumentSnapshot> open(String root, String path) async {
    final canonical = await _resolve(root, path);
    final revision = await _read(canonical);
    final bytes = revision.bytes;
    if (bytes.contains(0)) {
      throw const DocumentReadOnly('Binary files use a read-only preview.');
    }
    final bom =
        bytes.length >= 3 &&
        bytes[0] == 0xef &&
        bytes[1] == 0xbb &&
        bytes[2] == 0xbf;
    late String text;
    try {
      text = utf8.decode(bom ? bytes.sublist(3) : bytes);
    } on FormatException {
      throw const DocumentReadOnly('Only valid UTF-8 files can be edited.');
    }
    final crlf = text.contains('\r\n');
    final normalized = text.replaceAll('\r\n', '\n');
    if (normalized.contains('\r') ||
        (crlf && text.replaceAll('\r\n', '').contains('\n'))) {
      throw const DocumentReadOnly(
        'Mixed or legacy line endings use a read-only preview.',
      );
    }
    return DocumentSnapshot(
      root: root,
      path: canonical,
      text: normalized,
      revision: revision,
      newline: crlf ? '\r\n' : '\n',
      bom: bom,
    );
  }

  bool _same(_Revision a, _Revision b) {
    if (a.modified != b.modified ||
        a.mode != b.mode ||
        a.bytes.length != b.bytes.length) {
      return false;
    }
    for (var i = 0; i < a.bytes.length; i++) {
      if (a.bytes[i] != b.bytes[i]) return false;
    }
    return true;
  }

  @override
  Future<DocumentSnapshot> save(DocumentSnapshot baseline, String text) async {
    final revision = baseline.revision;
    if (revision is! _Revision) {
      throw const DocumentFailure('Reopen the file before saving.');
    }
    final normalized = text.replaceAll('\r\n', '\n');
    if (normalized.contains('\r') ||
        utf8.decode(utf8.encode(normalized)) != normalized) {
      throw const DocumentFailure(
        'The buffer contains unsupported line endings or invalid Unicode. Your edits are preserved.',
      );
    }
    final bytes = <int>[
      if (baseline.bom) ...[0xef, 0xbb, 0xbf],
      ...utf8.encode(normalized.replaceAll('\n', baseline.newline)),
    ];
    if (bytes.length > DocumentFiles.byteLimit || text.contains('\u0000')) {
      throw const DocumentFailure(
        'Edits must remain valid text within 512 KiB. Your buffer is preserved.',
      );
    }
    final path = baseline.path;
    final key = p.normalize(Platform.isWindows ? path.toLowerCase() : path);
    if (!_writers.add(key)) {
      throw const DocumentFailure(
        'A save is already in progress for this file.',
      );
    }
    Directory? staging;
    File? replacement;
    try {
      if (!p.equals(await _resolve(baseline.root, path), path) ||
          !_same(revision, await _read(path))) {
        throw const DocumentConflict();
      }
      if (revision.mode & 0x92 == 0) {
        throw FileSystemException('This file is read only.', path);
      }
      // The OS creates a fresh private staging directory; copy retains the
      // original's file mode, including executable/read-only attributes.
      staging = await Directory(p.dirname(path)).createTemp('.tabryo-save-');
      replacement = await File(path).copy(p.join(staging.path, 'content'));
      await replacement.writeAsBytes(bytes, flush: true);
      if ((await replacement.stat()).mode != revision.mode) {
        throw const DocumentFailure(
          'The file permissions could not be preserved. The original file and your buffer are unchanged.',
        );
      }
      if (!p.equals(await _resolve(baseline.root, path), path) ||
          !_same(revision, await _read(path))) {
        throw const DocumentConflict();
      }
      await replacement.rename(path);
      replacement = null;
      cache.clear();
      // This baseline describes our written bytes, not an external successor.
      final stat = await File(path).stat();
      return DocumentSnapshot(
        root: baseline.root,
        path: path,
        text: text,
        revision: _Revision(bytes, stat.modified, stat.mode),
        newline: baseline.newline,
        bom: baseline.bom,
      );
    } on DocumentReadOnly {
      throw const DocumentConflict();
    } finally {
      _writers.remove(key);
      // Delete only the two literal objects created by this save. Cleanup must
      // never turn a successful replacement into a failed save/retry.
      try {
        if (replacement != null) await replacement.delete();
        if (staging != null) await staging.delete();
      } on FileSystemException {
        // A sharing lock can retain the staging file; no recursive cleanup.
      }
    }
  }
}
