import 'package:flutter/material.dart';

import '../domain/project.dart';
import 'projects_view_model.dart';
import 'project_setup_panel.dart';
import '../../language/application/language_service.dart';
import '../../language/presentation/language_dialog.dart';

final class ProjectsScreen extends StatelessWidget {
  const ProjectsScreen({
    required this.model,
    required this.onApply,
    this.onRun,
    this.onCreate,
    this.language,
    this.taskPanel,
    super.key,
  });
  final ProjectsViewModel model;
  final LanguageService? language;
  final Widget Function(DevelopmentProject, ToolchainSelection)? taskPanel;
  final Future<void> Function(DevelopmentProject, ToolchainSelection) onApply;
  final Future<void> Function(DevelopmentProject, ProjectCommand)? onRun;
  final Future<void> Function(ProjectCreation)? onCreate;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model,
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: const Text('Projects and toolchains'),
        actions: [
          TextButton.icon(
            onPressed: onCreate == null || model.workspace == null
                ? null
                : () async {
                    final started = await showDialog<bool>(
                      context: context,
                      barrierDismissible: false,
                      builder: (_) => ProjectCreationDialog(
                        model: model,
                        onCreate: onCreate!,
                      ),
                    );
                    if (started == true && context.mounted) {
                      Navigator.pop(context);
                    }
                  },
            icon: const Icon(Icons.add),
            label: const Text('Create project'),
          ),
          IconButton(
            tooltip: 'Scan workspace',
            onPressed:
                model.scanning || model.applying || model.workspace == null
                ? null
                : () => model.scan(model.workspace!),
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Close projects',
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
      body: Column(
        children: [
          if (model.scanning || model.selecting || model.applying)
            const LinearProgressIndicator(),
          if (model.message != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(model.message!),
            ),
          if (model.discovery.limited)
            const Padding(
              padding: EdgeInsets.all(8),
              child: Text(
                'Scan limit reached. Open a narrower workspace to discover the remaining projects.',
              ),
            ),
          if (model.discovery.warnings.isNotEmpty)
            ExpansionTile(
              title: const Text('Discovery notices'),
              children: [
                for (final warning in model.discovery.warnings)
                  ListTile(title: Text(warning)),
              ],
            ),
          Expanded(
            child: model.discovery.projects.isEmpty
                ? const Center(
                    child: Text(
                      'No Dart, Flutter or Python manifest was found. Open a project folder or create a project from the command palette.',
                    ),
                  )
                : Row(
                    children: [
                      SizedBox(
                        width: 280,
                        child: ListView(
                          children: [
                            for (final project in model.discovery.projects)
                              ListTile(
                                selected: identical(project, model.selected),
                                title: Text(project.name),
                                subtitle: Text(
                                  '${project.kind.name}\n${project.directory}',
                                ),
                                onTap: model.applying
                                    ? null
                                    : () => model.select(project),
                              ),
                          ],
                        ),
                      ),
                      const VerticalDivider(width: 1),
                      if (model.selected case final project?)
                        Expanded(
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.all(24),
                            child: Column(
                              children: [
                                _ToolchainForm(
                                  key: ValueKey(
                                    '${project.id}:${model.selecting}',
                                  ),
                                  project: project,
                                  model: model,
                                  onApply: onApply,
                                ),
                                if (language != null)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 16,
                                    ),
                                    child: OutlinedButton.icon(
                                      icon: const Icon(Icons.code),
                                      label: const Text(
                                        'Language intelligence',
                                      ),
                                      onPressed:
                                          model.applying || model.selecting
                                          ? null
                                          : () => showDialog<void>(
                                              context: context,
                                              barrierDismissible: false,
                                              builder: (_) => LanguageDialog(
                                                service: language!,
                                                project: project,
                                                selection: model.selection,
                                                projects:
                                                    model.discovery.projects,
                                              ),
                                            ),
                                    ),
                                  ),
                                ProjectSetupPanel(
                                  key: ValueKey(project.id),
                                  model: model,
                                  project: project,
                                  onRun: onRun,
                                ),
                                if (taskPanel != null)
                                  taskPanel!(project, model.selection),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    ),
  );
}

final class _ToolchainForm extends StatefulWidget {
  const _ToolchainForm({
    required this.project,
    required this.model,
    required this.onApply,
    super.key,
  });
  final DevelopmentProject project;
  final ProjectsViewModel model;
  final Future<void> Function(DevelopmentProject, ToolchainSelection) onApply;
  @override
  State<_ToolchainForm> createState() => _ToolchainFormState();
}

final class _ToolchainFormState extends State<_ToolchainForm> {
  late ToolchainSelection value = widget.model.selection;
  List<ProjectTool> get tools => switch (widget.project.kind) {
    ProjectKind.dart => [ProjectTool.dart],
    ProjectKind.flutter => [ProjectTool.flutter],
    ProjectKind.python => [
      ProjectTool.python,
      ProjectTool.uv,
      ProjectTool.poetry,
      ProjectTool.node,
      ProjectTool.pyright,
      ProjectTool.ruff,
      ProjectTool.black,
    ],
  };
  final _fields = <ProjectTool, TextEditingController>{};
  @override
  void initState() {
    super.initState();
    for (final tool in tools) {
      _fields[tool] = TextEditingController(text: value[tool] ?? '');
    }
  }

  @override
  void dispose() {
    for (final controller in _fields.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        widget.project.name,
        style: Theme.of(context).textTheme.headlineSmall,
      ),
      SelectableText(widget.project.directory),
      const SizedBox(height: 12),
      Text('Manifests: ${widget.project.manifests.join(', ')}'),
      if (widget.project.versionHint != null)
        Text('Project version requirement: ${widget.project.versionHint}'),
      if (widget.project.kind == ProjectKind.python)
        Text('Detected environment manager: ${widget.project.manager.name}'),
      const SizedBox(height: 16),
      const Text(
        'Choose installed tools for this project. Discovery only reads files; applying a choice starts no process. Local paths are remembered only when preference persistence is enabled.',
      ),
      for (final tool in tools) ...[
        const SizedBox(height: 20),
        TextField(
          controller: _fields[tool],
          enabled: !widget.model.applying,
          decoration: InputDecoration(
            labelText: tool == ProjectTool.flutter
                ? 'Flutter SDK directory'
                : tool == ProjectTool.pyright
                ? 'Pyright langserver JavaScript file'
                : '${tool.name} executable',
            helperText: tool == ProjectTool.flutter
                ? 'Uses its bundled Dart SDK for format on save.'
                : tool == ProjectTool.black
                ? 'Optional: selects Black for Python format on save, even with Ruff active. Clear to use Ruff.'
                : 'Absolute path. Leave empty to clear the selection.',
          ),
          onChanged: (path) => value = value.withPath(tool, path),
        ),
        Wrap(
          spacing: 8,
          children: [
            for (final candidate
                in widget.model.hints.candidates[tool] ??
                    <ToolchainCandidate>[])
              ActionChip(
                label: Text(candidate.source),
                tooltip: candidate.path,
                onPressed: widget.model.applying
                    ? null
                    : () => setState(() {
                        _fields[tool]!.text = candidate.path;
                        value = value.withPath(tool, candidate.path);
                      }),
              ),
          ],
        ),
      ],
      const SizedBox(height: 24),
      FilledButton(
        onPressed: widget.model.applying || widget.model.selecting
            ? null
            : () => widget.onApply(widget.project, value),
        child: const Text('Apply toolchains'),
      ),
    ],
  );
}
