import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tabryo/core/cancellation.dart';
import 'package:tabryo/core/preview_cache.dart';
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
}
