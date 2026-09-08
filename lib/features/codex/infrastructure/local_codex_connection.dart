import 'dart:async';
import 'dart:io';

import '../domain/codex_connection.dart';
import 'codex_rpc_channel.dart';

final class LocalCodexConnection implements CodexConnection {
  LocalCodexConnection({required this.executable, this.environment});
  final String? executable;
  final Map<String, String>? environment;
  final _events = StreamController<CodexEvent>.broadcast();
  CodexRpcChannel? _channel;
  StreamSubscription<CodexEvent>? _subscription;
  bool _ready = false;
  int _generation = 0;
  Future<void> _closing = Future<void>.value();

  @override
  bool get connected => _ready && (_channel?.connected ?? false);
  @override
  Stream<CodexEvent> get events => _events.stream;

  @override
  Future<void> connect(String workspace) async {
    await close();
    final generation = ++_generation;
    if (executable == null) {
      throw const CodexFailure(
        'Install the native Codex CLI executable on PATH, then reconnect.',
      );
    }
    Process process;
    try {
      final launchEnvironment = {...Platform.environment, ...?environment};
      // This is an independent client. A Tabryo launched from Codex must not
      // attach its new server to the parent Desktop task's private tools pipe.
      for (final name in const [
        'CODEX_APP_TOOLS_PIPE_PATH',
        'CODEX_THREAD_ID',
        'CODEX_SESSION_ID',
        'CODEX_INTERNAL_ORIGINATOR_OVERRIDE',
      ]) {
        launchEnvironment.remove(name);
      }
      process = await Process.start(
        executable!,
        const ['app-server'],
        workingDirectory: workspace,
        environment: launchEnvironment,
        includeParentEnvironment: false,
        mode: ProcessStartMode.normal,
      );
    } catch (_) {
      throw const CodexFailure(
        'Could not start Codex App Server. Check the CLI installation and workspace.',
      );
    }
    // Never retain or surface stderr: it may contain credentials or server logs.
    final stderr = process.stderr.listen((_) {});
    final channel = CodexRpcChannel(
      input: process.stdout,
      send: process.stdin.add,
      closeTransport: () async {
        try {
          await process.stdin.close().timeout(const Duration(seconds: 2));
          // Closing stdin can fail after child exit; exitCode below remains authoritative.
          // ignore: dartitect_empty_catch
        } catch (_) {
          /* The process may already have closed its input. */
        }
        try {
          await process.exitCode.timeout(const Duration(seconds: 3));
        } on TimeoutException {
          process.kill();
          try {
            await process.exitCode.timeout(const Duration(seconds: 2));
          } on TimeoutException {
            throw const CodexFailure(
              'Codex did not stop. Check the owned process before reconnecting.',
            );
          }
        } finally {
          await stderr.cancel();
        }
      },
    );
    if (generation != _generation) {
      await channel.close();
      throw const CodexFailure('Connection cancelled.');
    }
    _channel = channel;
    _subscription = channel.events.listen((event) {
      if (event.method == 'connection/closed') _ready = false;
      _events.add(event);
    });
    try {
      await channel.request('initialize', {
        'clientInfo': {'name': 'tabryo', 'title': 'Tabryo', 'version': '0.1.0'},
        'capabilities': {'experimentalApi': false},
      });
      if (generation != _generation) {
        throw const CodexFailure('Connection cancelled.');
      }
      channel.initialized();
      _ready = true;
    } catch (_) {
      await channel.close();
      rethrow;
    }
  }

  @override
  Future<Map<String, Object?>> request(
    String method,
    Map<String, Object?> parameters,
  ) {
    if (!connected) {
      throw const CodexFailure('Codex is disconnected. Reconnect.');
    }
    return _channel!.request(method, parameters);
  }

  @override
  Future<void> close() {
    ++_generation;
    _ready = false;
    final channel = _channel;
    _channel = null;
    final subscription = _subscription;
    _subscription = null;
    final previous = _closing;
    return _closing = () async {
      await previous;
      await subscription?.cancel();
      await channel?.close();
    }();
  }
}
