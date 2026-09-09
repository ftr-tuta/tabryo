import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../domain/project.dart';
import 'projects_view_model.dart';

final class ProjectSetupPanel extends StatefulWidget {
  const ProjectSetupPanel({
    required this.model,
    required this.project,
    this.onRun,
    super.key,
  });
  final ProjectsViewModel model;
  final DevelopmentProject project;
  final Future<void> Function(DevelopmentProject, ProjectCommand)? onRun;
  @override
  State<ProjectSetupPanel> createState() => _ProjectSetupPanelState();
}

final class _ProjectSetupPanelState extends State<ProjectSetupPanel> {
  late PythonManager manager = widget.project.manager;
  String? error;
  bool running = false;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const SizedBox(height: 24),
      const Divider(),
      Text(
        'Prepare environment',
        style: Theme.of(context).textTheme.titleLarge,
      ),
      const Text(
        'Apply your tool choices first, then review and run one step at a time. Installation may download packages and execute their build code. The terminal shows progress and can stop the command.',
      ),
      if (widget.project.kind == ProjectKind.python)
        DropdownButton<PythonManager>(
          value: manager,
          items: PythonManager.values
              .map(
                (value) =>
                    DropdownMenuItem(value: value, child: Text(value.name)),
              )
              .toList(),
          onChanged: running
              ? null
              : (value) => setState(() => manager = value!),
        ),
      if (error != null)
        Text(
          error!,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      for (final command in widget.model.setup.commands(
        widget.project,
        widget.model.selection,
        pythonManager: manager,
      ))
        ListTile(
          title: Text(command.title),
          subtitle: Text(command.description),
          trailing: OutlinedButton(
            onPressed: widget.onRun == null || running
                ? null
                : () async {
                    if (!await _review(context, command)) return;
                    if (!mounted) return;
                    setState(() {
                      running = true;
                      error = null;
                    });
                    try {
                      await widget.onRun!(widget.project, command);
                    } catch (failure) {
                      if (mounted) setState(() => error = '$failure');
                    } finally {
                      if (mounted) setState(() => running = false);
                    }
                  },
            child: const Text('Review and run'),
          ),
        ),
      const SizedBox(height: 16),
      const ExpansionTile(
        title: Text('Install a missing SDK or manager'),
        children: [
          ListTile(
            title: SelectableText(
              'Flutter: https://docs.flutter.dev/install\nDart: https://dart.dev/get-dart\nPython: https://www.python.org/downloads/\nuv: https://docs.astral.sh/uv/getting-started/installation/\nPoetry: https://python-poetry.org/docs/#installation',
            ),
            subtitle: Text(
              'Use the official installation guide, then select the installed path. Python projects can bootstrap uv inside their .venv using the steps above.',
            ),
          ),
        ],
      ),
    ],
  );
}

Future<bool> _review(BuildContext context, ProjectCommand command) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(command.title),
        content: SizedBox(
          width: 720,
          child: SingleChildScrollView(
            child: SelectableText(
              '${command.description}\n\nDirectory: ${command.spec.workingDirectory}\nExecutable: ${command.spec.executable}\nArguments: ${jsonEncode(command.spec.arguments)}\nEnvironment overrides: ${jsonEncode(command.spec.environment)}\nRemoved inherited variables: ${command.spec.unsetEnvironment.join(', ')}',
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Run reviewed command'),
          ),
        ],
      ),
    ) ??
    false;

final class ProjectCreationDialog extends StatefulWidget {
  const ProjectCreationDialog({
    required this.model,
    required this.onCreate,
    super.key,
  });
  final ProjectsViewModel model;
  final Future<void> Function(ProjectCreation) onCreate;
  @override
  State<ProjectCreationDialog> createState() => _ProjectCreationDialogState();
}

final class _ProjectCreationDialogState extends State<ProjectCreationDialog> {
  late final String workspace = widget.model.workspace!;
  late ProjectKind kind = widget.model.selected?.native == true
      ? ProjectKind.dart
      : widget.model.selected?.kind ?? ProjectKind.dart;
  String name = '';
  late ToolchainSelection tools = ToolchainSelection({
    for (final entry in widget.model.hints.candidates.entries)
      if (entry.value.isNotEmpty) entry.key: entry.value.first.path,
    ...widget.model.selection.paths,
  });
  bool busy = false;
  bool submitted = false;
  String? error;
  ProjectCreation? preview;
  Future<void> _prepare() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final creation = await widget.model.setup.prepareCreation(
        workspace,
        name,
        kind,
        tools,
      );
      if (!mounted) {
        await widget.model.environment.finishCreation(creation, publish: false);
        return;
      }
      setState(() => preview = creation);
    } catch (failure) {
      if (mounted) setState(() => error = '$failure');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    final creation = preview;
    if (creation != null && !submitted) {
      unawaited(
        widget.model.environment
            .finishCreation(creation, publish: false)
            .catchError((Object _) {}),
      );
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: const Text('Create project'),
      content: SizedBox(
        width: 700,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText('Workspace: $workspace'),
              if (error != null)
                Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              if (preview == null) ...[
                DropdownButton<ProjectKind>(
                  value: kind,
                  items: ProjectKind.values
                      .where(
                        (value) =>
                            value != ProjectKind.cpp &&
                            value != ProjectKind.unreal,
                      )
                      .map(
                        (value) => DropdownMenuItem(
                          value: value,
                          child: Text(value.name),
                        ),
                      )
                      .toList(),
                  onChanged: busy
                      ? null
                      : (value) => setState(() {
                          kind = value!;
                          tools = ToolchainSelection();
                        }),
                ),
                TextFormField(
                  decoration: const InputDecoration(
                    labelText: 'New project name',
                  ),
                  enabled: !busy,
                  onChanged: (value) => name = value,
                ),
                for (final tool in switch (kind) {
                  ProjectKind.dart => [ProjectTool.dart],
                  ProjectKind.flutter => [ProjectTool.flutter],
                  ProjectKind.python => [ProjectTool.python, ProjectTool.uv],
                  ProjectKind.cpp || ProjectKind.unreal => <ProjectTool>[],
                }) ...[
                  TextFormField(
                    key: ValueKey('${kind.name}:${tool.name}:${tools[tool]}'),
                    initialValue: tools[tool] ?? '',
                    enabled: !busy,
                    decoration: InputDecoration(
                      labelText: tool == ProjectTool.flutter
                          ? 'Flutter SDK directory'
                          : '${tool.name} executable (absolute path)',
                    ),
                    onChanged: (value) => tools = tools.withPath(tool, value),
                  ),
                  for (final candidate
                      in widget.model.hints.candidates[tool] ??
                          <ToolchainCandidate>[])
                    ActionChip(
                      label: Text(candidate.source),
                      tooltip: candidate.path,
                      onPressed: busy
                          ? null
                          : () => setState(
                              () =>
                                  tools = tools.withPath(tool, candidate.path),
                            ),
                    ),
                ],
                const Padding(
                  padding: EdgeInsets.only(top: 16),
                  child: Text(
                    'Preview reserves a temporary folder and shows the exact command. Existing destination folders are refused.',
                  ),
                ),
              ] else ...[
                SelectableText(preview!.command.description),
                const SizedBox(height: 12),
                SelectableText(
                  '${preview!.command.spec.executable}\n${jsonEncode(preview!.command.spec.arguments)}\nDirectory: ${preview!.command.spec.workingDirectory}\nEnvironment: ${jsonEncode(preview!.command.spec.environment)}',
                ),
              ],
              if (busy) const LinearProgressIndicator(),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: busy
              ? null
              : preview == null
              ? _prepare
              : () async {
                  setState(() {
                    busy = true;
                    error = null;
                  });
                  try {
                    await widget.onCreate(preview!);
                    submitted = true;
                    if (context.mounted) Navigator.pop(context, true);
                  } catch (failure) {
                    if (mounted) setState(() => error = '$failure');
                  } finally {
                    if (mounted) setState(() => busy = false);
                  }
                },
          child: Text(
            preview == null ? 'Preview creation' : 'Run reviewed creation',
          ),
        ),
      ],
    ),
  );
}
