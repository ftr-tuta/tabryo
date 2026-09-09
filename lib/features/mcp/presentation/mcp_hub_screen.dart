import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../codex/domain/codex_connection.dart';
import '../domain/mcp_server.dart';
import 'mcp_hub_view_model.dart';

final class McpHubScreen extends StatefulWidget {
  const McpHubScreen({
    required this.model,
    this.dartFlutterServer,
    this.connectDartSession,
    super.key,
  });
  final McpHubViewModel model;
  final Future<McpServerDraft> Function()? dartFlutterServer;
  final Future<void> Function()? connectDartSession;
  @override
  State<McpHubScreen> createState() => _McpHubScreenState();
}

final class _McpHubScreenState extends State<McpHubScreen> {
  McpHubViewModel get model => widget.model;
  bool _sdkBusy = false;
  Future<void> _sdkAction(Future<void> Function() action) async {
    if (_sdkBusy || model.busy) return;
    setState(() => _sdkBusy = true);
    try {
      await action();
    } catch (error) {
      if (mounted) _error('$error');
    } finally {
      if (mounted) setState(() => _sdkBusy = false);
    }
  }

  Future<void> _review(McpConfigChange Function() prepare) async {
    McpConfigChange change;
    try {
      change = prepare();
    } on CodexFailure catch (error) {
      _error(error.message);
      return;
    }
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(change.description),
        content: SingleChildScrollView(
          child: SelectableText(
            'User configuration\n${change.filePath}\n\n${change.preview}',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save and reconnect'),
          ),
        ],
      ),
    );
    if (accepted == true && mounted) await model.apply(change);
  }

  void _error(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _configure([McpServer? existing]) async {
    var name = existing?.name ?? '';
    var transport = existing?.http == true
        ? McpTransport.streamableHttp
        : McpTransport.stdio;
    var command = '',
        arguments = '',
        cwd = '',
        url = '',
        environment = '',
        bearer = '';
    String? error;
    final draft = await showDialog<McpServerDraft>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(
            existing == null ? 'Add MCP server' : 'Edit ${existing.name}',
          ),
          content: SizedBox(
            width: 600,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'User configuration: ${model.userFile ?? 'unavailable'}',
                  ),
                  const SizedBox(height: 12),
                  Text(
                    existing == null
                        ? 'Use executable arguments as a JSON array. Supply secrets through environment variable names.'
                        : 'Blank fields keep existing values, including credentials and advanced options. Arguments [] clears the argument list.',
                  ),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  TextFormField(
                    initialValue: name,
                    enabled: existing == null,
                    maxLength: 80,
                    decoration: const InputDecoration(labelText: 'Server name'),
                    onChanged: (v) => name = v,
                  ),
                  DropdownButtonFormField<McpTransport>(
                    initialValue: transport,
                    decoration: const InputDecoration(labelText: 'Transport'),
                    items: const [
                      DropdownMenuItem(
                        value: McpTransport.stdio,
                        child: Text('STDIO — local process'),
                      ),
                      DropdownMenuItem(
                        value: McpTransport.streamableHttp,
                        child: Text('Streamable HTTP'),
                      ),
                    ],
                    onChanged: existing != null
                        ? null
                        : (v) => update(() => transport = v!),
                  ),
                  if (transport == McpTransport.stdio) ...[
                    TextFormField(
                      decoration: const InputDecoration(
                        labelText: 'Executable',
                        hintText: 'dart, python or an absolute executable path',
                      ),
                      onChanged: (v) => command = v,
                    ),
                    TextFormField(
                      maxLines: 3,
                      maxLength: 16384,
                      decoration: const InputDecoration(
                        labelText: 'Arguments (JSON array)',
                        hintText: '["run", "bin/server.dart"]',
                      ),
                      onChanged: (v) => arguments = v,
                    ),
                    TextFormField(
                      decoration: const InputDecoration(
                        labelText: 'Working directory (absolute, optional)',
                      ),
                      onChanged: (v) => cwd = v,
                    ),
                    TextFormField(
                      decoration: const InputDecoration(
                        labelText:
                            'Environment variable names (comma separated)',
                      ),
                      onChanged: (v) => environment = v,
                    ),
                  ] else ...[
                    TextFormField(
                      decoration: const InputDecoration(
                        labelText: 'Server URL',
                        hintText: 'https://server.example/mcp',
                      ),
                      onChanged: (v) => url = v,
                    ),
                    TextFormField(
                      decoration: const InputDecoration(
                        labelText:
                            'Bearer token environment variable (optional)',
                        hintText: 'SERVICE_TOKEN',
                      ),
                      onChanged: (v) => bearer = v,
                    ),
                    const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: Text(
                        'For OAuth, save the server first, then choose Authenticate. Remote endpoints require HTTPS.',
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                try {
                  final args = arguments.trim().isEmpty
                      ? null
                      : jsonDecode(arguments);
                  if (args != null &&
                      (args is! List || !args.every((v) => v is String))) {
                    throw const FormatException();
                  }
                  final value = McpServerDraft(
                    name: name.trim(),
                    transport: transport,
                    command: command.trim().isEmpty ? null : command.trim(),
                    arguments: args == null
                        ? null
                        : List<String>.from(args as List),
                    workingDirectory: cwd.trim().isEmpty ? null : cwd.trim(),
                    url: url.trim().isEmpty ? null : url.trim(),
                    environmentNames: environment.trim().isEmpty
                        ? null
                        : environment.split(',').map((v) => v.trim()).toList(),
                    bearerEnvironmentName: bearer.trim().isEmpty
                        ? null
                        : bearer.trim(),
                  );
                  model.prepare(value, editing: existing != null);
                  Navigator.pop(context, value);
                } on CodexFailure catch (failure) {
                  update(() => error = failure.message);
                } catch (_) {
                  update(
                    () => error = 'Arguments must be a JSON array containing only strings.',
                  );
                }
              },
              child: const Text('Review changes'),
            ),
          ],
        ),
      ),
    );
    if (draft != null && mounted) {
      await _review(() => model.prepare(draft, editing: existing != null));
    }
  }

  Future<void> _call(McpServer server, String tool, Object? definition) async {
    var value = '{}';
    String? error;
    final arguments = await showDialog<Map<String, Object?>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text('Inspect $tool'),
          content: SizedBox(
            width: 640,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Server: ${server.name}'),
                  ExpansionTile(
                    title: const Text('Tool definition'),
                    children: [SelectableText(model.inspect(definition))],
                  ),
                  TextFormField(
                    initialValue: '{}',
                    minLines: 4,
                    maxLines: 10,
                    maxLength: 65536,
                    decoration: InputDecoration(
                      labelText: 'Arguments (JSON object)',
                      errorText: error,
                    ),
                    onChanged: (v) => value = v,
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                try {
                  final args = jsonDecode(value);
                  if (args is! Map<String, Object?>) {
                    throw const FormatException();
                  }
                  Navigator.pop(context, args);
                } catch (_) {
                  update(() => error = 'Enter a valid JSON object.');
                }
              },
              child: const Text('Review call'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (arguments == null) return;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Call ${server.name} / $tool?'),
        content: SingleChildScrollView(
          child: SelectableText(
            'This tool can have side effects on its server. Review its definition and arguments.\n\n'
            '${model.inspect(arguments)}\n\nDisconnecting may not cancel work already running remotely.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Call tool'),
          ),
        ],
      ),
    );
    if (accepted == true && mounted) {
      await model.callTool(server, tool, arguments);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model,
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Close MCP Hub',
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('MCP Hub'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              model.workspace ?? 'No workspace',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: model.busy ? null : model.connect,
                  icon: const Icon(Icons.power),
                  label: Text(
                    model.connected ? 'Reconnect servers' : 'Connect Codex',
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: !model.connected || model.busy
                      ? null
                      : model.refresh,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Refresh'),
                ),
                OutlinedButton.icon(
                  onPressed:
                      !model.connected || model.busy || model.userFile == null
                      ? null
                      : () => _configure(),
                  icon: const Icon(Icons.add),
                  label: const Text('Add server'),
                ),
                TextButton(
                  onPressed: !model.connected && !model.busy
                      ? null
                      : model.disconnect,
                  child: const Text('Disconnect'),
                ),
                if (widget.dartFlutterServer != null)
                  OutlinedButton(
                    onPressed: !model.connected || model.busy || _sdkBusy
                        ? null
                        : () => _sdkAction(() async {
                            final draft = await widget.dartFlutterServer!();
                            if (!mounted) return;
                            await _review(
                              () => model.prepare(
                                draft,
                                editing: model.servers.any(
                                  (server) => server.name == draft.name,
                                ),
                              ),
                            );
                          }),
                    child: const Text('Register Dart/Flutter SDK'),
                  ),
                if (widget.connectDartSession != null)
                  OutlinedButton(
                    onPressed: !model.connected || model.busy || _sdkBusy
                        ? null
                        : () => _sdkAction(widget.connectDartSession!),
                    child: const Text('Connect running Dart/Flutter session'),
                  ),
              ],
            ),
            if (model.busy)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: LinearProgressIndicator(),
              ),
            if (model.message != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Text(model.message!),
              ),
            if (model.authorizationUrl != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () async {
                    final url = model.authorizationUrl;
                    if (url != null) {
                      // Flutter clipboard is a user-initiated presentation service.
                      // ignore: dartitect_dt3123, dartitect_dt3121
                      await Clipboard.setData(ClipboardData(text: url));
                      if (mounted) {
                        _error('Sign-in link copied. Open it in your browser.');
                      }
                    }
                  },
                  icon: const Icon(Icons.copy),
                  label: const Text('Copy sign-in link'),
                ),
              ),
            const SizedBox(height: 8),
            Expanded(
              child: !model.connected
                  ? Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 560),
                        child: const Text(
                          'Connect explicitly to start Codex App Server and the MCP servers enabled in your trusted configuration. '
                          'The Hub uses your existing Codex authentication. Closing the Hub disconnects its inspection session.',
                        ),
                      ),
                    )
                  : model.servers.isEmpty
                  ? const Center(
                      child: Text(
                        'No MCP servers configured. Add a local STDIO or Streamable HTTP server.',
                      ),
                    )
                  : LayoutBuilder(
                      builder: (context, bounds) {
                        if (bounds.maxWidth < 800) {
                          return Column(
                            children: [
                              DropdownButton<String>(
                                isExpanded: true,
                                value: model.selectedName,
                                items: [
                                  for (final server in model.servers)
                                    DropdownMenuItem(
                                      value: server.name,
                                      child: Text(
                                        server.name,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                ],
                                onChanged: model.busy
                                    ? null
                                    : (name) {
                                        if (name != null) model.select(name);
                                      },
                              ),
                              Expanded(child: _details()),
                            ],
                          );
                        }
                        return Row(
                          children: [
                            SizedBox(
                              width: 270,
                              child: ListView(
                                children: [
                                  for (final server in model.servers)
                                    ListTile(
                                      selected:
                                          server.name == model.selectedName,
                                      title: Text(
                                        server.name,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      subtitle: Text(
                                        server.enabled
                                            ? (model.statuses[server.name] ??
                                                  server.status)
                                            : 'Disabled',
                                      ),
                                      onTap: model.busy
                                          ? null
                                          : () => model.select(server.name),
                                    ),
                                ],
                              ),
                            ),
                            const VerticalDivider(),
                            Expanded(child: _details()),
                          ],
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _details() {
    final server = model.selected;
    if (server == null) return const SizedBox.shrink();
    final actionable = !model.busy;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Text(server.name, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        SelectableText(
          'Origin: ${server.origin}\n'
          'Transport: ${server.http
              ? 'Streamable HTTP'
              : server.configuration['command'] != null
              ? 'STDIO'
              : 'Managed by Codex'}\n'
          'Authentication: ${server.authStatus}\n'
          'State: ${model.statuses[server.name] ?? server.status}',
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton(
              onPressed: !actionable || !server.editable
                  ? null
                  : () => _configure(server),
              child: const Text('Edit'),
            ),
            OutlinedButton(
              onPressed: !actionable || !server.editable
                  ? null
                  : () => _review(
                      () => model.prepareEnabled(server, !server.enabled),
                    ),
              child: Text(server.enabled ? 'Disable' : 'Enable'),
            ),
            OutlinedButton(
              onPressed: !actionable || !server.editable
                  ? null
                  : () => _review(() => model.prepareRemoval(server)),
              child: const Text('Remove'),
            ),
            OutlinedButton(
              onPressed: !actionable || !server.enabled || !server.http
                  ? null
                  : () => model.authenticate(server),
              child: const Text('Authenticate'),
            ),
          ],
        ),
        if (!server.editable)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: Text(
              'This definition is supplied by a project, plugin or managed layer. This Codex version only accepts writes to user configuration.',
            ),
          ),
        ExpansionTile(
          initiallyExpanded: true,
          title: Text('Tools (${server.tools.length})'),
          children: [
            if (server.tools.isEmpty)
              const ListTile(
                title: Text(
                  'No tools reported. Refresh after server startup or authentication.',
                ),
              ),
            for (final entry in server.tools.entries.take(200))
              ListTile(
                title: Text(entry.key),
                trailing: const Icon(Icons.play_arrow),
                onTap: !actionable || !server.enabled
                    ? null
                    : () => _call(server, entry.key, entry.value),
              ),
            if (server.tools.length > 200)
              const ListTile(
                title: Text(
                  'Showing the first 200 tools. Narrow the server tool configuration.',
                ),
              ),
          ],
        ),
        ExpansionTile(
          title: Text('Resources (${server.resources.length})'),
          children: [
            for (final resource in server.resources.take(200))
              ListTile(
                title: Text(model.safeText('${resource['name']}')),
                subtitle: Text(
                  model.safeText('${resource['uri']}'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(Icons.visibility_outlined),
                onTap:
                    !actionable || !server.enabled || resource['uri'] is! String
                    ? null
                    : () =>
                          model.readResource(server, resource['uri'] as String),
              ),
            if (server.resources.isEmpty)
              const ListTile(title: Text('No resources reported.')),
            if (server.resources.length > 200)
              const ListTile(title: Text('Showing the first 200 resources.')),
          ],
        ),
        if (model.inspection != null) ...[
          const Divider(),
          Text(
            'Inspection result',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const Text(
            'Sensitive keys and known configuration credentials are hidden. Results are held only while the Hub is open.',
          ),
          const SizedBox(height: 12),
          SelectableText(
            model.inspection!,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ],
      ],
    );
  }
}
