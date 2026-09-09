import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../projects/domain/project.dart';
import '../domain/project_task.dart';
import '../application/shared_tasks.dart';
import 'tasks_view_model.dart';

Future<bool> reviewProjectTask(BuildContext context, ProjectTask task) async {
  final command = task.command;
  return await showDialog<bool>(
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
      ) ==
      true;
}

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
    this.onOpenConfiguration,
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
  final Future<void> Function()? onOpenConfiguration;

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
  bool coverage = false;
  TaskConfiguration? configuration;
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
      coverage: kind == ProjectTaskKind.test && coverage,
    );
    await _approve(task);
  });

  Future<void> _reviewShared(SharedTask preset) => _act(() async {
    final config = configuration;
    if (config == null) return;
    final task = await widget.model.prepare(
      widget.project,
      widget.selection,
      preset.kind,
      target: preset.target == null
          ? null
          : p.joinAll([widget.project.directory, ...preset.target!.split('/')]),
      filter: preset.filter,
      buildTarget: preset.buildTarget,
      arguments: preset.arguments,
      coverage: preset.coverage,
      configuration: config,
    );
    await _approve(task);
  });

  Future<void> _approve(ProjectTask task) async {
    try {
      if (!mounted) return;
      final approved = await reviewProjectTask(context, task);
      if (approved && mounted) await widget.onRun(task);
    } finally {
      await widget.model.discard(task);
    }
  }

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
          if (widget.project.kind == ProjectKind.python) ...[
            const Text(
              'Django management · requires manage.py in this project',
            ),
            Wrap(
              spacing: 8,
              children: [
                for (final preset in <String, List<String>>{
                  'Django check': ['check'],
                  'Django migration plan': ['migrate', '--plan'],
                  'Django make migrations': ['makemigrations'],
                  'Django migrate': ['migrate'],
                }.entries)
                  OutlinedButton(
                    onPressed: busy
                        ? null
                        : () => _act(() async {
                            final task = await widget.model.prepare(
                              widget.project,
                              widget.selection,
                              ProjectTaskKind.run,
                              target: p.join(
                                widget.project.directory,
                                'manage.py',
                              ),
                              arguments: preset.value,
                            );
                            await _approve(task);
                          }),
                    child: Text(preset.key),
                  ),
              ],
            ),
          ],
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
          if (kind == ProjectTaskKind.test)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Collect line coverage'),
              value: coverage,
              subtitle: Text(
                widget.project.kind == ProjectKind.python
                    ? 'Requires pytest-cov in the selected environment.'
                    : widget.project.kind == ProjectKind.dart
                    ? 'Requires package:coverage in this project. Uses its official test runner.'
                    : 'Uses Flutter’s native LCOV report.',
              ),
              onChanged: busy ? null : (v) => setState(() => coverage = v!),
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
          const SizedBox(height: 16),
          ExpansionTile(
            title: const Text('Shared tasks · .tabryo/project.json'),
            children: [
              const Text(
                'Load optional versioned tasks from this project. Opening this panel runs nothing. Executable paths stay in local tool selections; keep secrets out of shared arguments.',
              ),
              Wrap(
                spacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: busy
                        ? null
                        : () => _act(() async {
                            // Clear stale tasks even when the refreshed file is invalid.
                            setState(() => configuration = null);
                            final loaded = await widget.model.files
                                .readConfiguration(widget.project);
                            if (mounted) setState(() => configuration = loaded);
                          }),
                    child: const Text('Load shared tasks'),
                  ),
                  TextButton(
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('Shared task configuration'),
                        content: SelectableText(
                          'Create .tabryo/project.json inside the project and save this JSON. Targets use relative paths; loading and running are explicit.\n\n${SharedTasks.example(widget.project)}',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('Close'),
                          ),
                        ],
                      ),
                    ),
                    child: const Text('Show example'),
                  ),
                  if (widget.onOpenConfiguration != null)
                    TextButton(
                      onPressed: busy
                          ? null
                          : () => _act(widget.onOpenConfiguration!),
                      child: const Text('Open configuration'),
                    ),
                ],
              ),
              for (final preset in configuration?.tasks ?? <SharedTask>[])
                ListTile(
                  title: Text(preset.name),
                  subtitle: Text(preset.kind.name),
                  trailing: OutlinedButton(
                    onPressed: busy ? null : () => _reviewShared(preset),
                    child: const Text('Review shared task'),
                  ),
                ),
            ],
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
                if (task.coverageError != null)
                  SelectableText(task.coverageError!),
                if (task.coverage case final report?) ...[
                  Text(
                    'Line coverage: ${report.covered}/${report.total}${report.total == 0 ? ' · no executable lines reported' : ' · ${(100 * report.covered / report.total).toStringAsFixed(1)}%'}',
                  ),
                  const Text(
                    'Coverage describes this test run on saved files. Source edits can make locations stale.',
                  ),
                  if (report.excludedFiles > 0)
                    Text(
                      '${report.excludedFiles} source records outside this project excluded.',
                    ),
                  SizedBox(
                    height: 220,
                    child: ListView.builder(
                      itemCount: report.files.length,
                      itemBuilder: (context, index) {
                        final file = report.files[index];
                        final lines = file.lines.keys.toList()..sort();
                        return ListTile(
                          title: Text(
                            p.relative(
                              file.path,
                              from: widget.project.directory,
                            ),
                          ),
                          subtitle: Text(
                            '${file.covered}/${file.lines.length} lines covered',
                          ),
                          onTap: () => showDialog<void>(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: Text(p.basename(file.path)),
                              content: SizedBox(
                                width: 520,
                                height: 380,
                                child: ListView.builder(
                                  itemCount: lines.length,
                                  itemBuilder: (context, index) {
                                    final line = lines[index],
                                        hits = file.lines[line]!;
                                    return ListTile(
                                      dense: true,
                                      leading: Icon(
                                        hits == 0
                                            ? Icons.radio_button_unchecked
                                            : Icons.check_circle_outline,
                                      ),
                                      title: Text('Line $line · $hits hits'),
                                      onTap: () {
                                        Navigator.pop(context);
                                        _act(
                                          () => widget.onOpen(
                                            task,
                                            TestCaseResult(
                                              name: 'Line coverage',
                                              outcome: TestOutcome.passed,
                                              path: file.path,
                                              line: line,
                                            ),
                                          ),
                                        );
                                      },
                                    );
                                  },
                                ),
                              ),
                              actions: [
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
