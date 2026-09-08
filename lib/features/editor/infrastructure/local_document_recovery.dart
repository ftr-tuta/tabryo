import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/cancellation.dart';
import '../domain/document_files.dart';
import '../domain/document_recovery.dart';

/// Private session directories and OS locks isolate concurrently running apps.
/// Replacement is flushed before rename; a crash retains the previous snapshot.
final class LocalDocumentRecovery implements DocumentRecovery {
  LocalDocumentRecovery(this.directory);
  final Directory directory;
  final _gate = AsyncGate(1);
  static final _owned = <String>{};
  final _claims = <String, RandomAccessFile>{};
  final _pending = <String, List<RecoveredDocument>>{};
  String? _session;
  bool _closed = false;
  @override
  String? warning;
  static const _snapshotLimit = 80 * 1024 * 1024;

  factory LocalDocumentRecovery.forUser() => LocalDocumentRecovery(
    Directory(
      p.join(
        Platform.isWindows
            ? Platform.environment['LOCALAPPDATA']!
            : (Platform.environment['XDG_STATE_HOME'] ??
                  p.join(Platform.environment['HOME']!, '.local', 'state')),
        'Tabryo',
        'editor-recovery',
      ),
    ),
  );

  Future<void> _initialize() async {
    if (_closed) throw StateError('Recovery storage is closed.');
    if (_session != null) return;
    await directory.create(recursive: true);
    final session = await directory.createTemp('session-');
    final lock = await File(p.join(session.path, 'owner.lock'))
        .open(mode: FileMode.append);
    try {
      await lock.lock(FileLock.exclusive);
    } catch (_) {
      await lock.close();
      rethrow;
    }
    _session = session.path;
    _owned.add(session.path);
    _claims[session.path] = lock;
  }

  @override
  Future<List<RecoveredDocument>> pending() async {
    final release = await _gate.acquire();
    try {
      await _initialize();
      warning = null;
      var inspected = 0;
      var offered = _pending.values.fold(
        0,
        (count, copies) => count + copies.length,
      );
      await for (final entry in directory.list(followLinks: false)) {
        if (++inspected > 128) {
          warning =
              'Recovery scanning reached its session limit. Other copies were left untouched at ${directory.path}.';
          break;
        }
        if (entry is! Directory ||
            !p.basename(entry.path).startsWith('session-') ||
            _owned.contains(entry.path) ||
            _claims.containsKey(entry.path)) {
          continue;
        }
        if (offered == 12) {
          warning = 'Review the offered copies, then refresh to look for more. Other recovery sessions were left untouched.';
          break;
        }
        final lockPath = p.join(entry.path, 'owner.lock');
        if (await FileSystemEntity.type(lockPath, followLinks: false) !=
            FileSystemEntityType.file) {
          continue;
        }
        RandomAccessFile? lock;
        try {
          lock = await File(lockPath).open(mode: FileMode.append);
          await lock.lock(FileLock.exclusive);
        } on FileSystemException {
          await lock?.close();
          continue; // An active process owns this session.
        }
        try {
          final documents = await _read(entry.path);
          if (documents.isEmpty) {
            await lock.close();
            continue;
          }
          if (offered + documents.length > 12) {
            await lock.close();
            warning = 'Review the offered copies, then refresh to load more. Additional recovery copies were retained.';
            continue;
          }
          _claims[entry.path] = lock;
          _owned.add(entry.path);
          _pending[entry.path] = documents;
          offered += documents.length;
        } catch (_) {
          await lock.close();
          warning =
              'Some recovery copies could not be read and were retained at ${directory.path}.';
        }
      }
      return _pending.values.expand((v) => v).toList();
    } finally {
      release();
    }
  }

  Future<List<RecoveredDocument>> _read(String session) async {
    final file = File(p.join(session, 'documents.json'));
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return [];
    if (type != FileSystemEntityType.file) {
      throw const DocumentFailure(
        'Recovery snapshot is unavailable or too large.',
      );
    }
    final handle = await file.open();
    late final Map data;
    try {
      final length = await handle.length();
      if (length > _snapshotLimit) {
        throw const DocumentFailure('Recovery snapshot is too large.');
      }
      final bytes = await handle.read(length + 1);
      if (bytes.length != length) {
        throw const DocumentFailure('Recovery snapshot changed while reading.');
      }
      data = jsonDecode(utf8.decode(bytes)) as Map;
    } finally {
      await handle.close();
    }
    if (data['version'] != 1 ||
        data['documents'] is! List ||
        (data['documents'] as List).length > 12) {
      throw const FormatException('Unsupported recovery snapshot.');
    }
    final documents = <RecoveredDocument>[];
    for (final (index, value) in (data['documents'] as List).indexed) {
      final item = value as Map;
      final document = RecoveredDocument(
        id: '$session#$index',
        root: item['root'] as String,
        path: item['path'] as String,
        text: item['text'] as String,
        diskText: item['diskText'] as String,
        newline: item['newline'] as String,
        bom: item['bom'] as bool,
        start: item['start'] as int,
        end: item['end'] as int,
      );
      _validate(document);
      documents.add(document);
    }
    return documents;
  }

  void _validate(RecoveredDocument document) {
    if (!p.isAbsolute(document.root) ||
        !p.isAbsolute(document.path) ||
        !p.isWithin(document.root, document.path) ||
        !['\n', '\r\n'].contains(document.newline) ||
        document.start < 0 ||
        document.start > document.text.length ||
        document.end < 0 ||
        document.end > document.text.length) {
      throw const FormatException('Invalid recovery document.');
    }
    for (final text in [document.text, document.diskText]) {
      if (text.contains('\u0000') ||
          text.contains('\r') ||
          utf8.decode(utf8.encode(text)) != text ||
          utf8.encode(text.replaceAll('\n', document.newline)).length +
                  (document.bom ? 3 : 0) >
              DocumentFiles.byteLimit) {
        throw const FormatException('Invalid recovery text.');
      }
    }
  }

  Future<void> _write(String session, List<RecoveredDocument> documents) async {
    if (documents.length > 12) throw const FormatException('Too many buffers.');
    for (final document in documents) {
      _validate(document);
    }
    final temporary = File(p.join(session, 'documents.tmp'));
    await temporary.writeAsString(
      jsonEncode({
        'version': 1,
        'documents': [
          for (final document in documents)
            {
              'root': document.root,
              'path': document.path,
              'text': document.text,
              'diskText': document.diskText,
              'newline': document.newline,
              'bom': document.bom,
              'start': document.start,
              'end': document.end,
            },
        ],
      }),
      flush: true,
    );
    await temporary.rename(p.join(session, 'documents.json'));
  }

  @override
  Future<void> save(List<RecoveredDocument> documents) async {
    final release = await _gate.acquire();
    try {
      await _initialize();
      await _write(_session!, documents);
    } finally {
      release();
    }
  }

  @override
  Future<void> remove(String id) async {
    final release = await _gate.acquire();
    try {
      for (final entry in _pending.entries) {
        if (!entry.value.any((document) => document.id == id)) continue;
        final next = entry.value
            .where((document) => document.id != id)
            .toList();
        await _write(entry.key, next);
        _pending[entry.key] = next;
        return;
      }
    } finally {
      release();
    }
  }

  @override
  Future<void> close() async {
    final release = await _gate.acquire();
    try {
      if (_closed) return;
      _closed = true;
      for (final entry in _claims.entries) {
        var empty = false;
        // Clean only literal session files when no recoverable content remains.
        try {
          empty = (await _read(entry.key)).isEmpty;
          if (empty) {
            for (final name in ['documents.json', 'documents.tmp']) {
              final file = File(p.join(entry.key, name));
              if (await file.exists()) await file.delete();
            }
          }
        } catch (_) {
          empty = false;
        } finally {
          await entry.value.close();
          _owned.remove(entry.key);
        }
        if (empty) {
          try {
            await File(p.join(entry.key, 'owner.lock')).delete();
            await Directory(entry.key).delete();
          } on FileSystemException catch (error) {
            // Another process may be scanning; no recoverable content is lost.
            warning =
                'Empty recovery storage could not be removed at ${entry.key}: ${error.message}';
          }
        }
      }
      _claims.clear();
    } finally {
      release();
    }
  }
}
