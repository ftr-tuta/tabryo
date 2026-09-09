import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../domain/codex_connection.dart';

typedef ConversationJson = Map<String, Object?>;

final class Conversation {
  Conversation(this.id, this.workspace, this.title);
  final String id, workspace;
  String title;
  int updatedAt = 0;
  String status = 'idle';
  String? activeTurn;
  final turns = <String, ConversationJson>{};
  final items = <String, ConversationJson>{};
  final _itemSizes = <String, int>{};
  int _retainedCharacters = 0;
  final requests = <Object, CodexServerRequest>{};
  String draft = '';
  String? uncertainMessage;
  String? uncertainId;
  Set<String> beforeSend = {};
  bool controlled = false, sending = false, historyTruncated = false;
  bool originatedHere = false;
  bool get resumable =>
      originatedHere && !controlled && !active && status != 'active';
  ConversationJson configuration = {};
  bool get active => activeTurn != null;
}

/// The CLI owns history, execution and permissions. This service owns only its
/// attached conversations and never forwards collaboration envelopes.
final class ConversationService {
  ConversationService(this.connection) {
    _events = connection.events.listen(_event);
    _requests = connection.requests.listen((request) {
      final thread = conversations[request.parameters['threadId']];
      if (thread == null ||
          (!thread.controlled && !_resuming.containsKey(thread.id))) {
        return;
      }
      thread.requests[request.id] = request;
      _notify();
    });
  }
  final InteractiveCodexConnection connection;
  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;
  late final StreamSubscription<CodexEvent> _events;
  late final StreamSubscription<CodexServerRequest> _requests;
  final conversations = <String, Conversation>{};
  final _owned = <String>{};
  final _resuming = <String, Set<String>>{};
  Future<void>? _connecting;
  final _cursors = <String, String?>{};
  final _cursorHistory = <String, Set<String>>{};
  final models = <ConversationJson>[];
  ConversationJson account = {}, limits = {};
  String? selectedId, error;
  String? _workspace;
  int _generation = 0;
  bool loading = false, _closed = false;
  Conversation? get selected => conversations[selectedId];
  bool get connected => connection.connected;
  void _notify() {
    if (!_closed) _changes.add(null);
  }

  Future<void> connect(String workspace) =>
      _connecting ??= _connect(workspace)
          .whenComplete(() => _connecting = null);

  Future<void> _connect(String workspace) async {
    if (connected) return;
    await connection.connect(workspace);
    _workspace = workspace;
    error = null;
    for (final pair in [
      'account/read',
      'account/rateLimits/read',
      'model/list',
    ]) {
      try {
        final value = await connection.request(
          pair,
          pair == 'model/list' ? {'limit': 100} : {},
        );
        if (pair == 'account/read') account = value;
        if (pair == 'account/rateLimits/read') limits = value;
        if (pair == 'model/list') {
          models
            ..clear()
            ..addAll(
              (value['data'] as List? ?? []).whereType<Map>().map(
                (v) => Map<String, Object?>.from(v),
              ),
            );
        }
      } on CodexFailure {
        /* Older providers may omit account metadata. */
      }
    }
    // Reconnect only sessions this client already controlled. A history listing
    // does not transfer ownership from another App Server or collaboration.
    for (final id in _owned.toList()) {
      final conversation = conversations[id];
      if (conversation != null) await _resume(conversation);
    }
    _notify();
  }

  Future<void> list(
    String workspace, {
    String search = '',
    bool more = false,
  }) async {
    final generation = ++_generation;
    loading = true;
    error = null;
    _notify();
    final key = '$workspace\x00$search';
    try {
      await connect(workspace);
      if (more && !_cursors.containsKey(key)) return;
      final cursor = more ? _cursors[key] : null;
      if (more && cursor == null) return;
      final response = await connection.request('thread/list', {
        'cwd': workspace,
        'limit': 50,
        'sortKey': 'updated_at',
        'sourceKinds': [],
        if (search.isNotEmpty) 'searchTerm': search,
        'cursor': ?cursor,
      });
      if (generation != _generation || _closed) return;
      if (!more) _cursorHistory[key] = {};
      for (final raw in (response['data'] as List? ?? []).whereType<Map>()) {
        _summary(Map<String, Object?>.from(raw));
      }
      final next = response['nextCursor'] as String?;
      if (next != null &&
          !_cursorHistory.putIfAbsent(key, () => {}).add(next)) {
        throw const CodexFailure(
          'The history cursor repeated. Refresh the list.',
        );
      }
      _cursors[key] = next;
      _evict();
    } catch (failure) {
      error = '$failure';
    } finally {
      if (generation == _generation) {
        loading = false;
        _notify();
      }
    }
  }

  bool hasMore(String workspace, String search) =>
      _cursors['$workspace\x00$search'] != null;

  Conversation _summary(ConversationJson row) {
    final id = row['id'] as String;
    final title = (row['name'] ?? row['preview'] ?? 'New conversation')
        .toString();
    final conversation = conversations.putIfAbsent(
      id,
      () => Conversation(id, row['cwd'] as String? ?? _workspace ?? '', title),
    );
    conversation.title = title.isEmpty ? 'New conversation' : title;
    conversation.originatedHere = row['threadSource'] == 'tabryo_chat';
    if (row['updatedAt'] case final num updated) {
      conversation.updatedAt = updated.toInt();
    }
    final status = row['status'];
    if (status is Map && status['type'] is String) {
      conversation.status = status['type'] as String;
    }
    return conversation;
  }

  void _history(Conversation conversation, ConversationJson row) {
    conversation.turns.clear();
    conversation.items.clear();
    conversation._itemSizes.clear();
    conversation._retainedCharacters = 0;
    conversation.activeTurn = null;
    final turns = (row['turns'] as List? ?? []).whereType<Map>().toList();
    conversation.historyTruncated = turns.length > 200;
    for (final raw in turns.skip(turns.length > 200 ? turns.length - 200 : 0)) {
      final turn = Map<String, Object?>.from(raw);
      final turnId = turn['id'] as String;
      conversation.turns[turnId] = {...turn}..remove('items');
      if (turn['status'] == 'inProgress') conversation.activeTurn = turnId;
      for (final item in (turn['items'] as List? ?? []).whereType<Map>()) {
        _item(
          conversation,
          turnId,
          Map<String, Object?>.from(item),
          complete: turn['status'] != 'inProgress',
        );
      }
    }
    _reconcile(conversation);
    _evict();
  }

  Future<Conversation> create(
    String workspace, {
    String? model,
    String? effort,
  }) async {
    if (_owned.length >= 64) {
      throw const CodexFailure(
        'This window already controls 64 conversations. Open existing history or restart Tabryo to release inactive attachments.',
      );
    }
    await connect(workspace);
    final response = await connection.request('thread/start', {
      'cwd': workspace,
      'model': ?model,
      if (effort != null) 'config': {'model_reasoning_effort': effort},
      'serviceName': 'tabryo_chat',
      'threadSource': 'tabryo_chat',
    });
    final conversation = _summary(
      Map<String, Object?>.from(response['thread'] as Map),
    );
    _owned.add(conversation.id);
    conversation.controlled = true;
    conversation.configuration = {...response}..remove('thread');
    selectedId = conversation.id;
    _notify();
    return conversation;
  }

  Future<void> select(String id) async {
    selectedId = id;
    error = null;
    _notify();
    final conversation = conversations[id]!;
    try {
      await connect(conversation.workspace);
      if (_owned.contains(id)) {
        await _resume(conversation);
      } else {
        final response = await connection.request('thread/read', {
          'threadId': id,
          'includeTurns': true,
        });
        _summary(Map<String, Object?>.from(response['thread'] as Map));
        _history(
          conversation,
          Map<String, Object?>.from(response['thread'] as Map),
        );
      }
    } catch (failure) {
      error = '$failure';
    }
    _notify();
  }

  /// An explicit gesture can resume an idle conversation identified by the CLI
  /// as this client's creation. Generic/external and collaboration history never
  /// gains control from being listed or selected.
  Future<void> resumeCreatedConversation(String id) async {
    final conversation = conversations[id]!;
    if (!conversation.resumable) {
      throw const CodexFailure(
        'This conversation remains with its session owner.',
      );
    }
    await connect(conversation.workspace);
    if (_owned.length >= 64 && !_owned.contains(id)) {
      throw const CodexFailure(
        'This client already controls 64 conversations. Restart Tabryo before resuming another.',
      );
    }
    final response = await connection.request('thread/read', {
      'threadId': id,
      // CLI 0.147's metadata-only response omits the persisted threadSource.
      // Read the canonical history before confirming this client's origin.
      'includeTurns': true,
    });
    _summary(Map<String, Object?>.from(response['thread'] as Map));
    if (!conversation.resumable) {
      throw const CodexFailure('This conversation cannot be resumed here.');
    }
    _owned.add(id);
    try {
      await _resume(conversation);
    } catch (_) {
      _owned.remove(id);
      rethrow;
    } finally {
      _notify();
    }
  }

  Future<void> _resume(Conversation conversation) async {
    if (_resuming.containsKey(conversation.id)) return;
    final touched = _resuming[conversation.id] = {};
    try {
      final response = await connection.request('thread/resume', {
        'threadId': conversation.id,
      });
      final liveItems = {
        for (final entry in conversation.items.entries)
          if (touched.contains(entry.key))
            entry.key: Map<String, Object?>.from(entry.value),
      };
      final liveTurns = {
        for (final entry in conversation.turns.entries)
          if (touched.contains('turn:${entry.key}'))
            entry.key: Map<String, Object?>.from(entry.value),
      };
      conversation.controlled = true;
      conversation.configuration = {...response}..remove('thread');
      _history(
        conversation,
        Map<String, Object?>.from(response['thread'] as Map),
      );
      // Events may precede the resume reply. Merge their canonical IDs and the
      // longest common-prefix content, rather than appending deltas twice.
      for (final entry in liveItems.entries) {
        final snapshot = conversation.items[entry.key];
        final live = entry.value;
        if (snapshot?['complete'] == true) continue;
        final merged = {...?snapshot, ...live};
        for (final field in ['text', 'aggregatedOutput']) {
          final saved = snapshot?[field], current = live[field];
          if (saved is String &&
              current is String &&
              saved.startsWith(current)) {
            merged[field] = saved;
          }
        }
        conversation.items[entry.key] = merged;
        _limitItems(conversation, entry.key);
      }
      conversation.turns.addAll(liveTurns);
      conversation.activeTurn =
          conversation.turns.values
                  .where((turn) => turn['status'] == 'inProgress')
                  .lastOrNull?['id']
              as String?;
      _reconcile(conversation);
    } catch (_) {
      if (!conversation.controlled) conversation.requests.clear();
      rethrow;
    } finally {
      _resuming.remove(conversation.id);
    }
  }

  void draft(String id, String text) {
    if (text.length > 16384) throw const CodexFailure('Draft exceeds 16 KiB.');
    conversations[id]?.draft = text;
  }

  Future<void> send(String id, String text) async {
    final conversation = conversations[id]!;
    if (!conversation.controlled ||
        !connected ||
        conversation.sending ||
        conversation.uncertainId != null) {
      throw const CodexFailure(
        'Reconnect and reconcile the pending send before sending.',
      );
    }
    if (text.trim().isEmpty || text.length > 32768) {
      throw const CodexFailure('Enter a message within 32 KiB.');
    }
    final bytes = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final messageId =
        '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
    conversation
      ..sending = true
      ..uncertainId = messageId
      ..uncertainMessage = text
      ..beforeSend = conversation.items.keys.toSet();
    _notify();
    try {
      final active = conversation.activeTurn;
      final response = await connection.request(
        active == null ? 'turn/start' : 'turn/steer',
        {
          'threadId': id,
          'clientUserMessageId': messageId,
          'expectedTurnId': ?active,
          'input': [
            {'type': 'text', 'text': text, 'text_elements': []},
          ],
        },
      );
      if (response['turn'] case final Map turn) {
        final turnId = turn['id'] as String;
        conversation.turns.putIfAbsent(
          turnId,
          () => Map<String, Object?>.from(turn)..remove('items'),
        );
        if (![
          'completed',
          'failed',
          'interrupted',
        ].contains(conversation.turns[turnId]?['status'])) {
          conversation.activeTurn = turnId;
        }
      }
      conversation.uncertainId = null;
      conversation.uncertainMessage = null;
      if (conversation.draft == text) conversation.draft = '';
    } on CodexFailure catch (failure) {
      if (failure.code != null) {
        conversation.uncertainId = null;
        conversation.uncertainMessage = null;
      }
      error = failure.code == null
          ? 'Send outcome is uncertain. Reconnect or refresh history to reconcile; the message will not be resent automatically.'
          : failure.message;
    } finally {
      conversation.sending = false;
      _notify();
    }
  }

  void _reconcile(Conversation conversation) {
    if (conversation.uncertainId == null) return;
    final match = conversation.items.values.any(
      (item) =>
          item['type'] == 'userMessage' &&
          !conversation.beforeSend.contains(item['id']) &&
          (item['id'] == conversation.uncertainId ||
              item['clientUserMessageId'] == conversation.uncertainId ||
              itemText(item) == conversation.uncertainMessage),
    );
    if (match) {
      if (conversation.draft == conversation.uncertainMessage) {
        conversation.draft = '';
      }
      conversation.uncertainId = null;
      conversation.uncertainMessage = null;
      error = null;
    }
  }

  Future<void> interrupt(String id) async {
    final conversation = conversations[id]!;
    if (!conversation.controlled || conversation.activeTurn == null) return;
    await connection.request('turn/interrupt', {
      'threadId': id,
      'turnId': conversation.activeTurn,
    });
  }

  void respond(String id, CodexServerRequest request, ConversationJson result) {
    final conversation = conversations[id]!;
    if (!conversation.controlled ||
        !identical(conversation.requests[request.id], request)) {
      throw const CodexFailure('This interaction is no longer pending.');
    }
    connection.respond(request.id, result);
    conversation.requests.remove(request.id);
    _notify();
  }

  void _item(
    Conversation conversation,
    String turn,
    ConversationJson item, {
    bool complete = false,
  }) {
    final id = item['id'];
    if (id is! String) return;
    final previous = conversation.items[id];
    if (previous?['complete'] == true && !complete) return;
    if (!complete && item['text'] == '' && previous?['text'] is String) {
      item['text'] = previous!['text'];
    }
    conversation.items[id] = {
      ...?previous,
      ...item,
      'turnId': turn,
      'complete': complete,
    };
    _limitItems(conversation, id);
    _reconcile(conversation);
  }

  void _limitItems(Conversation conversation, String id) {
    final item = conversation.items[id]!;
    final text = itemText(item);
    final size = jsonEncode(item).length;
    if (size > 262144) {
      conversation.items[id] = {
        for (final field in [
          'id',
          'type',
          'turnId',
          'complete',
          'clientUserMessageId',
        ])
          if (item.containsKey(field)) field: item[field],
        item['type'] == 'commandExecution' ? 'aggregatedOutput' : 'text': text
            .substring(text.length > 262144 ? text.length - 262144 : 0),
      };
      conversation.historyTruncated = true;
    }
    final retained = size.clamp(0, 262144);
    conversation._retainedCharacters +=
        retained - (conversation._itemSizes[id] ?? 0);
    conversation._itemSizes[id] = retained;
    while (conversation.items.length > 2000 ||
        conversation._retainedCharacters > 2 * 1024 * 1024) {
      final removable = conversation.items.entries
          .where(
            (e) =>
                e.key != id &&
                !conversation.requests.values.any(
                  (request) => request.parameters['itemId'] == e.key,
                ),
          )
          .firstOrNull;
      if (removable == null) break;
      conversation.items.remove(removable.key);
      conversation._retainedCharacters -=
          conversation._itemSizes.remove(removable.key) ?? 0;
      conversation.historyTruncated = true;
    }
  }

  void _event(CodexEvent event) {
    final parameters = event.parameters;
    if (event.method == 'connection/closed') {
      for (final conversation in conversations.values) {
        conversation.controlled = false;
        conversation.requests.clear();
      }
      error = 'Codex disconnected. Reconnect to recover history and pending requests.';
      _notify();
      return;
    }
    if (event.method == 'account/rateLimits/updated') {
      limits = parameters;
      _notify();
      return;
    }
    if (event.method == 'serverRequest/resolved') {
      for (final conversation in conversations.values) {
        conversation.requests.remove(parameters['requestId']);
      }
      _notify();
      return;
    }
    final conversation = conversations[parameters['threadId']];
    if (conversation == null || !_owned.contains(conversation.id)) return;
    conversation.updatedAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final turnId =
        parameters['turnId'] as String? ?? conversation.activeTurn ?? '';
    final itemId =
        parameters['itemId'] ??
        (parameters['item'] is Map ? (parameters['item'] as Map)['id'] : null);
    if (itemId is String) _resuming[conversation.id]?.add(itemId);
    if (event.method == 'turn/started' || event.method == 'turn/completed') {
      final turn = Map<String, Object?>.from(parameters['turn'] as Map);
      final id = turn['id'] as String;
      _resuming[conversation.id]?.add('turn:$id');
      if (event.method == 'turn/started' &&
          [
            'completed',
            'interrupted',
            'failed',
          ].contains(conversation.turns[id]?['status'])) {
        return;
      }
      conversation.turns[id] = {...turn}..remove('items');
      if (event.method == 'turn/started') {
        conversation.activeTurn = id;
      } else if (conversation.activeTurn == id) {
        conversation.activeTurn = null;
      }
      if (turn['status'] == 'failed') error = 'Codex could not complete the turn. Inspect its work and retry explicitly.';
    } else if (event.method == 'item/started' ||
        event.method == 'item/completed') {
      _item(
        conversation,
        turnId,
        Map<String, Object?>.from(parameters['item'] as Map),
        complete: event.method == 'item/completed',
      );
    } else if (event.method.endsWith('/delta') ||
        event.method.endsWith('/outputDelta')) {
      final id = parameters['itemId'];
      final delta = parameters['delta'];
      if (id is String && delta is String) {
        final item = conversation.items.putIfAbsent(
          id,
          () => {
            'id': id,
            'turnId': turnId,
            'type': event.method.contains('agentMessage')
                ? 'agentMessage'
                : 'commandExecution',
          },
        );
        if (item['complete'] != true) {
          final field = item['type'] == 'agentMessage'
              ? 'text'
              : 'aggregatedOutput';
          final text = '${item[field] ?? ''}$delta';
          item[field] = text;
          _limitItems(conversation, id);
        }
      }
    } else if (event.method == 'thread/status/changed') {
      final status = parameters['status'];
      if (status is Map) conversation.status = '${status['type']}';
    } else if (event.method == 'error') {
      error = 'Codex reported an error. Refresh history to inspect the current turn.';
    }
    _notify();
  }

  void _evict() {
    final histories =
        conversations.values
            .where(
              (c) =>
                  c.items.isNotEmpty &&
                  !c.active &&
                  c.requests.isEmpty &&
                  c.uncertainId == null &&
                  c.id != selectedId,
            )
            .toList()
          ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    for (final old in histories.skip(12)) {
      old.items.clear();
      old.turns.clear();
      old._itemSizes.clear();
      old._retainedCharacters = 0;
      old.historyTruncated = true;
    }
    while (conversations.length > 300) {
      final old = conversations.values
          .where(
            (c) =>
                c.id != selectedId && !_owned.contains(c.id) && c.draft.isEmpty,
          )
          .firstOrNull;
      if (old == null) break;
      conversations.remove(old.id);
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    ++_generation;
    await _events.cancel();
    await _requests.cancel();
    await connection.close();
    await _changes.close();
  }
}

String itemText(ConversationJson item) {
  if (item['text'] is String) return item['text'] as String;
  final content = item['content'];
  if (content is List) {
    return content.whereType<Map>().map((v) => v['text'] ?? '').join('\n');
  }
  if (item['aggregatedOutput'] is String) {
    return item['aggregatedOutput'] as String;
  }
  return const JsonEncoder.withIndent('  ').convert(item);
}
