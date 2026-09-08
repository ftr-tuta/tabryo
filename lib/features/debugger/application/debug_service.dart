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
  DebugConfiguration? configuration;
  DebugStatus status = DebugStatus.idle;
  String? error;
  String output = '';
  int? threadId;
  int? frameId;
  int? exitCode;
  int stopCount = 0;
  Uri? vmService;
  bool appStarted = false;
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
    'request': 'launch',
    'type': config.project.kind == ProjectKind.python ? 'python' : 'dart',
    'cwd': config.project.directory,
    if (config.pythonModule == null)
      'program': config.program
    else
      'module': config.pythonModule,
    'args': config.arguments,
    'noDebug': config.noDebug,
    if (config.project.kind == ProjectKind.python) ...{
      'python': config.tools[ProjectTool.python],
      'console': 'internalConsole',
      'redirectOutput': true,
      'subProcess': false,
      'justMyCode': true,
      'django': config.django,
      'env': {'PYTHONNOUSERSITE': '1', 'PYTHONUNBUFFERED': '1'},
    } else ...{
      'debugSdkLibraries': false,
      'debugExternalPackageLibraries': false,
      'evaluateGettersInDebugViews': false,
      'evaluateToStringInDebugViews': false,
      'sendLogsToClient': false,
      if (config.project.kind == ProjectKind.flutter)
        'toolArgs': ['--no-pub', '--device-id', config.device!],
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
    configuration = config;
    status = DebugStatus.starting;
    error = null;
    output = '';
    exitCode = null;
    vmService = null;
    appStarted = false;
    frames = [];
    scopes = [];
    variables = [];
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
      Object? launchError;
      final launch = connection
          .request('launch', launchArguments(config))
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
          'breakpoints': [
            for (final line in entry.value) {'line': line},
          ],
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
        status = DebugStatus.paused;
        stopCount++;
        frames = [];
        scopes = [];
        variables = [];
        threadId = body['threadId'] is int ? body['threadId'] as int : null;
        unawaited(_loadPause(generation));
      case 'continued':
        status = DebugStatus.running;
        _pauseGeneration++;
        frames = [];
        scopes = [];
        variables = [];
        frameId = null;
      case 'exited':
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
        status = DebugStatus.terminated;
        _pauseGeneration++;
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
      if (generation == _generation && pause == _pauseGeneration) {
        error = '$failure';
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
    ++_variablesRequest;
    final result = await _connection!.request('evaluate', {
      'expression': expression,
      'frameId': frameId,
      'context': 'repl',
    });
    if (pause != _pauseGeneration) {
      throw const DebugFailure(
        'Execution resumed before evaluation completed.',
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
      if (configuration?.project.kind != ProjectKind.flutter || !appStarted) {
        throw const DebugFailure('Wait for the Flutter application to start.');
      }
      await _connection!.request(command, {'reason': 'manual'});
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
      await connection.request(command, {'threadId': thread});
    }
  }

  Future<void> stop() async {
    if (!active) {
      await _release();
      return;
    }
    ++_generation;
    ++_pauseGeneration;
    if (_initialized != null && !_initialized!.isCompleted) {
      _initialized!.complete();
    }
    status = DebugStatus.stopping;
    _changed();
    final connection = _connection;
    try {
      await connection
          ?.request('disconnect', {'terminateDebuggee': true})
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

  Future<void> openDevTools() async {
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
      await tools.open();
      _changed();
    } finally {
      _pendingDevTools = null;
      _startingDevTools = false;
    }
  }

  Future<void> _release() {
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
