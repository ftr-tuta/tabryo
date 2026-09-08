import 'dart:convert';

import 'package:path/path.dart' as p;

import '../../projects/domain/project.dart';
import '../domain/project_task.dart';

/// Reads line hits produced by Flutter, package:coverage and pytest-cov.
abstract final class NativeCoverage {
  static CoverageResults parse(String source, DevelopmentProject project) {
    if (source.length > 4 * 1024 * 1024) {
      throw const FormatException('Coverage exceeds 4 MiB.');
    }
    final files = <String, Map<int, int>>{};
    String? current;
    var recordOpen = false, records = 0, excluded = 0, entries = 0;
    int? expectedLines, expectedHits;
    var recordLines = <int, int>{};
    for (final line in const LineSplitter().convert(source)) {
      if (line.startsWith('SF:')) {
        if (recordOpen) {
          throw const FormatException('Incomplete coverage record.');
        }
        recordOpen = true;
        current = null;
        expectedLines = null;
        expectedHits = null;
        recordLines = {};
        var value = line.substring(3);
        final uri = Uri.tryParse(value);
        if (uri?.scheme == 'file' &&
            uri!.host.isEmpty &&
            !uri.hasQuery &&
            !uri.hasFragment) {
          value = uri.toFilePath();
        } else if (uri != null && uri.hasScheme && !p.isAbsolute(value)) {
          excluded++;
          continue;
        }
        final path = p.normalize(
          p.isAbsolute(value) ? value : p.join(project.directory, value),
        );
        if (p.isWithin(project.directory, path)) {
          current = path;
        } else {
          excluded++;
        }
      } else if (line.startsWith('DA:')) {
        if (!recordOpen || ++entries > 100000) {
          throw const FormatException('Invalid or excessive coverage lines.');
        }
        final fields = line.substring(3).split(',');
        if (fields.length < 2 || fields.length > 3) {
          throw const FormatException('Invalid line coverage.');
        }
        final number = int.tryParse(fields[0]), hits = int.tryParse(fields[1]);
        if (number == null ||
            number < 1 ||
            number > 10000000 ||
            hits == null ||
            hits < 0 ||
            recordLines.containsKey(number)) {
          throw const FormatException('Invalid or duplicate line coverage.');
        }
        recordLines[number] = hits;
      } else if (line.startsWith('LF:') || line.startsWith('LH:')) {
        final count = int.tryParse(line.substring(3));
        if (!recordOpen || count == null || count < 0) {
          throw const FormatException('Invalid coverage totals.');
        }
        if (line.startsWith('LF:')) {
          expectedLines = count;
        } else {
          expectedHits = count;
        }
      } else if (line == 'end_of_record') {
        if (!recordOpen ||
            ++records > 2000 ||
            expectedLines != null && expectedLines != recordLines.length ||
            expectedHits != null &&
                expectedHits != recordLines.values.where((n) => n > 0).length) {
          throw const FormatException(
            'Coverage totals do not match line hits.',
          );
        }
        if (current != null) {
          final target = files.putIfAbsent(current, () => {});
          for (final entry in recordLines.entries) {
            target[entry.key] = (target[entry.key] ?? 0) + entry.value;
          }
        }
        recordOpen = false;
      } else if (line.isNotEmpty &&
          !RegExp(r'^(TN|FN|FNDA|FNF|FNH|BRDA|BRF|BRH|VER):').hasMatch(line)) {
        throw const FormatException('Unsupported coverage report content.');
      }
    }
    if (recordOpen || records == 0) {
      throw const FormatException('Coverage is missing or incomplete.');
    }
    return CoverageResults(
      List.unmodifiable(
        (files.keys.toList()..sort()).map(
          (path) => CoverageFileResult(path, files[path]!),
        ),
      ),
      excludedFiles: excluded,
    );
  }
}
