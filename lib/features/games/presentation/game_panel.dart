import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../../core/cancellation.dart';
import '../../projects/domain/project.dart';
import '../application/game_commands.dart';
import '../application/game_service.dart';
import '../domain/game_workspace.dart';

final class GamePanel extends StatefulWidget {
  const GamePanel({
    required this.service,
    required this.project,
    required this.tools,
    required this.windows,
    required this.onRun,
    required this.onOpen,
    this.onAttach,
    super.key,
  });
  final GameService service;
  final DevelopmentProject project;
  final ToolchainSelection tools;
  final bool windows;
  final Future<void> Function(GamePlan) onRun;
  final Future<void> Function(String path, int? line) onOpen;
  final Future<void> Function(String executable, int pid)? onAttach;
  @override
  State<GamePanel> createState() => _GamePanelState();
}

final class _GamePanelState extends State<GamePanel> {
  final settings = TextEditingController();
  final map = TextEditingController();
  final port = TextEditingController();
  final clients = TextEditingController();
  final filter = TextEditingController();
  final lab = TextEditingController(
    text: '{\n  "cases": [\n    {"id": "recruit"},\n    {"id": "specialist"}\n  ]\n}',
  );
  final assetSearch = TextEditingController();
  final trace = TextEditingController();
  GameWorkspace? workspace;
  String? target;
  String? error;
  bool busy = false;
  String? assetDetails;
  final _loadCancellation = Cancellation();
  final Map<LabResult, bool> _stale = {};
  StreamSubscription<void>? _events;
  GameCommands get commands => GameCommands(windows: widget.windows);
  List<GameRun> get runs => widget.service.runs
      .where(
        (r) =>
            r.plan.workspace.project.id == widget.project.id &&
            r.plan.workspace.project.workspace == widget.project.workspace,
      )
      .toList()
      .reversed
      .toList();
  bool get running => runs.any((r) => r.active || !r.complete);

  @override
  void initState() {
    super.initState();
    _events = widget.service.changes.listen((_) {
      if (mounted) setState(() {});
    });
    unawaited(_act(_load));
  }

  Future<void> _load() async {
    final value = await widget.service.files.load(
      widget.project,
      _loadCancellation,
    );
    if (!mounted) return;
    setState(() {
      workspace = value;
      settings.text = value.configurationSource;
      map.text = value.configuration.map;
      port.text = '${value.configuration.port}';
      clients.text = '${value.configuration.clients}';
      filter.text = value.configuration.testFilter;
      target =
          value.targets
              .where((t) => t.name == value.configuration.target)
              .firstOrNull
              ?.name ??
          value.targets.where((t) => t.type == 'Editor').firstOrNull?.name ??
          value.targets.firstOrNull?.name;
    });
  }

  Future<void> _act(Future<void> Function() action) async {
    if (busy) return;
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

  Future<void> _save() async {
    if (running) {
      throw const GameFailure(
        'Stop the game operation before changing settings.',
      );
    }
    final value = jsonDecode(settings.text);
    if (value is! Map<String, dynamic>) {
      throw const GameFailure('Settings must be a JSON object.');
    }
    value.addAll({
      'map': map.text.trim(),
      'port': int.parse(port.text),
      'clients': int.parse(clients.text),
      'testFilter': filter.text.trim(),
      if (target != null) 'target': target,
    });
    final source = '${const JsonEncoder.withIndent('  ').convert(value)}\n';
    await widget.service.files.save(workspace!, source);
    await _load();
    _stale.clear();
  }

  Future<void> _review(GamePlan plan) async {
    if (!mounted) return;
    if (settings.text != workspace!.configurationSource ||
        map.text != workspace!.configuration.map ||
        port.text != '${workspace!.configuration.port}' ||
        clients.text != '${workspace!.configuration.clients}' ||
        filter.text != workspace!.configuration.testFilter) {
      throw const GameFailure(
        'Save or reload the changed game settings before running.',
      );
    }
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Run ${plan.title}'),
        content: SizedBox(
          width: 760,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Project: ${plan.workspace.project.directory}'),
                const SizedBox(height: 12),
                const Text(
                  'These installed tools run project code and may write build or content files. Save changes in Tabryo and external editors first. Stop closes only this operation’s owned processes.',
                ),
                for (final process in plan.processes) ...[
                  const Divider(),
                  Text(
                    process.name,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  SelectableText(
                    '${process.launch.executable}\n${jsonEncode(process.launch.arguments)}',
                  ),
                  if (process.environmentScript != null)
                    SelectableText(
                      'Compiler and SDK environment: ${process.environmentScript}',
                    ),
                  if (process.launch.environment.isNotEmpty)
                    SelectableText(
                      'Environment: ${jsonEncode(process.launch.environment)}',
                    ),
                  if (process.readyText != null)
                    Text('Ready when output contains: ${process.readyText}'),
                  if (process.dependsOn.isNotEmpty)
                    Text('Waits for: ${process.dependsOn.join(', ')}'),
                ],
                if (plan.labRequest != null)
                  SelectableText(
                    'Native laboratory input:\n${const JsonEncoder.withIndent('  ').convert(plan.labRequest)}',
                  ),
                if (plan.reportPath != null)
                  SelectableText('Native report: ${plan.reportPath}'),
              ],
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
            child: const Text('Run'),
          ),
        ],
      ),
    );
    if (yes == true && mounted) await widget.onRun(plan);
  }

  String get reportPath => p.join(
    widget.project.directory,
    'Saved',
    'Automation',
    '${DateTime.now().microsecondsSinceEpoch}${widget.project.kind == ProjectKind.cpp ? '.xml' : ''}',
  );
  Widget _action(
    String label,
    Future<void> Function() action, {
    IconData? icon,
  }) => Padding(
    padding: const EdgeInsets.only(right: 8, bottom: 8),
    child: OutlinedButton.icon(
      onPressed: busy || running || workspace == null
          ? null
          : () => _act(action),
      icon: Icon(icon ?? Icons.play_arrow),
      label: Text(label),
    ),
  );

  Future<void> _content(
    GameAsset asset, {
    bool export = false,
    bool import = false,
    bool validate = false,
  }) async {
    final problems = await widget.service.files.assetProblems(
      workspace!,
      asset,
    );
    if (problems.isNotEmpty && !export && !import) {
      throw GameFailure(problems.join('\n'));
    }
    if (asset.source != null) {
      await widget.service.files.checkedPath(widget.project, asset.source!);
    }
    if (asset.exported != null) {
      await widget.service.files.checkedPath(
        widget.project,
        asset.exported!,
        exists: !export,
      );
    }
    if (import || validate) {
      if (widget.project.kind != ProjectKind.unreal) {
        throw const GameFailure(
          'Select Unreal for content import and validation.',
        );
      }
      if (runs.any(
        (r) =>
            r.active && r.processes.any((p) => p.spec.name == 'Unreal Editor'),
      )) {
        throw const GameFailure(
          'Save and close the editor before offline content automation.',
        );
      }
      final script = validate
          ? workspace!.configuration.contentValidation
          : workspace!.configuration.unrealImport;
      if (script != null) {
        await widget.service.files.checkedPath(widget.project, script);
      }
    }
    if (export && workspace!.configuration.blenderExport != null) {
      await widget.service.files.checkedPath(
        widget.project,
        workspace!.configuration.blenderExport!,
      );
    }
    await widget.service.files.checkedPath(
      widget.project,
      asset.path,
      exists: false,
    );
    await _review(
      commands.content(
        workspace!,
        widget.tools,
        asset,
        export: export,
        import: import,
        validate: validate,
      ),
    );
  }

  Future<void> _lfs(String operation, [GameAsset? asset]) async {
    final executable = commands.tool(widget.tools, ProjectTool.git);
    final args = operation == 'files'
        ? ['lfs', 'ls-files', '--json']
        : operation == 'locks'
        ? ['lfs', 'locks', '--json']
        : ['lfs', operation, '--json', '--', asset!.path];
    await _review(
      GamePlan(
        workspace: workspace!,
        title: 'Git LFS $operation',
        toolPaths: widget.tools.paths,
        processes: [
          commands.process(workspace!, 'Git LFS $operation', executable, args),
        ],
      ),
    );
  }

  Future<void> _copy(GameRun run) async {
    final lab = run.lab;
    bool? stale;
    if (lab != null) {
      try {
        stale =
            await widget.service.files.fingerprint(run.plan.workspace) !=
            lab.fingerprint;
      } catch (_) {
        stale = true;
      }
      _stale[lab] = stale;
    }
    final context = {
      'project': run.plan.workspace.project.name,
      'directory': run.plan.workspace.project.directory,
      'operation': run.plan.title,
      'started': run.started.toIso8601String(),
      'scenario': run.plan.scenario,
      'configuration': jsonDecode(run.plan.workspace.configurationSource),
      'successful': run.successful,
      'error': run.error,
      'processes': [
        for (final process in run.processes)
          {
            'name': process.spec.name,
            'state': process.state.name,
            'executable': process.spec.launch.executable,
            'arguments': process.spec.launch.arguments,
            'exitCode': process.exitCode,
            'output': process.output.length > 8192
                ? process.output.substring(process.output.length - 8192)
                : process.output,
          },
      ],
      if (run.tests != null)
        'tests': [
          for (final c in run.tests!.cases.take(100))
            {'name': c.name, 'outcome': c.outcome.name, 'details': c.details},
        ],
      if (lab != null)
        'laboratory': {
          'codeVersion': lab.codeVersion,
          'dataVersion': lab.dataVersion,
          'fingerprint': lab.fingerprint,
          'stale': stale,
          'request': run.plan.labRequest,
          'cases': lab.cases,
        },
    };
    await Clipboard.setData(
      ClipboardData(text: const JsonEncoder.withIndent('  ').convert(context)),
    );
    if (mounted) {
      ScaffoldMessenger.of(this.context).showSnackBar(
        const SnackBar(
          content: Text(
            'Investigation context copied. Review it before sharing with Codex.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.sports_esports),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Game development',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              IconButton(
                tooltip: 'Reload game project',
                onPressed: busy || running ? null : () => _act(_load),
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          if (busy) const LinearProgressIndicator(),
          if (error != null)
            SelectableText(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (workspace case final w?) ...[
            Text(
              '${widget.project.kind == ProjectKind.unreal ? 'Unreal ${widget.project.versionHint ?? ''}' : 'CMake / C++'} · ${w.targets.length} targets · ${w.modules.length} modules · ${w.plugins.length} plugins · ${w.assets.length} assets',
            ),
            if (w.limited)
              const Text(
                'Discovery reached its limit. Asset mappings can also be added in project settings.',
              ),
            if (w.targets.isNotEmpty)
              DropdownButton<String>(
                value: target,
                isExpanded: true,
                items: [
                  for (final t in w.targets)
                    DropdownMenuItem(
                      value: t.name,
                      child: Text('${t.name} (${t.type})'),
                    ),
                ],
                onChanged: busy || running
                    ? null
                    : (v) => setState(() => target = v),
              ),
            const SizedBox(height: 12),
            Wrap(
              children: [
                if (widget.project.kind == ProjectKind.cpp)
                  _action(
                    'Configure CMake',
                    () => _review(
                      commands.action(
                        w,
                        widget.tools,
                        GameAction.configure,
                        reportPath: reportPath,
                      ),
                    ),
                  ),
                _action(
                  'Build',
                  () => _review(
                    commands.action(
                      w,
                      widget.tools,
                      GameAction.build,
                      reportPath: reportPath,
                      target: target,
                    ),
                  ),
                  icon: Icons.build,
                ),
                _action(
                  'Generate compile commands',
                  () => _review(
                    commands.action(
                      w,
                      widget.tools,
                      GameAction.compileCommands,
                      reportPath: reportPath,
                      target: target,
                    ),
                  ),
                ),
                _action(
                  'Run native tests',
                  () => _review(
                    commands.action(
                      w,
                      widget.tools,
                      GameAction.test,
                      reportPath: reportPath,
                    ),
                  ),
                  icon: Icons.science,
                ),
                if (widget.project.kind == ProjectKind.unreal) ...[
                  _action(
                    'Open Unreal Editor',
                    () => _review(
                      commands.action(
                        w,
                        widget.tools,
                        GameAction.editor,
                        reportPath: reportPath,
                      ),
                    ),
                  ),
                  _action(
                    'Cook content',
                    () => _review(
                      commands.action(
                        w,
                        widget.tools,
                        GameAction.cook,
                        reportPath: reportPath,
                      ),
                    ),
                  ),
                  _action(
                    'Package game',
                    () => _review(
                      commands.action(
                        w,
                        widget.tools,
                        GameAction.package,
                        reportPath: reportPath,
                      ),
                    ),
                  ),
                  _action(
                    'Validate content',
                    () => _review(
                      commands.action(
                        w,
                        widget.tools,
                        GameAction.validateContent,
                        reportPath: reportPath,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            ExpansionTile(
              title: const Text('Multiplayer and project settings'),
              children: [
                TextField(
                  controller: map,
                  enabled: !running && !busy,
                  decoration: const InputDecoration(labelText: 'Unreal map'),
                ),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: port,
                        enabled: !running && !busy,
                        decoration: const InputDecoration(
                          labelText: 'Server port',
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: TextField(
                        controller: clients,
                        enabled: !running && !busy,
                        decoration: const InputDecoration(
                          labelText: 'Local clients (1–16)',
                        ),
                      ),
                    ),
                  ],
                ),
                TextField(
                  controller: filter,
                  enabled: !running && !busy,
                  decoration: const InputDecoration(
                    labelText: 'Native test filter',
                  ),
                ),
                ExpansionTile(
                  title: const Text('Advanced settings · .tabryo/game.json'),
                  children: [
                    const Text(
                      'Configure the build directory, native laboratory, backend services with readiness markers, content scripts, source/dependency mappings and an existing delivery pipeline. Executable profiles use project-relative paths; installed tools use Toolchains above.',
                    ),
                    TextField(
                      controller: settings,
                      enabled: !running && !busy,
                      minLines: 8,
                      maxLines: 18,
                      decoration: const InputDecoration(
                        labelText: 'Portable game settings (JSON)',
                      ),
                    ),
                  ],
                ),
                Row(
                  children: [
                    FilledButton(
                      onPressed: running || busy ? null : () => _act(_save),
                      child: const Text('Save game settings'),
                    ),
                    const SizedBox(width: 12),
                    if (widget.project.kind == ProjectKind.unreal)
                      _action(
                        'Start server and clients',
                        () => _review(commands.session(w, widget.tools)),
                        icon: Icons.lan,
                      ),
                  ],
                ),
                const Text(
                  'A readiness log marker confirms startup. Network behavior, connection counts and rendering performance require the game’s native tests and measurements.',
                ),
                for (final profile in w.configuration.sessions)
                  ListTile(
                    title: Text(profile.name),
                    subtitle: Text(
                      '${profile.buildVersion} · ${profile.scenario}',
                    ),
                    trailing: _action(
                      'Start session',
                      () => _review(
                        commands.configuredSession(w, widget.tools, profile),
                      ),
                    ),
                  ),
              ],
            ),
            ExpansionTile(
              title: const Text('Native rules laboratory'),
              children: [
                const Text(
                  'Compare specialization, equipment, combat, progression or career cases using the game’s own executable. Add the inputs its native core accepts. Each result includes code/data versions, numeric metrics and explanations.',
                ),
                if (w.configuration.lab == null)
                  const Text(
                    'Configure lab.executable and versionFiles in Advanced settings to connect the game’s rules core.',
                  ),
                TextField(
                  controller: lab,
                  minLines: 5,
                  maxLines: 16,
                  enabled: !running && !busy,
                  decoration: const InputDecoration(
                    labelText: 'Native cases (JSON)',
                  ),
                ),
                _action('Compare cases', () async {
                  final fingerprint = await widget.service.files.fingerprint(w);
                  await _review(
                    commands.laboratory(w, widget.tools, lab.text, fingerprint),
                  );
                }, icon: Icons.compare),
              ],
            ),
            ExpansionTile(
              title: Text('Content and assets (${w.assets.length})'),
              children: [
                TextField(
                  controller: assetSearch,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: 'Filter assets by path or source',
                  ),
                ),
                const Text(
                  'Source mappings preserve the project’s authoring workflow. Export/import scripts own skeleton, units, sockets, collision, materials and LOD policy. Offline import requires saved and closed external Unreal editors.',
                ),
                Wrap(
                  children: [
                    _action('Git LFS files', () => _lfs('files')),
                    _action('Git LFS locks', () => _lfs('locks')),
                  ],
                ),
                if (assetDetails != null) SelectableText(assetDetails!),
                for (final asset
                    in w.assets
                        .where(
                          (a) => '${a.path} ${a.source ?? ''}'
                              .toLowerCase()
                              .contains(assetSearch.text.toLowerCase()),
                        )
                        .take(40))
                  ExpansionTile(
                    title: Text(asset.path),
                    subtitle: asset.source == null
                        ? null
                        : Text('Source: ${asset.source}'),
                    children: [
                      if (asset.objectPath != null)
                        SelectableText('Unreal object: ${asset.objectPath}'),
                      if (asset.exported != null)
                        SelectableText('Interchange file: ${asset.exported}'),
                      _action('Preview', () async {
                        final bytes = await widget.service.files.preview(
                          w,
                          asset,
                        );
                        if (!context.mounted) return;
                        await showDialog<void>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: Text(asset.preview ?? asset.path),
                            content: SizedBox(
                              width: 512,
                              height: 400,
                              child: Image.memory(
                                bytes,
                                cacheWidth: 512,
                                fit: BoxFit.contain,
                                errorBuilder: (_, _, _) => const Text(
                                  'The content tool did not produce a supported image.',
                                ),
                              ),
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context),
                                child: const Text('Close'),
                              ),
                            ],
                          ),
                        );
                      }),
                      Text(
                        'Dependencies: ${asset.dependencies.isEmpty ? 'No explicit mapping' : asset.dependencies.join(', ')}',
                      ),
                      Text(
                        'Used by: ${w.assets.where((a) => a.dependencies.contains(asset.path)).map((a) => a.path).join(', ')}',
                      ),
                      Wrap(
                        children: [
                          _action('Inspect', () async {
                            final issues = await widget.service.files
                                .assetProblems(w, asset);
                            if (mounted) {
                              setState(
                                () => assetDetails = issues.isEmpty
                                    ? '${asset.path}: source and declared dependencies are available.'
                                    : issues.join('\n'),
                              );
                            }
                          }),
                          _action('Open source', () async {
                            final path = await widget.service.files.checkedPath(
                              widget.project,
                              asset.source ?? asset.path,
                            );
                            if (p.extension(path).toLowerCase() == '.blend') {
                              await _content(asset);
                            } else {
                              await widget.onOpen(path, null);
                            }
                          }),
                          if (p
                                  .extension(asset.source ?? asset.path)
                                  .toLowerCase() ==
                              '.blend')
                            _action(
                              'Export',
                              () => _content(asset, export: true),
                            ),
                          if (widget.project.kind == ProjectKind.unreal) ...[
                            _action(
                              'Import / reimport',
                              () => _content(asset, import: true),
                            ),
                            _action(
                              'Validate asset',
                              () => _content(asset, validate: true),
                            ),
                          ],
                          _action('Lock in LFS', () => _lfs('lock', asset)),
                          _action('Unlock in LFS', () => _lfs('unlock', asset)),
                        ],
                      ),
                    ],
                  ),
              ],
            ),
            ExpansionTile(
              title: const Text('Delivery and performance investigation'),
              children: [
                const Text(
                  'Open a native Unreal Insights trace or run the existing project delivery pipeline. Pipeline output remains distinct from native tests and playtest acceptance.',
                ),
                TextField(
                  controller: trace,
                  decoration: const InputDecoration(
                    labelText: 'Project-relative .utrace file',
                  ),
                ),
                _action('Open Unreal Insights', () async {
                  final path = await widget.service.files.checkedPath(
                    widget.project,
                    trace.text.trim(),
                  );
                  if (p.extension(path) != '.utrace') {
                    throw const GameFailure('Select a .utrace capture.');
                  }
                  await _review(
                    GamePlan(
                      workspace: w,
                      title: 'Unreal Insights',
                      toolPaths: widget.tools.paths,
                      inputPaths: [trace.text.trim()],
                      processes: [
                        commands.process(
                          w,
                          'Unreal Insights',
                          commands.tool(widget.tools, ProjectTool.insights),
                          ['-OpenTraceFile=$path'],
                          persistent: true,
                        ),
                      ],
                    ),
                  );
                }),
                if (w.configuration.pipeline case final pipeline?)
                  _action(
                    'Run delivery pipeline',
                    () => _review(
                      GamePlan(
                        workspace: w,
                        title: pipeline.name,
                        toolPaths: widget.tools.paths,
                        processes: [commands.executable(w, pipeline)],
                      ),
                    ),
                  ),
              ],
            ),
          ],
          if (runs.isNotEmpty) ...[
            const Divider(),
            Text(
              'Operations and results',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            for (final run in runs.take(8))
              ExpansionTile(
                initiallyExpanded: identical(run, runs.first),
                title: Text(
                  '${run.plan.title} · ${run.active
                      ? 'active'
                      : run.stopped
                      ? 'stopped'
                      : run.successful
                      ? 'passed'
                      : run.complete
                      ? 'failed'
                      : 'finishing'}',
                ),
                subtitle: run.error == null ? null : Text(run.error!),
                children: [
                  Row(
                    children: [
                      if (run.active || !run.complete)
                        TextButton.icon(
                          onPressed: () => widget.service.stop(run),
                          icon: const Icon(Icons.stop),
                          label: const Text('Stop operation'),
                        ),
                      TextButton.icon(
                        onPressed: () => _act(() => _copy(run)),
                        icon: const Icon(Icons.copy),
                        label: const Text('Copy investigation for Codex'),
                      ),
                    ],
                  ),
                  if (run.plan.artifactDirectory != null)
                    SelectableText(
                      'Package destination: ${run.plan.artifactDirectory}',
                    ),
                  if (run.plan.reportPath != null)
                    SelectableText('Native report: ${run.plan.reportPath}'),
                  if (run.tests != null) ...[
                    Text(
                      '${run.tests!.cases.length} native test cases · ${run.tests!.complete ? 'complete' : 'incomplete'}',
                    ),
                    for (final test in run.tests!.cases.take(100))
                      ListTile(
                        dense: true,
                        title: Text('${test.outcome.name} · ${test.name}'),
                        subtitle: test.details.isEmpty
                            ? null
                            : Text(test.details),
                      ),
                  ],
                  if (run.lab case final result?) ...[
                    SelectableText(
                      'Code: ${result.codeVersion}\nData: ${result.dataVersion}',
                    ),
                    Text(
                      _stale[result] == true
                          ? 'Stale: rules/data changed or could not be verified.'
                          : 'Snapshot result. Verify current rules before reusing this comparison.',
                    ),
                    TextButton(
                      onPressed: () => _act(() async {
                        final current = await widget.service.files.fingerprint(
                          run.plan.workspace,
                        );
                        if (mounted) {
                          setState(
                            () =>
                                _stale[result] = current != result.fingerprint,
                          );
                        }
                      }),
                      child: const Text('Check comparison freshness'),
                    ),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: DataTable(
                        dataRowMaxHeight: double.infinity,
                        columns: const [
                          DataColumn(label: Text('Case')),
                          DataColumn(label: Text('Metrics')),
                          DataColumn(label: Text('Explanation')),
                        ],
                        rows: [
                          for (final c in result.cases)
                            DataRow(
                              cells: [
                                DataCell(Text('${c['id']}')),
                                DataCell(
                                  Text(
                                    (c['metrics'] as Map).entries
                                        .map((e) => '${e.key}: ${e.value}')
                                        .join('\n'),
                                  ),
                                ),
                                DataCell(
                                  SizedBox(
                                    width: 340,
                                    child: Text(
                                      (c['explanation'] as List).join('\n'),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ),
                  ],
                  for (final problem in run.problems.take(80))
                    ListTile(
                      dense: true,
                      title: Text('${problem.kind.name}: ${problem.message}'),
                      onTap: problem.path == null
                          ? null
                          : () => _act(
                              () => widget.onOpen(problem.path!, problem.line),
                            ),
                    ),
                  for (final process in run.processes)
                    ExpansionTile(
                      title: Text(
                        '${process.spec.name} · ${process.state.name} · PID ${process.pid ?? 'pending'}',
                      ),
                      subtitle: Text(
                        'Exit ${process.exitCode ?? 'pending'}${process.outputLimited ? ' · older output trimmed' : ''}',
                      ),
                      children: [
                        if (process.active &&
                            process.pid != null &&
                            widget.onAttach != null)
                          TextButton.icon(
                            onPressed: busy
                                ? null
                                : () => _act(
                                    () => widget.onAttach!(
                                      process.spec.launch.executable,
                                      process.pid!,
                                    ),
                                  ),
                            icon: const Icon(Icons.bug_report),
                            label: const Text('Attach C++ debugger'),
                          ),
                        SizedBox(
                          height: 220,
                          child: SingleChildScrollView(
                            child: SelectableText(
                              process.output,
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
          ],
        ],
      ),
    ),
  );

  @override
  void dispose() {
    _loadCancellation.cancel();
    unawaited(_events?.cancel());
    for (final controller in [
      settings,
      map,
      port,
      clients,
      filter,
      lab,
      assetSearch,
      trace,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }
}
