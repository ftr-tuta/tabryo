library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

const int sessionInputLimit = 256 * 1024;
const int globalInputLimit = 2 * 1024 * 1024;

final class TerminalLaunchSpec {
  const TerminalLaunchSpec({
    required this.executable,
    required this.workingDirectory,
    this.arguments = const <String>[],
    this.environment,
    this.unsetEnvironment = const [],
    this.rows = 24,
    this.columns = 80,
  });

  final String executable;
  final String workingDirectory;
  final List<String> arguments;
  final Map<String, String>? environment;
  final List<String> unsetEnvironment;
  final int rows;
  final int columns;
}

final class TerminalPty {
  TerminalPty.start(TerminalLaunchSpec requested) {
    _output = StreamController<Uint8List>(
      sync: true,
      onListen: _resumeOutput,
      onPause: _pauseOutput,
      onResume: _resumeOutput,
      onCancel: _cancelOutput,
    );
    late final TerminalLaunchSpec spec;
    try {
      _validateLaunch(requested);
      spec = _windowsCommandScriptSpec(requested);
    } catch (_) {
      _nativeOutputPort.close();
      _nativeExitPort.close();
      _output.close();
      rethrow;
    }
    final environment = <String, String>{};
    for (final source in [
      Platform.environment,
      spec.environment ?? const <String, String>{},
    ]) {
      for (final entry in source.entries) {
        environment[Platform.isWindows ? entry.key.toUpperCase() : entry.key] =
            entry.value;
      }
    }
    environment['TERM'] = 'xterm-256color';
    for (final key in spec.unsetEnvironment) {
      environment.remove(Platform.isWindows ? key.toUpperCase() : key);
    }
    final argv = calloc<Pointer<Utf8>>(spec.arguments.length + 2);
    final envp = calloc<Pointer<Utf8>>(environment.length + 1);
    final options = calloc<_PtyOptions>();
    try {
      argv[0] = spec.executable.toNativeUtf8();
      for (var index = 0; index < spec.arguments.length; index++) {
        argv[index + 1] = spec.arguments[index].toNativeUtf8();
      }
      for (var index = 0; index < environment.length; index++) {
        final entry = environment.entries.elementAt(index);
        envp[index] = '${entry.key}=${entry.value}'.toNativeUtf8();
      }
      options.ref
        ..rows = spec.rows
        ..cols = spec.columns
        ..executable = spec.executable.toNativeUtf8().cast()
        ..arguments = argv.cast()
        ..environment = envp.cast()
        ..workingDirectory = spec.workingDirectory.toNativeUtf8().cast()
        ..stdoutPort = _nativeOutputPort.sendPort.nativePort
        ..exitPort = _nativeExitPort.sendPort.nativePort
        ..ackRead = true
        ..windowsCommandScript = !identical(requested, spec);
      _handle = _bindings.create(options);
      if (_handle == nullptr) {
        throw StateError('PTY spawn failed: ${_bindings.error()}');
      }
      _pid = _bindings.pid(_handle);
    } catch (_) {
      if (!_output.isClosed) _output.close();
      _nativeOutputPort.close();
      _nativeExitPort.close();
      rethrow;
    } finally {
      calloc.free(options.ref.executable);
      calloc.free(options.ref.workingDirectory);
      for (var index = 0; index <= spec.arguments.length; index++) {
        calloc.free(argv[index]);
      }
      for (var index = 0; index < environment.length; index++) {
        calloc.free(envp[index]);
      }
      calloc.free(argv);
      calloc.free(envp);
      calloc.free(options);
    }
    _nativeOutputPort.listen(_handleNativeOutput);
    _nativeExitPort.first.then((value) {
      _exit.complete(value as int);
      _tryRelease();
    });
  }

  final ReceivePort _nativeOutputPort = ReceivePort();
  final ReceivePort _nativeExitPort = ReceivePort();
  late final StreamController<Uint8List> _output;
  final Completer<int> _exit = Completer<int>();
  final Completer<void> _drained = Completer<void>();
  final Completer<void> _released = Completer<void>();
  late final Pointer<Void> _handle;
  late final int _pid;
  Timer? _releaseTimer;
  bool _closeRequested = false;
  bool _nativeReleased = false;
  bool _outputReady = false;
  bool _outputAckPending = false;
  bool _outputConsumerGone = false;
  StreamSubscription<Uint8List>? _consumer;

  Stream<Uint8List> get output => _PtyOutput(this);
  Future<int> get exitCode => _exit.future;
  Future<void> get drained => _drained.future;
  int get pid => _pid;

  bool write(Uint8List value) {
    if (_closeRequested ||
        _nativeReleased ||
        value.isEmpty ||
        value.length > sessionInputLimit) {
      return false;
    }
    final bytes = malloc<Int8>(value.length);
    try {
      bytes.asTypedList(value.length).setAll(0, value);
      return _bindings.write(_handle, bytes, value.length) == 1;
    } finally {
      malloc.free(bytes);
    }
  }

  void resize(int rows, int columns) {
    if (rows < 1 || rows > 32767 || columns < 1 || columns > 32767) {
      throw ArgumentError('Terminal dimensions must be between 1 and 32767.');
    }
    if (!_closeRequested && !_nativeReleased) {
      _bindings.resize(_handle, rows, columns);
    }
  }

  Future<void> close() {
    // Closing drains even a paused or never-observed output stream. An active
    // listener receives the remaining bytes; unobserved output is discarded.
    if (!_outputConsumerGone) {
      _consumer ??= _output.stream.listen((_) {});
      while (_consumer!.isPaused) {
        _consumer!.resume();
      }
    }
    if (!_closeRequested && !_nativeReleased) {
      _closeRequested = true;
      _bindings.close(_handle);
    }
    return _released.future;
  }

  void _handleNativeOutput(Object? value) {
    if (value is Uint8List) {
      if (_outputConsumerGone) {
        _bindings.ack(_handle);
      } else {
        _output.add(value);
        if (_outputReady) {
          _bindings.ack(_handle);
        } else {
          _outputAckPending = true;
        }
      }
      return;
    }
    if (value is int && !_drained.isCompleted) {
      _drained.complete();
      _output.close();
      _nativeOutputPort.close();
      _tryRelease();
    }
  }

  void _pauseOutput() => _outputReady = false;

  void _resumeOutput() {
    _outputReady = true;
    if (_outputAckPending && !_nativeReleased) {
      _outputAckPending = false;
      _bindings.ack(_handle);
    }
  }

  Future<void> _cancelOutput() async {
    _outputConsumerGone = true;
    _outputReady = true;
    if (_outputAckPending && !_nativeReleased) {
      _outputAckPending = false;
      _bindings.ack(_handle);
    }
    if (!_closeRequested && !_nativeReleased) {
      _closeRequested = true;
      _bindings.close(_handle);
    }
  }

  void _tryRelease() {
    if (!_exit.isCompleted || !_drained.isCompleted || _released.isCompleted) {
      return;
    }
    if (_bindings.destroy(_handle) == 1) {
      _releaseTimer?.cancel();
      _nativeReleased = true;
      _nativeExitPort.close();
      _released.complete();
    } else {
      _releaseTimer ??= Timer.periodic(
        const Duration(milliseconds: 10),
        (_) => _tryRelease(),
      );
    }
  }
}

final class _PtyOutput extends Stream<Uint8List> {
  _PtyOutput(this.owner);
  final TerminalPty owner;

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    final subscription = owner._output.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
    owner._consumer = subscription;
    return subscription;
  }
}

void _validateLaunch(TerminalLaunchSpec spec) {
  if (!File(spec.executable).isAbsolute ||
      !Directory(spec.workingDirectory).isAbsolute ||
      [
        spec.executable,
        spec.workingDirectory,
        ...spec.arguments,
      ].any((v) => v.contains('\x00')) ||
      spec.rows < 1 ||
      spec.rows > 32767 ||
      spec.columns < 1 ||
      spec.columns > 32767) {
    throw ArgumentError(
      'Launch requires absolute paths, valid dimensions, and no NUL characters.',
    );
  }
  for (final entry in (spec.environment ?? const <String, String>{}).entries) {
    if (entry.key.isEmpty ||
        entry.key.contains('=') ||
        entry.key.contains('\x00') ||
        entry.value.contains('\x00')) {
      throw ArgumentError('Invalid environment entry.');
    }
  }
}

TerminalLaunchSpec _windowsCommandScriptSpec(TerminalLaunchSpec spec) {
  if (!Platform.isWindows ||
      (!spec.executable.toLowerCase().endsWith('.cmd') &&
          !spec.executable.toLowerCase().endsWith('.bat'))) {
    return spec;
  }
  final values = <String>[spec.executable, ...spec.arguments];
  // cmd expands percent variables even inside quotes. Delayed expansion is
  // disabled; other metacharacters remain literal within the quoted argv.
  final unsafe = RegExp(r'["%]');
  if (values.any(
    (value) =>
        value.contains('\x00') ||
        value.contains('\r') ||
        value.contains('\n') ||
        unsafe.hasMatch(value),
  )) {
    throw ArgumentError('Unsafe command-script path or argument.');
  }
  final invocation =
      '""${spec.executable}"${spec.arguments.map((value) => ' "$value"').join()}"';
  return TerminalLaunchSpec(
    executable:
        Platform.environment['ComSpec'] ?? r'C:\Windows\System32\cmd.exe',
    workingDirectory: spec.workingDirectory,
    arguments: <String>['/d', '/s', '/v:off', '/c', invocation],
    environment: spec.environment,
    unsetEnvironment: spec.unsetEnvironment,
    rows: spec.rows,
    columns: spec.columns,
  );
}

final DynamicLibrary _library = DynamicLibrary.open(
  Platform.isWindows ? 'terminal_host.dll' : 'libterminal_host.so',
);
final _Bindings _bindings = _Bindings(_library);

final class _PtyOptions extends Struct {
  @Int32()
  external int rows;
  @Int32()
  external int cols;
  external Pointer<Int8> executable;
  external Pointer<Pointer<Int8>> arguments;
  external Pointer<Pointer<Int8>> environment;
  external Pointer<Int8> workingDirectory;
  @Int64()
  external int stdoutPort;
  @Int64()
  external int exitPort;
  @Bool()
  external bool ackRead;
  @Bool()
  external bool windowsCommandScript;
}

final class _Bindings {
  _Bindings(DynamicLibrary library)
    : create = library
          .lookupFunction<
            Pointer<Void> Function(Pointer<_PtyOptions>),
            Pointer<Void> Function(Pointer<_PtyOptions>)
          >('pty_create'),
      write = library
          .lookupFunction<
            Int32 Function(Pointer<Void>, Pointer<Int8>, Int32),
            int Function(Pointer<Void>, Pointer<Int8>, int)
          >('pty_write'),
      ack = library
          .lookupFunction<
            Void Function(Pointer<Void>),
            void Function(Pointer<Void>)
          >('pty_ack_read'),
      resize = library
          .lookupFunction<
            Int32 Function(Pointer<Void>, Int32, Int32),
            int Function(Pointer<Void>, int, int)
          >('pty_resize'),
      pid = library
          .lookupFunction<
            Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)
          >('pty_getpid'),
      close = library
          .lookupFunction<
            Void Function(Pointer<Void>),
            void Function(Pointer<Void>)
          >('pty_close'),
      destroy = library
          .lookupFunction<
            Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)
          >('pty_destroy'),
      _error = library
          .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
            'pty_error',
          ) {
    // Initialize before pty_create can start workers that post to Dart ports.
    final initialize = library
        .lookupFunction<
          IntPtr Function(Pointer<Void>),
          int Function(Pointer<Void>)
        >('Dart_InitializeApiDL');
    if (initialize(NativeApi.initializeApiDLData) != 0) {
      throw StateError('The terminal host is incompatible with this Dart VM.');
    }
  }

  final Pointer<Void> Function(Pointer<_PtyOptions>) create;
  final int Function(Pointer<Void>, Pointer<Int8>, int) write;
  final void Function(Pointer<Void>) ack;
  final int Function(Pointer<Void>, int, int) resize;
  final int Function(Pointer<Void>) pid;
  final void Function(Pointer<Void>) close;
  final int Function(Pointer<Void>) destroy;
  final Pointer<Utf8> Function() _error;

  String? error() {
    final value = _error();
    return value == nullptr ? null : value.toDartString();
  }
}
