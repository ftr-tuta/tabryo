import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../projects/domain/project.dart';
import '../application/debug_service.dart';
import '../application/debug_profiles.dart';
import '../domain/debug_session.dart';

final class DebugPanel extends StatefulWidget {
  const DebugPanel({
    required this.service,
    required this.project,
    required this.tools,
    required this.onStart,
    required this.onStop,
    required this.onControl,
    required this.onSource,
    this.onDevTools,
    super.key,
  });
  final DebugService service;
  final DevelopmentProject project;
  final ToolchainSelection tools;
  final Future<void> Function(DebugConfiguration) onStart;
  final Future<void> Function() onStop;
  final Future<void> Function(String) onControl;
  final Future<void> Function(String, int, int) onSource;
  final Future<void> Function()? onDevTools;
  @override
  State<DebugPanel> createState() => _DebugPanelState();
}

final class _DebugPanelState extends State<DebugPanel> {
  late final program = TextEditingController(
    text: widget.project.kind == ProjectKind.flutter
        ? 'lib/main.dart'
        : 'main.${widget.project.kind == ProjectKind.python ? 'py' : 'dart'}',
  );
  final arguments = TextEditingController(text: '[]');
  final breakpoints = TextEditingController();
  final expression = TextEditingController();
  final port = TextEditingController(text: '8000');
  final attachEndpoint = TextEditingController();
  final directory = TextEditingController(text: '.');
  final environment = TextEditingController(text: '{}');
  final conditions = TextEditingController(text: '{}');
  final flavor = TextEditingController();
  final toolArguments = TextEditingController(text: '[]');
  bool attach = false;
  String flutterMode = 'debug';
  String profile = 'Script';
  String? device;
  List<FlutterDevice> devices = [];
  bool busy = false;
  bool noDebug = false;
  String? error;
  String? evaluation;
  int? evaluationStop;
  int? evaluationFrame;
  @override
  void dispose() {
    program.dispose();
    arguments.dispose();
    breakpoints.dispose();
    expression.dispose();
    port.dispose();
    attachEndpoint.dispose();
    directory.dispose();
    environment.dispose();
    conditions.dispose();
    flavor.dispose();
    toolArguments.dispose();
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
    final args = jsonDecode(arguments.text);
    if (args is! List || args.any((v) => v is! String)) {
      throw const DebugFailure('Arguments must be a JSON list of strings.');
    }
    final path = p.normalize(
      p.isAbsolute(program.text)
          ? program.text
          : p.join(widget.project.directory, program.text),
    );
    final lines = breakpoints.text.trim().isEmpty
        ? <int>[]
        : breakpoints.text
              .split(',')
              .map((s) => int.parse(s.trim()))
              .toSet()
              .toList();
    final conditional = jsonDecode(conditions.text);
    if (conditional is! Map ||
        conditional.entries.any(
          (entry) =>
              entry.key is! String ||
              entry.value is! String ||
              !lines.contains(int.tryParse('${entry.key}')),
        )) {
      throw const DebugFailure(
        'Conditions must map a declared breakpoint line to an expression, for example {"5":"count > 2"}.',
      );
    }
    final env = jsonDecode(environment.text);
    final toolArgs = jsonDecode(toolArguments.text);
    if (env is! Map ||
        env.values.any((v) => v is! String) ||
        toolArgs is! List ||
        toolArgs.any((v) => v is! String)) {
      throw const DebugFailure(
        'Environment must be a JSON object of strings; tool arguments must be a JSON list of strings.',
      );
    }
    final config = debugProfile(
      project: widget.project,
      tools: widget.tools,
      program: path,
      arguments: args.cast<String>(),
      profile: profile,
      port: int.parse(port.text),
      device: device,
      noDebug: noDebug,
      attachUri: attach ? Uri.parse(attachEndpoint.text.trim()) : null,
      workingDirectory: p.normalize(
        p.isAbsolute(directory.text)
            ? directory.text
            : p.join(widget.project.directory, directory.text),
      ),
      environment: Map<String, String>.from(env),
      toolArguments: toolArgs.cast<String>(),
      flavor: flavor.text.trim().isEmpty ? null : flavor.text.trim(),
      flutterMode: flutterMode,
      breakpoints: lines.isEmpty
          ? {}
          : {
              path: [
                for (final line in lines)
                  DebugBreakpoint(
                    line,
                    condition: conditional['$line'] as String?,
                  ),
              ],
            },
    );
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Review debug session'),
        content: SizedBox(
          width: 720,
          child: SingleChildScrollView(
            child: SelectableText(
              '${config.isAttach ? 'Connects to an existing local application. Disconnect keeps that application running.' : 'Runs saved project code using the selected adapter. Stop closes its owned process tree. Python requires debugpy in this environment.'}\n\nTools: ${jsonEncode(config.tools.toJson())}\n\n${const JsonEncoder.withIndent('  ').convert(widget.service.launchArguments(config))}\n\nBreakpoints: ${jsonEncode(config.breakpoints)}',
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
            child: const Text('Start reviewed session'),
          ),
        ],
      ),
    );
    if (approved == true && mounted) await widget.onStart(config);
  });

  @override
  Widget build(BuildContext context) => StreamBuilder<void>(
    stream: widget.service.changes,
    builder: (context, _) {
      final service = widget.service;
      final here = service.configuration?.project.id == widget.project.id;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(),
          Text('Run and debug', style: Theme.of(context).textTheme.titleLarge),
          const Text(
            'Choose saved source, optional breakpoint lines and review before starting. No adapter starts when this panel opens.',
          ),
          if (error != null)
            Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (widget.project.kind == ProjectKind.python)
            DropdownButton<String>(
              value: profile,
              items: [
                'Script',
                'Django',
                'FastAPI',
              ].map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(),
              onChanged: busy || service.active
                  ? null
                  : (v) => setState(() {
                      profile = v!;
                      program.text = v == 'Django' ? 'manage.py' : 'main.py';
                    }),
            ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Attach to an existing local application'),
            value: attach,
            onChanged: busy || service.active
                ? null
                : (value) => setState(() => attach = value!),
          ),
          if (attach)
            TextField(
              controller: attachEndpoint,
              enabled: !busy && !service.active,
              decoration: InputDecoration(
                labelText: widget.project.kind == ProjectKind.python
                    ? 'debugpy endpoint (tcp://127.0.0.1:5678)'
                    : 'Local Dart VM service URI',
                helperText:
                    'Disconnect keeps the existing application running.',
              ),
            ),
          TextField(
            controller: program,
            enabled: !busy && !service.active,
            decoration: const InputDecoration(
              labelText: 'Debug entrypoint (project-relative path)',
            ),
          ),
          TextField(
            controller: arguments,
            enabled: !attach && !busy && !service.active,
            decoration: const InputDecoration(
              labelText: 'Program arguments (JSON list)',
            ),
          ),
          ExpansionTile(
            title: const Text(
              'Directory, environment and breakpoint conditions',
            ),
            children: [
              TextField(
                controller: directory,
                enabled: !busy && !service.active,
                decoration: const InputDecoration(
                  labelText: 'Working directory inside the project',
                ),
              ),
              TextField(
                controller: environment,
                enabled: !attach && !busy && !service.active,
                decoration: const InputDecoration(
                  labelText: 'Environment overrides (JSON object)',
                  helperText:
                      'Kept in memory; values appear in the session review.',
                ),
              ),
              TextField(
                controller: conditions,
                enabled: !busy && !service.active,
                decoration: const InputDecoration(
                  labelText: 'Breakpoint conditions (JSON line to expression)',
                  helperText:
                      'Example: {"5":"count > 2"}. Requires adapter support.',
                ),
              ),
              if (widget.project.kind != ProjectKind.python)
                TextField(
                  controller: toolArguments,
                  enabled: !attach && !busy && !service.active,
                  decoration: const InputDecoration(
                    labelText: 'SDK tool arguments (JSON list)',
                  ),
                ),
              if (widget.project.kind == ProjectKind.flutter) ...[
                TextField(
                  controller: flavor,
                  enabled: !attach && !busy && !service.active,
                  decoration: const InputDecoration(
                    labelText: 'Flutter flavor (optional)',
                  ),
                ),
                DropdownButton<String>(
                  value: flutterMode,
                  items: [
                    for (final mode in ['debug', 'profile', 'release'])
                      DropdownMenuItem(
                        value: mode,
                        child: Text('Flutter $mode'),
                      ),
                  ],
                  onChanged: attach || busy || service.active
                      ? null
                      : (value) => setState(() => flutterMode = value!),
                ),
                const Text(
                  'Profile/Release depend on the target. Breakpoints and hot reload require debug mode.',
                ),
              ],
            ],
          ),
          if (profile != 'Script')
            TextField(
              controller: port,
              enabled: !busy && !service.active,
              decoration: const InputDecoration(labelText: 'Local server port'),
            ),
          TextField(
            controller: breakpoints,
            enabled: !busy && !service.active,
            decoration: const InputDecoration(
              labelText: 'Breakpoint lines in this file (for example 5, 12)',
            ),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: noDebug,
            title: const Text('Run without debugging'),
            onChanged: attach || busy || service.active
                ? null
                : (v) => setState(() => noDebug = v!),
          ),
          if (widget.project.kind == ProjectKind.flutter) ...[
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: service.reloadOnSave,
              title: const Text('Hot reload after successful Dart saves'),
              onChanged: (value) => service.setReloadOnSave(value!),
            ),
            OutlinedButton(
              onPressed: busy
                  ? null
                  : () => _act(() async {
                      final result = await service.adapters.devices(
                        widget.project,
                        widget.tools,
                      );
                      if (mounted) {
                        setState(() {
                          devices = result;
                          if (!devices.any((d) => d.id == device)) {
                            device = null;
                          }
                        });
                      }
                    }),
              child: const Text('Discover Flutter devices'),
            ),
            if (devices.isNotEmpty)
              DropdownButton<String>(
                value: device,
                hint: const Text('Choose a device'),
                items: devices
                    .map(
                      (d) => DropdownMenuItem(
                        value: d.id,
                        child: Text('${d.name} · ${d.platform}'),
                      ),
                    )
                    .toList(),
                onChanged: busy || service.active
                    ? null
                    : (v) => setState(() => device = v),
              ),
          ],
          FilledButton(
            onPressed: busy || service.active ? null : _review,
            child: const Text('Review run / debug'),
          ),
          if (service.active && !here) ...[
            Text(
              'Debugger active in ${service.configuration?.project.name ?? 'another project'}',
            ),
            OutlinedButton(
              onPressed: () => _act(widget.onStop),
              child: const Text('Stop debugger'),
            ),
          ],
          if (here) ...[
            if (service.vmService != null)
              OutlinedButton(
                onPressed: busy
                    ? null
                    : () => _act(widget.onDevTools ?? service.openDevTools),
                child: Text(
                  widget.onDevTools == null
                      ? 'Open DevTools in browser'
                      : 'Open DevTools in Tabryo',
                ),
              ),
            Text(
              'Debugger: ${service.status.name}${service.stopReason == null ? '' : ' · ${service.stopReason}'}${service.exitCode == null ? '' : ' · exit ${service.exitCode}'}',
            ),
            if (service.error != null) Text(service.error!),
            if (service.active)
              Wrap(
                spacing: 8,
                children: [
                  FilledButton(
                    onPressed: () => _act(widget.onStop),
                    child: Text(
                      service.configuration?.isAttach == true
                          ? 'Disconnect debugger'
                          : 'Stop debugger',
                    ),
                  ),
                  for (final command
                      in service.status == DebugStatus.paused
                          ? ['continue', 'next', 'stepIn', 'stepOut']
                          : service.status == DebugStatus.running
                          ? ['pause']
                          : <String>[])
                    OutlinedButton(
                      onPressed: busy
                          ? null
                          : () => _act(() => widget.onControl(command)),
                      child: Text(command),
                    ),
                  if (widget.project.kind == ProjectKind.flutter &&
                      service.appStarted &&
                      service.configuration?.flutterMode == 'debug')
                    for (final command in ['hotReload', 'hotRestart'])
                      OutlinedButton(
                        onPressed: busy
                            ? null
                            : () => _act(() => widget.onControl(command)),
                        child: Text(
                          command == 'hotReload' ? 'Hot reload' : 'Hot restart',
                        ),
                      ),
                ],
              ),
            for (final entry in service.verifiedBreakpoints.entries)
              Text(
                '${p.basename(entry.key)}: ${entry.value.map((b) => '${b['line'] ?? '?'} ${b['verified'] == true ? 'verified' : 'pending'}').join(', ')}',
              ),
            if (service.frames.isNotEmpty)
              SizedBox(
                height: 160,
                child: ListView(
                  children: [
                    for (final frame in service.frames)
                      ListTile(
                        dense: true,
                        selected: service.frameId == frame['id'],
                        title: Text('${frame['name']} · ${frame['line']}'),
                        onTap: () =>
                            _act(() => service.selectFrame(frame['id'] as int)),
                        trailing:
                            frame['source'] is Map &&
                                (frame['source'] as Map)['path'] is String
                            ? IconButton(
                                icon: const Icon(Icons.open_in_new),
                                tooltip: 'Open stack source',
                                onPressed: () => _act(
                                  () => widget.onSource(
                                    (frame['source'] as Map)['path'] as String,
                                    frame['line'] as int,
                                    frame['column'] as int? ?? 1,
                                  ),
                                ),
                              )
                            : null,
                      ),
                  ],
                ),
              ),
            Wrap(
              spacing: 8,
              children: [
                for (final scope in service.scopes)
                  OutlinedButton(
                    onPressed: busy
                        ? null
                        : () => _act(
                            () => service.loadVariables(
                              scope['variablesReference'] as int,
                            ),
                          ),
                    child: Text('${scope['name']}'),
                  ),
              ],
            ),
            if (service.variables.isNotEmpty)
              SizedBox(
                height: 180,
                child: ListView(
                  children: [
                    for (final variable in service.variables)
                      ListTile(
                        dense: true,
                        title: SelectableText(
                          '${variable['name']} = ${variable['value']}',
                        ),
                        subtitle: Text('${variable['type'] ?? ''}'),
                        trailing:
                            (variable['variablesReference'] as int? ?? 0) > 0
                            ? IconButton(
                                icon: const Icon(Icons.chevron_right),
                                onPressed: () => _act(
                                  () => service.loadVariables(
                                    variable['variablesReference'] as int,
                                  ),
                                ),
                              )
                            : null,
                      ),
                  ],
                ),
              ),
            if (service.status == DebugStatus.paused) ...[
              TextField(
                controller: expression,
                decoration: const InputDecoration(
                  labelText: 'Expression to evaluate',
                  helperText:
                      'Evaluation can execute code in the paused application.',
                ),
              ),
              OutlinedButton(
                onPressed: busy
                    ? null
                    : () => _act(() async {
                        final value = await service.evaluate(expression.text);
                        if (mounted) {
                          setState(() {
                            evaluation = value;
                            evaluationStop = service.stopCount;
                            evaluationFrame = service.frameId;
                          });
                        }
                      }),
                child: const Text('Evaluate expression'),
              ),
              OutlinedButton(
                onPressed: busy
                    ? null
                    : () => _act(() => service.addWatch(expression.text)),
                child: const Text(
                  'Add watch (evaluates after each pause or frame change)',
                ),
              ),
              if (evaluation != null &&
                  evaluationStop == service.stopCount &&
                  evaluationFrame == service.frameId)
                SelectableText(evaluation!),
            ],
            if (service.watches.isNotEmpty) ...[
              const Text('Watches'),
              for (final watch in service.watches)
                ListTile(
                  dense: true,
                  title: SelectableText(watch.expression),
                  subtitle: SelectableText(
                    watch.error ??
                        watch.value ??
                        (service.status == DebugStatus.paused
                            ? 'Evaluating…'
                            : 'Waiting for a paused frame'),
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: 'Remove watch',
                    onPressed: () => service.removeWatch(watch.expression),
                  ),
                ),
            ],
            if (service.output.isNotEmpty)
              ExpansionTile(
                title: const Text('Debug console'),
                children: [
                  SizedBox(
                    height: 220,
                    child: SingleChildScrollView(
                      child: SelectableText(service.output),
                    ),
                  ),
                ],
              ),
          ],
        ],
      );
    },
  );
}
