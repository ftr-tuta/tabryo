import 'dart:convert';

import 'package:path/path.dart' as p;

import '../../projects/domain/project.dart';
import '../domain/project_task.dart';

abstract final class SharedTasks {
  static TaskConfiguration parse(String source) {
    if (utf8.encode(source).length > 64 * 1024) {
      throw const FormatException('Shared task configuration exceeds 64 KiB.');
    }
    final value = jsonDecode(source);
    if (value is! Map ||
        value['version'] != 1 ||
        value['tasks'] is! List ||
        value.keys.any((k) => k != 'version' && k != 'tasks') ||
        (value['tasks'] as List).length > 32) {
      throw const FormatException(
        'Expected version 1 and up to 32 tasks in .tabryo/project.json.',
      );
    }
    final names = <String>{};
    final tasks = <SharedTask>[];
    for (final item in value['tasks'] as List) {
      if (item is! Map ||
          item.keys.any(
            (k) => !{
              'name',
              'kind',
              'target',
              'filter',
              'buildTarget',
              'arguments',
              'coverage',
            }.contains(k),
          )) {
        throw const FormatException(
          'Unknown shared task field. Executables, local paths and environment values belong in local tool settings.',
        );
      }
      String string(String key, {int limit = 512}) {
        final field = item[key] ?? '';
        if (field is! String ||
            field.length > limit ||
            field.contains('\u0000')) {
          throw FormatException('Invalid task $key.');
        }
        return field;
      }

      final name = string('name', limit: 80).trim();
      final kind = ProjectTaskKind.values
          .where((k) => k.name == item['kind'])
          .firstOrNull;
      final target = string('target');
      final args = item['arguments'] ?? <String>[];
      final coverage = item['coverage'] ?? false;
      if (name.isEmpty ||
          !names.add(name) ||
          kind == null ||
          coverage is! bool ||
          args is! List ||
          args.length > 64 ||
          args.any(
            (v) => v is! String || v.length > 4096 || v.contains('\u0000'),
          )) {
        throw const FormatException('Invalid or duplicate shared task.');
      }
      if (target.isNotEmpty &&
          (p.posix.isAbsolute(target) ||
              p.windows.isAbsolute(target) ||
              target.contains('\\') ||
              target.contains(':') ||
              target.split('/').any((v) => v == '..' || v.isEmpty))) {
        throw const FormatException(
          'Task targets must use project-relative paths with forward slashes.',
        );
      }
      if (coverage && kind != ProjectTaskKind.test ||
          args.isNotEmpty && kind != ProjectTaskKind.run) {
        throw const FormatException(
          'Coverage applies to tests; application arguments apply to Run.',
        );
      }
      tasks.add(
        SharedTask(
          name: name,
          kind: kind,
          target: target.isEmpty ? null : target,
          filter: string('filter'),
          buildTarget: string('buildTarget'),
          arguments: List.unmodifiable(args.cast<String>()),
          coverage: coverage,
        ),
      );
    }
    return TaskConfiguration(source, List.unmodifiable(tasks));
  }

  static String example(DevelopmentProject project) =>
      const JsonEncoder.withIndent('  ').convert({
        'version': 1,
        'tasks': [
          {'name': 'Analyze', 'kind': 'analyze'},
          {'name': 'Tests', 'kind': 'test', 'coverage': false},
        ],
      });
}
