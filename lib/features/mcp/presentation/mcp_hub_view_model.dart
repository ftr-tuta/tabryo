import 'dart:async';

import 'package:dartitect_flutter/dartitect_flutter.dart';

import '../../codex/domain/codex_connection.dart';
import '../application/mcp_hub.dart';
import '../domain/mcp_server.dart';

final class McpHubViewModel extends DartitectViewModel {
  McpHubViewModel(this.hub) {
    _subscription = hub.events.listen(_event);
  }
  final McpHub hub;
  late final StreamSubscription<CodexEvent> _subscription;
  String? workspace;
  String? selectedName;
  String? message;
  String? inspection;
  String? authorizationUrl;
  List<McpServer> servers = const [];
  final statuses = <String, String>{};
  bool busy = false;
  bool _disposed = false;
  int _generation = 0;

  bool get connected => hub.connected;
  String? get userFile => hub.userFile;
  McpServer? get selected =>
      servers.where((s) => s.name == selectedName).firstOrNull;

  Future<void> selectWorkspace(String root) async {
    if (workspace != root) await disconnect();
    workspace = root;
    _notify();
  }

  void select(String name) {
    selectedName = name;
    inspection = null;
    _notify();
  }

  Future<bool> _run(Future<void> Function() action) async {
    if (busy || _disposed) return false;
    final generation = _generation;
    busy = true;
    message = null;
    _notify();
    try {
      await action();
      if (generation != _generation || _disposed) return false;
      _sync();
      return true;
    } catch (error) {
      if (generation == _generation && !_disposed) {
        _sync();
        message = error is CodexFailure
            ? error.message
            : 'The operation failed. Reconnect and check server configuration.';
      }
      return false;
    } finally {
      if (generation == _generation && !_disposed) {
        busy = false;
        _notify();
      }
    }
  }

  void _sync() {
    servers = hub.servers;
    if (!servers.any((s) => s.name == selectedName)) {
      selectedName = servers.firstOrNull?.name;
    }
  }

  Future<bool> connect() => _run(() async {
    if (workspace == null) throw const CodexFailure('Open a workspace first.');
    statuses.clear();
    inspection = null;
    authorizationUrl = null;
    await hub.connect(workspace!);
  });

  Future<bool> refresh() => _run(() async {
    await hub.readConfiguration();
    await hub.refreshInventory();
  });

  McpConfigChange prepare(McpServerDraft draft, {bool editing = false}) =>
      hub.configure(draft, editing: editing);
  McpConfigChange prepareEnabled(McpServer server, bool value) =>
      hub.setEnabled(server, value);
  McpConfigChange prepareRemoval(McpServer server) => hub.remove(server);

  Future<bool> apply(McpConfigChange change) => _run(() async {
    final generation = _generation;
    inspection = null;
    authorizationUrl = null;
    statuses.clear();
    final result = await hub.apply(change);
    if (generation == _generation) message = result;
  });

  Future<bool> authenticate(McpServer server) => _run(() async {
    final generation = _generation;
    final url = await hub.authenticate(server);
    if (generation != _generation) return;
    authorizationUrl = url;
    message = 'Copy the sign-in link and open it in your browser. Codex owns the authentication flow.';
  });

  Future<bool> callTool(
    McpServer server,
    String name,
    Map<String, Object?> arguments,
  ) => _run(() async {
    inspection = await hub.callTool(server, name, arguments);
  });

  Future<bool> readResource(McpServer server, String uri) => _run(() async {
    inspection = await hub.readResource(server, uri);
  });

  String inspect(Object? value) => hub.inspect(value);
  String safeText(String value) => hub.safeText(value);

  void _event(CodexEvent event) {
    if (_disposed) return;
    if (event.method == 'connection/closed') {
      servers = const [];
      inspection = null;
      authorizationUrl = null;
      message =
          'Codex disconnected. Reconnect to check server and operation state.';
    } else if (event.method == 'interaction/unsupported') {
      message = 'The server requested an interaction this Hub cannot present. It was refused. Use the Codex terminal for that flow.';
    } else if (event.method == 'mcpServer/startupStatus/updated') {
      final name = event.parameters['name'];
      final status = event.parameters['status'];
      if (name is String &&
          ['starting', 'ready', 'failed', 'cancelled'].contains(status)) {
        statuses[name] = status as String;
      }
    } else if (event.method == 'mcpServer/oauthLogin/completed') {
      authorizationUrl = null;
      message = event.parameters['success'] == true
          ? 'Authentication completed. Reconnect to refresh access.'
          : 'Authentication did not complete. Check the provider and try again.';
    }
    _notify();
  }

  Future<void> disconnect() async {
    ++_generation;
    busy = false;
    servers = const [];
    selectedName = null;
    inspection = null;
    authorizationUrl = null;
    statuses.clear();
    try {
      await hub.close();
    } on CodexFailure catch (error) {
      message = error.message;
    }
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  Future<void> disposeAsync() async {
    _disposed = true;
    await disconnect();
    await _subscription.cancel();
    await super.disposeAsync();
  }
}
