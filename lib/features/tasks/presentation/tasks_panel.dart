import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../projects/domain/project.dart';
import '../domain/project_task.dart';
import 'tasks_view_model.dart';

final class TasksPanel extends StatefulWidget {
  const TasksPanel({
    required this.model,
    required this.project,
    required this.projects,
    required this.selection,
    required this.onRun,
    required this.onStop,
    required this.onTerminal,
    required this.onOpen,
    super.key,
  });
  final TasksViewModel model;
  final DevelopmentProject project;
  final List<DevelopmentProject> projects;
  final ToolchainSelection selection;
  final Future<void> Function(ProjectTask) onRun;
  final Future<void> Function(ProjectTask) onStop;
  final void Function(ProjectTask) onTerminal;
  final Future<void> Function(ProjectTask, TestCaseResult) onOpen;

  @override
  State<TasksPanel> createState() => _TasksPanelState();
}

final class _TasksPanelState extends State<TasksPanel> {
  final target = TextEditingController();
  final filter = TextEditingController();
  final arguments = TextEditingController(text: '[]');
  ProjectTaskKind kind = ProjectTaskKind.test;
  String buildTarget = 'web';
  bool busy = false;
  String? error;

  @override
  void dispose() {
    target.dispose();
    filter.dispose();
    arguments.dispose();
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

  Future<void> _review() => _act(() async {
    final argv = kind == ProjectTaskKind.run
        ? jsonDecode(arguments.text)
        : <String>[];
    if (argv is! List || argv.any((v) => v is! String)) {
      throw const ProjectFailure(
        'Application arguments must be a JSON list of strings.',
      );
    }
    final path =
        kind == ProjectTaskKind.analyze ||
            (kind == ProjectTaskKind.build &&
                widget.project.kind == ProjectKind.flutter)
        ? ''
        : target.text.trim();
    final task = await widget.model.prepare(
      widget.project,
      widget.selection,
      kind,
      target: path.isEmpty
          ? null
          : p.normalize(
              p.isAbsolute(path)
                  ? path
                  : p.join(widget.project.directory, path),
            ),
      filter: filter.text,
      buildTarget: buildTarget,
      arguments: kind == ProjectTaskKind.run ? argv.cast<String>() : const [],
    );
    try {
      if (!mounted) return;
      final command = task.command;
      final approved = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Review project task'),
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
              child: const Text('Run reviewed task'),
            ),
          ],
        ),
      );
      if (approved == true && mounted) await widget.onRun(task);
    } finally {
      await widget.model.discard(task);
    }
  });

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.model,
    builder: (context, _) {
      final discovery = widget.model.discoveries[widget.project.id];
      final runs = widget.model.runs
          .where(
            (v) =>
                v.project.id == widget.project.id &&
                v.project.workspace == widget.project.workspace,
          )
          .toList()
          .reversed;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 24),
          const Divider(),
          Text(
            'Tasks and tests',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const Text(
            'Discover test files without executing them. Review a command to run from saved files in an owned terminal. Results remain available in this session.',
          ),
          if (error != null)
            Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (widget.model.message != null) Text(widget.model.message!),
          OutlinedButton(
            onPressed: busy || widget.model.scanning
                ? null
                : () => widget.model.discover(widget.project, widget.projects),
            child: const Text('Discover test files'),
          ),
          if (widget.model.scanning) const LinearProgressIndicator(),
          if (discovery != null) ...[
            Text(
              '${discovery.paths.length} test files${discovery.limited ? ' · scan limit reached; open a narrower project' : ''}',
            ),
            if (discovery.paths.isNotEmpty)
              SizedBox(
                height: 180,
                child: ListView.builder(
                  itemCount: discovery.paths.length,
                  itemBuilder: (context, index) {
                    final path = discovery.paths[index];
                    return ListTile(
                      dense: true,
                      title: Text(
                        p.relative(path, from: widget.project.directory),
                      ),
                      onTap: busy
                          ? null
                          : () => setState(() {
                              target.text = path;
                              kind = ProjectTaskKind.test;
                            }),
                    );
                  },
                ),
              ),
          ],
          DropdownButton<ProjectTaskKind>(
            value: kind,
            items: ProjectTaskKind.values
                .where(
                  (k) =>
                      !(widget.project.kind == ProjectKind.python &&
                          k == ProjectTaskKind.build) &&
                      !(widget.project.kind == ProjectKind.flutter &&
                          k == ProjectTaskKind.run),
                )
                .map((k) => DropdownMenuItem(value: k, child: Text(k.name)))
                .toList(),
            onChanged: busy ? null : (v) => setState(() => kind = v!),
          ),
          if (kind != ProjectTaskKind.analyze &&
              !(kind == ProjectTaskKind.build &&
                  widget.project.kind == ProjectKind.flutter))
            TextField(
              controller: target,
              enabled: !busy,
              decoration: const InputDecoration(
                labelText: 'Project file (empty runs all tests)',
                helperText: 'Absolute path or path relative to this project.',
              ),
            ),
          if (kind == ProjectTaskKind.test)
            TextField(
              controller: filter,
              enabled: !busy,
              decoration: InputDecoration(
                labelText: widget.project.kind == ProjectKind.python
                    ? 'Test filter (pytest -k expression)'
                    : 'Test name contains',
                helperText:
                    'Optional; the native test runner applies this filter.',
              ),
            ),
          if (kind == ProjectTaskKind.run)
            TextField(
              controller: arguments,
              enabled: !busy,
              decoration: const InputDecoration(
                labelText: 'Application arguments (JSON list)',
              ),
            ),
          if (kind == ProjectTaskKind.build &&
              widget.project.kind == ProjectKind.flutter)
            DropdownButton<String>(
              value: buildTarget,
              items: [
                'web',
                'apk',
                widget.model.planner.windows ? 'windows' : 'linux',
              ].map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(),
              onChanged: busy ? null : (v) => setState(() => buildTarget = v!),
            ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: busy ? null : _review,
            child: const Text('Review task'),
          ),
          for (final task in runs)
            ExpansionTile(
              key: ObjectKey(task),
              initiallyExpanded: true,
              title: Text(
                '${task.kind.name} · ${task.status.name}${task.exitCode == null ? '' : ' · exit ${task.exitCode}'}',
              ),
              subtitle: task.target == null
                  ? null
                  : Text(
                      p.relative(task.target!, from: widget.project.directory),
                    ),
              children: [
                if (task.error != null) SelectableText(task.error!),
                Wrap(
                  spacing: 8,
                  children: [
                    OutlinedButton(
                      onPressed: () => widget.onTerminal(task),
                      child: const Text('Show terminal'),
                    ),
                    if (task.status == TaskStatus.running)
                      OutlinedButton(
                        onPressed: task.stopRequested
                            ? null
                            : () => _act(() => widget.onStop(task)),
                        child: const Text('Stop task'),
                      ),
                  ],
                ),
                if (task.results != null) ...[
                  Text(
                    '${task.results!.cases.length} results · ${task.results!.complete ? 'report complete' : 'report incomplete'}',
                  ),
                  SizedBox(
                    height: 240,
                    child: ListView.builder(
                      itemCount: task.results!.cases.length,
                      itemBuilder: (context, index) {
                        final result = task.results!.cases[index];
                        return ListTile(
                          title: Text(
                            '${result.outcome.name} · ${result.name}',
                          ),
                          subtitle: result.details.isEmpty
                              ? null
                              : Text(
                                  result.details,
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                ),
                          onTap: () => showDialog<void>(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: Text(result.name),
                              content: SizedBox(
                                width: 700,
                                child: SingleChildScrollView(
                                  child: SelectableText(
                                    '${result.outcome.name}\n${result.path ?? ''}${result.line == null ? '' : ':${result.line}'}\n${result.details}',
                                  ),
                                ),
                              ),
                              actions: [
                                if (result.path != null)
                                  TextButton(
                                    onPressed: () {
                                      Navigator.pop(context);
                                      _act(() => widget.onOpen(task, result));
                                    },
                                    child: const Text('Open source'),
                                  ),
                                TextButton(
                                  onPressed: () => Navigator.pop(context),
                                  child: const Text('Close'),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ],
            ),
        ],
      );
    },
  );
}
