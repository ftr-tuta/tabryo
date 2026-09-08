import 'dart:convert';

import 'package:flutter/material.dart';

import '../domain/collaboration.dart';
import 'collaboration_view_model.dart';

final class CollaborationScreen extends StatefulWidget {
  const CollaborationScreen({
    required this.model,
    required this.onOpenTerminal,
    this.root,
    super.key,
  });
  final CollaborationViewModel model;
  final String? root;
  final Future<void> Function(Json) onOpenTerminal;
  @override
  State<CollaborationScreen> createState() => _CollaborationScreenState();
}

final class _CollaborationScreenState extends State<CollaborationScreen> {
  CollaborationViewModel get model => widget.model;
  @override
  void initState() {
    super.initState();
    model.open();
  }

  @override
  void dispose() {
    model.hide();
    super.dispose();
  }

  Future<void> _newGroup() async {
    final name = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New collaboration group'),
        content: TextField(
          controller: name,
          autofocus: true,
          maxLength: 120,
          decoration: const InputDecoration(
            labelText: 'Name',
            hintText: 'API + Flutter',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, name.text.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    name.dispose();
    if (value != null && value.isNotEmpty) await model.createGroup(value);
  }

  Future<void> _addParticipant() async {
    final name = TextEditingController();
    final root = TextEditingController(text: widget.root);
    final objective = TextEditingController();
    var writer = false;
    var wake = false;
    final values = await showDialog<Json>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('Connect a Codex participant'),
          content: SizedBox(
            width: 600,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: name,
                    autofocus: true,
                    maxLength: 120,
                    decoration: const InputDecoration(
                      labelText: 'Participant name',
                    ),
                  ),
                  TextField(
                    controller: root,
                    decoration: const InputDecoration(
                      labelText: 'Project folder (absolute path)',
                    ),
                  ),
                  TextField(
                    controller: objective,
                    minLines: 3,
                    maxLines: 7,
                    maxLength: 32000,
                    decoration: const InputDecoration(
                      labelText: 'Authorized objective',
                      hintText:
                          'Describe the work this participant may perform.',
                    ),
                  ),
                  SwitchListTile(
                    title: const Text('Writer for this repository'),
                    subtitle: const Text(
                      'One registered writer per repository. Otherwise this session is read-only.',
                    ),
                    value: writer,
                    onChanged: (v) => update(() => writer = v),
                  ),
                  SwitchListTile(
                    title: const Text('Continue automatically for requests'),
                    subtitle: const Text(
                      'Requests and completed dependencies may resume idle work within this objective. Paused sessions stay paused.',
                    ),
                    value: wake,
                    onChanged: (v) => update(() => wake = v),
                  ),
                  const Text(
                    'Connecting starts the installed Codex and its configured MCP servers with your saved login and permissions. You can open its terminal here or in an external window.',
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
              onPressed: () => Navigator.pop(context, <String, Object?>{
                'name': name.text.trim(),
                'root': root.text.trim(),
                'objective': objective.text.trim(),
                'writer': writer,
                'auto_wake': wake,
              }),
              child: const Text('Connect participant'),
            ),
          ],
        ),
      ),
    );
    name.dispose();
    root.dispose();
    objective.dispose();
    if (values != null) await model.addParticipant(values);
  }

  Future<void> _stop() async {
    final stop = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Stop collaboration service?'),
        content: const Text(
          'This disconnects the managed Codex sessions and their terminals. Messages and checkpoints remain saved. Closing this panel keeps the service running.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep running'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Stop service'),
          ),
        ],
      ),
    );
    if (stop == true) await model.stop();
  }

  Future<void> _detail(Json checkpoint) => model.run(() async {
    final detail = await model.client.call('checkpoint_detail', {
      'group': model.group,
      'id': checkpoint['id'],
    });
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          'Checkpoint ${detail['id']} · version ${detail['version']}',
        ),
        content: SizedBox(
          width: 750,
          child: SingleChildScrollView(
            child: SelectableText(
              const JsonEncoder.withIndent('  ').convert(detail),
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
  });

  Future<void> _approval(Json participant, Json approval) async {
    final method = approval['method'] as String;
    Json? loaded;
    final fetched = await model.run(() async {
      loaded = await model.client.call('approval_detail', {
        'participant': participant['id'],
        'request': approval['id'],
      });
    });
    if (!mounted) return;
    if (!fetched) return;
    final detail = loaded!;
    final params = Map<String, Object?>.from(detail['parameters'] as Map);
    final questions = (params['questions'] as List? ?? []).cast<Map>();
    final answers = {
      for (final question in questions)
        question['id'] as String: TextEditingController(),
    };
    final form = TextEditingController();
    final canApprove =
        {
          'item/commandExecution/requestApproval',
          'item/fileChange/requestApproval',
          'item/permissions/requestApproval',
          'item/tool/requestUserInput',
          'mcpServer/elicitation/request',
        }.contains(method) &&
        detail['review_available'] == true;
    final result = await showDialog<Json>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${participant['name']} needs your response'),
        content: SizedBox(
          width: 750,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Project: ${participant['root']}'),
                SelectableText(detail['review'] as String),
                for (final question in questions)
                  TextField(
                    controller: answers[question['id']],
                    decoration: InputDecoration(
                      labelText:
                          question['question'] as String? ??
                          question['id'] as String,
                    ),
                  ),
                if (method == 'mcpServer/elicitation/request' &&
                    params['mode'] != 'url')
                  TextField(
                    controller: form,
                    minLines: 3,
                    maxLines: 8,
                    decoration: const InputDecoration(
                      labelText:
                          'Response content (JSON matching the displayed form)',
                    ),
                  ),
                if (!canApprove)
                  const Text(
                    'Open this participant in a Codex terminal to answer this request.',
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Later'),
          ),
          if (canApprove && method != 'item/tool/requestUserInput')
            TextButton(
              onPressed: () => Navigator.pop(context, <String, Object?>{
                'decision': 'decline',
              }),
              child: const Text('Decline'),
            ),
          if (canApprove)
            FilledButton(
              onPressed: () {
                Object? content;
                if (method == 'mcpServer/elicitation/request' &&
                    params['mode'] != 'url') {
                  try {
                    content = jsonDecode(form.text);
                  } catch (_) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Enter valid JSON for the displayed form.',
                        ),
                      ),
                    );
                    return;
                  }
                }
                Navigator.pop(context, <String, Object?>{
                  'decision': 'accept',
                  'content': content,
                  if (method == 'item/tool/requestUserInput')
                    'answers': {
                      for (final entry in answers.entries)
                        entry.key: {
                          'answers': [entry.value.text],
                        },
                    },
                });
              },
              child: Text(
                method == 'item/tool/requestUserInput'
                    ? 'Send answers'
                    : 'Approve once',
              ),
            ),
        ],
      ),
    );
    for (final controller in answers.values) {
      controller.dispose();
    }
    form.dispose();
    if (result != null) {
      await model.action('respond', {
        'participant': participant['id'],
        'request': approval['id'],
        'response': result,
      });
    }
  }

  Widget _participant(Json participant) {
    final id = participant['id'];
    final status = (participant['status'] as Map?)?['type'] ?? 'offline';
    final approvals = ((participant['approvals'] as List?) ?? [])
        .map((v) => Map<String, Object?>.from(v as Map))
        .toList();
    final live = status != 'offline' && status != 'disconnected';
    final done = participant['state'] == 'completed';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${participant['name']} · ${participant['writer'] == 1 ? 'writer' : 'read-only'}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            SelectableText('${participant['root']}'),
            Text(
              '${participant['state']} · ${participant['connecting'] == true ? 'connecting' : status} · updated ${participant['updated']}',
            ),
            Text('${participant['objective']}'),
            if (participant['error'] != null)
              Text(
                '${participant['error']}',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (participant['last_message'] != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: SelectableText('${participant['last_message']}'),
              ),
            Wrap(
              spacing: 8,
              children: [
                TextButton(
                  onPressed: model.busy || done
                      ? null
                      : () => model.action('connect', {'id': id}),
                  child: const Text('Connect / resume'),
                ),
                TextButton(
                  onPressed: model.busy || !live || done
                      ? null
                      : () => model.action('pause', {'id': id}),
                  child: const Text('Pause'),
                ),
                TextButton(
                  onPressed: model.busy || !live
                      ? null
                      : () => model.run(() async {
                          final launch = await model.client.call('launch', {
                            'id': id,
                          });
                          await widget.onOpenTerminal(launch);
                        }),
                  child: const Text('Open in Tabryo'),
                ),
                TextButton(
                  onPressed: model.busy || !live
                      ? null
                      : () => model.action('external_terminal', {'id': id}),
                  child: const Text('External terminal'),
                ),
                TextButton(
                  onPressed: model.busy || done
                      ? null
                      : () => model.action('disconnect', {'id': id}),
                  child: const Text('Disconnect'),
                ),
                TextButton(
                  onPressed: model.busy || done
                      ? null
                      : () => model.action('complete', {'id': id}),
                  child: const Text('Complete'),
                ),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Continue automatically for requests'),
              value: participant['auto_wake'] == 1,
              onChanged: model.busy || done
                  ? null
                  : (v) => model.action('auto_wake', {'id': id, 'enabled': v}),
            ),
            for (final approval in approvals)
              FilledButton.tonal(
                onPressed: model.busy
                    ? null
                    : () => _approval(participant, approval),
                child: Text('Respond · ${approval['method']}'),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model,
    builder: (context, _) => DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Collaboration'),
          actions: [
            if (model.connected)
              TextButton(
                onPressed: model.busy ? null : _stop,
                child: const Text('Stop service'),
              ),
            IconButton(
              tooltip: 'Close panel (keep service running)',
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close),
            ),
          ],
        ),
        body: Column(
          children: [
            if (model.busy) const LinearProgressIndicator(),
            if (model.message != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: SelectableText(model.message!),
              ),
            if (!model.connected)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    const Text(
                      'Connect Codex sessions across projects. The local service keeps working when Tabryo closes.',
                    ),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: model.busy
                          ? null
                          : () => model.open(start: true),
                      child: const Text('Start / reconnect service'),
                    ),
                  ],
                ),
              ),
            if (model.connected) ...[
              Padding(
                padding: const EdgeInsets.all(12),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    DropdownButton<String>(
                      value: model.group,
                      hint: const Text('Select a group'),
                      items: [
                        for (final g in model.groups)
                          DropdownMenuItem(
                            value: g['id'] as String,
                            child: Text(g['name'] as String),
                          ),
                      ],
                      onChanged: model.busy ? null : model.select,
                    ),
                    OutlinedButton(
                      onPressed: model.busy ? null : _newGroup,
                      child: const Text('New group'),
                    ),
                    FilledButton.tonal(
                      onPressed: model.busy || model.group == null
                          ? null
                          : _addParticipant,
                      child: const Text('Add participant'),
                    ),
                    IconButton(
                      tooltip: 'Refresh',
                      onPressed: model.busy ? null : model.refresh,
                      icon: const Icon(Icons.refresh),
                    ),
                  ],
                ),
              ),
              const TabBar(
                tabs: [
                  Tab(text: 'Participants'),
                  Tab(text: 'Messages'),
                  Tab(text: 'Checkpoints'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    model.participants.isEmpty
                        ? const Center(
                            child: Text(
                              'Create a group and connect participants to begin.',
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.all(16),
                            itemCount: model.participants.length,
                            itemBuilder: (_, index) =>
                                _participant(model.participants[index]),
                          ),
                    ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        const Text(
                          'Stored → forwarded → confirmed. Uncertain delivery waits for reconciliation or recipient acknowledgement.',
                        ),
                        for (final message in model.messages)
                          Card(
                            child: ListTile(
                              title: Text(
                                '${model.participantName(message['sender'])} → ${model.participantName(message['recipient'])} · ${message['kind']}',
                              ),
                              subtitle: SelectableText(
                                '#${message['id']} · ${message['status']} · ${message['updated']}\n${message['summary']}',
                              ),
                              trailing: message['checkpoint_id'] == null
                                  ? null
                                  : IconButton(
                                      tooltip: 'Read checkpoint',
                                      onPressed: model.busy
                                          ? null
                                          : () => _detail({
                                              'id': message['checkpoint_id'],
                                            }),
                                      icon: const Icon(Icons.bookmark_outline),
                                    ),
                            ),
                          ),
                        Wrap(
                          children: [
                            TextButton(
                              onPressed: () {
                                model.after = 0;
                                model.refresh();
                              },
                              child: const Text('Beginning'),
                            ),
                            TextButton(
                              onPressed: model.messages.length < 100
                                  ? null
                                  : () {
                                      model.after =
                                          model.messages.last['id'] as int;
                                      model.refresh();
                                    },
                              child: const Text('Next messages'),
                            ),
                          ],
                        ),
                      ],
                    ),
                    ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        for (final checkpoint in model.checkpoints)
                          Card(
                            child: ListTile(
                              title: Text(
                                '${model.participantName(checkpoint['author'])} · version ${checkpoint['version']}',
                              ),
                              subtitle: Text(
                                '${checkpoint['summary']}\n${checkpoint['state']} · ${checkpoint['local_changes'] == 1
                                    ? 'Local changes'
                                    : checkpoint['local_changes'] == 0
                                    ? 'Committed state'
                                    : 'Git state unavailable'}\n${checkpoint['created']}',
                              ),
                              onTap: model.busy
                                  ? null
                                  : () => _detail(checkpoint),
                            ),
                          ),
                        Wrap(
                          children: [
                            TextButton(
                              onPressed: () {
                                model.checkpointAfter = 0;
                                model.refresh();
                              },
                              child: const Text('Beginning'),
                            ),
                            TextButton(
                              onPressed: model.checkpoints.length < 100
                                  ? null
                                  : () {
                                      model.checkpointAfter =
                                          model.checkpoints.last['id'] as int;
                                      model.refresh();
                                    },
                              child: const Text('Next checkpoints'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}
