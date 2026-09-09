import 'dart:convert';
import 'dart:io';

import 'owned_process.dart';

/// Dart quotes Windows arguments containing whitespace. Other cmd metacharacters
/// must not reach the shell unquoted; percent/caret expansion is never allowed.
List<String> windowsBatchArguments(String executable, List<String> arguments) {
  for (final value in [executable, ...arguments]) {
    if (RegExp('["%^\r\n\u0000]').hasMatch(value) ||
        (RegExp(r'[&|<>()]').hasMatch(value) &&
            !RegExp(r'[ \t]').hasMatch(value))) {
      throw const FormatException(
        'Unsupported command-script character. Use paths without shell metacharacters.',
      );
    }
  }
  return ['/d', '/s', '/v:off', '/c', 'call', executable, ...arguments];
}

/// Imports only compiler search paths from a selected Visual Studio installation.
/// The host environment is never persisted or exposed in operation output.
Future<Map<String, String>> nativeToolEnvironment(
  String? script,
  String root,
) async {
  if (script == null) return const {};
  if (!Platform.isWindows ||
      !File(script).isAbsolute ||
      !await File(script).exists() ||
      !script.toLowerCase().endsWith('vsdevcmd.bat') ||
      RegExp('["%\r\n\u0000]').hasMatch(script)) {
    throw const FormatException(
      'Select the installed Visual Studio Common7/Tools/VsDevCmd.bat.',
    );
  }
  final child = await OwnedProcess.start(
    '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}\\System32\\cmd.exe',
    [
      ...windowsBatchArguments(script, ['-arch=x64', '-host_arch=x64']),
      '>nul',
      '&&',
      'set',
      'INCLUDE',
      '&&',
      'set',
      'LIB',
      '&&',
      'set',
      'PATH',
    ],
    root,
  );
  final output = StringBuffer();
  var size = 0;
  final out = child.process.stdout
      .transform(const Utf8Decoder(allowMalformed: true))
      .listen((text) {
        size += text.length;
        if (size <= 256 * 1024) output.write(text);
      })
      .asFuture<void>();
  final errors = child.process.stderr.drain<void>();
  final done = Future.wait<Object?>([
    out,
    errors,
    child.process.exitCode.then((code) async {
      await child.close();
      return code;
    }),
  ]);
  try {
    await child.process.stdin.close();
    final results = await done.timeout(const Duration(seconds: 30));
    if (results.last != 0 || size > 256 * 1024) {
      throw const FormatException(
        'Visual Studio could not initialize a bounded C++ compiler environment.',
      );
    }
    final values = <String, String>{};
    for (final line in const LineSplitter().convert(output.toString())) {
      final index = line.indexOf('=');
      if (index < 0) continue;
      final key = line.substring(0, index).toUpperCase();
      if (const {'PATH', 'INCLUDE', 'LIB', 'LIBPATH'}.contains(key)) {
        values[key] = line.substring(index + 1);
      }
    }
    if (!values.containsKey('INCLUDE') || !values.containsKey('LIB')) {
      throw const FormatException(
        'The selected Visual Studio installation has no C++ SDK environment.',
      );
    }
    return values;
  } finally {
    await child.close();
  }
}
