import '../../../core/cancellation.dart';

enum LanguageServerKind { dart, pyright, ruff }

final class LanguageServerSpec {
  const LanguageServerSpec({
    required this.kind,
    required this.workspace,
    required this.root,
    required this.executable,
    this.module,
    this.python,
    this.excludedRoots = const [],
  });
  final LanguageServerKind kind;
  final String workspace;
  final String root;
  final String executable;
  final String? module;
  final String? python;
  final List<String> excludedRoots;
  String get language => kind == LanguageServerKind.dart ? 'dart' : 'python';
  String get id => '${kind.name}:$workspace:$root';
  List<String> get arguments => switch (kind) {
    LanguageServerKind.dart => ['language-server', '--protocol=lsp'],
    LanguageServerKind.pyright => [module!, '--stdio'],
    LanguageServerKind.ruff => ['server'],
  };
}

final class LanguageFailure implements Exception {
  const LanguageFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

abstract interface class LanguageConnection {
  Stream<Map<String, dynamic>> get notifications;
  Future<Object?> request(
    String method,
    Map<String, Object?> parameters, {
    Cancellation? cancellation,
  });
  void notify(String method, Map<String, Object?> parameters);
  Future<void> close();
}

abstract interface class LanguageServers {
  Future<LanguageConnection> start(LanguageServerSpec spec);
}

final class LanguageProblem {
  const LanguageProblem({
    required this.server,
    required this.workspace,
    required this.path,
    required this.diagnostic,
    required this.version,
  });
  final String server;
  final String workspace;
  final String path;
  final Map<String, dynamic> diagnostic;
  final int? version;
}

final class LanguageDocument {
  const LanguageDocument(this.workspace, this.path, this.text, this.version);
  final String workspace;
  final String path;
  final String text;
  final int version;
}

/// LSP positions use UTF-16 code units, as do Dart strings and Monaco offsets.
int languageOffset(String text, Map position) {
  final line = position['line'];
  final character = position['character'];
  if (line is! int || character is! int || line < 0 || character < 0) {
    throw const LanguageFailure('Invalid language position.');
  }
  var offset = 0;
  for (var i = 0; i < line; i++) {
    final next = text.indexOf('\n', offset);
    if (next < 0) {
      throw const LanguageFailure('Language position is outside the document.');
    }
    offset = next + 1;
  }
  final end = text.indexOf('\n', offset);
  if (offset + character > (end < 0 ? text.length : end)) {
    throw const LanguageFailure('Language position is outside the line.');
  }
  final result = offset + character;
  if (result > 0 &&
      result < text.length &&
      text.codeUnitAt(result - 1) >= 0xD800 &&
      text.codeUnitAt(result - 1) <= 0xDBFF &&
      text.codeUnitAt(result) >= 0xDC00 &&
      text.codeUnitAt(result) <= 0xDFFF) {
    throw const LanguageFailure(
      'Language position splits a Unicode character.',
    );
  }
  return result;
}

Map<String, int> languagePosition(String text, int offset) {
  if (offset < 0 || offset > text.length) {
    throw const LanguageFailure('Invalid cursor position.');
  }
  final prefix = text.substring(0, offset);
  return {
    'line': '\n'.allMatches(prefix).length,
    'character': offset - prefix.lastIndexOf('\n') - 1,
  };
}

String applyLanguageEdits(String text, List edits) {
  if (edits.length > 2000) {
    throw const LanguageFailure('Too many proposed edits.');
  }
  final parsed = <({int start, int end, String text})>[];
  for (final edit in edits) {
    if (edit is! Map || edit['range'] is! Map || edit['newText'] is! String) {
      throw const LanguageFailure('Unsupported language edit.');
    }
    final range = edit['range'] as Map;
    if (range['start'] is! Map || range['end'] is! Map) {
      throw const LanguageFailure('Invalid edit range.');
    }
    final start = languageOffset(text, range['start'] as Map);
    final end = languageOffset(text, range['end'] as Map);
    if (start > end) throw const LanguageFailure('Reversed language edit.');
    parsed.add((
      start: start,
      end: end,
      text: (edit['newText'] as String).replaceAll('\r\n', '\n'),
    ));
  }
  parsed.sort((a, b) => b.start.compareTo(a.start));
  var boundary = text.length + 1;
  for (final edit in parsed) {
    if (edit.end > boundary || edit.start == boundary) {
      throw const LanguageFailure('Overlapping language edits.');
    }
    boundary = edit.start;
    text = text.replaceRange(edit.start, edit.end, edit.text);
  }
  return text;
}
