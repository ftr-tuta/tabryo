import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../domain/collaboration.dart';
import 'managed_codex_session.dart';

Directory collaborationDirectory() {
  final override = Platform.environment['TABRYO_COLLABORATION_DIRECTORY'];
  if (override != null && p.isAbsolute(override)) return Directory(override);
  final base = Platform.isWindows
      ? Platform.environment['LOCALAPPDATA']
      : Platform.environment['XDG_STATE_HOME'];
  final home =
      Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'];
  if (base == null && home == null) {
    throw const CollaborationFailure(
      'A private user data directory is required.',
    );
  }
  return Directory(
    p.join(base ?? p.join(home!, '.local', 'state'), 'Tabryo', 'collaboration'),
  );
}

final class LocalCollaborationClient implements CollaborationClient {
  LocalCollaborationClient({
    Directory? directory,
    this.serviceExecutable,
    this.serviceArguments = const ['--collaboration-service'],
  }) : directory = directory ?? collaborationDirectory();
  final Directory directory;
  final String? serviceExecutable;
  final List<String> serviceArguments;
  Uri? _endpoint;
  String? _token;
  final HttpClient _http = HttpClient()..findProxy = ((_) => 'DIRECT');

  Future<bool> _discover() async {
    try {
      final file = File(p.join(directory.path, 'service.json'));
      if (await file.length() > 4096) return false;
      final value = jsonDecode(await file.readAsString()) as Map;
      final endpoint = Uri.parse(value['endpoint'] as String);
      if (endpoint.scheme != 'http' ||
          endpoint.host != '127.0.0.1' ||
          endpoint.port == 0 ||
          endpoint.userInfo.isNotEmpty ||
          endpoint.hasQuery ||
          endpoint.hasFragment ||
          endpoint.path.isNotEmpty) {
        return false;
      }
      _endpoint = endpoint;
      _token = value['token'] as String;
      await call('snapshot').timeout(const Duration(seconds: 2));
      return true;
    } catch (_) {
      _endpoint = null;
      _token = null;
      return false;
    }
  }

  @override
  Future<void> connect({bool start = false}) async {
    if (await _discover()) return;
    if (!start) {
      throw CollaborationFailure(
        'Collaboration service is stopped. Start it to connect sessions.',
        serviceAbsent: !await File(p.join(directory.path, 'service.json'))
            .exists(),
      );
    }
    final executable = serviceExecutable ?? Platform.resolvedExecutable;
    if (p.basename(executable).toLowerCase().contains('flutter_tester')) {
      throw const CollaborationFailure(
        'Use the built Tabryo application to start the background service.',
      );
    }
    final environment = {
      ...Platform.environment,
      'TABRYO_COLLABORATION_DIRECTORY': directory.path,
    };
    for (final key in collaborationEnvironmentKeys.where(
      (key) => key != 'TABRYO_COLLABORATION_DIRECTORY',
    )) {
      environment.remove(key);
    }
    await Process.start(
      executable,
      serviceArguments,
      mode: ProcessStartMode.detached,
      environment: environment,
      includeParentEnvironment: false,
      workingDirectory: p.dirname(executable),
    );
    for (var attempt = 0; attempt < 100; attempt++) {
      if (await _discover()) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw const CollaborationFailure(
      'The background service did not start. Check the installed Tabryo build and its data directory.',
    );
  }

  @override
  Future<Json> call(String operation, [Json arguments = const {}]) async {
    final endpoint = _endpoint;
    if (endpoint == null) {
      throw const CollaborationFailure(
        'Connect to the collaboration service first.',
      );
    }
    try {
      final request = await _http
          .postUrl(endpoint.resolve('/control'))
          .timeout(const Duration(seconds: 5));
      request.followRedirects = false;
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_token');
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({'operation': operation, 'arguments': arguments}),
      );
      final response = await request.close().timeout(
        const Duration(seconds: 90),
      );
      if (response.statusCode != 200) {
        await response.drain<void>();
        throw const CollaborationFailure(
          'Service unavailable or authorization expired. Reconnect.',
        );
      }
      final bytes = <int>[];
      await for (final part in response.timeout(const Duration(seconds: 10))) {
        if (bytes.length + part.length > 4 * 1024 * 1024) {
          throw const CollaborationFailure(
            'Service response exceeded its limit.',
          );
        }
        bytes.addAll(part);
      }
      final value = jsonDecode(utf8.decode(bytes)) as Map;
      if (value['error'] is String) {
        throw CollaborationFailure(value['error'] as String);
      }
      return Map<String, Object?>.from(value['result'] as Map);
    } on CollaborationFailure {
      rethrow;
    } catch (_) {
      throw const CollaborationFailure(
        'Connection lost. Check the saved state before retrying an operation.',
      );
    }
  }

  @override
  void close() => _http.close(force: true);
}
