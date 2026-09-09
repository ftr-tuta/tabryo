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

final class WorkspaceSearchQuery {
  const WorkspaceSearchQuery(
    this.text, {
    this.caseSensitive = false,
    this.pathContains = '',
    this.excludedDirectories = const [],
  });
  final String text;
  final bool caseSensitive;
  final String pathContains;
  final List<String> excludedDirectories;
}

final class WorkspaceMatch {
  const WorkspaceMatch({
    required this.path,
    required this.line,
    required this.column,
    required this.text,
    required this.preview,
  });
  final String path;
  final int line;
  final int column;
  final String text;
  final String preview;
}

final class WorkspaceSearchResults {
  const WorkspaceSearchResults(
    this.matches, {
    this.limited = false,
    this.skipped = 0,
  });
  final List<WorkspaceMatch> matches;
  final bool limited;
  final int skipped;
}

abstract interface class WorkspaceFiles {
  Future<WorkspaceSearchResults> search(
    String root,
    WorkspaceSearchQuery query,
    Cancellation cancellation,
  );
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
