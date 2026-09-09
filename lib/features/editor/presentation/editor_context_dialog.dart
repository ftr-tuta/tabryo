import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../editor_context/domain/editor_context.dart';
import 'editor_view_model.dart';

final class EditorContextDialog extends StatefulWidget {
  const EditorContextDialog({required this.model, super.key});
  final EditorViewModel model;
  @override
  State<EditorContextDialog> createState() => _EditorContextDialogState();
}

final class _EditorContextDialogState extends State<EditorContextDialog> {
  final client = TextEditingController(text: 'Codex');
  bool whole = false;
  bool diagnostics = false;
  bool busy = false;
  String? error;
  @override
  void dispose() {
    client.dispose();
    super.dispose();
  }

  Future<void> _act(Future<void> Function() action) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
    } catch (failure) {
      if (mounted) setState(() => error = '$failure');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<bool> _review(String title, Widget content, String accept) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 760,
            height: 420,
            child: SingleChildScrollView(child: content),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(accept),
            ),
          ],
        ),
      ) ==
      true;

  Future<void> _publish() => _act(() async {
    final snapshot = await widget.model.prepareContext(
      wholeDocument: whole,
      includeDiagnostics: diagnostics,
    );
    if (!mounted) return;
    final approved = await _review(
      'Review shared editor context',
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Client: ${client.text}\n${snapshot.path}\nVersion ${snapshot.version} · ${snapshot.dirty ? 'unsaved' : 'saved'}\nUTF-16 range ${snapshot.start}–${snapshot.end}',
          ),
          const Text(
            'Publishes this captured text to a local MCP connection. Later typing is not shared. Revoke, close this document, change workspace or close Tabryo to end access. Clients can propose replacements for review; saving stays explicit.',
          ),
          const Divider(),
          SelectableText(snapshot.text),
          if (snapshot.includesDiagnostics) ...[
            const Divider(),
            const Text(
              'Captured diagnostics · a null documentVersion means the server did not report a version. Only ranges fully inside the excerpt are included.',
            ),
            if (snapshot.diagnosticsLimited)
              const Text('Diagnostic limit reached; this is a partial list.'),
            SelectableText(
              const JsonEncoder.withIndent('  ').convert([
                for (final diagnostic in snapshot.diagnostics)
                  diagnostic.toJson(),
              ]),
            ),
          ],
        ],
      ),
      'Publish reviewed context',
    );
    if (approved && mounted) {
      await widget.model.publishContext(snapshot, client.text);
    }
  });

  Future<void> _proposal(EditorProposal proposal) => _act(() async {
    final approved = await _review(
      'Review MCP replacement',
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${proposal.snapshot.path}\nSnapshot ${proposal.snapshot.id}'),
          const Text('Before'),
          SelectableText(proposal.snapshot.text),
          const Divider(),
          const Text('After'),
          SelectableText(proposal.text),
          const Text(
            'Replaces only the published excerpt in the unsaved editor buffer. Changes to the document or share invalidate this proposal.',
          ),
        ],
      ),
      'Apply unsaved replacement',
    );
    if (approved && mounted) await widget.model.applyContextProposal(proposal);
  });

  Future<void> _copy(Object value) async {
    await Clipboard.setData(
      ClipboardData(text: const JsonEncoder.withIndent('  ').convert(value)),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.model,
    builder: (context, _) {
      final service = widget.model.contextSharing!;
      final connection = service.connection;
      final snapshot = service.snapshot;
      return AlertDialog(
        title: const Text('Editor context for Codex / MCP'),
        content: SizedBox(
          width: 760,
          height: 500,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (error != null)
                  Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                if (connection == null) ...[
                  const Text(
                    'Select text in the editor before opening this dialog, or choose the whole document. Review the exact content before making it available.',
                  ),
                  TextField(
                    controller: client,
                    enabled: !busy,
                    decoration: const InputDecoration(labelText: 'Client name'),
                  ),
                  CheckboxListTile(
                    value: whole,
                    onChanged: busy
                        ? null
                        : (value) => setState(() => whole = value!),
                    title: const Text('Share the whole document'),
                  ),
                  CheckboxListTile(
                    value: diagnostics,
                    onChanged: busy
                        ? null
                        : (value) => setState(() => diagnostics = value!),
                    title: const Text('Include captured diagnostics'),
                  ),
                  FilledButton(
                    onPressed: busy ? null : _publish,
                    child: const Text('Review editor context'),
                  ),
                ] else ...[
                  Text(
                    'Shared for ${service.client} · captured version ${snapshot!.version}',
                  ),
                  SelectableText(snapshot.path),
                  SelectableText('${connection.endpoint}'),
                  const Text(
                    'Add this Streamable HTTP connection in the MCP client using the copied URL and Authorization header. The credential grants access to this excerpt until revoked.',
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      OutlinedButton(
                        onPressed: () => _act(
                          () => _copy({
                            'url': '${connection.endpoint}',
                            'http_headers': {
                              'Authorization': 'Bearer ${connection.token}',
                            },
                          }),
                        ),
                        child: const Text('Copy MCP connection'),
                      ),
                      OutlinedButton(
                        onPressed: () => _act(() => _copy(snapshot.toJson())),
                        child: const Text('Copy context for Codex'),
                      ),
                      FilledButton(
                        onPressed: () => _act(widget.model.revokeContext),
                        child: const Text('Revoke editor context'),
                      ),
                    ],
                  ),
                  const Divider(),
                  if (service.proposals.isEmpty)
                    const Text('No replacement proposals received.'),
                  for (final proposal in service.proposals.values)
                    ListTile(
                      title: Text(proposal.id),
                      subtitle: Text(proposal.status),
                      trailing: proposal.status != 'pending'
                          ? null
                          : Wrap(
                              spacing: 8,
                              children: [
                                OutlinedButton(
                                  onPressed: busy
                                      ? null
                                      : () => _proposal(proposal),
                                  child: const Text('Review replacement'),
                                ),
                                TextButton(
                                  onPressed: busy
                                      ? null
                                      : () => service.decided(
                                          proposal,
                                          applied: false,
                                        ),
                                  child: const Text('Reject'),
                                ),
                              ],
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
            child: const Text('Close'),
          ),
        ],
      );
    },
  );
}
