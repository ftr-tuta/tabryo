import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tabryo/core/cancellation.dart';
import 'package:tabryo/core/preview_cache.dart';
import 'package:tabryo/features/editor/infrastructure/local_document_files.dart';
import 'package:tabryo/features/editor/presentation/editor_view_model.dart';
import 'package:tabryo/features/language/application/language_service.dart';
import 'package:tabryo/features/language/domain/language_server.dart';
import 'package:tabryo/features/language/infrastructure/lsp_connection.dart';
import 'package:tabryo/features/language/infrastructure/local_language_sources.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('LSP framing handles fragmented Unicode, concatenation and limits', () {
    final data = LspFramer.encode({
      'method': 'notice',
      'params': {'text': 'ação 🌱'},
    });
    final parser = LspFramer();
    final messages = <Map<String, dynamic>>[];
    for (final byte in data) {
      messages.addAll(parser.add([byte]));
    }
    expect(messages.single['params']['text'], 'ação 🌱');
    expect(parser.add([...data, ...data]), hasLength(2));
    for (final header in [
      'Content-Length: -1\r\n\r\n',
      'Content-Length: 99999999\r\n\r\n',
      'Content-Length: 2\r\nContent-Length: 2\r\n\r\n{}',
    ]) {
      expect(
        () => LspFramer().add(ascii.encode(header)),
        throwsFormatException,
      );
    }
    expect(() => LspFramer().add(List.filled(8193, 65)), throwsFormatException);
  });

  test(
    'LSP cancellation retires pending IDs and ignores late responses',
    () async {
      final input = StreamController<List<int>>();
      final sent = <Map<String, dynamic>>[];
      final connection = LspConnection(
        input.stream,
        (bytes) => sent.addAll(LspFramer().add(bytes)),
        closeTransport: () async {},
      );
      final cancellation = Cancellation();
      final pending = connection.request(
        'textDocument/hover',
        {},
        cancellation: cancellation,
      );
      final cancelled = expectLater(pending, throwsA(isA<Cancelled>()));
      cancellation.cancel();
      await cancelled;
      expect(sent.last['method'], r'$/cancelRequest');
      input.add(
        LspFramer.encode({'id': sent.first['id'], 'result': 'obsolete'}),
      );
      final second = connection.request('textDocument/hover', {});
      input.add(LspFramer.encode({'id': sent.last['id'], 'result': 'current'}));
      expect(await second, 'current');
      await connection.close();
      await input.close();
    },
  );

  test(
    'LSP disconnect fails pending work and refuses server mutations',
    () async {
      final input = StreamController<List<int>>();
      final sent = <Map<String, dynamic>>[];
      final connection = LspConnection(
        input.stream,
        (bytes) => sent.addAll(LspFramer().add(bytes)),
        closeTransport: () async {},
      );
      input.add(
        LspFramer.encode({
          'id': 'server-1',
          'method': 'workspace/applyEdit',
          'params': {},
        }),
      );
      await Future<void>.delayed(Duration.zero);
      expect(sent.single['result']['applied'], isFalse);
      final pending = connection.request('textDocument/hover', {});
      final failed = expectLater(pending, throwsA(isA<LanguageFailure>()));
      await input.close();
      await failed;
      await connection.close();
    },
  );

  test(
    'UTF-16 edits preserve Unicode and reject overlap and surrogate splits',
    () {
      const text = 'ação 🌱\nint value = 1;\n';
      expect(languagePosition(text, 7), {'line': 0, 'character': 7});
      expect(languageOffset(text, {'line': 1, 'character': 4}), 12);
      expect(
        () => languageOffset(text, {'line': 0, 'character': 6}),
        throwsA(isA<LanguageFailure>()),
      );
      final edit = {
        'range': {
          'start': {'line': 1, 'character': 4},
          'end': {'line': 1, 'character': 9},
        },
        'newText': 'count',
      };
      expect(applyLanguageEdits(text, [edit]), 'ação 🌱\nint count = 1;\n');
      expect(
        () => applyLanguageEdits(text, [edit, edit]),
        throwsA(isA<LanguageFailure>()),
      );
    },
  );

  test(
    'LSP timeout remains handled when the cancellation write fails',
    () async {
      final input = StreamController<List<int>>();
      var writes = 0;
      var closed = false;
      final connection = LspConnection(
        input.stream,
        (_) {
          if (++writes > 1) throw const FileSystemException('Pipe closed');
        },
        closeTransport: () async {
          closed = true;
        },
        timeout: const Duration(milliseconds: 10),
      );
      await expectLater(
        connection.request('textDocument/hover', {}),
        throwsA(isA<LanguageFailure>()),
      );
      await connection.close();
      await input.close();
      expect(closed, isTrue);
    },
  );

  test('Dependency browsing admits declared libraries and rejects unrelated files and escaping links', () async {
    final directory = await Directory.systemTemp.createTemp(
      'tabryo_dependencies_',
    );
    final base = await directory.resolveSymbolicLinks();
    final project = await Directory(p.join(base, 'app')).create();
    final library = await Directory(p.join(base, 'package', 'lib'))
        .create(recursive: true);
    final source = await File(p.join(library.path, 'value.dart'))
        .writeAsString('class Value {}\n');
    final outside = await File(p.join(base, 'unrelated.dart'))
        .writeAsString('private\n');
    await Directory(p.join(project.path, '.dart_tool')).create();
    await File(p.join(project.path, '.dart_tool', 'package_config.json'))
        .writeAsString(
          jsonEncode({
            'configVersion': 2,
            'packages': [
              {
                'name': 'dependency',
                'rootUri': '../../package/',
                'packageUri': 'lib/',
              },
            ],
          }),
        );
    final sources = LocalLanguageSources(LocalDocumentFiles(PreviewCache()));
    final spec = LanguageServerSpec(
      kind: LanguageServerKind.dart,
      workspace: project.path,
      root: project.path,
      executable: _dart(),
    );
    addTearDown(() => directory.delete(recursive: true));
    expect((await sources.open(spec, source.path)).text, 'class Value {}\n');
    await expectLater(
      sources.open(spec, outside.path),
      throwsA(isA<LanguageFailure>()),
    );
    final link = Link(p.join(library.path, 'escape.dart'));
    try {
      await link.create(outside.path);
    } on FileSystemException {
      return;
    }
    await expectLater(
      sources.open(spec, link.path),
      throwsA(isA<LanguageFailure>()),
    );
  });

  test('Completion imports reject overlapping edits and server commands', () {
    final edit = {
      'range': {
        'start': {'line': 0, 'character': 0},
        'end': {'line': 0, 'character': 3},
      },
      'newText': 'Random',
    };
    expect(
      () => checkedCompletion('Ran', {
        'textEdit': edit,
        'additionalTextEdits': [edit],
      }),
      throwsA(isA<LanguageFailure>()),
    );
    expect(
      () => checkedCompletion('Ran', {
        'command': {'command': 'execute'},
      }),
      throwsA(isA<LanguageFailure>()),
    );
    final item = <String, Object?>{'textEdit': edit};
    final before = LanguageDocument('root', 'main.dart', 'Ran', 8);
    expect(
      completionVersionMatches(
        before,
        LanguageDocument('root', 'main.dart', 'Random', 9),
        item,
      ),
      isTrue,
    );
    expect(
      completionVersionMatches(
        before,
        LanguageDocument('root', 'main.dart', 'Random', 10),
        item,
      ),
      isFalse,
    );
    expect(
      completionVersionMatches(
        before,
        LanguageDocument('root', 'main.dart', 'Random typing', 9),
        item,
      ),
      isFalse,
    );
  });

  test(
    'Dart server analyzes unsaved buffers, navigates, renames and formats',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'tabryo_language_',
      );
      final root = await directory.resolveSymbolicLinks();
      final file = File(p.join(root, 'main.dart'));
      await file.writeAsString('void main() {}\n');
      final dart = _dart();
      final service = LanguageService(LocalLanguageServers());
      final editor = EditorViewModel(
        LocalDocumentFiles(PreviewCache()),
        language: service,
        languageSources: LocalLanguageSources(
          LocalDocumentFiles(PreviewCache()),
        ),
      );
      addTearDown(() async {
        await editor.disposeAsync();
        await directory.delete(recursive: true);
      });
      editor.selectWorkspace(root);
      await editor.open(root, file.path);
      await service.start(
        LanguageServerSpec(
          kind: LanguageServerKind.dart,
          workspace: root,
          root: root,
          executable: dart,
        ),
      );
      final buffer = editor.active!;
      buffer.controller.text =
          'int value = 1;\nvoid main(){ print(value); missingName(); }\n';
      await _until(
        () => service.problems.any(
          (d) => '${d.diagnostic['message']}'.contains('missingName'),
        ),
      );
      expect(await file.readAsString(), 'void main() {}\n');
      final version = buffer.version;
      final definition = await editor.languageRequest(
        buffer,
        'textDocument/definition',
        {
          'position': {'line': 1, 'character': 20},
        },
      );
      expect(definition, isNotNull);
      final hover = await editor.languageRequest(buffer, 'textDocument/hover', {
        'position': {'line': 0, 'character': 5},
      });
      expect(hover, isA<Map>());
      final symbols = await editor.languageRequest(
        buffer,
        'textDocument/documentSymbol',
        {},
      );
      expect(symbols, isNotEmpty);
      final renamed = await editor.languageRequest(
        buffer,
        'textDocument/rename',
        {
          'position': {'line': 0, 'character': 5},
          'newName': 'count',
        },
      );
      expect(renamed, isA<Map>());
      final edits = await editor.prepareLanguageEdit(
        buffer,
        renamed as Map,
        version: version,
      );
      expect(buffer.controller.text, contains('value'));
      await editor.applyReviewedLanguageEdit(edits);
      expect(buffer.controller.text, contains('print(count)'));
      expect(await file.readAsString(), 'void main() {}\n');
      const completionSource =
          'void main() { final value = "ação"; value.toStr; }\n';
      buffer.controller.text = completionSource;
      final completion = await editor.languageRequest(
        buffer,
        'textDocument/completion',
        {
          'position': languagePosition(
            completionSource,
            completionSource.indexOf('toStr') + 5,
          ),
        },
      );
      final items = completion is List
          ? completion
          : (completion as Map)['items'] as List;
      expect(
        items.any((item) => '${item['label']}'.startsWith('toString')),
        isTrue,
      );
      const importSource = 'void main() { Ran; }\n';
      buffer.controller.text = importSource;
      final imports = await editor.languageRequest(
        buffer,
        'textDocument/completion',
        {
          'position': languagePosition(
            importSource,
            importSource.indexOf('Ran') + 3,
          ),
        },
      ) as Map;
      final random = (imports['items'] as List).cast<Map>().firstWhere(
        (item) => item['label'] == 'Random',
      );
      final resolved = await editor.languageRequest(
        buffer,
        'completionItem/resolve',
        {'ticket': random['ticket']},
      ) as Map;
      expect(resolved['additionalTextEdits'], isNotEmpty);
      expect(resolved.containsKey('command'), isFalse);
      final imported = applyLanguageEdits(importSource, [
        resolved['textEdit'],
        ...resolved['additionalTextEdits'] as List,
      ]);
      expect(imported, contains("import 'dart:math';"));
      expect(imported, contains('Random'));
      final sdkSource = p.join(
        p.dirname(p.dirname(dart)),
        'lib',
        'math',
        'random.dart',
      );
      await editor.navigateLanguage(buffer, Uri.file(sdkSource).toString(), {
        'line': 0,
        'character': 0,
      });
      final source = editor.active!;
      expect(source.readOnly, isTrue);
      expect(source.controller.text, contains('Random'));
      expect(
        service.sessions.values.single.documents.containsKey(source.path),
        isFalse,
      );
      editor.applyWebEdit(source, 'overwrite', 0, 0, false, false);
      expect(source.controller.text, isNot('overwrite'));
      expect(await editor.save(source), isFalse);
      expect(await editor.reload(source), isTrue);
      editor.select(buffer);
      expect(await file.readAsString(), 'void main() {}\n');
      buffer.controller.text = 'new typing\n';
      await expectLater(
        editor.languageRequest(buffer, 'completionItem/resolve', {
          'ticket': random['ticket'],
        }),
        throwsA(isA<Cancelled>()),
      );
      buffer.controller.text = 'int count=1; void main(){print(count);}\n';
      expect(await editor.save(buffer), isTrue, reason: buffer.error);
      expect(buffer.controller.text, contains('int count = 1;'));
      expect(await file.readAsString(), buffer.controller.text);
      await _until(() => service.problems.isEmpty);
    },
    timeout: const Timeout(Duration(seconds: 80)),
  );

  test('Sessions isolate nested roots, drop stale replies and cancel pending startup', () async {
    final servers = _Servers();
    final service = LanguageService(servers);
    addTearDown(service.close);
    final root = p.absolute('workspace');
    final nested = p.join(root, 'nested');
    final outer = LanguageDocument(
      root,
      p.join(root, 'main.dart'),
      'int a = 1;',
      0,
    );
    final inner = LanguageDocument(
      root,
      p.join(nested, 'main.dart'),
      'int b = 2;',
      0,
    );
    service.synchronize([outer, inner]);
    await service.start(
      LanguageServerSpec(
        kind: LanguageServerKind.dart,
        workspace: root,
        root: root,
        executable: 'dart',
        excludedRoots: [nested],
      ),
    );
    final connection = servers.connections.single;
    final opened = connection.sent
        .where((e) => e['method'] == 'textDocument/didOpen')
        .toList();
    expect(opened, hasLength(1));
    expect(
      opened.single['params']['textDocument']['uri'],
      Uri.file(outer.path).toString(),
    );
    connection.hover = Completer<Object?>();
    final pending = service.request(outer, 'textDocument/hover', {});
    final stale = expectLater(pending, throwsA(isA<Cancelled>()));
    service.synchronize([
      LanguageDocument(root, outer.path, 'int a = 3;', 1),
      inner,
    ]);
    connection.hover!.complete({'contents': 'obsolete'});
    await stale;
    connection.events.add({
      'method': 'textDocument/publishDiagnostics',
      'params': {
        'uri': Uri.file(outer.path).toString(),
        'version': 0,
        'diagnostics': [_diagnostic('old')],
      },
    });
    connection.events.add({
      'method': 'textDocument/publishDiagnostics',
      'params': {
        'uri': Uri.file(inner.path).toString(),
        'version': 0,
        'diagnostics': [_diagnostic('wrong project')],
      },
    });
    await Future<void>.delayed(Duration.zero);
    expect(service.problems, isEmpty);
    await service.closeWorkspace(root);
    expect(connection.closed, isTrue);
    servers.block = Completer<void>();
    final starting = service.start(
      LanguageServerSpec(
        kind: LanguageServerKind.dart,
        workspace: root,
        root: root,
        executable: 'dart',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    await service.closeWorkspace(root);
    servers.block!.complete();
    await starting;
    expect(service.sessions, isEmpty);
    expect(servers.connections.last.closed, isTrue);
  });

  test(
    'Pyright resolves the selected environment and Ruff fixes and formats unsaved Python',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'tabryo_python_language_',
      );
      final root = await directory.resolveSymbolicLinks();
      final interpreter = _tool('python');
      final venv = p.join(root, '.venv');
      final created = await Process.run(interpreter, ['-m', 'venv', venv]);
      expect(created.exitCode, 0, reason: '${created.stderr}');
      final python = p.join(
        venv,
        Platform.isWindows ? 'Scripts' : 'bin',
        Platform.isWindows ? 'python.exe' : 'python',
      );
      final site = await Process.run(python, [
        '-c',
        'import sysconfig; print(sysconfig.get_path("purelib"))',
      ]);
      expect(site.exitCode, 0);
      await File(p.join('${site.stdout}'.trim(), 'only_here.py'))
          .writeAsString('value: int = 1\n');
      final file = File(p.join(root, 'main.py'));
      await file.writeAsString('');
      final service = LanguageService(LocalLanguageServers());
      final editor = EditorViewModel(
        LocalDocumentFiles(PreviewCache()),
        language: service,
      );
      addTearDown(() async {
        await editor.disposeAsync();
        await directory.delete(recursive: true);
      });
      editor.selectWorkspace(root);
      await editor.open(root, file.path);
      await service.start(
        LanguageServerSpec(
          kind: LanguageServerKind.pyright,
          workspace: root,
          root: root,
          executable: _tool('node'),
          python: python,
          module: p.absolute(
            'packages',
            'editor_web',
            'node_modules',
            'pyright',
            'dist',
            'pyright-langserver.js',
          ),
        ),
      );
      await service.start(
        LanguageServerSpec(
          kind: LanguageServerKind.ruff,
          workspace: root,
          root: root,
          executable: _tool('ruff'),
        ),
      );
      final buffer = editor.active!;
      buffer.controller.text =
          'import os\nimport only_here\nanswer: str = only_here.value\n';
      await _until(
        () =>
            service.problems.any((p) => p.server.startsWith('pyright:')) &&
            service.problems.any((p) => p.server.startsWith('ruff:')),
      );
      expect(
        service.problems.any(
          (p) => '${p.diagnostic['message']}'.contains('could not be resolved'),
        ),
        isFalse,
      );
      expect(
        service.problems
            .where((p) => p.server.startsWith('pyright:'))
            .any((p) => '${p.diagnostic['message']}'.contains('str')),
        isTrue,
      );
      final actions = await editor.languageRequest(
        buffer,
        'textDocument/codeAction',
        {
          'range': {
            'start': {'line': 0, 'character': 0},
            'end': {'line': 0, 'character': 9},
          },
          'context': {
            'diagnostics': service.problems
                .where((p) => p.server.startsWith('ruff:'))
                .map((p) => p.diagnostic)
                .toList(),
            'only': ['quickfix'],
          },
        },
        lint: true,
      ) as List;
      final action = actions.cast<Map>().firstWhere((a) => a['edit'] is Map);
      final proposal = await editor.prepareLanguageEdit(
        buffer,
        action['edit'] as Map,
        version: buffer.version,
      );
      await editor.applyReviewedLanguageEdit(proposal);
      expect(buffer.controller.text, isNot(contains('import os')));
      expect(await file.readAsString(), isEmpty);
      buffer.controller.text = 'values=[1,2,3]\n';
      expect(await editor.save(buffer), isTrue, reason: buffer.error);
      expect(buffer.controller.text, 'values = [1, 2, 3]\n');
    },
    skip: Platform.environment['TABRYO_TEST_LANGUAGE_PYTHON'] != '1',
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'An LSP format response cannot overwrite typing received while saving',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'tabryo_language_format_',
      );
      final root = await directory.resolveSymbolicLinks();
      final file = File(p.join(root, 'main.dart'));
      await file.writeAsString('before\n');
      final servers = _Servers();
      final service = LanguageService(servers);
      final editor = EditorViewModel(
        LocalDocumentFiles(PreviewCache()),
        language: service,
      );
      addTearDown(() async {
        await editor.disposeAsync();
        await directory.delete(recursive: true);
      });
      editor.selectWorkspace(root);
      await editor.open(root, file.path);
      await service.start(
        LanguageServerSpec(
          kind: LanguageServerKind.dart,
          workspace: root,
          root: root,
          executable: 'dart',
        ),
      );
      final buffer = editor.active!;
      buffer.controller.text = 'captured\n';
      final connection = servers.connections.single;
      connection.formatting = Completer<Object?>();
      final saving = editor.save(buffer);
      await _until(() => connection.formatRequested);
      buffer.controller.text = 'new typing\n';
      connection.formatting!.complete([
        {
          'range': {
            'start': {'line': 0, 'character': 0},
            'end': {'line': 0, 'character': 8},
          },
          'newText': 'formatted',
        },
      ]);
      expect(await saving, isFalse);
      expect(buffer.controller.text, 'new typing\n');
      expect(buffer.formatFailed, isTrue);
      expect(await file.readAsString(), 'before\n');
    },
  );

  test('Reviewed multi-file edits reject new input and paths outside the workspace', () async {
    final directory = await Directory.systemTemp.createTemp(
      'tabryo_language_edit_',
    );
    final root = await directory.resolveSymbolicLinks();
    final file = File(p.join(root, 'main.dart'));
    await file.writeAsString('value\n');
    final editor = EditorViewModel(LocalDocumentFiles(PreviewCache()));
    addTearDown(() async {
      await editor.disposeAsync();
      await directory.delete(recursive: true);
    });
    editor.selectWorkspace(root);
    await editor.open(root, file.path);
    final buffer = editor.active!;
    final edit = {
      'changes': {
        Uri.file(file.path).toString(): [
          {
            'range': {
              'start': {'line': 0, 'character': 0},
              'end': {'line': 0, 'character': 5},
            },
            'newText': 'count',
          },
        ],
      },
    };
    final proposal = await editor.prepareLanguageEdit(
      buffer,
      edit,
      version: buffer.version,
    );
    buffer.controller.value = const TextEditingValue(text: 'typing\n');
    await expectLater(
      editor.applyReviewedLanguageEdit(proposal),
      throwsA(isA<Cancelled>()),
    );
    expect(buffer.controller.text, 'typing\n');
    expect(await file.readAsString(), 'value\n');
    await expectLater(
      editor.prepareLanguageEdit(buffer, {
        'changes': {
          Uri.file(p.join(p.dirname(root), 'outside.dart')).toString(): [],
        },
      }, version: buffer.version),
      throwsA(isA<LanguageFailure>()),
    );
  });
}

String _dart() {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root == null) throw StateError('Flutter test must provide FLUTTER_ROOT.');
  return p.join(
    root,
    'bin',
    'cache',
    'dart-sdk',
    'bin',
    Platform.isWindows ? 'dart.exe' : 'dart',
  );
}

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 25));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Language server did not reach the expected state.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 40));
  }
}

String _tool(String name) {
  final override = Platform.environment['TABRYO_TEST_${name.toUpperCase()}'];
  if (override != null) return override;
  for (final directory in (Platform.environment['PATH'] ?? '').split(
    Platform.isWindows ? ';' : ':',
  )) {
    final file = File(
      p.join(directory, Platform.isWindows ? '$name.exe' : name),
    );
    if (file.existsSync()) return file.absolute.path;
  }
  throw StateError(
    'Set TABRYO_TEST_${name.toUpperCase()} to its native executable.',
  );
}

Map<String, Object?> _diagnostic(String message) => {
  'message': message,
  'range': {
    'start': {'line': 0, 'character': 0},
    'end': {'line': 0, 'character': 1},
  },
};

final class _Servers implements LanguageServers {
  final connections = <_Connection>[];
  Completer<void>? block;
  @override
  Future<LanguageConnection> start(LanguageServerSpec spec) async {
    await block?.future;
    final connection = _Connection();
    connections.add(connection);
    return connection;
  }
}

final class _Connection implements LanguageConnection {
  final events = StreamController<Map<String, dynamic>>.broadcast();
  final sent = <Map<String, dynamic>>[];
  Completer<Object?>? hover;
  Completer<Object?>? formatting;
  bool formatRequested = false;
  bool closed = false;
  @override
  Stream<Map<String, dynamic>> get notifications => events.stream;
  @override
  void notify(String method, Map<String, Object?> parameters) =>
      sent.add({'method': method, 'params': parameters});
  @override
  Future<Object?> request(
    String method,
    Map<String, Object?> parameters, {
    Cancellation? cancellation,
  }) async {
    if (method == 'initialize') {
      return {
        'capabilities': {
          'textDocumentSync': 2,
          'hoverProvider': true,
          'documentFormattingProvider': true,
        },
      };
    }
    if (method == 'textDocument/hover') return await hover?.future;
    if (method == 'textDocument/formatting') {
      formatRequested = true;
      return await formatting?.future;
    }
    return null;
  }

  @override
  Future<void> close() async {
    closed = true;
    await events.close();
  }
}
