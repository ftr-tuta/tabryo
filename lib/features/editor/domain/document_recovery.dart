import 'document_files.dart';

/// A recoverable buffer, never an instruction to write its source file.
final class RecoveredDocument {
  const RecoveredDocument({
    required this.id,
    required this.root,
    required this.path,
    required this.text,
    required this.diskText,
    required this.newline,
    required this.bom,
    required this.start,
    required this.end,
  });
  final String id;
  final String root;
  final String path;
  final String text;
  final String diskText;
  final String newline;
  final bool bom;
  final int start;
  final int end;

  bool matches(DocumentSnapshot disk) =>
      disk.text == diskText && disk.newline == newline && disk.bom == bom;
}

abstract interface class DocumentRecovery {
  String? get warning;

  /// Claims only abandoned sessions. Other running editors retain ownership.
  Future<List<RecoveredDocument>> pending();
  Future<void> save(List<RecoveredDocument> documents);
  Future<void> remove(String id);

  /// Releases ownership, retaining the last durable snapshot if one exists.
  Future<void> close();
}
