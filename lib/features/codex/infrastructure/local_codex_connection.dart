import 'dart:async';
import 'dart:io';

import '../../../core/owned_process.dart';

import '../domain/codex_connection.dart';
import 'codex_rpc_channel.dart';

final class LocalCodexConnection implements InteractiveCodexConnection {
  LocalCodexConnection({
    required this.executable,
    this.environment,
    this.interactive = false,
  });
  final bool interactive;
  final String? executable;
  final Map<String, String>? environment;
  final _events = StreamController<CodexEvent>.broadcast();
  final _requests = StreamController<CodexServerRequest>.broadcast();
  @override
  Stream<CodexServerRequest> get requests => _requests.stream;
  @override
  void respond(Object requestId, Map<String, Object?> response) {
    if (!interactive || !connected) {
      throw const CodexFailure('This interaction is disconnected.');
    }
    _channel!.respond(requestId, response);
  }

  CodexRpcChannel? _channel;
  StreamSubscription<CodexEvent>? _subscription;
  bool _ready = false;
  int _generation = 0;
  Future<void> _closing = Future<void>.value();

  @override
  bool get connected => _ready && (_channel?.connected ?? false);
  @override
  Stream<CodexEvent> get events => _events.stream;

  Future<void> _closeInput(Process process) async {
    try {
      await process.stdin.close().timeout(const Duration(seconds: 2));
    } catch (_) {
      // Child exit can close stdin first; the subsequent exitCode wait remains authoritative.
      return;
    }
  }

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
    late final OwnedProcess child;
    try {
      final launchEnvironment = {...Platform.environment, ...?environment};
      // This is an independent client. A Tabryo launched from Codex must not
      // attach its new server to the parent Desktop task's private tools pipe.
      for (final name in const [
        'CODEX_APP_TOOLS_PIPE_PATH',
        'CODEX_THREAD_ID',
        'CODEX_SESSION_ID',
        'CODEX_INTERNAL_ORIGINATOR_OVERRIDE',
        'CODEX_PERMISSION_PROFILE',
      ]) {
        launchEnvironment.remove(name);
      }
      child = await OwnedProcess.start(
        executable!,
        const ['app-server'],
        workspace,
        environment: launchEnvironment,
        includeParentEnvironment: false,
      );
      process = child.process;
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
      onServerRequest: interactive ? _requests.add : null,
      closeTransport: () async {
        await _closeInput(process);
        try {
          await process.exitCode.timeout(const Duration(seconds: 3));
        } on TimeoutException {
          await child.close();
        } finally {
          try {
            // Parent exit alone does not retire MCP servers or helper children.
            await child.close();
          } finally {
            await stderr.cancel();
          }
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
