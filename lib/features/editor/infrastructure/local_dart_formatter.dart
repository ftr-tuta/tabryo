import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../domain/document_files.dart';
import '../domain/document_formatter.dart';

/// Uses the explicitly selected SDK. No shell and no project command execution.
final class LocalDartFormatter implements DocumentFormatter {
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
            p.extension(executable).toLowerCase() != '.exe')) {
      throw const DocumentFailure(
        'Select an absolute Dart executable in Preferences (dart.exe on Windows).',
      );
    }
    final offset = start < end ? start : end;
    final process = await Process.start(
      executable,
      [
        'format',
        '--output=json',
        '--summary=none',
        '--stdin-name',
        path,
        '--selection',
        '$offset:${(end - start).abs()}',
      ],
      workingDirectory: root,
      runInShell: false,
    );
    if (_closed) {
      process.kill();
      throw const DocumentFailure('The editor was closed.');
    }
    _processes.add(process);
    try {
      final output = _read(process.stdout, 2 * 1024 * 1024);
      final errors = _read(process.stderr, 16 * 1024);
      final result =
          await Future.wait<Object>([
            output,
            errors,
            process.exitCode,
            () async {
              process.stdin.add(utf8.encode(text));
              await process.stdin.flush();
              await process.stdin.close();
              return true;
            }(),
          ], eagerError: true).timeout(
            const Duration(seconds: 30),
            onTimeout: () {
              throw const DocumentFailure(
                'Dart formatting did not finish within 30 seconds.',
              );
            },
          );
      if (result[2] != 0) {
        throw DocumentFailure('Dart formatting failed. ${result[1]}');
      }
      final json = jsonDecode(result[0] as String) as Map<String, dynamic>;
      final source = json['source'] as String;
      final selection = json['selection'] as Map<String, dynamic>;
      final selectedStart = selection['offset'] as int;
      final selectedEnd = selectedStart + (selection['length'] as int);
      if (selectedStart < 0 ||
          selectedEnd < selectedStart ||
          selectedEnd > source.length) {
        throw const FormatException('Invalid formatter selection.');
      }
      final normalized = source.replaceAll('\r\n', '\n');
      if (normalized.contains('\r') ||
          normalized.contains('\u0000') ||
          utf8.encode(normalized).length > DocumentFiles.byteLimit) {
        throw const FormatException('Unsupported formatter output.');
      }
      final a = source
          .substring(0, selectedStart)
          .replaceAll('\r\n', '\n')
          .length;
      final b = source
          .substring(0, selectedEnd)
          .replaceAll('\r\n', '\n')
          .length;
      return FormattedDocument(
        normalized,
        start <= end ? a : b,
        start <= end ? b : a,
      );
    } finally {
      _processes.remove(process);
      process.kill();
    }
  }

  Future<String> _read(Stream<List<int>> stream, int limit) async {
    final bytes = <int>[];
    await for (final chunk in stream) {
      if (bytes.length + chunk.length > limit) {
        throw const DocumentFailure('The formatter returned too much output.');
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
