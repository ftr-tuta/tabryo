import 'dart:convert';

import 'package:flutter/material.dart';

import '../../terminals/domain/terminal_ports.dart';
import '../domain/studio_project.dart';
import 'mcp_studio_view_model.dart';

final class McpStudioScreen extends StatefulWidget {
  const McpStudioScreen({
    required this.model,
    required this.onOpen,
    required this.onRun,
    required this.onRegister,
    super.key,
  });
  final McpStudioViewModel model;
  final Future<void> Function(StudioPlan project) onOpen;
  final Future<void> Function(StudioPlan project, LaunchSpec spec, String title)
  onRun;
  final Future<void> Function(StudioPlan project) onRegister;
  @override
  State<McpStudioScreen> createState() => _McpStudioScreenState();
}

final class _McpStudioScreenState extends State<McpStudioScreen> {
  McpStudioViewModel get model => widget.model;
  final _name = TextEditingController();
  late final _runtime = TextEditingController(
    text: model.studio.storage.runtimeHint(StudioLanguage.dart) ?? '',
  );
  StudioLanguage _language = StudioLanguage.dart;
  String? _file;
  bool _acting = false;

  @override
  void dispose() {
    _name.dispose();
    _runtime.dispose();
    super.dispose();
  }

  Future<void> _action(Future<void> Function() operation) async {
    if (_acting || model.busy) return;
    setState(() => _acting = true);
    try {
      await operation();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$error')));
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  Future<void> _run(StudioPlan project, int index) async {
    final command = model.studio.commands(project)[index];
    final spec = await model.studio.prepareCommand(project, index);
    if (!mounted) return;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(command.title),
        content: SingleChildScrollView(
          child: SelectableText(
            '${command.installs ? 'This installs packages from the public registry.\n\n' : ''}'
            'Runs the current files on disk. Save your edits first.\n\n'
            'Directory: ${spec.workingDirectory}\nExecutable: ${spec.executable}\n'
            'Arguments: ${jsonEncode(spec.arguments)}',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Run in terminal'),
          ),
        ],
      ),
    );
    if (accepted == true && mounted) {
      // Revalidate after the review, immediately before launching.
      final current = await model.studio.prepareCommand(project, index);
      await widget.onRun(project, current, command.title);
    }
  }

  Future<void> _changeRuntime(StudioPlan project) async {
    var runtime = project.runtime;
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Choose runtime'),
        content: TextFormField(
          initialValue: runtime,
          decoration: const InputDecoration(
            labelText: 'Absolute native executable path',
          ),
          onChanged: (value) => runtime = value,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, runtime),
            child: const Text('Use runtime'),
          ),
        ],
      ),
    );
    if (result != null) await model.changeRuntime(result.trim());
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model,
    builder: (context, _) {
      final disabled = model.busy || _acting;
      final plan = model.preview;
      final project = model.selected;
      return PopScope(
        canPop: !disabled,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('MCP Studio'),
            leading: IconButton(
              tooltip: 'Close Studio',
              onPressed: disabled ? null : () => Navigator.pop(context),
              icon: const Icon(Icons.close),
            ),
          ),
          body: ListView(
            key: const ValueKey('studio-content'),
            padding: const EdgeInsets.all(20),
            children: [
              if (disabled) const LinearProgressIndicator(),
              Text(
                'Create a new STDIO server in ${model.workspace}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              const Text(
                'Review the source and commands before creating the folder. '
                'Creation starts no process. Existing folders are preserved.',
              ),
              if (model.message != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: SelectableText(model.message!),
                ),
              Wrap(
                spacing: 16,
                runSpacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    width: 280,
                    child: TextField(
                      controller: _name,
                      enabled: !disabled,
                      decoration: const InputDecoration(
                        labelText: 'Project name',
                        hintText: 'greeting_server',
                      ),
                      onChanged: (_) => model.invalidatePreview(),
                    ),
                  ),
                  SizedBox(
                    width: 200,
                    child: DropdownButtonFormField<StudioLanguage>(
                      initialValue: _language,
                      decoration: const InputDecoration(labelText: 'Language'),
                      items: const [
                        DropdownMenuItem(
                          value: StudioLanguage.dart,
                          child: Text('Dart'),
                        ),
                        DropdownMenuItem(
                          value: StudioLanguage.python,
                          child: Text('Python'),
                        ),
                        DropdownMenuItem(
                          value: StudioLanguage.typescript,
                          child: Text('TypeScript'),
                        ),
                      ],
                      onChanged: disabled
                          ? null
                          : (value) {
                              setState(() {
                                _language = value!;
                                _runtime.text =
                                    model.studio.storage.runtimeHint(value) ??
                                    '';
                              });
                              model.invalidatePreview();
                            },
                    ),
                  ),
                ],
              ),
              TextField(
                controller: _runtime,
                enabled: !disabled,
                decoration: const InputDecoration(
                  labelText: 'Runtime executable (absolute path)',
                  helperText: 'Dart 3.11+, Python 3.10+ or Node.js 22+. Leave blank to choose it after creation.',
                ),
                onChanged: (_) => model.invalidatePreview(),
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  onPressed: disabled
                      ? null
                      : () async {
                          _file = null;
                          await model.prepare(
                            _name.text.trim(),
                            _language,
                            _runtime.text.trim(),
                          );
                        },
                  icon: const Icon(Icons.preview_outlined),
                  label: const Text('Review project'),
                ),
              ),
              if (plan != null) ...[
                const Divider(height: 32),
                Text('New folder: ${plan.path}'),
                DropdownButton<String>(
                  isExpanded: true,
                  value: plan.files.containsKey(_file)
                      ? _file
                      : plan.files.keys.first,
                  items: [
                    for (final path in plan.files.keys)
                      DropdownMenuItem(value: path, child: Text(path)),
                  ],
                  onChanged: (value) => setState(() => _file = value),
                ),
                _sourcePreview(plan.files[_file] ?? plan.files.values.first),
                const SizedBox(height: 12),
                for (final command in model.previewCommands)
                  SelectableText(command),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton(
                    onPressed: disabled ? null : model.create,
                    child: const Text('Create reviewed project'),
                  ),
                ),
              ],
              if (model.projects.isNotEmpty) ...[
                const Divider(height: 32),
                Text(
                  'Created this session',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                DropdownButton<StudioPlan>(
                  isExpanded: true,
                  value: project,
                  items: [
                    for (final item in model.projects)
                      DropdownMenuItem(
                        value: item,
                        child: Text(item.path, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: disabled
                      ? null
                      : (value) {
                          if (value != null) model.select(value);
                        },
                ),
              ],
              if (project != null) ...[
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: disabled
                          ? null
                          : () => _action(() => widget.onOpen(project)),
                      icon: const Icon(Icons.edit_note),
                      label: const Text('Open source in editor'),
                    ),
                    OutlinedButton(
                      onPressed: disabled
                          ? null
                          : () => _changeRuntime(project),
                      child: const Text('Choose runtime'),
                    ),
                    OutlinedButton.icon(
                      onPressed: disabled
                          ? null
                          : () => _action(() => widget.onRegister(project)),
                      icon: const Icon(Icons.hub_outlined),
                      label: const Text('Register in MCP Hub'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                const Text(
                  'Run in order. Check that each command exits successfully before continuing. '
                  'Terminal output is local and transient; the Hub masks inspected MCP results.',
                ),
                for (final (index, command) in model.commands.indexed)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('${index + 1}. ${command.title}'),
                    subtitle: Text(command.subtitle),
                    trailing: IconButton(
                      tooltip: 'Review ${command.title}',
                      onPressed: disabled
                          ? null
                          : () => _action(() => _run(project, index)),
                      icon: const Icon(Icons.play_arrow),
                    ),
                  ),
              ],
            ],
          ),
        ),
      );
    },
  );

  Widget _sourcePreview(String text) => Container(
    height: 280,
    decoration: BoxDecoration(
      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
    ),
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: SelectableText(
        text,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
      ),
    ),
  );
}
