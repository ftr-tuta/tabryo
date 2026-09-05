import '../../../core/cancellation.dart';

final class WorkspaceEntry {
  const WorkspaceEntry(
    this.path,
    this.name, {
    required this.directory,
    required this.link,
  });
  final String path;
  final String name;
  final bool directory;
  final bool link;
}

final class FilePage {
  const FilePage(this.entries, this.hasMore);
  final List<WorkspaceEntry> entries;
  final bool hasMore;
}

final class FilePreview {
  const FilePreview(
    this.path,
    this.text, {
    this.truncated = false,
    this.binary = false,
    this.invalidUtf8 = false,
  });
  final String path;
  final String text;
  final bool truncated;
  final bool binary;
  final bool invalidUtf8;
}

abstract interface class WorkspaceFiles {
  Future<String> authorizeRoot(String path);
  Future<FilePage> list(
    String root,
    String directory, {
    int offset = 0,
    Cancellation? cancellation,
  });
  Future<FilePreview> preview(
    String root,
    String path, {
    Cancellation? cancellation,
  });
  Stream<void> watch(String root);
}
