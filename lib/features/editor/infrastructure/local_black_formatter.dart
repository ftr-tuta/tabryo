import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../domain/document_files.dart';
import '../domain/document_formatter.dart';

/// Black receives the captured buffer on stdin; the source is never its output.
final class LocalBlackFormatter implements DocumentFormatter {
  final _processes = <Process>{};
  bool _closed = false;

  @override
  Future<FormattedDocument> format({
    required String executable,
    required String root,
    required String path,
    required String text,
    required int start,
    required int end,
  }) async {
    if (_closed ||
        !p.isAbsolute(executable) ||
        (Platform.isWindows &&
            p.extension(executable).toLowerCase() != '.exe') ||
        !p.isWithin(root, path) ||
        !p.equals(await Directory(root).resolveSymbolicLinks(), root)) {
      throw const DocumentFailure(
        'Select an installed Black executable and a current project root.',
      );
    }
    final process = await Process.start(
      executable,
      ['--quiet', '--stdin-filename', path, '-'],
      workingDirectory: root,
      environment: const {'PYTHONIOENCODING': 'utf-8', 'PYTHONUTF8': '1'},
      runInShell: false,
    );
    if (_closed) {
      process.kill();
      throw const DocumentFailure('The editor was closed.');
    }
    _processes.add(process);
    try {
      final result = await Future.wait<Object>([
        _read(process.stdout, 2 * 1024 * 1024),
        _read(process.stderr, 16 * 1024),
        process.exitCode,
        () async {
          process.stdin.add(utf8.encode(text));
          await process.stdin.flush();
          await process.stdin.close();
          return true;
        }(),
      ], eagerError: true).timeout(const Duration(seconds: 30));
      if (result[2] != 0) {
        throw DocumentFailure('Black formatting failed. ${result[1]}');
      }
      final output = (result[0] as String).replaceAll('\r\n', '\n');
      if (output.contains('\r') ||
          output.contains('\u0000') ||
          utf8.encode(output).length > DocumentFiles.byteLimit) {
        throw const DocumentFailure(
          'Black returned unsupported or oversized text.',
        );
      }
      var prefix = 0;
      while (prefix < text.length &&
          prefix < output.length &&
          text.codeUnitAt(prefix) == output.codeUnitAt(prefix)) {
        prefix++;
      }
      var suffix = 0;
      while (suffix < text.length - prefix &&
          suffix < output.length - prefix &&
          text.codeUnitAt(text.length - suffix - 1) ==
              output.codeUnitAt(output.length - suffix - 1)) {
        suffix++;
      }
      int mapped(int position) => position <= prefix
          ? position
          : position >= text.length - suffix
          ? (position + output.length - text.length).clamp(0, output.length)
          : position.clamp(prefix, output.length - suffix);
      var a = mapped(start);
      var b = mapped(end);
      final selected = text.substring(
        start < end ? start : end,
        start < end ? end : start,
      );
      if (selected.isNotEmpty) {
        final found = output.indexOf(selected);
        if (found >= 0 && output.indexOf(selected, found + 1) < 0) {
          a = start <= end ? found : found + selected.length;
          b = start <= end ? found + selected.length : found;
        }
      }
      return FormattedDocument(output, a, b);
    } on TimeoutException {
      throw const DocumentFailure(
        'Black formatting did not finish within 30 seconds.',
      );
    } on FormatException {
      throw const DocumentFailure('Black returned invalid UTF-8 output.');
    } finally {
      _processes.remove(process);
      process.kill();
    }
  }

  Future<String> _read(Stream<List<int>> stream, int limit) async {
    final bytes = <int>[];
    await for (final chunk in stream) {
      if (bytes.length + chunk.length > limit) {
        throw const DocumentFailure('Black returned too much output.');
      }
      bytes.addAll(chunk);
    }
    return utf8.decode(bytes);
  }

  @override
  void close() {
    _closed = true;
    for (final process in _processes) {
      process.kill();
    }
    _processes.clear();
  }
}
