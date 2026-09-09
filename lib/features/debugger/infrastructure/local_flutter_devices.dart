import 'dart:async';
import 'dart:convert';

import '../../../core/cancellation.dart';
import '../domain/debug_session.dart';

/// The Flutter daemon's bracketed JSON lines are distinct from DAP framing.
/// This connection only enables discovery; it never launches applications.
final class LocalFlutterDevices implements FlutterDeviceDiscovery {
  LocalFlutterDevices(
    Stream<List<int>> output,
    this._write,
    this._closeTransport, {
    Stream<List<int>>? errors,
  }) {
    _output = output
        .transform(utf8.decoder)
        .listen(
          _read,
          onError: (Object _) =>
              _fail('Flutter device discovery disconnected.'),
          onDone: () =>
              _fail('Flutter device discovery ended. Start discovery again.'),
        );
    _errors = errors?.listen((_) {}, onError: (Object _) {});
  }
  final void Function(List<int>) _write;
  final Future<void> Function() _closeTransport;
  late final StreamSubscription<String> _output;
  StreamSubscription<List<int>>? _errors;
  final _changes = StreamController<void>.broadcast();
  final _pending = <int, Completer<Object?>>{};
  final _devices = <String, FlutterDevice>{};
  final _initialEvents = <Map>[];
  bool _initializing = true;
  bool _closed = false;
  int _next = 0;
  String _buffer = '';
  Future<void>? _closing;
  @override
  String? error;
  @override
  Stream<void> get changes => _changes.stream;
  @override
  List<FlutterDevice> get devices => List.unmodifiable(_devices.values);

  Future<void> initialize(Cancellation cancellation) async {
    final poll = Timer.periodic(const Duration(milliseconds: 30), (_) {
      if (cancellation.isCancelled) {
        _fail('Flutter device discovery was cancelled.');
      }
    });
    try {
      cancellation.check();
      await _request('device.enable');
      final initial = await _request('device.getDevices');
      cancellation.check();
      if (initial is! List || initial.length > 100) {
        throw const FormatException();
      }
      for (final item in initial) {
        _device(item);
      }
      for (final event in _initialEvents) {
        _event(event);
      }
      _initialEvents.clear();
      _initializing = false;
      if (_closed) {
        throw const DebugFailure(
          'Flutter device discovery ended during startup.',
        );
      }
      _changes.add(null);
    } catch (failure) {
      await close();
      if (failure is Cancelled || failure is DebugFailure) rethrow;
      throw const DebugFailure('Flutter returned an invalid device list.');
    } finally {
      poll.cancel();
    }
  }

  Future<Object?> _request(String method) async {
    if (_closed) {
      throw const DebugFailure('Flutter device discovery is closed.');
    }
    final id = ++_next;
    final pending = _pending[id] = Completer<Object?>();
    try {
      _write(
        utf8.encode(
          '${jsonEncode([
            {'id': id, 'method': method},
          ])}\n',
        ),
      );
      return await pending.future.timeout(const Duration(seconds: 60));
    } on TimeoutException {
      throw const DebugFailure(
        'Flutter device discovery timed out. Check the selected SDK.',
      );
    } finally {
      _pending.remove(id);
    }
  }

  void _read(String text) {
    if (_closed) return;
    try {
      _buffer += text;
      if (_buffer.length > 512 * 1024) throw const FormatException();
      int newline;
      while ((newline = _buffer.indexOf('\n')) >= 0) {
        final line = _buffer.substring(0, newline).trim();
        _buffer = _buffer.substring(newline + 1);
        if (!RegExp(r'^\[\s*\{').hasMatch(line)) continue;
        final batch = jsonDecode(line);
        if (batch is! List || batch.length > 128) throw const FormatException();
        for (final message in batch) {
          if (message is! Map) throw const FormatException();
          final pending = _pending[message['id']];
          if (pending != null && !pending.isCompleted) {
            if (message.containsKey('error')) {
              final failure = message['error'];
              final detail = failure is Map ? failure['message'] : failure;
              final summary = detail is String
                  ? String.fromCharCodes(
                          detail.split('\n').first.runes.take(512),
                        )
                        .replaceAll(
                          RegExp(r'https?://\S+|wss?://\S+'),
                          '[endpoint]',
                        )
                        .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ')
                  : 'No diagnostic supplied.';
              pending.completeError(
                DebugFailure(
                  'Flutter refused device discovery. Check the selected SDK. $summary',
                ),
              );
            } else {
              pending.complete(message['result']);
            }
          } else if (message['event'] == 'device.added' ||
              message['event'] == 'device.removed') {
            if (_initializing) {
              if (_initialEvents.length >= 256) throw const FormatException();
              final params = message['params'];
              if (params is! Map) throw const FormatException();
              final removal =
                  message['event'] == 'device.removed' ||
                  params['isSupported'] == false ||
                  params['available'] == false;
              // Retain only bounded fields, never arbitrary daemon payloads.
              _initialEvents.add({
                'event': removal ? 'device.removed' : 'device.added',
                'params': {
                  'id': _text(params, 'id'),
                  if (!removal) 'name': _text(params, 'name'),
                  if (!removal) 'platform': _text(params, 'platform'),
                },
              });
            } else {
              _event(message);
              _changes.add(null);
            }
          }
        }
      }
    } catch (_) {
      _fail('Flutter device discovery returned invalid or excessive output.');
    }
  }

  String _text(Map value, String key) {
    final text = value[key];
    if (text is! String ||
        text.isEmpty ||
        text.length > 4096 ||
        text.contains('\u0000')) {
      throw const FormatException();
    }
    return text;
  }

  void _device(Object? value) {
    if (value is! Map) throw const FormatException();
    final id = _text(value, 'id');
    if (value['isSupported'] == false || value['available'] == false) {
      _devices.remove(id);
      return;
    }
    if (!_devices.containsKey(id) && _devices.length >= 100) {
      throw const FormatException();
    }
    _devices[id] = FlutterDevice(
      id,
      _text(value, 'name'),
      _text(value, 'platform'),
    );
  }

  void _event(Map message) {
    final value = message['params'];
    if (message['event'] == 'device.removed') {
      if (value is! Map) throw const FormatException();
      _devices.remove(_text(value, 'id'));
    } else {
      _device(value);
    }
  }

  void _fail(String message) {
    if (_closed) return;
    error = message;
    unawaited(close().catchError((Object _) {}));
  }

  @override
  Future<void> close() => _closing ??= () async {
    _closed = true;
    _buffer = '';
    _devices.clear();
    _initialEvents.clear();
    for (final pending in _pending.values) {
      if (!pending.isCompleted) {
        pending.completeError(
          DebugFailure(error ?? 'Flutter device discovery closed.'),
        );
      }
    }
    _changes.add(null);
    try {
      await _closeTransport();
    } finally {
      await _output.cancel();
      await _errors?.cancel();
      await _changes.close();
    }
  }();
}
