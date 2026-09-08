import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tabryo/core/cancellation.dart';
import 'package:tabryo/core/preview_cache.dart';
import 'package:tabryo/features/editor/domain/document_files.dart';
import 'package:tabryo/features/editor/infrastructure/local_document_files.dart';
import 'package:tabryo/features/files/infrastructure/local_workspace_files.dart';

void main() {
  late Directory temporary;
  late String root;
  late PreviewCache cache;
  late LocalWorkspaceFiles files;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('tabryo-files-');
    root = await temporary.resolveSymbolicLinks();
    cache = PreviewCache();
    files = LocalWorkspaceFiles(cache);
  });
  tearDown(() async {
    await temporary.delete(recursive: true);
  });
  test('incremental listing and literal Unicode preview', () async {
    for (var i = 0; i < 205; i++) {
      await File(p.join(root, 'file $i.txt')).writeAsString('$i');
    }
    final page = await files.list(root, root);
    expect(page.entries.length, 200);
    expect(page.hasMore, isTrue);
    final last = await files.list(root, root, offset: 200);
    expect(last.entries.length, 5);
    expect(last.hasMore, isFalse);
    final file = File(p.join(root, '[ação] & name.txt'));
    await file.writeAsString('olá');
    expect((await files.preview(root, file.path)).text, 'olá');
    expect(cache.bytes, greaterThan(0));
  });
  test(
    'binary, invalid UTF-8, and large files are bounded explicitly',
    () async {
      final binary = File(p.join(root, 'binary'));
      await binary.writeAsBytes([0, 1, 2]);
      expect((await files.preview(root, binary.path)).binary, isTrue);
      final invalid = File(p.join(root, 'invalid'));
      await invalid.writeAsBytes([0xff, 0xfe]);
      expect((await files.preview(root, invalid.path)).invalidUtf8, isTrue);
      final large = File(p.join(root, 'large'));
      await large.writeAsString('a' * (1024 * 1024));
      final result = await files.preview(root, large.path);
      expect(result.truncated, isTrue);
      expect(result.text.length, LocalWorkspaceFiles.previewLimit);
    },
  );
  test('links outside the authorized root are refused', () async {
    final inner = await Directory(p.join(root, 'inside')).create();
    final outside = await File(p.join(root, 'outside.txt'))
        .writeAsString('private');
    await Link(p.join(inner.path, 'escape')).create(outside.path);
    final authorized = await files.authorizeRoot(inner.path);
    final listed = await files.list(authorized, authorized);
    expect(listed.entries.single.link, isTrue);
    await expectLater(
      files.preview(authorized, p.join(inner.path, 'escape')),
      throwsA(isA<FileSystemException>()),
    );
  });
  test('cancelled previews and global cache eviction stay bounded', () async {
    final file = await File(p.join(root, 'text')).writeAsString('hello');
    await expectLater(
      files.preview(root, file.path, cancellation: Cancellation()..cancel()),
      throwsA(isA<Cancelled>()),
    );
    final small = PreviewCache(limit: 20);
    small.put('a', '12345');
    small.put('b', '67890');
    expect(small.get('a'), isNull);
    expect(small.bytes, lessThanOrEqualTo(20));
  });

  test(
    'document save preserves UTF-8 BOM and CRLF and invalidates previews',
    () async {
      final file = File(p.join(root, 'ação.dart'));
      await file.writeAsBytes([0xef, 0xbb, 0xbf, ...'first\r\n'.codeUnits]);
      final documents = LocalDocumentFiles(cache);
      final baseline = await documents.open(root, file.path);
      expect(baseline.text, 'first\n');
      expect(baseline.bom, isTrue);
      await files.preview(root, file.path);
      final saved = await documents.save(baseline, 'second\nthird\n');
      expect(await file.readAsBytes(), [
        0xef,
        0xbb,
        0xbf,
        ...'second\r\nthird\r\n'.codeUnits,
      ]);
      expect(cache.bytes, 0);
      expect((await documents.save(saved, 'final\n')).text, 'final\n');
      expect((await Directory(root).list().toList()).length, 1);
    },
  );

  test(
    'document save refuses changed bytes even with the same size and timestamp',
    () async {
      final file = await File(p.join(root, 'server.py'))
          .writeAsString('original');
      final documents = LocalDocumentFiles(cache);
      final baseline = await documents.open(root, file.path);
      final stamp = await file.lastModified();
      await file.writeAsString('external');
      await file.setLastModified(stamp);
      await expectLater(
        documents.save(baseline, 'my edit'),
        throwsA(isA<DocumentConflict>()),
      );
      expect(await file.readAsString(), 'external');
      await file.delete();
      await expectLater(
        documents.save(baseline, 'my edit'),
        throwsA(isA<FileSystemException>()),
      );
      expect(await file.exists(), isFalse);
    },
  );

  test('noneditable documents and saving outside a root are refused', () async {
    final documents = LocalDocumentFiles(cache);
    final file = File(p.join(root, 'input'));
    for (final bytes in [
      [0, 1],
      [255],
      'a\r\nb\n'.codeUnits,
      List.filled(DocumentFiles.byteLimit + 1, 65),
    ]) {
      await file.writeAsBytes(bytes);
      await expectLater(
        documents.open(root, file.path),
        throwsA(isA<DocumentReadOnly>()),
      );
    }
    await file.writeAsString('safe');
    final inner = await Directory(p.join(root, 'inner')).create();
    await Link(p.join(inner.path, 'escape')).create(file.path);
    await expectLater(
      documents.open(inner.path, p.join(inner.path, 'escape')),
      throwsA(isA<DocumentFailure>()),
    );
    final baseline = await documents.open(root, file.path);
    await expectLater(
      documents.save(baseline, 'a' * (DocumentFiles.byteLimit + 1)),
      throwsA(isA<DocumentFailure>()),
    );
    expect(await file.readAsString(), 'safe');
  });

  test(
    'a linked destination swapped after opening cannot redirect a save',
    () async {
      final directory = await Directory(p.join(root, 'authorized')).create();
      final file = await File(p.join(directory.path, 'server.ts'))
          .writeAsString('safe');
      final outside = await File(p.join(root, 'outside'))
          .writeAsString('private');
      final documents = LocalDocumentFiles(cache);
      final baseline = await documents.open(directory.path, file.path);
      await file.delete();
      await Link(file.path).create(outside.path);
      await expectLater(
        documents.save(baseline, 'edit'),
        throwsA(isA<DocumentFailure>()),
      );
      expect(await outside.readAsString(), 'private');
    },
  );

  test('saving a read-only file preserves the original on failure', () async {
    final file = await File(p.join(root, 'readonly.txt'))
        .writeAsString('original');
    await Process.run('attrib', ['+R', file.path]);
    try {
      final documents = LocalDocumentFiles(cache);
      final baseline = await documents.open(root, file.path);
      await expectLater(
        documents.save(baseline, 'edit'),
        throwsA(isA<FileSystemException>()),
      );
      expect(await file.readAsString(), 'original');
    } finally {
      await Process.run('attrib', ['-R', file.path]);
      // A failed copy retains the source's read-only bit in its owned staging directory.
      await for (final entry in Directory(root).list()) {
        if (entry is Directory &&
            p.basename(entry.path).startsWith('.tabryo-save-')) {
          await Process.run('attrib', ['-R', p.join(entry.path, 'content')]);
        }
      }
    }
  }, skip: !Platform.isWindows);
}
