final class FormattedDocument {
  const FormattedDocument(this.text, this.start, this.end);
  final String text;
  final int start;
  final int end;
}

/// Formatting transforms a captured buffer; it never writes the source file.
abstract interface class DocumentFormatter {
  Future<FormattedDocument> format({
    required String executable,
    required String root,
    required String path,
    required String text,
    required int start,
    required int end,
  });
  void close();
}
