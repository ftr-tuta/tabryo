import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../../core/tool_environment.dart';

import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../../core/cancellation.dart';
import '../domain/language_server.dart';

/// Byte framing is separate from the Codex JSONL transport. Headers and bodies
/// may arrive fragmented or coalesced; Content-Length counts UTF-8 bytes.
final class LspFramer {
  static const bodyLimit = 4 * 1024 * 1024;
  final _bytes = BytesBuilder(copy: false);
  int? _length;
  List<Map<String, dynamic>> add(List<int> chunk) {
    _bytes.add(chunk);
    var data = _bytes.takeBytes();
    final messages = <Map<String, dynamic>>[];
    while (data.isNotEmpty) {
      if (_length == null) {
        var end = -1;
        for (var i = 0; i + 3 < data.length; i++) {
          if (data[i] == 13 &&
              data[i + 1] == 10 &&
              data[i + 2] == 13 &&
              data[i + 3] == 10) {
            end = i;
            break;
          }
        }
        if (end < 0) {
          if (data.length > 8192) {
            throw const FormatException('LSP header limit.');
          }
          break;
        }
        if (end > 8192) throw const FormatException('LSP header limit.');
        final headers = ascii.decode(data.sublist(0, end)).split('\r\n');
        final lengths = headers
            .where((line) => line.toLowerCase().startsWith('content-length:'))
            .toList();
        if (lengths.length != 1) {
          throw const FormatException('Invalid LSP length.');
        }
        final length = int.tryParse(lengths.single.split(':').last.trim());
        if (length == null || length < 2 || length > bodyLimit) {
          throw const FormatException('LSP body limit.');
        }
        _length = length;
        data = Uint8List.sublistView(data, end + 4);
      }
      if (data.length < _length!) break;
      final value = jsonDecode(utf8.decode(data.sublist(0, _length!)));
      if (value is! Map<String, dynamic> || value['jsonrpc'] != '2.0') {
        throw const FormatException('Invalid LSP message.');
      }
      messages.add(value);
      data = Uint8List.sublistView(data, _length!);
      _length = null;
    }
    _bytes.add(data);
    return messages;
  }

  static List<int> encode(Map<String, Object?> value) {
    final body = utf8.encode(jsonEncode({'jsonrpc': '2.0', ...value}));
    if (body.length > bodyLimit) {
      throw const LanguageFailure('LSP message limit reached.');
    }
    return [...ascii.encode('Content-Length: ${body.length}\r\n\r\n'), ...body];
  }
}

final class LocalLanguageServers implements LanguageServers {
  @override
  Future<LanguageConnection> start(LanguageServerSpec spec) async {
    if (!p.isAbsolute(spec.executable) ||
        (Platform.isWindows &&
            p.extension(spec.executable).toLowerCase() != '.exe') ||
        !await File(spec.executable).exists()) {
      throw const LanguageFailure(
        'Select an installed absolute native executable.',
      );
    }
    final workspace = await Directory(spec.workspace).resolveSymbolicLinks();
    final root = await Directory(spec.root).resolveSymbolicLinks();
    if (!p.equals(workspace, spec.workspace) ||
        !p.equals(root, spec.root) ||
        (!p.equals(workspace, root) && !p.isWithin(workspace, root))) {
      throw const LanguageFailure(
        'Project is outside the authorized workspace.',
      );
    }
    if (spec.kind == LanguageServerKind.pyright &&
        (spec.module == null ||
            !p.isAbsolute(spec.module!) ||
            !await File(spec.module!).exists() ||
            spec.python == null ||
            !p.isAbsolute(spec.python!) ||
            !await File(spec.python!).exists())) {
      throw const LanguageFailure(
        'Select the Pyright langserver JavaScript file and the project Python executable.',
      );
    }
    if (spec.kind == LanguageServerKind.clangd) {
      final database = spec.compilationDatabase;
      if (database == null ||
          !p.isAbsolute(database) ||
          !await File(p.join(database, 'compile_commands.json')).exists()) {
        throw const LanguageFailure(
          'Generate compile_commands.json and select its directory before starting clangd.',
        );
      }
    }
    final process = await Process.start(
      spec.executable,
      spec.arguments,
      workingDirectory: root,
      environment: await nativeToolEnvironment(spec.environmentScript, root),
      runInShell: false,
    );
    final connection = LspConnection(
      process.stdout,
      process.stdin.add,
      closeTransport: () async {
        process.kill();
        try {
          await process.exitCode.timeout(const Duration(seconds: 3));
        } on TimeoutException {
          process.kill(ProcessSignal.sigkill);
          await process.exitCode.timeout(const Duration(seconds: 3));
        }
        try {
          await process.stdin.close();
        } catch (_) {
          /* Child may close stdin first. */
        }
      },
      errors: process.stderr,
    );
    unawaited(
      process.stdin.done.catchError((Object error) {
        connection._fail(
          const LanguageFailure('Language server input closed.'),
        );
      }),
    );
    return connection;
  }
}

final class LspConnection implements LanguageConnection, LanguageRefactors {
  LspConnection(
    Stream<List<int>> input,
    this._write, {
    required this._closeTransport,
    Stream<List<int>>? errors,
    this.timeout = const Duration(seconds: 20),
  }) {
    _input = input.listen(
      (chunk) {
        try {
          for (final value in _framer.add(chunk)) {
            _receive(value);
          }
        } catch (_) {
          _fail(
            const LanguageFailure(
              'Malformed or oversized language server output.',
            ),
          );
        }
      },
      onError: (_) =>
          _fail(const LanguageFailure('Language server connection failed.')),
      onDone: () => _fail(
        const LanguageFailure(
          'Language server stopped. Restart it from Projects and toolchains.',
        ),
      ),
    );
    // Drain stderr without retaining source text, paths, tokens or unbounded logs.
    _errors = errors?.listen((_) {}, onError: (_) {});
  }
  final void Function(List<int>) _write;
  final Future<void> Function() _closeTransport;
  final Duration timeout;
  final _framer = LspFramer();
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final _pending = <int, Completer<Object?>>{};
  late final StreamSubscription<List<int>> _input;
  StreamSubscription<List<int>>? _errors;
  int _next = 0;
  bool _closed = false;
  Future<void>? _closing;
  _RefactorProposal? _refactor;

  @override
  Future<Map<String, Object?>> proposeRefactor(
    List<Object?> arguments, {
    Cancellation? cancellation,
  }) async {
    if (_refactor != null) {
      throw const LanguageFailure('Wait for the current refactoring proposal.');
    }
    cancellation?.check();
    final proposal = _refactor = _RefactorProposal();
    try {
      try {
        await request('workspace/executeCommand', {
          'command': 'refactor.perform',
          'arguments': arguments,
        }, cancellation: cancellation);
      } on LanguageFailure {
        // Dart reports the explicitly negative applyEdit acknowledgement as an
        // error. A captured edit is still only a proposal for native review.
        if (proposal.edit == null) rethrow;
      }
      cancellation?.check();
      if (_closed ||
          !proposal.replied ||
          proposal.count != 1 ||
          proposal.edit == null) {
        throw const LanguageFailure(
          'The server did not return one reviewable refactoring.',
        );
      }
      return proposal.edit!;
    } finally {
      if (!proposal.replied && !_closed) {
        // applyEdit has no originating request ID. After cancellation/timeout,
        // retire the transport so a late edit cannot belong to another review.
        _fail(
          const LanguageFailure(
            'Refactoring did not finish. Restart the language server.',
          ),
        );
      }
      if (identical(_refactor, proposal)) _refactor = null;
    }
  }

  @override
  Stream<Map<String, dynamic>> get notifications => _events.stream;

  void _send(Map<String, Object?> value) {
    if (_closed) {
      throw const LanguageFailure('Language server is disconnected.');
    }
    try {
      _write(LspFramer.encode(value));
    } catch (_) {
      _fail(const LanguageFailure('Language server write failed.'));
      rethrow;
    }
  }

  @override
  void notify(String method, Map<String, Object?> parameters) =>
      _send({'method': method, 'params': parameters});

  @override
  Future<Object?> request(
    String method,
    Map<String, Object?> parameters, {
    Cancellation? cancellation,
  }) async {
    cancellation?.check();
    if (_pending.length >= 32) {
      throw const LanguageFailure('Too many pending language requests.');
    }
    final id = ++_next;
    if (method == 'workspace/executeCommand') _refactor?.requestId = id;
    final completion = Completer<Object?>();
    _pending[id] = completion;
    final timer = Timer(timeout, () {
      if (!completion.isCompleted) {
        completion.completeError(
          const LanguageFailure('Language request timed out.'),
        );
        _cancel(id);
      }
    });
    // A timer releases the cancellation listener along with each request.
    final cancelTimer = cancellation == null
        ? null
        : Timer.periodic(const Duration(milliseconds: 25), (_) {
            if (cancellation.isCancelled && !completion.isCompleted) {
              completion.completeError(const Cancelled());
              _cancel(id);
            }
          });
    try {
      try {
        _send({'id': id, 'method': method, 'params': parameters});
      } catch (error) {
        if (!completion.isCompleted) completion.completeError(error);
      }
      return await completion.future;
    } finally {
      timer.cancel();
      cancelTimer?.cancel();
      _pending.remove(id);
    }
  }

  void _receive(Map<String, dynamic> value) {
    if (value['method'] is String) {
      if (value.containsKey('id')) {
        final proposal = _refactor;
        if (value['method'] == 'workspace/applyEdit' && proposal != null) {
          proposal.count++;
          final parameters = value['params'];
          final edit = parameters is Map ? parameters['edit'] : null;
          if (edit is Map) proposal.edit = Map<String, Object?>.from(edit);
        }
        // Servers cannot execute commands, register arbitrary client handlers,
        // open URLs or apply edits without the application's review flow.
        _send({
          'id': value['id'],
          if (value['method'] == 'workspace/applyEdit')
            'result': {
              'applied': false,
              'failureReason': 'Request a reviewed editor proposal. Unsolicited edits are refused.',
            }
          else
            'error': {'code': -32601, 'message': 'Unsupported client request'},
        });
      } else {
        _events.add(value);
      }
    } else {
      if (_refactor?.requestId == value['id']) _refactor?.replied = true;
      final completion = _pending[value['id']];
      if (completion == null || completion.isCompleted) return;
      if (value['error'] != null) {
        completion.completeError(
          const LanguageFailure('The language server rejected this request.'),
        );
      } else {
        completion.complete(value['result']);
      }
    }
  }

  void _cancel(int id) {
    if (_closed) return;
    try {
      notify(r'$/cancelRequest', {'id': id});
    } catch (_) {
      // The completed request owns its error; transport failure closes peers.
    }
  }

  void _fail(LanguageFailure error) {
    if (_closed) return;
    _events.add({
      'method': 'tabryo/disconnected',
      'params': {'message': error.message},
    });
    for (final pending in _pending.values) {
      if (!pending.isCompleted) pending.completeError(error);
    }
    unawaited(close().catchError((Object _) {}));
  }

  @override
  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    for (final pending in _pending.values) {
      if (!pending.isCompleted) {
        pending.completeError(
          const LanguageFailure('Language server was closed.'),
        );
      }
    }
    await _input.cancel();
    await _errors?.cancel();
    try {
      await _closeTransport();
    } finally {
      await _events.close();
    }
  }
}

final class _RefactorProposal {
  int? requestId;
  bool replied = false;
  int count = 0;
  Map<String, Object?>? edit;
}
