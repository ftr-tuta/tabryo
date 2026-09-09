import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../domain/debug_session.dart';
import '../../../core/cancellation.dart';
import 'debug_process.dart';
import 'local_debug_inspection.dart';

final class LocalDevTools implements DebugTools {
  LocalDevTools._(
    this.child,
    this._output,
    this._errors,
    this.uri,
    this._inspection,
  );
  final LocalDebugInspection _inspection;
  Future<void>? _closing;
  @override
  Uri get dtdUri => _inspection.uri;
  @override
  Stream<DebugSourceLocation> get sourceLocations => _inspection.sources;
  @override
  Future<void> selectWidget(bool enabled) => _inspection.selectWidget(enabled);
  @override
  Future<DebugSourceLocation> selectedWidgetSource() =>
      _inspection.selectedWidgetSource();
  final DebugProcess child;
  final StreamSubscription<String> _output;
  final StreamSubscription<List<int>> _errors;
  @override
  final Uri uri;
  static Future<LocalDevTools> start(
    String dart,
    String root,
    Uri service,
    Cancellation cancellation,
  ) async {
    cancellation.check();
    if (!['ws', 'http'].contains(service.scheme) ||
        !['127.0.0.1', 'localhost', '::1'].contains(service.host) ||
        service.userInfo.isNotEmpty) {
      throw const DebugFailure('DevTools requires this local debug session.');
    }
    final inspection = await LocalDebugInspection.start(
      dart,
      root,
      service,
      cancellation,
    );
    late final DebugProcess child;
    try {
      child = await DebugProcess.start(dart, [
        'devtools',
        '--machine',
        '--host',
        '127.0.0.1',
        '--port',
        '0',
        '--no-launch-browser',
        '--dtd-uri',
        inspection.uri.toString(),
      ], root);
    } catch (_) {
      await inspection.close();
      rethrow;
    }
    final ready = Completer<Uri>();
    final cancelled = Timer.periodic(const Duration(milliseconds: 30), (_) {
      if (cancellation.isCancelled && !ready.isCompleted) {
        ready.completeError(const Cancelled());
      }
    });
    String buffered = '';
    final output = child.process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(
          (text) {
            if (ready.isCompleted) return;
            buffered += text;
            if (buffered.length > 64 * 1024) {
              ready.completeError(
                const DebugFailure('DevTools startup output limit.'),
              );
              return;
            }
            var end = buffered.indexOf('\n');
            while (end >= 0) {
              final line = buffered.substring(0, end).trim();
              buffered = buffered.substring(end + 1);
              try {
                final event = jsonDecode(line);
                if (event is Map &&
                    event['event'] == 'server.started' &&
                    event['params'] is Map) {
                  final params = event['params'] as Map;
                  final port = params['port'];
                  if (port is int &&
                      port > 0 &&
                      port <= 65535 &&
                      ['127.0.0.1', 'localhost'].contains(params['host'])) {
                    ready.complete(
                      Uri(
                        scheme: 'http',
                        host: '127.0.0.1',
                        port: port,
                        path: '/',
                        queryParameters: {'uri': service.toString()},
                      ),
                    );
                    return;
                  }
                }
              } on FormatException {
                /* SDK startup notices are not protocol events. */
              }
              end = buffered.indexOf('\n');
            }
          },
          onDone: () {
            if (!ready.isCompleted) {
              ready.completeError(
                const DebugFailure('DevTools stopped before startup.'),
              );
            }
          },
          onError: (Object error) {
            if (!ready.isCompleted) ready.completeError(error);
          },
        );
    final errors = child.process.stderr.listen((_) {});
    try {
      final uri = await ready.future.timeout(const Duration(seconds: 45));
      cancellation.check();
      return LocalDevTools._(child, output, errors, uri, inspection);
    } catch (_) {
      await child.close();
      await output.cancel();
      await errors.cancel();
      await inspection.close();
      rethrow;
    } finally {
      cancelled.cancel();
    }
  }

  @override
  Future<void> open() async {
    if (Platform.isWindows) {
      final execute = DynamicLibrary.open('shell32.dll')
          .lookupFunction<
            IntPtr Function(
              IntPtr,
              Pointer<Utf16>,
              Pointer<Utf16>,
              Pointer<Utf16>,
              Pointer<Utf16>,
              Int32,
            ),
            int Function(
              int,
              Pointer<Utf16>,
              Pointer<Utf16>,
              Pointer<Utf16>,
              Pointer<Utf16>,
              int,
            )
          >('ShellExecuteW');
      final verb = 'open'.toNativeUtf16();
      final target = uri.toString().toNativeUtf16();
      try {
        if (execute(0, verb, target, nullptr, nullptr, 1) <= 32) {
          throw const DebugFailure('Could not open the system browser.');
        }
      } finally {
        malloc.free(verb);
        malloc.free(target);
      }
    } else {
      final result = await Process.run('xdg-open', [uri.toString()]);
      if (result.exitCode != 0) {
        throw const DebugFailure('Could not open the system browser.');
      }
    }
  }

  @override
  Future<void> close() => _closing ??= () async {
    try {
      await child.close();
      await _output.cancel();
      await _errors.cancel();
    } finally {
      await _inspection.close();
    }
  }();
}
