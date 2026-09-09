import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dtd/dtd.dart';
import 'package:vm_service/vm_service.dart' as vm;

import '../../../core/cancellation.dart';
import '../domain/debug_session.dart';
import 'debug_process.dart';

/// The daemon and VM connection belong to one debug session. Neither its
/// trusted-client secret nor its authenticated URI is persisted to disk.
final class LocalDebugInspection {
  LocalDebugInspection._(this._child);
  final DebugProcess _child;
  DartToolingDaemon? _daemon;
  vm.VmService? _vm;
  final _sources = StreamController<DebugSourceLocation>.broadcast();
  Stream<DebugSourceLocation> get sources => _sources.stream;
  final _subscriptions = <StreamSubscription<dynamic>>[];
  late final Uri uri;
  bool _closed = false;
  Future<void>? _closing;
  static const _deadline = Duration(seconds: 15);

  static Future<LocalDebugInspection> start(
    String dart,
    String root,
    Uri service,
    Cancellation cancellation,
  ) async {
    cancellation.check();
    final result = LocalDebugInspection._(
      await DebugProcess.start(dart, ['tooling-daemon', '--machine'], root),
    );
    final ready = Completer<Map>();
    final cancelled = Timer.periodic(const Duration(milliseconds: 30), (_) {
      if (cancellation.isCancelled && !ready.isCompleted) {
        ready.completeError(const Cancelled());
      }
    });
    var buffered = '';
    result._subscriptions.add(
      result._child.process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(
            (chunk) {
              if (ready.isCompleted) return;
              buffered += chunk;
              if (buffered.length > 64 * 1024) {
                ready.completeError(
                  const DebugFailure('DTD startup output limit.'),
                );
                return;
              }
              var end = buffered.indexOf('\n');
              while (end >= 0) {
                final line = buffered.substring(0, end).trim();
                buffered = buffered.substring(end + 1);
                try {
                  final message = jsonDecode(line);
                  if (message is Map &&
                      message['tooling_daemon_details'] is Map) {
                    ready.complete(message['tooling_daemon_details'] as Map);
                    return;
                  }
                } on FormatException {
                  // SDK notices preceding the machine event are not protocol.
                  end = buffered.indexOf('\n');
                  continue;
                }
                end = buffered.indexOf('\n');
              }
            },
            onDone: () {
              if (!ready.isCompleted) {
                ready.completeError(
                  const DebugFailure('DTD stopped before startup.'),
                );
              }
            },
            onError: (Object failure) {
              if (!ready.isCompleted) ready.completeError(failure);
            },
          ),
    );
    result._subscriptions.add(result._child.process.stderr.listen((_) {}));
    try {
      final details = await ready.future.timeout(_deadline);
      cancellation.check();
      final address = details['uri'];
      final secret = details['trusted_client_secret'];
      final uri = address is String ? Uri.tryParse(address) : null;
      if (uri == null ||
          uri.scheme != 'ws' ||
          !['127.0.0.1', '::1'].contains(uri.host) ||
          !uri.hasPort ||
          uri.userInfo.isNotEmpty ||
          secret is! String ||
          secret.isEmpty ||
          secret.length > 4096) {
        throw const DebugFailure('Invalid local DTD startup response.');
      }
      result.uri = uri;
      final connecting = DartToolingDaemon.connect(uri).then((daemon) async {
        if (result._closed) {
          await daemon.close();
          throw const Cancelled();
        }
        return result._daemon = daemon;
      });
      final daemon = await connecting.timeout(_deadline);
      cancellation.check();
      await daemon
          .setIDEWorkspaceRoots(secret, [Uri.directory(root)])
          .timeout(_deadline);
      await daemon
          .registerVmService(
            uri: service.toString(),
            secret: secret,
            name: root,
          )
          .timeout(_deadline);
      cancellation.check();
      final socketUri = service.replace(
        scheme: 'ws',
        path: service.path.endsWith('/ws')
            ? service.path
            : '${service.path.endsWith('/') ? service.path : '${service.path}/'}ws',
      );
      final socket = await WebSocket.connect(socketUri.toString())
          .then((socket) {
            if (result._closed) {
              unawaited(socket.close());
              throw const Cancelled();
            }
            return socket;
          })
          .timeout(_deadline);
      final connection = result._vm = vm.VmService(
        socket.map((message) {
          if (message is! String || message.length > 4 * 1024 * 1024) {
            unawaited(socket.close());
            throw const DebugFailure('VM inspection message limit.');
          }
          return message;
        }),
        socket.add,
        disposeHandler: socket.close,
      );
      result._subscriptions.add(
        connection
            .onEvent('ToolEvent')
            .listen(
              (event) {
                if (result._closed || event.extensionKind != 'navigate') return;
                final data = event.extensionData?.data;
                if (data?['source'] != 'flutter.inspector') return;
                final location = DebugSourceLocation.fromInspector(data);
                if (location != null) result._sources.add(location);
              },
              onError: (Object _) {
                // A disconnected VM cannot navigate the editor. DAP owns session state.
              },
            ),
      );
      await connection.streamListen('ToolEvent').timeout(_deadline);
      cancellation.check();
      return result;
    } catch (_) {
      await result.close();
      rethrow;
    } finally {
      cancelled.cancel();
    }
  }

  Future<String> _flutterIsolate() async {
    final connection = _vm;
    if (_closed || connection == null) {
      throw const DebugFailure('Inspection stopped.');
    }
    final isolates =
        (await connection.getVM().timeout(_deadline)).isolates ?? [];
    for (final isolate in isolates.take(64)) {
      final id = isolate.id;
      if (id == null) continue;
      final details = await connection.getIsolate(id).timeout(_deadline);
      if (details.extensionRPCs?.contains('ext.flutter.inspector.show') ==
          true) {
        return id;
      }
    }
    throw const DebugFailure(
      'Wait for a running Flutter debug application with Inspector extensions.',
    );
  }

  Future<void> selectWidget(bool enabled) async {
    final isolate = await _flutterIsolate();
    if (_closed) throw const DebugFailure('Inspection stopped.');
    await _vm!
        .callServiceExtension(
          'ext.flutter.inspector.show',
          isolateId: isolate,
          args: {'enabled': enabled.toString()},
        )
        .timeout(_deadline);
  }

  Future<DebugSourceLocation> selectedWidgetSource() async {
    final isolate = await _flutterIsolate();
    if (_closed) throw const DebugFailure('Inspection stopped.');
    const group = 'tabryo.source';
    try {
      final response = await _vm!
          .callServiceExtension(
            'ext.flutter.inspector.getSelectedSummaryWidget',
            isolateId: isolate,
            args: {'objectGroup': group},
          )
          .timeout(_deadline);
      final widget = response.json?['result'];
      final creation = widget is Map ? widget['creationLocation'] : null;
      final location = DebugSourceLocation.fromInspector(creation);
      if (location == null) {
        throw const DebugFailure(
          'Select a widget with a source location in the Flutter Inspector.',
        );
      }
      return location;
    } finally {
      if (!_closed) {
        await _vm!
            .callServiceExtension(
              'ext.flutter.inspector.disposeGroup',
              isolateId: isolate,
              args: {'objectGroup': group},
            )
            .timeout(_deadline);
      }
    }
  }

  Future<void> close() => _closing ??= () async {
    _closed = true;
    try {
      try {
        await _vm?.dispose();
      } finally {
        await _daemon?.close();
      }
    } finally {
      await _child.close();
      for (final subscription in _subscriptions) {
        await subscription.cancel();
      }
      await _sources.close();
    }
  }();
}
