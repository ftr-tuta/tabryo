import 'dart:async';

import '../../projects/domain/project.dart';
import '../../../core/cancellation.dart';
import '../domain/debug_session.dart';

final class DebugService {
  DebugService(this.adapters);
  final DebugAdapters adapters;
  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;
  DebugConnection? _connection;
  Future<DebugConnection>? _pendingAdapter;
  bool _startingSession = false;
  StreamSubscription<Map<String, dynamic>>? _events;
  Future<void> _releasing = Future.value();
  bool _releasingConnection = false;
  DebugTools? _devTools;
  bool _startingDevTools = false;
  Cancellation? _devToolsCancellation;
  Future<DebugTools>? _pendingDevTools;
  Uri? get devToolsUri => _devTools?.uri;
  Completer<void>? _initialized;
  bool _disposed = false;
  int _generation = 0;
  int _pauseGeneration = 0;
  int _variablesRequest = 0;
  int _watchRequest = 0;
  List<DebugWatch> watches = [];
  DebugConfiguration? configuration;
  DebugStatus status = DebugStatus.idle;
  String? error;
  bool _pauseFailure = false;
  void _clearPauseFailure() {
    if (_pauseFailure) error = null;
    _pauseFailure = false;
  }

  String output = '';
  int? threadId;
  int? frameId;
  int? exitCode;
  int stopCount = 0;
  String? stopReason;
  Uri? vmService;
  bool appStarted = false;
  bool reloadOnSave = true;
  Timer? _reloadTimer;
  Future<bool> Function()? _savedReloadCheck;
  Future<void>? _hotOperation;

  void setReloadOnSave(bool enabled) {
    reloadOnSave = enabled;
    if (!enabled) {
      _reloadTimer?.cancel();
      _savedReloadCheck = null;
    }
    _changed();
  }

  void scheduleReloadAfterSave(Future<bool> Function() check) {
    if (_disposed ||
        !reloadOnSave ||
        !active ||
        !appStarted ||
        configuration?.flutterMode != 'debug' ||
        configuration?.project.kind != ProjectKind.flutter) {
      return;
    }
    _savedReloadCheck = check;
    _reloadTimer?.cancel();
    _reloadTimer = Timer(const Duration(milliseconds: 300), () {
      unawaited(_reloadSaved());
    });
  }

  Future<void> _reloadSaved() async {
    if (status == DebugStatus.paused) return;
    final check = _savedReloadCheck;
    _savedReloadCheck = null;
    if (check == null || !reloadOnSave || !active || !appStarted) return;
    final generation = _generation;
    try {
      await _flutterControl('hotReload', 'save', check: check);
    } catch (failure) {
      if (!_disposed && generation == _generation && active) {
        error = 'Saved successfully; hot reload was not completed: $failure';
        _pauseFailure = false;
        _changed();
      }
    }
  }

  Future<void> _flutterControl(
    String command,
    String reason, {
    Future<bool> Function()? check,
  }) async {
    final connection = _connection;
    final generation = _generation;
    final previous = _hotOperation;
    final finished = Completer<void>();
    _hotOperation = finished.future;
    try {
      await previous;
      if (check != null && (!reloadOnSave || !await check())) return;
      if (_disposed ||
          generation != _generation ||
          connection == null ||
          !active ||
          !appStarted) {
        return;
      }
      if (reason == 'save' && status == DebugStatus.paused) {
        _savedReloadCheck ??= check;
        return;
      }
      await connection.request(command, {'reason': reason});
    } finally {
      finished.complete();
      if (identical(_hotOperation, finished.future)) _hotOperation = null;
    }
  }

  Map<String, dynamic> capabilities = {};
  List<Map<String, dynamic>> frames = [];
  List<Map<String, dynamic>> scopes = [];
  List<Map<String, dynamic>> variables = [];
  final verifiedBreakpoints = <String, List<Map<String, dynamic>>>{};
  final _breakpointUpdates = <int, Map<String, dynamic>>{};
  bool get active =>
      _connection != null ||
      _startingSession ||
      _releasingConnection ||
      [
        DebugStatus.starting,
        DebugStatus.running,
        DebugStatus.paused,
        DebugStatus.stopping,
      ].contains(status);
  void _changed() {
    if (!_disposed) _changes.add(null);
  }

  Map<String, Object?> launchArguments(DebugConfiguration config) => {
    'name': config.project.name,
    'request': config.isAttach ? 'attach' : 'launch',
    'type': config.project.kind == ProjectKind.python ? 'python' : 'dart',
    'cwd': config.directory,
    if (config.isAttach && config.project.kind == ProjectKind.python)
      'connect': {
        'host': config.attachUri!.host,
        'port': config.attachUri!.port,
      }
    else if (config.isAttach)
      'vmServiceUri': config.attachUri.toString(),
    if (!config.isAttach && config.pythonModule == null)
      'program': config.program
    else if (!config.isAttach)
      'module': config.pythonModule,
    if (!config.isAttach) ...{
      'args': config.arguments,
      'noDebug': config.noDebug || config.flutterMode != 'debug',
      'env': {
        if (config.project.kind == ProjectKind.python) ...{
          'PYTHONNOUSERSITE': '1',
          'PYTHONUNBUFFERED': '1',
        },
        ...config.environment,
      },
    },
    if (config.project.kind == ProjectKind.python) ...{
      'python': config.tools[ProjectTool.python],
      'console': 'internalConsole',
      'redirectOutput': true,
      'subProcess': false,
      'justMyCode': true,
      'django': config.django,
    } else ...{
      'debugSdkLibraries': false,
      'debugExternalPackageLibraries': false,
      'evaluateGettersInDebugViews': false,
      'evaluateToStringInDebugViews': false,
      'sendLogsToClient': false,
      if (config.project.kind == ProjectKind.flutter)
        'toolArgs': [
          if (!config.isAttach) '--no-pub',
          if (config.device != null) ...['--device-id', config.device!],
          if (!config.isAttach && config.flutterMode != 'debug')
            '--${config.flutterMode}',
          if (!config.isAttach && config.flavor != null) ...[
            '--flavor',
            config.flavor!,
          ],
          if (!config.isAttach) ...config.toolArguments,
        ]
      else if (!config.isAttach && config.toolArguments.isNotEmpty)
        'toolArgs': config.toolArguments,
    },
  };

  Future<void> start(DebugConfiguration config) async {
    if (_disposed || active) {
      throw const DebugFailure('Stop the active debug session first.');
    }
    _startingSession = true;
    final generation = ++_generation;
    ++_pauseGeneration;
    threadId = null;
    frameId = null;
    stopCount = 0;
    stopReason = null;
    configuration = config;
    status = DebugStatus.starting;
    error = null;
    _pauseFailure = false;
    output = '';
    exitCode = null;
    vmService = null;
    appStarted = false;
    frames = [];
    scopes = [];
    variables = [];
    watches = [];
    ++_watchRequest;
    verifiedBreakpoints.clear();
    _breakpointUpdates.clear();
    final initialized = _initialized = Completer<void>();
    _changed();
    try {
      await _release();
      if (_disposed || generation != _generation) return;
      final connection = await (_pendingAdapter = adapters.start(config));
      if (_disposed || generation != _generation) {
        await connection.close();
        return;
      }
      _connection = connection;
      _pendingAdapter = null;
      _events = connection.events.listen((event) => _event(event, generation));
      capabilities = await connection.request('initialize', {
        'clientID': 'tabryo',
        'clientName': 'Tabryo',
        'adapterID': config.project.kind == ProjectKind.python
            ? 'python'
            : 'dart',
        'pathFormat': 'path',
        'linesStartAt1': true,
        'columnsStartAt1': true,
        'supportsVariableType': true,
        'supportsVariablePaging': true,
        'supportsRunInTerminalRequest': false,
        'supportsStartDebuggingRequest': false,
      });
      if (generation != _generation) return;
      if (config.breakpoints.values
              .expand((v) => v)
              .any((b) => b.condition != null) &&
          capabilities['supportsConditionalBreakpoints'] != true) {
        throw const DebugFailure(
          'This adapter does not support conditional breakpoints. Review the breakpoints before starting.',
        );
      }
      Object? launchError;
      final launch = connection
          .request(
            config.isAttach ? 'attach' : 'launch',
            launchArguments(config),
          )
          .catchError((Object failure) {
            launchError = failure;
            if (!initialized.isCompleted) initialized.complete();
            return <String, dynamic>{};
          });
      await initialized.future.timeout(const Duration(seconds: 60));
      if (generation != _generation) return;
      if (launchError != null) throw launchError!;
      if (status == DebugStatus.failed || status == DebugStatus.terminated) {
        throw DebugFailure(error ?? 'Debug adapter stopped during startup.');
      }
      for (final entry in config.breakpoints.entries) {
        final response = await connection.request('setBreakpoints', {
          'source': {'path': entry.key},
          'breakpoints': [for (final point in entry.value) point.toJson()],
        });
        verifiedBreakpoints[entry.key] = [
          for (final breakpoint in _maps(response['breakpoints']))
            {...breakpoint, ...?_breakpointUpdates[breakpoint['id']]},
        ];
      }
      if (capabilities['supportsConfigurationDoneRequest'] == true) {
        await connection.request('configurationDone');
      }
      await launch;
      if (launchError != null) throw launchError!;
      if (generation != _generation) return;
      if (status == DebugStatus.starting) status = DebugStatus.running;
      _changed();
    } catch (failure) {
      if (generation != _generation || _disposed) return;
      if (generation == _generation && !_disposed) {
        status = DebugStatus.failed;
        error = '$failure';
        await _release();
        _changed();
      }
      rethrow;
    } finally {
      _pendingAdapter = null;
      _startingSession = false;
      _changed();
    }
  }

  List<Map<String, dynamic>> _maps(Object? value) => value is List
      ? value
            .whereType<Map>()
            .take(200)
            .map((v) => Map<String, dynamic>.from(v))
            .toList()
      : [];
  void _event(Map<String, dynamic> event, int generation) {
    if (_disposed || generation != _generation) return;
    final body = event['body'] is Map ? event['body'] as Map : const {};
    switch (event['event']) {
      case 'initialized':
        if (!_initialized!.isCompleted) _initialized!.complete();
      case 'output':
        final text = body['output'];
        if (text is String) {
          output += text;
          if (output.length > 256 * 1024) {
            output = output.substring(output.length - 256 * 1024);
          }
        }
      case 'stopped':
        _clearPauseFailure();
        status = DebugStatus.paused;
        stopCount++;
        stopReason = body['reason'] as String?;
        frames = [];
        scopes = [];
        variables = [];
        _clearWatchValues();
        threadId = body['threadId'] is int ? body['threadId'] as int : null;
        unawaited(_loadPause(generation));
      case 'continued':
        _continued();
      case 'exited':
        _pauseGeneration++;
        _clearWatchValues();
        _clearPauseFailure();
        exitCode = body['exitCode'] is int ? body['exitCode'] as int : null;
      case 'breakpoint':
        final breakpoint = body['breakpoint'];
        if (breakpoint is Map && breakpoint['id'] is int) {
          final id = breakpoint['id'] as int;
          final change = Map<String, dynamic>.from(breakpoint);
          if (_breakpointUpdates.length < 20000) {
            _breakpointUpdates[id] = change;
          }
          for (final entry in verifiedBreakpoints.entries.toList()) {
            verifiedBreakpoints[entry.key] = [
              for (final point in entry.value)
                point['id'] == id ? {...point, ...change} : point,
            ];
          }
        }
      case 'terminated':
        _clearPauseFailure();
        status = DebugStatus.terminated;
        _pauseGeneration++;
        _clearWatchValues();
        vmService = null;
        appStarted = false;
        if (!_initialized!.isCompleted) _initialized!.complete();
        unawaited(_release());
      case 'tabryo.disconnected':
        if (status != DebugStatus.terminated &&
            status != DebugStatus.stopping) {
          status = DebugStatus.failed;
          error = '${body['message']}';
        }
        if (!_initialized!.isCompleted) _initialized!.complete();
        vmService = null;
        appStarted = false;
        unawaited(_release());
      case 'flutter.appStarted':
        appStarted = true;
      case 'dart.debuggerUris':
        final uri = Uri.tryParse('${body['vmServiceUri']}');
        if (uri != null &&
            ['ws', 'http'].contains(uri.scheme) &&
            ['127.0.0.1', 'localhost', '::1'].contains(uri.host) &&
            uri.userInfo.isEmpty) {
          vmService = uri;
        }
    }
    _changed();
  }

  void _continued() {
    _clearPauseFailure();
    status = DebugStatus.running;
    stopReason = null;
    _pauseGeneration++;
    frames = [];
    scopes = [];
    variables = [];
    frameId = null;
    _clearWatchValues();
    if (_savedReloadCheck != null) {
      scheduleReloadAfterSave(_savedReloadCheck!);
    }
  }

  void _clearWatchValues() {
    ++_watchRequest;
    watches = [for (final watch in watches) DebugWatch(watch.expression)];
  }

  Future<void> addWatch(String expression) async {
    final text = expression.trim();
    if (status != DebugStatus.paused ||
        text.isEmpty ||
        text.length > 4096 ||
        watches.length >= 20) {
      throw const DebugFailure(
        'Pause and enter a watch of up to 4096 characters (maximum 20).',
      );
    }
    if (watches.any((w) => w.expression == text)) return;
    watches = [...watches, DebugWatch(text)];
    await _refreshWatches();
  }

  void removeWatch(String expression) {
    watches = watches.where((w) => w.expression != expression).toList();
    _changed();
  }

  Future<void> _refreshWatches() async {
    final connection = _connection;
    final pause = _pauseGeneration;
    final frame = frameId;
    final request = ++_watchRequest;
    if (connection == null || status != DebugStatus.paused || frame == null) {
      return;
    }
    bool current() =>
        !_disposed &&
        request == _watchRequest &&
        pause == _pauseGeneration &&
        frame == frameId &&
        status == DebugStatus.paused &&
        identical(connection, _connection);
    final expressions = watches.map((w) => w.expression).toList();
    _changed();
    for (final expression in expressions) {
      if (!current()) return;
      if (!watches.any((watch) => watch.expression == expression)) continue;
      DebugWatch watch;
      try {
        final result = await connection.request('evaluate', {
          'expression': expression,
          'frameId': frame,
          'context': 'watch',
        });
        final value = '${result['result'] ?? ''}';
        watch = DebugWatch(
          expression,
          value: value.length > 16384 ? '${value.substring(0, 16384)}…' : value,
        );
      } catch (failure) {
        final message = '$failure';
        watch = DebugWatch(
          expression,
          error: message.substring(0, message.length.clamp(0, 4096)),
        );
      }
      if (!current()) return;
      watches = [
        for (final existing in watches)
          existing.expression == expression ? watch : existing,
      ];
      _changed();
    }
  }

  Future<void> _loadPause(int generation) async {
    final pause = ++_pauseGeneration;
    try {
      final connection = _connection;
      if (connection == null) return;
      if (threadId == null) {
        final threads = await connection.request('threads');
        if (generation != _generation || pause != _pauseGeneration) return;
        threadId = _maps(threads['threads']).firstOrNull?['id'] as int?;
      }
      if (threadId == null) return;
      final response = await connection.request('stackTrace', {
        'threadId': threadId,
        'startFrame': 0,
        'levels': 100,
      });
      if (generation != _generation ||
          pause != _pauseGeneration ||
          status != DebugStatus.paused) {
        return;
      }
      frames = _maps(response['stackFrames']);
      if (frames.isNotEmpty) await selectFrame(frames.first['id'] as int);
      _changed();
    } catch (failure) {
      if (generation == _generation &&
          pause == _pauseGeneration &&
          status == DebugStatus.paused &&
          exitCode == null) {
        error = '$failure';
        _pauseFailure = true;
        _changed();
      }
    }
  }

  Future<void> selectFrame(int id) async {
    if (status != DebugStatus.paused || !frames.any((f) => f['id'] == id)) {
      return;
    }
    final pause = _pauseGeneration;
    frameId = id;
    _clearWatchValues();
    scopes = [];
    variables = [];
    final result = await _connection!.request('scopes', {'frameId': id});
    if (pause != _pauseGeneration ||
        frameId != id ||
        status != DebugStatus.paused) {
      return;
    }
    scopes = _maps(result['scopes']);
    _changed();
    await _refreshWatches();
  }

  Future<void> loadVariables(int reference) async {
    if (status != DebugStatus.paused || reference <= 0) return;
    final pause = _pauseGeneration;
    final request = ++_variablesRequest;
    final frame = frameId;
    final result = await _connection!.request('variables', {
      'variablesReference': reference,
      'start': 0,
      'count': 200,
    });
    if (request != _variablesRequest ||
        pause != _pauseGeneration ||
        frame != frameId ||
        status != DebugStatus.paused) {
      return;
    }
    variables = _maps(result['variables']);
    _changed();
  }

  Future<String> evaluate(String expression) async {
    if (status != DebugStatus.paused ||
        expression.isEmpty ||
        expression.length > 4096) {
      throw const DebugFailure(
        'Pause execution and enter an expression of up to 4096 characters.',
      );
    }
    final pause = _pauseGeneration;
    final frame = frameId;
    final connection = _connection!;
    ++_variablesRequest;
    final result = await connection.request('evaluate', {
      'expression': expression,
      'frameId': frameId,
      'context': 'repl',
    });
    if (pause != _pauseGeneration ||
        frame != frameId ||
        !identical(connection, _connection) ||
        status != DebugStatus.paused) {
      throw const DebugFailure(
        'The paused frame changed before evaluation completed.',
      );
    }
    return '${result['result'] ?? ''}';
  }

  Future<void> control(String command) async {
    if (![
      'continue',
      'next',
      'stepIn',
      'stepOut',
      'pause',
      'hotReload',
      'hotRestart',
    ].contains(command)) {
      throw const DebugFailure('Unsupported debug control.');
    }
    if (_connection == null ||
        !active ||
        status == DebugStatus.starting ||
        status == DebugStatus.stopping) {
      return;
    }
    if (command == 'hotReload' || command == 'hotRestart') {
      if (configuration?.project.kind != ProjectKind.flutter ||
          !appStarted ||
          configuration?.flutterMode != 'debug') {
        throw const DebugFailure('Wait for the Flutter application to start.');
      }
      await _flutterControl(command, 'manual');
    } else {
      if (command != 'pause' && status != DebugStatus.paused) return;
      final connection = _connection!;
      final generation = _generation;
      var thread = threadId;
      if (thread == null) {
        final result = await connection.request('threads');
        thread = _maps(result['threads']).firstOrNull?['id'] as int?;
      }
      if (thread == null || generation != _generation) return;
      final resumes = command != 'pause';
      if (resumes) {
        _continued();
        _changed();
      }
      final pause = _pauseGeneration;
      try {
        await connection.request(command, {'threadId': thread});
      } catch (_) {
        if (resumes &&
            generation == _generation &&
            pause == _pauseGeneration &&
            status == DebugStatus.running) {
          status = DebugStatus.paused;
          await _loadPause(generation);
        }
        rethrow;
      }
    }
  }

  Future<void> stop() async {
    if (!active) {
      await _release();
      return;
    }
    ++_generation;
    ++_pauseGeneration;
    _clearWatchValues();
    if (_initialized != null && !_initialized!.isCompleted) {
      _initialized!.complete();
    }
    status = DebugStatus.stopping;
    _changed();
    final connection = _connection;
    try {
      await connection
          ?.request('disconnect', {
            'terminateDebuggee': configuration?.isAttach != true,
          })
          .timeout(const Duration(seconds: 3));
    } catch (_) {
      /* The owned process tree is the final stop boundary. */
    }
    await _release();
    status = DebugStatus.terminated;
    vmService = null;
    appStarted = false;
    frames = [];
    scopes = [];
    variables = [];
    _changed();
  }

  Future<void> openDevTools({bool external = true}) async {
    if (_startingDevTools) return;
    final uri = vmService;
    final config = configuration;
    if (uri == null || config == null || !active) {
      throw const DebugFailure(
        'Wait for the local Dart or Flutter debug service.',
      );
    }
    _startingDevTools = true;
    final generation = _generation;
    try {
      final cancellation = _devToolsCancellation = Cancellation();
      final tools =
          _devTools ??
          await (_pendingDevTools = adapters.devTools(
            config,
            uri,
            cancellation,
          ));
      if (_disposed ||
          generation != _generation ||
          vmService != uri ||
          !active) {
        await tools.close();
        return;
      }
      _devTools = tools;
      if (external) await tools.open();
      _changed();
    } finally {
      _pendingDevTools = null;
      _startingDevTools = false;
    }
  }

  Future<void> _release() {
    _clearWatchValues();
    _reloadTimer?.cancel();
    _savedReloadCheck = null;
    final previous = _releasing;
    return _releasing = () async {
      await previous;
      final connection = _connection;
      final pendingAdapter = _pendingAdapter;
      final events = _events;
      final devTools = _devTools;
      _devToolsCancellation?.cancel();
      final pendingDevTools = _pendingDevTools;
      _devTools = null;
      _releasingConnection =
          connection != null ||
          pendingAdapter != null ||
          devTools != null ||
          pendingDevTools != null;
      _connection = null;
      _events = null;
      try {
        await events?.cancel();
        if (pendingAdapter != null) {
          DebugConnection? pendingConnection;
          try {
            pendingConnection = await pendingAdapter;
          } catch (_) {
            /* Adapter creation failed before ownership transfer. */
          }
          await pendingConnection?.close();
        }
        await connection?.close();
        if (pendingDevTools != null) {
          try {
            await (await pendingDevTools).close();
          } catch (_) {
            /* Cancelled startup has reaped its process. */
          }
        }
        await devTools?.close();
      } finally {
        _releasingConnection = false;
        _changed();
      }
    }();
  }

  Future<void> dispose() async {
    await stop();
    _disposed = true;
    await _changes.close();
  }
}
