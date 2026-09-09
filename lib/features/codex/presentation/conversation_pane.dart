import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../application/conversation_service.dart';
import '../domain/codex_connection.dart';

final class ConversationPane extends StatefulWidget {
  const ConversationPane({
    required this.service,
    required this.workspace,
    required this.copy,
    required this.openLink,
    required this.captureContext,
    required this.saveDrafts,
    this.visible = true,
    super.key,
  });
  final ConversationService service;
  final String? workspace;
  final Future<void> Function(String) copy;
  final Future<void> Function(String) openLink;
  final Future<String?> Function() captureContext;
  final VoidCallback saveDrafts;
  final bool visible;
  @override
  State<ConversationPane> createState() => _ConversationPaneState();
}

final class _ConversationPaneState extends State<ConversationPane> {
  ConversationService get service => widget.service;
  final _composer = TextEditingController();
  final _composerFocus = FocusNode();
  final _scroll = ScrollController();
  StreamSubscription<void>? _subscription;
  String _search = '';
  String? _shown, _context, _model, _effort;
  bool _newMessages = false, _listing = true;
  Timer? _searchTimer;
  final _positions = <String, double>{};
  final _contexts = <String, String>{};
  final _workspaceSelections = <String, String>{};

  @override
  void initState() {
    super.initState();
    _subscription = service.changes.listen((_) => _changed());
  }

  void _changed() {
    if (!mounted) return;
    if (!widget.visible) return;
    final follow = !_scroll.hasClients || _scroll.position.extentAfter < 64;
    final selected = service.selected;
    if (_shown != selected?.id) {
      if (_shown != null) {
        if (_context case final text?) {
          _contexts[_shown!] = text;
        } else {
          _contexts.remove(_shown);
        }
      }
      _contexts.removeWhere((id, _) => !service.conversations.containsKey(id));
      _positions.removeWhere((id, _) => !service.conversations.containsKey(id));
      if (_shown != null && _scroll.hasClients) {
        _positions[_shown!] = _scroll.offset;
      }
      _shown = selected?.id;
      _composer.text = selected?.draft ?? '';
      _context = _contexts[_shown];
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) {
          _scroll.jumpTo(
            (_positions[_shown] ?? _scroll.position.maxScrollExtent).clamp(
              0,
              _scroll.position.maxScrollExtent,
            ),
          );
        }
      });
    } else if (_composer.text != selected?.draft &&
        selected?.draft.isEmpty == true &&
        selected?.sending != true) {
      _composer.clear();
    }
    setState(() => _newMessages = !follow);
    if (follow) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
  }

  @override
  void didUpdateWidget(ConversationPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.workspace != oldWidget.workspace) {
      if (oldWidget.workspace != null && service.selectedId != null) {
        _workspaceSelections[oldWidget.workspace!] = service.selectedId!;
      }
      service.selectedId = _workspaceSelections[widget.workspace];
      _listing = true;
      _search = '';
      _changed();
    }
    if (widget.visible && !oldWidget.visible) {
      _changed();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.visible && service.selected?.controlled == true) {
          _composerFocus.requestFocus();
        }
      });
    }
  }

  Future<void> _action(Future<void> Function() run) async {
    try {
      await run();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }

  @override
  void dispose() {
    _searchTimer?.cancel();
    unawaited(_subscription?.cancel());
    _composer.dispose();
    _composerFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Widget _list() {
    final rows =
        service.conversations.values
            .where(
              (c) =>
                  c.workspace == widget.workspace &&
                  c.title.toLowerCase().contains(_search.toLowerCase()),
            )
            .toList()
          ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return Column(
      children: [
        if (widget.workspace != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Text(
              widget.workspace!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: TextField(
            decoration: const InputDecoration(
              hintText: 'Search conversations',
              prefixIcon: Icon(Icons.search),
            ),
            onChanged: (text) {
              setState(() => _search = text);
              _searchTimer?.cancel();
              _searchTimer = Timer(const Duration(milliseconds: 350), () {
                if (widget.workspace != null) {
                  service.list(widget.workspace!, search: text);
                }
              });
            },
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: rows.length,
            itemBuilder: (_, index) {
              final row = rows[index];
              return ListTile(
                key: ValueKey(row.id),
                selected: row.id == service.selectedId,
                leading: Icon(
                  row.requests.isNotEmpty
                      ? Icons.pending_actions
                      : row.active
                      ? Icons.autorenew
                      : Icons.chat_bubble_outline,
                ),
                title: Text(
                  row.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${row.status}${row.controlled ? '' : ' · history'}',
                ),
                onTap: () {
                  service.select(row.id);
                  if (MediaQuery.sizeOf(context).width < 1100) {
                    setState(() => _listing = false);
                  }
                },
              );
            },
          ),
        ),
        if (widget.workspace != null &&
            service.hasMore(widget.workspace!, _search))
          TextButton(
            onPressed: service.loading
                ? null
                : () => service.list(
                    widget.workspace!,
                    search: _search,
                    more: true,
                  ),
            child: const Text('Load more conversations'),
          ),
      ],
    );
  }

  Widget _message(ConversationJson item) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Expanded(
            child: Text(
              item['type'] == 'userMessage' ? 'You' : 'Codex',
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ),
          IconButton(
            tooltip: 'Copy message or code',
            onPressed: () => widget.copy(itemText(item)),
            icon: const Icon(Icons.copy, size: 16),
          ),
        ],
      ),
      MarkdownBody(
        data: itemText(item),
        selectable: true,
        onTapLink: (_, href, _) {
          if (href != null) _action(() => widget.openLink(href));
        },
        imageBuilder: (_, _, _) =>
            const Text('[Image · open in the originating CLI]'),
      ),
    ],
  );

  Widget _turn(Conversation conversation, String id) {
    final items = conversation.items.values
        .where((item) => item['turnId'] == id)
        .toList();
    final work = items
        .where((i) => !['userMessage', 'agentMessage'].contains(i['type']))
        .toList();
    final failed =
        conversation.turns[id]?['status'] == 'failed' ||
        work.any((i) => i['status'] == 'failed');
    return Padding(
      key: ValueKey(id),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final item in items.where((i) => i['type'] == 'userMessage'))
            _message(item),
          if (work.isNotEmpty)
            ExpansionTile(
              key: PageStorageKey('work:$id'),
              title: Text(
                'Work performed · ${work.length}${failed ? ' · error' : ''}',
              ),
              leading: Icon(
                failed ? Icons.error_outline : Icons.checklist,
                color: failed ? Theme.of(context).colorScheme.error : null,
              ),
              children: [
                for (final item in work)
                  ExpansionTile(
                    key: PageStorageKey('item:${item['id']}'),
                    title: Text(
                      '${item['command'] ?? item['tool'] ?? item['type']}',
                    ),
                    subtitle: Text(
                      '${item['status'] ?? (item['complete'] == true ? 'completed' : 'running')}',
                    ),
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: SelectableText(
                          itemText(item),
                          style: const TextStyle(fontFamily: 'monospace'),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          for (final item in items.where((i) => i['type'] == 'agentMessage'))
            _message(item),
          if (conversation.turns[id]?['status'] == 'interrupted')
            const Text('Turn interrupted'),
          if (failed)
            Text(
              'This turn needs attention.',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    );
  }

  Widget _chat() {
    final conversation = service.selected;
    if (conversation == null || conversation.workspace != widget.workspace) {
      return const Center(
        child: Text('Select a conversation or start a new one.'),
      );
    }
    final turnIds = conversation.turns.keys.toList();
    return Column(
      children: [
        ListTile(
          title: Text(
            conversation.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            '${conversation.configuration['model'] ?? 'CLI model'} · ${conversation.status}',
          ),
          trailing: IconButton(
            tooltip: 'Refresh or resume conversation',
            onPressed: () => service.select(conversation.id),
            icon: const Icon(Icons.refresh),
          ),
        ),
        if (!conversation.controlled)
          const Padding(
            padding: EdgeInsets.all(8),
            child: Text(
              'History only. Execution remains with the session owner.',
            ),
          ),
        if (conversation.historyTruncated)
          const Text(
            'Showing the latest bounded history. Full history remains in the CLI.',
          ),
        Expanded(
          child: ListView.builder(
            controller: _scroll,
            itemCount: turnIds.length,
            itemBuilder: (_, i) => _turn(conversation, turnIds[i]),
          ),
        ),
        if (_newMessages)
          TextButton(
            onPressed: () {
              if (_scroll.hasClients) {
                _scroll.jumpTo(_scroll.position.maxScrollExtent);
              }
              setState(() => _newMessages = false);
            },
            child: const Text('New messages ↓'),
          ),
        if (conversation.requests.isNotEmpty)
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * .32,
            ),
            child: SingleChildScrollView(
              child: Column(
                children: [
                  for (final request in conversation.requests.values)
                    _Interaction(
                      key: ValueKey('${conversation.id}:${request.id}'),
                      request: request,
                      respond: (result) => _action(
                        () async =>
                            service.respond(conversation.id, request, result),
                      ),
                    ),
                ],
              ),
            ),
          ),
        if (conversation.uncertainId != null && !conversation.sending)
          Card(
            child: ListTile(
              leading: const Icon(Icons.sync_problem),
              title: const Text('Send outcome uncertain'),
              subtitle: const Text(
                'Refresh or reconnect to reconcile with CLI history before sending again.',
              ),
              trailing: IconButton(
                onPressed: () => service.select(conversation.id),
                icon: const Icon(Icons.refresh),
              ),
            ),
          ),
        if (_context != null)
          InputChip(
            label: Text('Attached context · ${_context!.length} characters'),
            onDeleted: () => setState(() => _context = null),
          ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              TextField(
                controller: _composer,
                focusNode: _composerFocus,
                minLines: 2,
                maxLines: 7,
                maxLength: 16384,
                enabled: conversation.controlled && service.connected,
                decoration: InputDecoration(
                  hintText: conversation.active
                      ? 'Direct the active work…'
                      : 'Message Codex…',
                  border: const OutlineInputBorder(),
                ),
                onChanged: (text) {
                  service.draft(conversation.id, text);
                  widget.saveDrafts();
                },
              ),
              Wrap(
                spacing: 8,
                children: [
                  TextButton.icon(
                    onPressed: conversation.controlled
                        ? () async {
                            final captured = await widget.captureContext();
                            if (captured == null || !mounted) return;
                            final accepted = await showDialog<bool>(
                              context: context,
                              builder: (context) => AlertDialog(
                                title: const Text('Attach this context?'),
                                content: SizedBox(
                                  width: 620,
                                  child: SingleChildScrollView(
                                    child: SelectableText(captured),
                                  ),
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.pop(context, false),
                                    child: const Text('Cancel'),
                                  ),
                                  FilledButton(
                                    onPressed: () =>
                                        Navigator.pop(context, true),
                                    child: const Text('Attach'),
                                  ),
                                ],
                              ),
                            );
                            if (accepted == true &&
                                mounted &&
                                service.selectedId == conversation.id) {
                              setState(() => _context = captured);
                            }
                          }
                        : null,
                    icon: const Icon(Icons.attach_file),
                    label: const Text('Attach file, excerpt or diff'),
                  ),
                  if (conversation.active)
                    OutlinedButton(
                      onPressed: conversation.controlled
                          ? () => _action(
                              () => service.interrupt(conversation.id),
                            )
                          : null,
                      child: const Text('Interrupt'),
                    ),
                  FilledButton(
                    onPressed:
                        !conversation.controlled ||
                            conversation.sending ||
                            conversation.uncertainId != null
                        ? null
                        : () => _action(() async {
                            final text = _composer.text;
                            final contextText = _context;
                            await service.send(
                              conversation.id,
                              contextText == null
                                  ? text
                                  : '$text\n\n<context>\n$contextText\n</context>',
                            );
                            if (conversation.uncertainId == null &&
                                service.error == null) {
                              service.draft(conversation.id, '');
                              _composer.clear();
                              if (mounted) setState(() => _context = null);
                              widget.saveDrafts();
                            }
                          }),
                    child: Text(conversation.active ? 'Steer' : 'Send'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Wrap(
        spacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          IconButton(
            tooltip: 'Conversations',
            onPressed: () => setState(() => _listing = !_listing),
            icon: const Icon(Icons.forum_outlined),
          ),
          TextButton.icon(
            onPressed: widget.workspace == null || service.loading
                ? null
                : () => service.list(widget.workspace!, search: _search),
            icon: const Icon(Icons.refresh),
            label: Text(service.connected ? 'Refresh history' : 'Connect CLI'),
          ),
          DropdownButton<String>(
            hint: const Text('CLI default model'),
            value: _model,
            items: [
              const DropdownMenuItem<String>(
                value: null,
                child: Text('CLI default model'),
              ),
              for (final model in service.models)
                DropdownMenuItem(
                  value: model['model'] as String,
                  child: Text('${model['displayName'] ?? model['model']}'),
                ),
            ],
            onChanged: (value) => setState(() {
              _model = value;
              _effort = null;
            }),
          ),
          if (_model != null)
            DropdownButton<String>(
              hint: const Text('CLI effort'),
              value: _effort,
              items: [
                for (final entry
                    in (service.models
                                    .where((m) => m['model'] == _model)
                                    .firstOrNull?['supportedReasoningEfforts']
                                as List? ??
                            [])
                        .whereType<Map>())
                  DropdownMenuItem(
                    value: entry['reasoningEffort'] as String,
                    child: Text('${entry['reasoningEffort']}'),
                  ),
              ],
              onChanged: (value) => setState(() => _effort = value),
            ),
          FilledButton.icon(
            onPressed: widget.workspace == null
                ? null
                : () => _action(() async {
                    await service.create(
                      widget.workspace!,
                      model: _model,
                      effort: _effort,
                    );
                  }),
            icon: const Icon(Icons.add),
            label: const Text('New conversation'),
          ),
        ],
      ),
      if (service.loading) const LinearProgressIndicator(),
      ExpansionTile(
        title: const Text('CLI account, permissions and limits'),
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 180),
            child: SingleChildScrollView(
              child: SelectableText(
                const JsonEncoder.withIndent('  ').convert({
                  'account': service.account,
                  'limits': service.limits,
                  'configuration': service.selected?.configuration,
                }),
              ),
            ),
          ),
        ],
      ),
      if (service.error != null)
        Padding(
          padding: const EdgeInsets.all(8),
          child: Text(
            service.error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      Expanded(
        child: LayoutBuilder(
          builder: (context, constraints) => Row(
            children: [
              if (_listing)
                SizedBox(
                  width: constraints.maxWidth < 700
                      ? constraints.maxWidth
                      : 260,
                  child: _list(),
                ),
              if (!_listing || constraints.maxWidth >= 700)
                Expanded(child: _chat()),
            ],
          ),
        ),
      ),
    ],
  );
}

final class _Interaction extends StatefulWidget {
  const _Interaction({required this.request, required this.respond, super.key});
  final CodexServerRequest request;
  final ValueChanged<ConversationJson> respond;
  @override
  State<_Interaction> createState() => _InteractionState();
}

final class _InteractionState extends State<_Interaction> {
  final answers = <String, String>{};
  @override
  Widget build(BuildContext context) {
    final request = widget.request;
    final questions = (request.parameters['questions'] as List? ?? [])
        .whereType<Map>()
        .toList();
    final approval = [
      'item/commandExecution/requestApproval',
      'item/fileChange/requestApproval',
    ].contains(request.method);
    return Card(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              approval ? 'Approval required' : 'Input required',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (approval) ...[
              SelectableText(
                '${request.parameters['reason'] ?? ''}\n${request.parameters['command'] ?? request.parameters['grantRoot'] ?? 'Review the file changes in Work performed.'}\n${request.parameters['cwd'] ?? ''}',
              ),
              Wrap(
                spacing: 8,
                children: [
                  FilledButton(
                    onPressed: () => widget.respond({'decision': 'accept'}),
                    child: const Text('Allow once'),
                  ),
                  OutlinedButton(
                    onPressed: () => widget.respond({'decision': 'decline'}),
                    child: const Text('Decline'),
                  ),
                  TextButton(
                    onPressed: () => widget.respond({'decision': 'cancel'}),
                    child: const Text('Cancel turn'),
                  ),
                ],
              ),
            ] else if (request.method ==
                'item/permissions/requestApproval') ...[
              SelectableText(
                '${request.parameters['reason'] ?? ''}\n${const JsonEncoder.withIndent('  ').convert(request.parameters['permissions'])}',
              ),
              Wrap(
                spacing: 8,
                children: [
                  FilledButton(
                    onPressed: () => widget.respond({
                      'permissions': request.parameters['permissions'],
                      'scope': 'turn',
                    }),
                    child: const Text('Allow for this turn'),
                  ),
                  OutlinedButton(
                    onPressed: () =>
                        widget.respond({'permissions': {}, 'scope': 'turn'}),
                    child: const Text('Decline'),
                  ),
                ],
              ),
            ] else if (request.method == 'mcpServer/elicitation/request') ...[
              Text(
                '${request.parameters['serverName']}: ${request.parameters['message']}',
              ),
              if (request.parameters['url'] != null)
                SelectableText('${request.parameters['url']}'),
              if (request.parameters['requestedSchema'] != null) ...[
                ExpansionTile(
                  title: const Text('Requested fields'),
                  children: [
                    SelectableText(
                      const JsonEncoder.withIndent('  ')
                          .convert(request.parameters['requestedSchema']),
                    ),
                  ],
                ),
                TextField(
                  minLines: 2,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    labelText: 'Structured response (JSON)',
                  ),
                  onChanged: (value) =>
                      setState(() => answers['content'] = value),
                ),
              ],
              Wrap(
                spacing: 8,
                children: [
                  FilledButton(
                    onPressed: () {
                      try {
                        final content =
                            request.parameters['requestedSchema'] == null
                            ? null
                            : jsonDecode(answers['content'] ?? '');
                        if (request.parameters['requestedSchema'] != null &&
                            content is! Map) {
                          throw const FormatException();
                        }
                        widget.respond({
                          'action': 'accept',
                          'content': content,
                        });
                      } on FormatException {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Enter a JSON object for the requested fields.',
                            ),
                          ),
                        );
                      }
                    },
                    child: Text(
                      request.parameters['url'] == null
                          ? 'Submit response'
                          : 'I completed this step',
                    ),
                  ),
                  OutlinedButton(
                    onPressed: () => widget.respond({'action': 'decline'}),
                    child: const Text('Decline'),
                  ),
                  TextButton(
                    onPressed: () => widget.respond({'action': 'cancel'}),
                    child: const Text('Cancel'),
                  ),
                ],
              ),
            ] else if (request.method == 'item/tool/requestUserInput') ...[
              for (final question in questions)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${question['question']}'),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final option
                            in (question['options'] as List? ?? [])
                                .whereType<Map>())
                          ChoiceChip(
                            label: Text('${option['label']}'),
                            tooltip: '${option['description'] ?? ''}',
                            selected:
                                answers[question['id']] == option['label'],
                            onSelected: (_) => setState(
                              () => answers[question['id'] as String] =
                                  option['label'] as String,
                            ),
                          ),
                      ],
                    ),
                    TextField(
                      obscureText: question['isSecret'] == true,
                      decoration: const InputDecoration(
                        hintText: 'Your answer',
                      ),
                      onChanged: (text) => setState(
                        () => answers[question['id'] as String] = text,
                      ),
                    ),
                  ],
                ),
              FilledButton(
                onPressed:
                    questions.any(
                      (q) => (answers[q['id']] ?? '').trim().isEmpty,
                    )
                    ? null
                    : () => widget.respond({
                        'answers': {
                          for (final question in questions)
                            question['id'] as String: {
                              'answers': [answers[question['id']]],
                            },
                        },
                      }),
                child: const Text('Submit answers'),
              ),
            ] else
              Text(
                'The CLI requested ${request.method}. This interaction needs its supported client.',
              ),
          ],
        ),
      ),
    );
  }
}
