import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../projects/domain/project.dart';
import '../../../core/cancellation.dart';
import '../domain/debug_session.dart';
import 'debug_process.dart';
import 'local_devtools.dart';

final class DapFramer {
  static const limit = 4 * 1024 * 1024;
  final _bytes = BytesBuilder(copy: false);
  int? _length;
  List<Map<String, dynamic>> add(List<int> chunk) {
    _bytes.add(chunk);
    var bytes = _bytes.takeBytes();
    final values = <Map<String, dynamic>>[];
    while (bytes.isNotEmpty) {
      if (_length == null) {
        var end = -1;
        for (var i = 0; i + 3 < bytes.length; i++) {
          if (bytes[i] == 13 &&
              bytes[i + 1] == 10 &&
              bytes[i + 2] == 13 &&
              bytes[i + 3] == 10) {
            end = i;
            break;
          }
        }
        if (end < 0) {
          if (bytes.length > 8192) {
            throw const FormatException('DAP header limit.');
          }
          break;
        }
        if (end > 8192) throw const FormatException('DAP header limit.');
        final lengths = ascii
            .decode(bytes.sublist(0, end))
            .split('\r\n')
            .where((s) => s.toLowerCase().startsWith('content-length:'))
            .toList();
        final length = lengths.length == 1
            ? int.tryParse(lengths.single.substring(15).trim())
            : null;
        if (length == null || length < 2 || length > limit) {
          throw const FormatException('Invalid DAP length.');
        }
        _length = length;
        bytes = Uint8List.sublistView(bytes, end + 4);
      }
      if (bytes.length < _length!) break;
      final value = jsonDecode(utf8.decode(bytes.sublist(0, _length!)));
      if (value is! Map<String, dynamic> ||
          value['seq'] is! int ||
          value['type'] is! String) {
        throw const FormatException('Invalid DAP message.');
      }
      values.add(value);
      bytes = Uint8List.sublistView(bytes, _length!);
      _length = null;
    }
    _bytes.add(bytes);
    return values;
  }

  static List<int> encode(Map<String, Object?> value) {
    final bytes = utf8.encode(jsonEncode(value));
    if (bytes.length > limit) {
      throw const DebugFailure('Debug request exceeds 4 MiB.');
    }
    return [
      ...ascii.encode('Content-Length: ${bytes.length}\r\n\r\n'),
      ...bytes,
    ];
  }
}

final class DapConnection implements DebugConnection {
  DapConnection(
    Stream<List<int>> input,
    this._write,
    this._closeTransport, {
    Stream<List<int>>? errors,
  }) {
    _input = input.listen(
      (bytes) {
        try {
          for (final value in _framer.add(bytes)) {
            _receive(value);
          }
        } catch (_) {
          _fail('Malformed or oversized debug adapter output.');
        }
      },
      onDone: () => _fail('Debug adapter stopped.'),
      onError: (_) => _fail('Debug adapter disconnected.'),
    );
    _errors = errors?.listen((_) {}, onError: (_) {});
  }
  final void Function(List<int>) _write;
  final Future<void> Function() _closeTransport;
  final _framer = DapFramer();
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  late final StreamSubscription<List<int>> _input;
  StreamSubscription<List<int>>? _errors;
  int _next = 0;
  bool _closed = false;
  Future<void>? _closing;
  @override
  Stream<Map<String, dynamic>> get events => _events.stream;
  void _send(Map<String, Object?> value) =>
      _write(DapFramer.encode({'seq': ++_next, ...value}));
  void _receive(Map<String, dynamic> value) {
    if (_closed) return;
    if (value['type'] == 'event') {
      _events.add(value);
    } else if (value['type'] == 'request') {
      _send({
        'type': 'response',
        'request_seq': value['seq'],
        'command': value['command'],
        'success': false,
        'message': 'Reverse requests cannot start terminals or child sessions.',
      });
    } else if (value['type'] == 'response') {
      final pending = _pending.remove(value['request_seq']);
      if (pending == null) return;
      if (value['success'] == true) {
        pending.complete(
          value['body'] is Map
              ? Map<String, dynamic>.from(value['body'] as Map)
              : {},
        );
      } else {
        pending.completeError(
          DebugFailure('${value['message'] ?? 'Debug request failed.'}'),
        );
      }
    }
  }

  @override
  Future<Map<String, dynamic>> request(
    String command, [
    Map<String, Object?> arguments = const {},
  ]) async {
    if (_closed || _pending.length >= 32) {
      throw const DebugFailure('Debug adapter unavailable or busy.');
    }
    final id = ++_next;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    try {
      _write(
        DapFramer.encode({
          'seq': id,
          'type': 'request',
          'command': command,
          'arguments': arguments,
        }),
      );
      return await completer.future.timeout(
        command == 'launch'
            ? const Duration(minutes: 10)
            : const Duration(seconds: 30),
      );
    } finally {
      _pending.remove(id);
    }
  }

  void _fail(String message) {
    if (_closed) return;
    _closed = true;
    for (final pending in _pending.values) {
      pending.completeError(DebugFailure(message));
    }
    _pending.clear();
    _events.add({
      'type': 'event',
      'event': 'tabryo.disconnected',
      'body': {'message': message},
    });
  }

  @override
  Future<void> close() => _closing ??= () async {
    _fail('Debug session closed.');
    await _closeTransport();
    await _input.cancel();
    await _errors?.cancel();
    await _events.close();
  }();
}

final class LocalDebugAdapters implements DebugAdapters {
  @override
  Future<DebugTools> devTools(
    DebugConfiguration configuration,
    Uri service,
    Cancellation cancellation,
  ) async {
    final project = configuration.project;
    if (project.kind == ProjectKind.python) {
      throw const DebugFailure('DevTools requires Dart or Flutter.');
    }
    final executable = command(
      project,
      configuration.tools,
      'devtools',
    ).executable;
    await _validate(project, executable);
    return LocalDevTools.start(
      executable,
      project.directory,
      service,
      cancellation,
    );
  }

  ({String executable, List<String> arguments}) command(
    DevelopmentProject project,
    ToolchainSelection tools,
    String command,
  ) {
    if (project.kind == ProjectKind.flutter) {
      final sdk = tools[ProjectTool.flutter];
      if (sdk == null) throw const DebugFailure('Select a Flutter SDK.');
      return (
        executable: p.join(
          sdk,
          'bin',
          'cache',
          'dart-sdk',
          'bin',
          Platform.isWindows ? 'dart.exe' : 'dart',
        ),
        arguments: [
          p.join(sdk, 'bin', 'cache', 'flutter_tools.snapshot'),
          command,
        ],
      );
    }
    final executable =
        tools[project.kind == ProjectKind.python
            ? ProjectTool.python
            : ProjectTool.dart];
    if (executable == null) {
      throw const DebugFailure('Select the project SDK or Python interpreter.');
    }
    return (
      executable: executable,
      arguments: project.kind == ProjectKind.python
          ? ['-m', 'debugpy.adapter']
          : [command],
    );
  }

  Future<void> _validate(DevelopmentProject project, String executable) async {
    if (!p.isAbsolute(executable) ||
        !await File(executable).exists() ||
        (Platform.isWindows &&
            p.extension(executable).toLowerCase() != '.exe') ||
        !p.equals(
          await Directory(project.workspace).resolveSymbolicLinks(),
          project.workspace,
        ) ||
        !p.equals(
          await Directory(project.directory).resolveSymbolicLinks(),
          project.directory,
        ) ||
        !(p.equals(project.workspace, project.directory) ||
            p.isWithin(project.workspace, project.directory))) {
      throw const DebugFailure(
        'The selected debugger or project is unavailable or moved.',
      );
    }
  }

  Future<void> _file(DevelopmentProject project, String path) async {
    if (!p.isAbsolute(path) ||
        !p.isWithin(project.directory, path) ||
        !p.equals(await File(path).resolveSymbolicLinks(), path)) {
      throw const DebugFailure(
        'Debug targets must be regular project files without links.',
      );
    }
    if ((await File(path).stat()).type != FileSystemEntityType.file) {
      throw const DebugFailure('Select a regular source file.');
    }
  }

  @override
  Future<DebugConnection> start(DebugConfiguration configuration) async {
    final project = configuration.project;
    final launch = command(project, configuration.tools, 'debug_adapter');
    await _validate(project, launch.executable);
    await _file(project, configuration.program);
    if (configuration.arguments.length > 64 ||
        configuration.arguments.any(
          (a) => a.length > 4096 || a.contains('\u0000'),
        ) ||
        configuration.breakpoints.length > 100 ||
        configuration.breakpoints.values.any(
          (v) => v.length > 200 || v.any((line) => line < 1),
        ) ||
        (project.kind == ProjectKind.flutter &&
            (configuration.device == null || configuration.device!.isEmpty))) {
      throw const DebugFailure(
        'Choose a device and bounded debugger arguments and breakpoints.',
      );
    }
    for (final path in configuration.breakpoints.keys) {
      await _file(project, path);
    }
    final child = await DebugProcess.start(
      launch.executable,
      launch.arguments,
      project.directory,
      environment: {'PYTHONNOUSERSITE': '1', 'PYTHONUNBUFFERED': '1'},
    );
    final connection = DapConnection(
      child.process.stdout,
      child.process.stdin.add,
      child.close,
      errors: child.process.stderr,
    );
    unawaited(
      child.process.stdin.done.catchError((Object error) {
        connection._fail('Debug adapter input closed.');
      }),
    );
    return connection;
  }

  @override
  Future<List<FlutterDevice>> devices(
    DevelopmentProject project,
    ToolchainSelection tools,
  ) async {
    if (project.kind != ProjectKind.flutter) {
      throw const DebugFailure('Device discovery requires Flutter.');
    }
    final launch = command(project, tools, 'devices');
    await _validate(project, launch.executable);
    final child = await DebugProcess.start(launch.executable, [
      ...launch.arguments,
      '--machine',
    ], project.directory);
    final errors = child.process.stderr.listen((_) {});
    try {
      final bytes = <int>[];
      await for (final chunk in child.process.stdout.timeout(
        const Duration(seconds: 60),
      )) {
        bytes.addAll(chunk);
        if (bytes.length > 512 * 1024) {
          throw const DebugFailure('Device discovery output limit.');
        }
      }
      if (await child.process.exitCode != 0) {
        throw const DebugFailure(
          'Flutter device discovery failed. Check the selected SDK.',
        );
      }
      final value = jsonDecode(utf8.decode(bytes));
      if (value is! List || value.length > 100) {
        throw const DebugFailure('Invalid Flutter device list.');
      }
      return [
        for (final item in value)
          if (item is Map &&
              item['id'] is String &&
              item['name'] is String &&
              item['isSupported'] != false)
            FlutterDevice(
              item['id'] as String,
              item['name'] as String,
              '${item['targetPlatform'] ?? ''}',
            ),
      ];
    } finally {
      await child.close();
      await errors.cancel();
    }
  }
}
