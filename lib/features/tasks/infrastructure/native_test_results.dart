import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import '../../projects/domain/project.dart';
import '../domain/project_task.dart';

/// Parses the runners' documented JSON/JUnit output, never terminal rendering.
abstract final class NativeTestResults {
  static TestResults parse(
    String source,
    DevelopmentProject project, {
    required bool python,
  }) {
    if (source.length > 4 * 1024 * 1024) {
      throw const ProjectFailure('Test report limit exceeded.');
    }
    return python ? _junit(source, project) : _dart(source, project);
  }

  static String? _path(Object? value, DevelopmentProject project) {
    if (value is! String || value.isEmpty) return null;
    String path;
    try {
      final uri = Uri.tryParse(value);
      if (uri?.scheme == 'file') {
        if (uri!.host.isNotEmpty) return null;
        path = uri.toFilePath();
      } else if (p.isAbsolute(value)) {
        path = value;
      } else if (uri != null && uri.hasScheme) {
        return null;
      } else {
        path = p.join(project.directory, value);
      }
      path = p.normalize(path);
      return p.isWithin(project.directory, path) ? path : null;
    } catch (_) {
      return null;
    }
  }

  static TestResults _dart(String source, DevelopmentProject project) {
    final suites = <int, String?>{};
    final tests = <int, TestCaseResult>{};
    final hidden = <int>{};
    var complete = false;
    var successful = false;
    var started = false;
    for (final line in const LineSplitter().convert(source)) {
      if (line.trim().isEmpty) continue;
      final value = jsonDecode(line);
      if (value is! Map || complete) {
        throw const FormatException('Invalid test event stream.');
      }
      switch (value['type']) {
        case 'start':
          if (value['protocolVersion'] is! String ||
              !(value['protocolVersion'] as String).startsWith('0.1.')) {
            throw const ProjectFailure(
              'Unsupported Dart test reporter protocol.',
            );
          }
          started = true;
        case 'suite':
          final suite = value['suite'] as Map;
          suites[suite['id'] as int] = _path(suite['path'], project);
        case 'testStart':
          final test = value['test'] as Map;
          tests[test['id'] as int] = TestCaseResult(
            name: test['name'] as String,
            outcome: TestOutcome.incomplete,
            path:
                _path(test['root_url'], project) ??
                _path(test['url'], project) ??
                suites[test['suiteID']],
            line: (test['root_line'] ?? test['line']) as int?,
          );
        case 'error':
          final id = value['testID'] as int;
          final test = tests[id];
          if (test == null) throw const FormatException('Unknown failed test.');
          hidden.remove(id);
          final details =
              '${test.details}${value['error']}\n${value['stackTrace']}';
          tests[id] = TestCaseResult(
            name: test.name,
            outcome: TestOutcome.failed,
            path: test.path,
            line: test.line,
            details: details.substring(0, details.length.clamp(0, 16384)),
          );
        case 'testDone':
          final id = value['testID'] as int;
          final test = tests[id];
          if (test == null) {
            throw const FormatException('Unknown completed test.');
          }
          final outcome =
              test.outcome == TestOutcome.failed || value['result'] != 'success'
              ? TestOutcome.failed
              : value['skipped'] == true
              ? TestOutcome.skipped
              : TestOutcome.passed;
          if (value['hidden'] == true && outcome != TestOutcome.failed) {
            hidden.add(id);
          }
          tests[id] = TestCaseResult(
            name: test.name,
            outcome: outcome,
            path: test.path,
            line: test.line,
            details: test.details,
          );
        case 'done':
          complete = value['success'] is bool;
          successful = value['success'] == true;
      }
      if (tests.length > 2000 || suites.length > 2000) {
        throw const ProjectFailure(
          'More than 2000 test entries. Run a smaller selection.',
        );
      }
    }
    return TestResults(
      List.unmodifiable(
        tests.entries.where((e) => !hidden.contains(e.key)).map((e) => e.value),
      ),
      successful: successful,
      complete:
          started &&
          complete &&
          tests.values.every((t) => t.outcome != TestOutcome.incomplete),
    );
  }

  static TestResults _junit(String source, DevelopmentProject project) {
    if (RegExp(
      r'<!\s*(DOCTYPE|ENTITY)',
      caseSensitive: false,
    ).hasMatch(source)) {
      throw const FormatException(
        'DTD and entities are not supported in test reports.',
      );
    }
    final document = XmlDocument.parse(source);
    if (![
      'testsuites',
      'testsuite',
    ].contains(document.rootElement.name.local)) {
      throw const FormatException('Expected a JUnit test suite.');
    }
    final cases = <TestCaseResult>[];
    for (final element in document.findAllElements('testcase')) {
      if (cases.length == 2000) {
        throw const ProjectFailure(
          'More than 2000 test results. Run a smaller selection.',
        );
      }
      final failures = [
        ...element.findElements('failure'),
        ...element.findElements('error'),
      ];
      final details = failures
          .map((e) => '${e.getAttribute('message') ?? ''}\n${e.innerText}')
          .join('\n');
      final line = int.tryParse(element.getAttribute('line') ?? '');
      cases.add(
        TestCaseResult(
          name: element.getAttribute('name') ?? '(unnamed test)',
          outcome: failures.isNotEmpty
              ? TestOutcome.failed
              : element.findElements('skipped').isNotEmpty
              ? TestOutcome.skipped
              : TestOutcome.passed,
          path: _path(element.getAttribute('file'), project),
          line: line == null ? null : line + 1,
          details: details.substring(0, details.length.clamp(0, 16384)),
        ),
      );
    }
    var expected = 0;
    var successful = !cases.any((v) => v.outcome == TestOutcome.failed);
    for (final suite in document.findAllElements('testsuite')) {
      if (suite.findElements('testsuite').isNotEmpty) continue;
      final count = int.tryParse(suite.getAttribute('tests') ?? '');
      if (count == null || count < 0) {
        throw const FormatException('Missing JUnit test count.');
      }
      expected += count;
      for (final name in ['errors', 'failures']) {
        final reported = int.tryParse(suite.getAttribute(name) ?? '0');
        if (reported == null || reported < 0) {
          throw const FormatException('Invalid JUnit failure count.');
        }
        if (reported > 0) successful = false;
      }
    }
    return TestResults(
      List.unmodifiable(cases),
      complete: expected == cases.length,
      successful: successful,
    );
  }
}
