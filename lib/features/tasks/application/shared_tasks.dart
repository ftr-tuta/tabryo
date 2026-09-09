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
        (!value.containsKey('tasks') && !value.containsKey('launches')) ||
        (value.containsKey('tasks') && value['tasks'] is! List) ||
        (value.containsKey('launches') && value['launches'] is! List) ||
        value.keys.any(
          (k) => k != 'version' && k != 'tasks' && k != 'launches',
        ) ||
        ((value['tasks'] ?? []) as List).length > 32 ||
        ((value['launches'] ?? []) as List).length > 32) {
      throw const FormatException(
        'Expected version 1 and up to 32 tasks and launch profiles in .tabryo/project.json.',
      );
    }
    final names = <String>{};
    final tasks = <SharedTask>[];
    for (final item in (value['tasks'] ?? []) as List) {
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
    final launches = <ProjectLaunchProfile>[];
    names.clear();
    for (final item in (value['launches'] ?? []) as List) {
      if (item is! Map ||
          item.keys.any(
            (key) => !{
              'name',
              'program',
              'profile',
              'directory',
              'arguments',
              'toolArguments',
              'flavor',
              'flutterMode',
              'noDebug',
              'port',
            }.contains(key),
          )) {
        throw const FormatException(
          'Unknown launch field. SDKs, device IDs, attach endpoints and environment values stay local.',
        );
      }
      String text(String key, [String fallback = '']) {
        final value = item[key] ?? fallback;
        if (value is! String || value.length > 512 || value.contains('\u0000')) {
          throw FormatException('Invalid launch $key.');
        }
        return value;
      }

      List<String> arguments(String key) {
        final value = item[key] ?? [];
        if (value is! List ||
            value.length > 64 ||
            value.any(
              (arg) =>
                  arg is! String || arg.length > 4096 || arg.contains('\u0000'),
            )) {
          throw FormatException('Invalid launch $key.');
        }
        return List.unmodifiable(value.cast<String>());
      }

      final name = text('name').trim();
      final program = text('program');
      final directory = text('directory', '.');
      final profile = text('profile', 'Script');
      final flavor = text('flavor');
      final mode = text('flutterMode', 'debug');
      final noDebug = item['noDebug'] ?? false;
      final port = item['port'] ?? 8000;
      if (name.isEmpty ||
          name.length > 80 ||
          !names.add(name) ||
          program.isEmpty ||
          [program, directory].any(
            (path) =>
                path.isEmpty ||
                p.posix.isAbsolute(path) ||
                p.windows.isAbsolute(path) ||
                path.contains('\\') ||
                path.contains(':') ||
                path.split('/').any((part) => part.isEmpty || part == '..'),
          ) ||
          !{'Script', 'Django', 'FastAPI'}.contains(profile) ||
          !{'debug', 'profile', 'release'}.contains(mode) ||
          noDebug is! bool ||
          port is! int ||
          port < 1 ||
          port > 65535 ||
          flavor.isNotEmpty &&
              !RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_-]{0,79}$').hasMatch(flavor)) {
        throw const FormatException(
          'Invalid or duplicate launch profile. Use portable project-relative paths.',
        );
      }
      launches.add(
        ProjectLaunchProfile(
          name: name,
          program: program,
          directory: directory,
          profile: profile,
          arguments: arguments('arguments'),
          toolArguments: arguments('toolArguments'),
          flavor: flavor.isEmpty ? null : flavor,
          flutterMode: mode,
          noDebug: noDebug,
          port: port,
        ),
      );
    }
    return TaskConfiguration(
      source,
      List.unmodifiable(tasks),
      launches: List.unmodifiable(launches),
    );
  }

  static String example(DevelopmentProject project) =>
      const JsonEncoder.withIndent('  ').convert({
        'version': 1,
        'tasks': [
          {'name': 'Analyze', 'kind': 'analyze'},
          {'name': 'Tests', 'kind': 'test', 'coverage': false},
        ],
        'launches': [
          {
            'name': 'Application',
            'program': project.kind == ProjectKind.flutter
                ? 'lib/main.dart'
                : 'main.${project.kind == ProjectKind.python ? 'py' : 'dart'}',
            'profile': 'Script',
          },
        ],
      });
}
