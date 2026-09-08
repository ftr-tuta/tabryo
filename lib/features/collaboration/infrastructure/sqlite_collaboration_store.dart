import 'dart:convert';
import 'dart:collection';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';

import '../domain/collaboration.dart';

String collaborationToken() =>
    base64UrlEncode(List<int>.generate(32, (_) => Random.secure().nextInt(256)))
        .replaceAll('=', '');

String _digest(String token) => sha256.convert(utf8.encode(token)).toString();

Object? _canonical(Object? value) => switch (value) {
  Map map => SplayTreeMap<String, Object?>.from({
    for (final entry in map.entries)
      entry.key as String: _canonical(entry.value),
  }),
  List list => list.map(_canonical).toList(),
  _ => value,
};

/// Only the background service opens this database. SQLite commits precede
/// every receipt; a dispatch is recorded before crossing the process boundary.
final class SqliteCollaborationStore implements CollaborationStore {
  SqliteCollaborationStore(String path) : _db = sqlite3.open(path) {
    _db.execute('PRAGMA journal_mode=WAL');
    _db.execute('PRAGMA synchronous=FULL');
    _db.execute('PRAGMA foreign_keys=ON');
    _db.execute('PRAGMA busy_timeout=5000');
    final version = _db.select('PRAGMA user_version').first.values.first as int;
    if (version > 1) {
      _db.close();
      throw const CollaborationFailure(
        'This collaboration database needs a newer Tabryo.',
      );
    }
    _transaction(() {
      _db.execute('''
CREATE TABLE IF NOT EXISTS groups (
 id TEXT PRIMARY KEY, name TEXT NOT NULL, created TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS participants (
 id TEXT PRIMARY KEY, group_id TEXT NOT NULL REFERENCES groups(id),
 name TEXT NOT NULL, root TEXT NOT NULL, repository TEXT NOT NULL,
 objective TEXT NOT NULL, writer INTEGER NOT NULL, auto_wake INTEGER NOT NULL,
 state TEXT NOT NULL, thread TEXT, token_hash TEXT NOT NULL UNIQUE,
 updated TEXT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS repository_writer ON participants(repository)
 WHERE writer=1 AND state != 'completed';
CREATE TABLE IF NOT EXISTS messages (
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 group_id TEXT NOT NULL REFERENCES groups(id),
 sender TEXT NOT NULL REFERENCES participants(id),
 recipient TEXT NOT NULL REFERENCES participants(id),
 client_id TEXT NOT NULL, kind TEXT NOT NULL, summary TEXT NOT NULL,
 checkpoint_id INTEGER REFERENCES checkpoints(id),
 status TEXT NOT NULL DEFAULT 'stored', turn TEXT,
 created TEXT NOT NULL, updated TEXT NOT NULL,
 UNIQUE(sender, client_id)
);
CREATE INDEX IF NOT EXISTS inbox ON messages(recipient,status,id);
CREATE TABLE IF NOT EXISTS checkpoints (
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 group_id TEXT NOT NULL REFERENCES groups(id),
 author TEXT NOT NULL REFERENCES participants(id),
 client_id TEXT NOT NULL, version INTEGER NOT NULL,
 summary TEXT NOT NULL, detail TEXT NOT NULL, created TEXT NOT NULL,
 UNIQUE(author,version), UNIQUE(author,client_id)
);
PRAGMA user_version=1;
''');
      // A crash between submission and its response has an unknown outcome.
      _db.execute(
        "UPDATE messages SET status='uncertain' WHERE status='dispatching'",
      );
    });
  }

  final Database _db;
  String get _now => DateTime.now().toUtc().toIso8601String();

  T _transaction<T>(T Function() action) {
    _db.execute('BEGIN IMMEDIATE');
    try {
      final value = action();
      _db.execute('COMMIT');
      return value;
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  List<Json> _rows(String sql, [List<Object?> args = const []]) => _db
      .select(sql, args)
      .map((row) => Map<String, Object?>.from(row))
      .toList();
  Json _public(Json row) => {...row}..remove('token_hash');

  @override
  List<Json> groups() => _rows('SELECT * FROM groups ORDER BY created');
  @override
  Json createGroup(String name) {
    if (groups().length >= 100) {
      throw const CollaborationFailure(
        'This local service supports up to 100 groups.',
      );
    }
    requiredText({'name': name}, 'name', max: 120);
    final id = collaborationToken();
    _db.execute('INSERT INTO groups VALUES (?,?,?)', [id, name, _now]);
    return _rows('SELECT * FROM groups WHERE id=?', [id]).single;
  }

  @override
  List<Json> participants({String? group}) => _rows(
    'SELECT * FROM participants ${group == null ? '' : 'WHERE group_id=?'} ORDER BY updated',
    group == null ? [] : [group],
  ).map(_public).toList();

  @override
  Json participant(String id) {
    final rows = _rows('SELECT * FROM participants WHERE id=?', [id]);
    if (rows.isEmpty) {
      throw const CollaborationFailure('Participant not found.');
    }
    return _public(rows.single);
  }

  @override
  Json addParticipant(Json values) {
    if (participants().where((p) => p['state'] != 'completed').length >= 16) {
      throw const CollaborationFailure(
        'Complete a participant before connecting more than 16 sessions.',
      );
    }
    final id = collaborationToken();
    final token = collaborationToken();
    try {
      _db.execute('INSERT INTO participants VALUES (?,?,?,?,?,?,?,?,?,?,?,?)', [
        id,
        requiredText(values, 'group_id', max: 128),
        requiredText(values, 'name', max: 120),
        requiredText(values, 'root'),
        requiredText(values, 'repository'),
        requiredText(values, 'objective'),
        values['writer'] == true ? 1 : 0,
        values['auto_wake'] == true ? 1 : 0,
        'paused',
        null,
        _digest(token),
        _now,
      ]);
    } on SqliteException {
      throw const CollaborationFailure(
        'Group unavailable or this repository already has a writer. Complete its participant before transferring ownership.',
      );
    }
    return {...participant(id), 'token': token};
  }

  @override
  void updateParticipant(String id, Json values) {
    participant(id);
    if (values.keys.any(
      (key) => !{'state', 'thread', 'auto_wake', 'token_hash'}.contains(key),
    )) {
      throw const CollaborationFailure('Participant identity is immutable.');
    }
    if (values.containsKey('state') &&
        !{
          'active',
          'paused',
          'disconnected',
          'completed',
        }.contains(values['state'])) {
      throw const CollaborationFailure('Invalid participant state.');
    }
    final fields = {...values, 'updated': _now};
    _db.execute(
      'UPDATE participants SET ${fields.keys.map((k) => '$k=?').join(',')} WHERE id=?',
      [...fields.values, id],
    );
  }

  String rotateToken(String id) {
    final token = collaborationToken();
    updateParticipant(id, {'token_hash': _digest(token)});
    return token;
  }

  @override
  Json? authenticate(String token) {
    if (token.length != 43) return null;
    final rows = _rows(
      "SELECT * FROM participants WHERE token_hash=? AND state != 'completed'",
      [_digest(token)],
    );
    return rows.isEmpty ? null : _public(rows.single);
  }

  @override
  Json send(String sender, Json values) => _transaction(() {
    final origin = participant(sender);
    final recipient = requiredText(values, 'recipient', max: 128);
    final target = participant(recipient);
    if (origin['state'] == 'completed' ||
        origin['group_id'] != target['group_id']) {
      throw const CollaborationFailure(
        'Messages are restricted to this collaboration group.',
      );
    }
    final clientId = requiredText(values, 'client_id', max: 128);
    final summary = requiredText(values, 'summary', max: 8000);
    final kind = values['kind'] ?? 'information';
    if (!{'information', 'request', 'dependency_ready'}.contains(kind)) {
      throw const CollaborationFailure('Invalid message kind.');
    }
    final checkpoint = values['checkpoint_id'];
    if (checkpoint != null) {
      if (checkpoint is! int) {
        throw const CollaborationFailure('Invalid checkpoint.');
      }
      checkpointDetail(origin['group_id'] as String, checkpoint);
    }
    final existing = _rows(
      'SELECT * FROM messages WHERE sender=? AND client_id=?',
      [sender, clientId],
    );
    if (existing.isNotEmpty) {
      final old = existing.single;
      if (old['recipient'] != recipient ||
          old['summary'] != summary ||
          old['kind'] != kind ||
          old['checkpoint_id'] != checkpoint) {
        throw const CollaborationFailure(
          'This client_id already identifies different content.',
        );
      }
      return old;
    }
    _db.execute(
      '''INSERT INTO messages
 (group_id,sender,recipient,client_id,kind,summary,checkpoint_id,created,updated)
 VALUES (?,?,?,?,?,?,?,?,?)''',
      [
        origin['group_id'],
        sender,
        recipient,
        clientId,
        kind,
        summary,
        checkpoint,
        _now,
        _now,
      ],
    );
    return _rows('SELECT * FROM messages WHERE id=?', [
      _db.lastInsertRowId,
    ]).single;
  });

  @override
  List<Json> messages(String group, {int after = 0, int limit = 100}) => _rows(
    'SELECT * FROM messages WHERE group_id=? AND id>? ORDER BY id LIMIT ?',
    [group, after, limit.clamp(1, 200)],
  );
  @override
  List<Json> pending(String recipient) => _rows(
    "SELECT * FROM messages WHERE recipient=? AND status IN ('stored','uncertain') ORDER BY id LIMIT 100",
    [recipient],
  );
  @override
  void delivery(int id, String status, {String? turn}) {
    if (!{'stored', 'dispatching', 'forwarded', 'uncertain'}.contains(status)) {
      throw const CollaborationFailure('Invalid delivery state.');
    }
    _db.execute(
      "UPDATE messages SET status=?,turn=COALESCE(?,turn),updated=? WHERE id=? AND status != 'confirmed'",
      [status, turn, _now, id],
    );
  }

  @override
  Json acknowledge(String recipient, int id) {
    final rows = _rows('SELECT * FROM messages WHERE recipient=? AND id=?', [
      recipient,
      id,
    ]);
    if (rows.isEmpty) {
      throw const CollaborationFailure(
        'Only the recipient can acknowledge this message.',
      );
    }
    _db.execute("UPDATE messages SET status='confirmed',updated=? WHERE id=?", [
      _now,
      id,
    ]);
    return _rows('SELECT * FROM messages WHERE id=?', [id]).single;
  }

  @override
  Json checkpoint(String author, Json values) => _transaction(() {
    final owner = participant(author);
    final clientId = requiredText(values, 'client_id', max: 128);
    final summary = requiredText(values, 'summary', max: 2000);
    for (final field in [
      'objective',
      'state',
      'decisions',
      'review',
      'validation',
      'next_step',
    ]) {
      requiredText(values, field, max: 8000);
    }
    final detail = jsonEncode(_canonical(values));
    if (detail.length > 60000) {
      throw const CollaborationFailure('Checkpoint is too large.');
    }
    final old = _rows(
      'SELECT * FROM checkpoints WHERE author=? AND client_id=?',
      [author, clientId],
    );
    if (old.isNotEmpty) {
      final original = Map<String, Object?>.from(
        jsonDecode(old.single['detail'] as String) as Map,
      )..remove('source');
      final submitted = {...values}..remove('source');
      if (jsonEncode(_canonical(original)) !=
          jsonEncode(_canonical(submitted))) {
        throw const CollaborationFailure('Checkpoint client_id already used.');
      }
      return _checkpoint(old.single);
    }
    final version =
        (_db.select(
              'SELECT COALESCE(MAX(version),0)+1 AS version FROM checkpoints WHERE author=?',
              [author],
            ).single['version'])
            as int;
    _db.execute(
      'INSERT INTO checkpoints (group_id,author,client_id,version,summary,detail,created) VALUES (?,?,?,?,?,?,?)',
      [owner['group_id'], author, clientId, version, summary, detail, _now],
    );
    return checkpointDetail(owner['group_id'] as String, _db.lastInsertRowId);
  });
  Json _checkpoint(Json row) => {
    ...row,
    'detail': jsonDecode(row['detail'] as String),
  };
  @override
  List<Json> checkpoints(
    String group, {
    String? author,
    int after = 0,
  }) => _rows(
    "SELECT id,group_id,author,version,summary,created,json_extract(detail,'\$.source.local_changes') AS local_changes,json_extract(detail,'\$.source.commit') AS revision,substr(json_extract(detail,'\$.state'),1,200) AS state FROM checkpoints WHERE group_id=? AND id>? ${author == null ? '' : 'AND author=?'} ORDER BY id LIMIT 100",
    [group, after, ?author],
  );
  @override
  Json checkpointDetail(String group, int id) {
    final rows = _rows('SELECT * FROM checkpoints WHERE group_id=? AND id=?', [
      group,
      id,
    ]);
    if (rows.isEmpty) {
      throw const CollaborationFailure('Checkpoint not found in this group.');
    }
    return _checkpoint(rows.single);
  }

  @override
  void close() => _db.close();
}
