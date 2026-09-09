import 'dart:async';
import 'dart:convert';

import 'package:path/path.dart' as p;

import '../../codex/domain/codex_connection.dart';
import '../domain/mcp_server.dart';

Map<String, Object?> _map(Object? value) =>
    value is Map<String, Object?> ? value : const {};

/// MCP operations go through Codex, which owns transport/authentication and TOML.
final class McpHub {
  McpHub(this.connection);
  final CodexConnection connection;
  String? _workspace;
  String? _thread;
  String? _userFile;
  String? _version;
  Map<String, Object?> _configured = const {};
  Map<String, Object?> _userServers = const {};
  final _otherOrigins = <String, String>{};
  final _inventory = <String, Map<String, Object?>>{};
  final _secrets = <String>{};
  bool _writing = false;
  int _generation = 0;
  McpConfigChange? _prepared;

  Stream<CodexEvent> get events => connection.events;
  bool get connected => connection.connected;
  String? get userFile => _userFile;

  Future<void> connect(String workspace) async {
    final generation = ++_generation;
    _workspace = workspace;
    _thread = null;
    _inventory.clear();
    await connection.connect(workspace);
    _checkGeneration(generation);
    try {
      await readConfiguration();
    } catch (_) {
      if (generation == _generation) await close();
      rethrow;
    }
    // A broken required server must not prevent repairing its configuration.
    final result = await connection.request('thread/start', {
      'cwd': workspace,
      'ephemeral': true,
    });
    _checkGeneration(generation);
    _thread = _map(result['thread'])['id'] as String?;
    if (_thread == null) {
      throw const CodexFailure(
        'Codex did not create an inspection session. Configuration remains available.',
      );
    }
    await refreshInventory();
  }

  Future<void> readConfiguration() async {
    final generation = _generation;
    final result = await connection.request('config/read', {
      'cwd': _workspace,
      'includeLayers': true,
    });
    _checkGeneration(generation);
    _prepared = null;
    _configured = _map(_map(result['config'])['mcp_servers']);
    _userFile = null;
    _version = null;
    _userServers = const {};
    _otherOrigins.clear();
    _secrets.clear();
    _collectSecrets(_configured);
    for (final item in result['layers'] as List? ?? const []) {
      final layer = _map(item);
      final source = _map(layer['name']);
      final servers = _map(_map(layer['config'])['mcp_servers']);
      _collectSecrets(servers);
      if (source['type'] == 'user' && source['profile'] == null) {
        _userFile = source['file'] as String?;
        _version = layer['version'] as String?;
        _userServers = servers;
      } else if (layer['disabledReason'] == null) {
        final origin = source['type'] == 'project'
            ? '${source['dotCodexFolder']} (project, read-only)'
            : '${source['type']} configuration (read-only)';
        for (final name in servers.keys) {
          _otherOrigins[name] = origin;
        }
      }
    }
  }

  Future<void> refreshInventory() async {
    final generation = _generation;
    final thread = _requireThread();
    final inventory = <String, Map<String, Object?>>{};
    final seenCursors = <String>{};
    String? cursor;
    do {
      final result = await connection.request('mcpServerStatus/list', {
        'threadId': thread,
        'detail': 'full',
        'limit': 50,
        'cursor': ?cursor,
      });
      _checkGeneration(generation);
      for (final item in result['data'] as List? ?? const []) {
        final server = _map(item);
        if (server['name'] case final String name) inventory[name] = server;
      }
      cursor = result['nextCursor'] as String?;
      if (inventory.length > 500 ||
          (cursor != null && !seenCursors.add(cursor))) {
        throw const CodexFailure(
          'MCP inventory exceeded its limit or repeated a page. Narrow the configured servers.',
        );
      }
    } while (cursor != null);
    _inventory
      ..clear()
      ..addAll(inventory);
  }

  List<McpServer> get servers {
    final names = {
      ..._configured.keys,
      ..._userServers.keys,
      ..._inventory.keys,
    }.toList()..sort();
    return names.map((name) {
      final configuration = _map(_configured[name] ?? _userServers[name]);
      final runtime = _inventory[name];
      final editable =
          _userServers.containsKey(name) && !_otherOrigins.containsKey(name);
      return McpServer(
        name: name,
        configuration: Map.unmodifiable(configuration),
        origin:
            _otherOrigins[name] ??
            (editable ? _userFile! : 'Codex / plugin (read-only)'),
        editable: editable,
        tools: Map.unmodifiable(_map(runtime?['tools'])),
        resources: List.unmodifiable([
          for (final item in runtime?['resources'] as List? ?? const [])
            _map(item),
        ]),
        authStatus: runtime?['authStatus'] as String? ?? 'unknown',
        status: configuration['enabled'] == false
            ? 'Disabled'
            : runtime == null
            ? 'Unavailable — refresh to check'
            : 'Inventory reported by Codex',
      );
    }).toList();
  }

  McpConfigChange configure(McpServerDraft draft, {bool editing = false}) {
    _checkName(draft.name);
    final current = servers.where((s) => s.name == draft.name).firstOrNull;
    if (!editing && current != null) {
      throw const CodexFailure('A server with this name already exists.');
    }
    if (editing && (current == null || !current.editable)) {
      throw const CodexFailure(
        'This server is read-only. Edit its originating configuration with Codex.',
      );
    }
    if (editing &&
        current!.http != (draft.transport == McpTransport.streamableHttp)) {
      throw const CodexFailure(
        'Remove and recreate a server to change its transport.',
      );
    }
    final fields = <String, Object?>{};
    if (draft.transport == McpTransport.stdio) {
      if (!editing && (draft.command?.trim().isEmpty ?? true)) {
        throw const CodexFailure('A STDIO server needs an executable.');
      }
      if (draft.command != null) {
        if (draft.command!.trim().isEmpty ||
            draft.command!.contains('\n') ||
            draft.command!.contains('\u0000')) {
          throw const CodexFailure(
            'Enter one executable; supply its arguments separately.',
          );
        }
        fields['command'] = draft.command!.trim();
      }
      if (draft.arguments != null) fields['args'] = draft.arguments!;
      if (draft.workingDirectory != null) {
        if (!p.isAbsolute(draft.workingDirectory!)) {
          throw const CodexFailure('Working directory must be absolute.');
        }
        fields['cwd'] = draft.workingDirectory!;
      }
      if (draft.environmentNames != null) {
        for (final name in draft.environmentNames!) {
          _checkEnvironment(name);
        }
        fields['env_vars'] = draft.environmentNames!;
      }
    } else {
      if (!editing && draft.url == null) {
        throw const CodexFailure('An HTTP server needs a URL.');
      }
      if (draft.url != null) {
        final uri = Uri.tryParse(draft.url!);
        if (uri == null ||
            !['http', 'https'].contains(uri.scheme) ||
            uri.host.isEmpty ||
            uri.userInfo.isNotEmpty ||
            uri.hasFragment ||
            uri.hasQuery) {
          throw const CodexFailure(
            'Use an HTTP(S) URL without credentials, query or fragment. Reference credentials through an environment variable.',
          );
        }
        if (uri.scheme == 'http' &&
            !['127.0.0.1', 'localhost', '::1'].contains(uri.host)) {
          throw const CodexFailure(
            'Remote MCP servers require HTTPS. HTTP is limited to loopback.',
          );
        }
        fields['url'] = uri.toString();
      }
      if (draft.bearerEnvironmentName != null) {
        _checkEnvironment(draft.bearerEnvironmentName!);
        fields['bearer_token_env_var'] = draft.bearerEnvironmentName!;
      }
    }
    if (fields.isEmpty) {
      throw const CodexFailure(
        'Enter at least one change. Blank fields keep existing values.',
      );
    }
    final prefix = 'mcp_servers.${draft.name}';
    return _change(
      editing ? 'Update ${draft.name}' : 'Add ${draft.name}',
      editing
          ? [
              for (final entry in fields.entries)
                {
                  'keyPath': '$prefix.${entry.key}',
                  'value': entry.value,
                  'mergeStrategy': 'replace',
                },
            ]
          : [
              {
                'keyPath': prefix,
                'value': {...fields, 'enabled': true},
                'mergeStrategy': 'replace',
              },
            ],
      '${editing ? 'Replace fields' : 'Create server'}: ${fields.keys.join(', ')}\n'
      '${fields.containsKey('url') ? 'Endpoint: ${fields['url']}\n' : ''}'
      '${fields.containsKey('args') ? 'Arguments: ${(fields['args'] as List).length} (values hidden)\n' : ''}'
      'Other existing configuration and credentials are preserved.\n'
      'Saving reconnects this Hub and can start configured server processes.\n'
      'Other Codex clients may need to reconnect separately.',
    );
  }

  McpConfigChange setEnabled(McpServer server, bool enabled) {
    _checkEditable(server);
    return _change(
      '${enabled ? 'Enable' : 'Disable'} ${server.name}',
      [
        {
          'keyPath': 'mcp_servers.${server.name}.enabled',
          'value': enabled,
          'mergeStrategy': 'replace',
        },
      ],
      'Enabled: ${server.enabled} → $enabled\n'
          'This Hub reconnects after saving. Other Codex sessions must reconnect too.\n'
          'Disabling blocks access through this configuration; it does not revoke provider credentials.',
    );
  }

  McpConfigChange remove(McpServer server) {
    _checkEditable(server);
    return _change(
      'Remove ${server.name}',
      [
        {
          'keyPath': 'mcp_servers.${server.name}',
          'value': null,
          'mergeStrategy': 'replace',
        },
      ],
      'Remove this server entry from user configuration and reconnect this Hub.\n'
          'Project/plugin definitions may still apply. Credentials at the provider are not revoked.',
    );
  }

  McpConfigChange _change(
    String description,
    List<Map<String, Object?>> edits,
    String preview,
  ) {
    if (_userFile == null || _version == null) {
      throw const CodexFailure(
        'Codex did not provide a versioned user configuration. Refresh before editing.',
      );
    }
    return _prepared = McpConfigChange(
      filePath: _userFile!,
      expectedVersion: _version!,
      edits: List.unmodifiable(
        edits.map((e) => _freeze(e) as Map<String, Object?>),
      ),
      description: description,
      preview: preview,
    );
  }

  Future<String> apply(McpConfigChange change) async {
    final generation = _generation;
    if (_writing) {
      throw const CodexFailure('Another configuration update is in progress.');
    }
    if (!identical(change, _prepared) ||
        change.filePath != _userFile ||
        change.expectedVersion != _version) {
      throw const CodexFailure(
        'Configuration changed. Refresh and review a new preview.',
      );
    }
    _writing = true;
    _prepared = null;
    try {
      final result = await connection.request('config/batchWrite', {
        'filePath': change.filePath,
        'expectedVersion': change.expectedVersion,
        'edits': change.edits,
      });
      if (generation != _generation) {
        return 'Configuration saved. The Hub was disconnected; reconnect explicitly to inspect the effective state.';
      }
      // Invalidate the approved snapshot even if reconnecting fails.
      _version = null;
      try {
        await connect(_workspace!);
      } catch (_) {
        return 'Configuration saved. Hub reconnection failed; reconnect to inspect the effective state. Do not repeat the write.';
      }
      return result['status'] == 'okOverridden'
          ? 'Saved, but another configuration layer overrides this value. Review the effective configuration.'
          : 'Saved and reconnected. Reconnect other Codex clients to apply the change there.';
    } finally {
      _writing = false;
    }
  }

  Future<String> authenticate(McpServer server) async {
    final generation = _generation;
    if (!_current(server).http) {
      throw const CodexFailure(
        'OAuth authentication is available for HTTP servers.',
      );
    }
    final result = await connection.request('mcpServer/oauth/login', {
      'name': server.name,
      'threadId': _requireThread(),
      'timeoutSecs': 180,
    });
    _checkGeneration(generation);
    final url = result['authorizationUrl'];
    final uri = url is String ? Uri.tryParse(url) : null;
    if (uri == null ||
        !['https', 'http'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        (uri.scheme == 'http' &&
            !['127.0.0.1', 'localhost', '::1'].contains(uri.host))) {
      throw const CodexFailure('Codex returned an unsupported sign-in URL.');
    }
    return uri.toString();
  }

  Future<String> callTool(
    McpServer server,
    String tool,
    Map<String, Object?> arguments,
  ) async {
    final generation = _generation;
    if (!_current(server).tools.containsKey(tool)) {
      throw const CodexFailure(
        'The selected tool is unavailable. Refresh the inventory.',
      );
    }
    final result = await connection.request('mcpServer/tool/call', {
      'threadId': _requireThread(),
      'server': server.name,
      'tool': tool,
      'arguments': arguments,
    });
    _checkGeneration(generation);
    return inspect(result);
  }

  Future<String> readResource(McpServer server, String uri) async {
    final generation = _generation;
    if (!_current(server).resources.any((r) => r['uri'] == uri)) {
      throw const CodexFailure(
        'The selected resource is unavailable. Refresh the inventory.',
      );
    }
    final result = await connection.request('mcpServer/resource/read', {
      'threadId': _requireThread(),
      'server': server.name,
      'uri': uri,
    });
    _checkGeneration(generation);
    return inspect(result);
  }

  Future<String> connectDartSession(McpServerDraft sdk, Uri uri) async {
    if (sdk.name != 'dart_flutter' ||
        sdk.transport != McpTransport.stdio ||
        sdk.arguments?.firstOrNull != 'mcp-server' ||
        uri.scheme != 'ws' ||
        !['127.0.0.1', '::1'].contains(uri.host) ||
        !uri.hasPort ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const CodexFailure('Choose the owned local Dart/Flutter session.');
    }
    final server = servers
        .where((server) => server.name == sdk.name)
        .firstOrNull;
    if (server == null ||
        !server.enabled ||
        server.http ||
        server.configuration['command'] != sdk.command ||
        server.configuration['cwd'] != sdk.workingDirectory ||
        jsonEncode(server.configuration['args']) != jsonEncode(sdk.arguments) ||
        !server.tools.containsKey('dtd')) {
      throw const CodexFailure(
        'Register the selected Dart/Flutter SDK in this Hub and reconnect before sharing its session.',
      );
    }
    final response = await callTool(server, 'dtd', {
      'command': 'connect',
      'uri': uri.toString(),
    });
    if ((jsonDecode(response) as Map)['isError'] == true) {
      throw const CodexFailure(
        'The Dart/Flutter MCP server could not connect to this session. Inspect its dtd tool for details.',
      );
    }
    return response;
  }

  String inspect(Object? value) {
    final text = const JsonEncoder.withIndent('  ').convert(_redact(value));
    return text.length > 128 * 1024
        ? '${text.substring(0, 128 * 1024)}\n[Display truncated at 128 KiB]'
        : text;
  }

  String safeText(String value) => _redact(value) as String;

  Object? _redact(Object? value) {
    if (value is Map) {
      return {
        for (final entry in value.entries)
          '${entry.key}': _sensitive('${entry.key}')
              ? '[hidden]'
              : _redact(entry.value),
      };
    }
    if (value is List) return value.map(_redact).toList();
    if (value is String) {
      var safe = value;
      for (final secret in _secrets) {
        safe = safe.replaceAll(secret, '[hidden]');
      }
      safe = safe.replaceAll(
        RegExp(r'Bearer\s+[^\s"\\]+', caseSensitive: false),
        'Bearer [hidden]',
      );
      safe = safe.replaceAllMapped(RegExp(r'https?://[^\s"<>]+'), (match) {
        final uri = Uri.tryParse(match[0]!);
        if (uri == null || (uri.userInfo.isEmpty && !uri.hasQuery)) {
          return match[0]!;
        }
        final address = uri
            .replace(userInfo: '', query: '')
            .toString()
            .replaceFirst(RegExp(r'\?$'), '');
        return '$address${uri.hasQuery ? '?[hidden]' : ''}';
      });
      return safe;
    }
    return value;
  }

  bool _sensitive(String key) => RegExp(
    r'token|secret|password|authorization|api.?key|cookie|^env$|http_headers',
    caseSensitive: false,
  ).hasMatch(key);

  void _collectSecrets(Object? value, {bool sensitive = false}) {
    if (value is Map) {
      for (final entry in value.entries) {
        _collectSecrets(
          entry.value,
          sensitive: sensitive || _sensitive('${entry.key}'),
        );
      }
    } else if (value is List) {
      for (final item in value) {
        _collectSecrets(item, sensitive: sensitive);
      }
    } else if (sensitive && value is String && value.isNotEmpty) {
      _secrets.add(value);
    }
  }

  void _checkEditable(McpServer server) {
    _checkName(server.name);
    if (!server.editable) {
      throw const CodexFailure('This configuration is read-only.');
    }
  }

  McpServer _current(McpServer selected) {
    final current = servers.where((s) => s.name == selected.name).firstOrNull;
    if (current == null || !current.enabled) {
      throw const CodexFailure(
        'The selected server is disabled or no longer available. Refresh the inventory.',
      );
    }
    return current;
  }

  void _checkName(String name) {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,80}$').hasMatch(name)) {
      throw const CodexFailure(
        'Use 1–80 letters, digits, hyphens or underscores for the server name.',
      );
    }
  }

  void _checkEnvironment(String name) {
    if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(name)) {
      throw const CodexFailure(
        'Enter an environment variable name, never its secret value.',
      );
    }
  }

  String _requireThread() {
    if (!connected || _thread == null) {
      throw const CodexFailure('Connect the Hub before using MCP servers.');
    }
    return _thread!;
  }

  Future<void> close() async {
    ++_generation;
    _prepared = null;
    _thread = null;
    _inventory.clear();
    _configured = const {};
    _userServers = const {};
    _userFile = null;
    _version = null;
    _otherOrigins.clear();
    _secrets.clear();
    await connection.close();
  }

  void _checkGeneration(int generation) {
    if (generation != _generation) {
      throw const CodexFailure(
        'The inspection session changed. Reconnect before continuing.',
      );
    }
  }

  Object? _freeze(Object? value) {
    if (value is Map<String, Object?>) {
      return Map<String, Object?>.unmodifiable(
        value.map((key, entry) => MapEntry(key, _freeze(entry))),
      );
    }
    if (value is List) return List<Object?>.unmodifiable(value.map(_freeze));
    return value;
  }
}
