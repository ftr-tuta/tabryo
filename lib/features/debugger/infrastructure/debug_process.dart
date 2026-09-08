import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../domain/debug_session.dart';

/// Adapter children stay in an owned Windows Job / Linux process group. The
/// adapter receives no protocol input until ownership has been established.
final class DebugProcess {
  DebugProcess._(this.process, this._job);
  final Process process;
  final int? _job;
  Future<void>? _closing;
  static final _kernel = DynamicLibrary.open('kernel32.dll');
  static final _close = _kernel
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');

  static Future<DebugProcess> start(
    String executable,
    List<String> arguments,
    String root, {
    Map<String, String> environment = const {},
  }) async {
    final env = {...Platform.environment, ...environment};
    env.remove('PYTHONHOME');
    env.remove('PYTHONPATH');
    final process = await Process.start(
      Platform.isLinux ? '/usr/bin/setsid' : executable,
      Platform.isLinux ? [executable, ...arguments] : arguments,
      workingDirectory: root,
      environment: env,
      includeParentEnvironment: false,
      runInShell: false,
    );
    int? job;
    try {
      if (Platform.isWindows) {
        final create = _kernel
            .lookupFunction<
              IntPtr Function(Pointer<Void>, Pointer<Utf16>),
              int Function(Pointer<Void>, Pointer<Utf16>)
            >('CreateJobObjectW');
        final configure = _kernel
            .lookupFunction<
              Int32 Function(IntPtr, Int32, Pointer<Void>, Uint32),
              int Function(int, int, Pointer<Void>, int)
            >('SetInformationJobObject');
        final open = _kernel
            .lookupFunction<
              IntPtr Function(Uint32, Int32, Uint32),
              int Function(int, int, int)
            >('OpenProcess');
        final assign = _kernel
            .lookupFunction<
              Int32 Function(IntPtr, IntPtr),
              int Function(int, int)
            >('AssignProcessToJobObject');
        job = create(nullptr, nullptr);
        if (job == 0) {
          throw const DebugFailure(
            'Could not create the debugger process job.',
          );
        }
        final info = calloc<Uint8>(
          144,
        ); // JOBOBJECT_EXTENDED_LIMIT_INFORMATION, x64.
        final handle = open(0x0101, 0, process.pid); // SET_QUOTA | TERMINATE.
        try {
          ByteData.sublistView(info.asTypedList(144))
              .setUint32(16, 0x2000, Endian.little);
          if (configure(job, 9, info.cast(), 144) == 0 ||
              handle == 0 ||
              assign(job, handle) == 0) {
            throw const DebugFailure(
              'Could not contain the debugger process tree.',
            );
          }
        } finally {
          calloc.free(info);
          if (handle != 0) _close(handle);
        }
      }
      return DebugProcess._(process, job);
    } catch (_) {
      if (job != null && job != 0) _close(job);
      process.kill();
      await process.exitCode;
      rethrow;
    }
  }

  Future<void> close() => _closing ??= () async {
    if (_job != null) {
      _close(_job);
    } else if (Platform.isLinux) {
      Process.killPid(-process.pid, ProcessSignal.sigkill);
      process.kill(ProcessSignal.sigkill);
    } else {
      process.kill();
    }
    await process.exitCode.timeout(const Duration(seconds: 5));
    try {
      await process.stdin.close();
    } catch (_) {
      /* The adapter can close first. */
    }
  }();
}
