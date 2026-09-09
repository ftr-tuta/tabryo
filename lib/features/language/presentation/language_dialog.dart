import 'package:flutter/material.dart';

import '../../projects/domain/project.dart';
import '../application/language_service.dart';
import '../domain/language_server.dart';

final class LanguageDialog extends StatefulWidget {
  const LanguageDialog({
    required this.service,
    required this.project,
    required this.selection,
    required this.projects,
    super.key,
  });
  final LanguageService service;
  final DevelopmentProject project;
  final ToolchainSelection selection;
  final List<DevelopmentProject> projects;
  @override
  State<LanguageDialog> createState() => _LanguageDialogState();
}

final class _LanguageDialogState extends State<LanguageDialog> {
  late final _dart = TextEditingController(
    text: widget.selection[ProjectTool.dart] ?? '',
  );
  late final _python = TextEditingController(
    text: widget.selection[ProjectTool.python] ?? '',
  );
  late final _node = TextEditingController(
    text: widget.selection[ProjectTool.node] ?? '',
  );
  late final _pyright = TextEditingController(
    text: widget.selection[ProjectTool.pyright] ?? '',
  );
  late final _ruff = TextEditingController(
    text: widget.selection[ProjectTool.ruff] ?? '',
  );
  bool _busy = false;
  String? _message;
  bool get python => widget.project.kind == ProjectKind.python;

  Future<void> _start() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    final project = widget.project;
    final specs = <LanguageServerSpec>[
      if (!python)
        LanguageServerSpec(
          kind: LanguageServerKind.dart,
          workspace: project.workspace,
          root: project.directory,
          executable: _dart.text.trim(),
          excludedRoots: widget.projects
              .where((p) => p.directory != project.directory)
              .map((p) => p.directory)
              .toList(),
        ),
      if (python && _node.text.trim().isNotEmpty)
        LanguageServerSpec(
          kind: LanguageServerKind.pyright,
          workspace: project.workspace,
          root: project.directory,
          executable: _node.text.trim(),
          module: _pyright.text.trim(),
          python: _python.text.trim(),
          excludedRoots: widget.projects
              .where((p) => p.directory != project.directory)
              .map((p) => p.directory)
              .toList(),
        ),
      if (python && _ruff.text.trim().isNotEmpty)
        LanguageServerSpec(
          kind: LanguageServerKind.ruff,
          workspace: project.workspace,
          root: project.directory,
          executable: _ruff.text.trim(),
          excludedRoots: widget.projects
              .where((p) => p.directory != project.directory)
              .map((p) => p.directory)
              .toList(),
        ),
    ];
    try {
      if (specs.isEmpty) {
        throw const LanguageFailure('Choose Pyright, Ruff, or both.');
      }
      for (final spec in specs) {
        await widget.service.start(spec);
      }
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) setState(() => _message = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _field(
    TextEditingController controller,
    String label,
    String helper,
  ) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: TextField(
      controller: controller,
      enabled: !_busy,
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        helperMaxLines: 3,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: Text('Language intelligence · ${widget.project.name}'),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(widget.project.directory),
              const SizedBox(height: 12),
              const Text(
                'Start installed tools for this project. They can read project files and configuration. Use Apply toolchains in Projects to remember paths; overrides below apply only to this session. Opening a workspace never starts a server.',
              ),
              if (!python)
                _field(
                  _dart,
                  'Dart executable',
                  'Runs: dart language-server --protocol=lsp',
                ),
              if (python) ...[
                _field(
                  _python,
                  'Project Python executable',
                  'The interpreter used by Pyright to resolve imports.',
                ),
                _field(
                  _node,
                  'Node executable for Pyright',
                  'Optional. Absolute node.exe on Windows or node on Linux.',
                ),
                _field(
                  _pyright,
                  'Pyright langserver JavaScript file',
                  'Runs: node <pyright/dist/pyright-langserver.js> --stdio',
                ),
                _field(
                  _ruff,
                  'Ruff executable',
                  'Optional. Runs: ruff server. Enables lint, import fixes and Python format on save.',
                ),
              ],
              const SizedBox(height: 16),
              const Text(
                'Stop or restart servers here. Output is bounded; commands returned by servers are never executed. Refactorings require review and open as unsaved edits.',
              ),
              StreamBuilder<void>(
                stream: widget.service.changes,
                builder: (context, _) => Column(
                  children: [
                    for (final session in widget.service.sessions.values.where(
                      (s) => s.spec.workspace == widget.project.workspace,
                    ))
                      ListTile(
                        title: Text(
                          '${session.spec.kind.name} · ${session.spec.root}',
                        ),
                        subtitle: Text(
                          session.error ??
                              (session.ready ? 'Connected' : 'Starting'),
                        ),
                        trailing: IconButton(
                          tooltip: 'Stop language server',
                          icon: const Icon(Icons.stop),
                          onPressed: _busy
                              ? null
                              : () => widget.service.stop(session.spec.id),
                        ),
                      ),
                  ],
                ),
              ),
              if (_message != null) Text(_message!),
              if (_busy) const LinearProgressIndicator(),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _start,
          child: const Text('Start language servers'),
        ),
      ],
    ),
  );

  @override
  void dispose() {
    for (final controller in [_dart, _python, _node, _pyright, _ruff]) {
      controller.dispose();
    }
    super.dispose();
  }
}
