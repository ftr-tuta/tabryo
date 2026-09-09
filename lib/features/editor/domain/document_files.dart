/// An immutable disk baseline. Revisions are owned by the filesystem adapter.
final class DocumentSnapshot {
  const DocumentSnapshot({
    required this.root,
    required this.path,
    required this.text,
    required this.revision,
    this.newline = '\n',
    this.bom = false,
  });
  final String root;
  final String path;
  final String text;
  final Object revision;
  final String newline;
  final bool bom;
}

class DocumentFailure implements Exception {
  const DocumentFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

final class DocumentReadOnly extends DocumentFailure {
  const DocumentReadOnly(super.message);
}

final class DocumentConflict extends DocumentFailure {
  const DocumentConflict()
    : super(
        'The file changed on disk. Your edits are preserved. Compare with the disk or reload before saving.',
      );
}

abstract interface class DocumentFiles {
  static const byteLimit = 512 * 1024;
  Future<DocumentSnapshot> open(String root, String path);
  Future<DocumentSnapshot> save(DocumentSnapshot baseline, String text);
}
