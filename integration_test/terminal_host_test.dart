import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:ffi/ffi.dart';
import 'package:integration_test/integration_test.dart';
import 'package:terminal_host/terminal_host.dart';

TerminalLaunchSpec command(
  String windows,
  String linux, {
  String? directory,
  Map<String, String>? environment,
  List<String> unsetEnvironment = const [],
}) => TerminalLaunchSpec(
  executable: Platform.isWindows
      ? '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}\\System32\\WindowsPowerShell\\v1.0\\powershell.exe'
      : '/bin/sh',
  arguments: Platform.isWindows
      ? ['-NoLogo', '-NoProfile', '-NonInteractive', '-Command', windows]
      : ['-c', linux],
  workingDirectory: directory ?? Directory.current.path,
  environment: environment,
  unsetEnvironment: unsetEnvironment,
);

Future<String> collect(TerminalPty pty, {int? exit}) async {
  final output = pty.output.expand((chunk) => chunk).toList();
  final code = await pty.exitCode.timeout(const Duration(seconds: 15));
  await pty.drained.timeout(const Duration(seconds: 15));
  await pty.close().timeout(const Duration(seconds: 15));
  final text = utf8.decode(await output);
  if (exit != null) expect(code, exit, reason: text);
  return text;
}

Future<int> windowsHandleCount() async {
  final count = calloc<Uint32>();
  try {
    final getCount = DynamicLibrary.open('kernel32.dll')
        .lookupFunction<
          Int32 Function(Pointer<Void>, Pointer<Uint32>),
          int Function(Pointer<Void>, Pointer<Uint32>)
        >('GetProcessHandleCount');
    expect(getCount(Pointer<Void>.fromAddress(-1), count), 1);
    return count.value;
  } finally {
    calloc.free(count);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'child standard streams belong to its PTY, including redirected parent output',
    (_) async {
      final directory = await Directory.systemTemp.createTemp('tabryo-stdio-');
      addTearDown(() => directory.delete(recursive: true));
      final state = File('${directory.path}/stdio.txt');
      final pty = TerminalPty.start(
        command(
          r"$ErrorActionPreference='Stop';[IO.File]::WriteAllText($env:TABRYO_STREAM_STATE,([Console]::IsInputRedirected.ToString()+'|'+[Console]::IsOutputRedirected.ToString()));[Console]::WriteLine('NATIVE_READY');exit 7",
          r'''test -t 0 && test -t 1 || exit 9; printf 'False|False' > "$TABRYO_STREAM_STATE"; printf 'NATIVE_READY\n'; exit 7''',
          environment: {'TABRYO_STREAM_STATE': state.path},
        ),
      );
      addTearDown(pty.close);
      expect(await collect(pty, exit: 7), contains('NATIVE_READY'));
      expect(await state.readAsString(), 'False|False');
    },
  );

  testWidgets('keeps fragmented UTF-8 and final output before drain', (
    _,
  ) async {
    final pty = TerminalPty.start(
      command(
        r"[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false);$o=[Console]::OpenStandardOutput();$o.Write([byte[]](0xE2),0,1);Start-Sleep -Milliseconds 30;$b=[byte[]](0x82,0xAC)+[Text.Encoding]::UTF8.GetBytes(' FINAL');$o.Write($b,0,$b.Length);exit 7",
        r"printf '\342'; sleep 0.03; printf '\202\254 FINAL'; exit 7",
      ),
    );
    addTearDown(pty.close);
    expect(await collect(pty, exit: 7), contains('€ FINAL'));
  });

  testWidgets(
    'preserves a Unicode cwd and environment without injecting LANG',
    (_) async {
      final parent = await Directory.systemTemp.createTemp('tabryo-unicode-');
      final directory = await Directory('${parent.path}/ação & space').create();
      addTearDown(() => parent.delete(recursive: true));
      final pty = TerminalPty.start(
        command(
          r"[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false);Write-Output $env:TABRYO_SYNTHETIC;Write-Output (Get-Location).Path;if(Test-Path Env:LANG){exit 8}",
          r'''printf '%s\n%s\n' "$TABRYO_SYNTHETIC" "$PWD"; test "${LANG+x}" != x''',
          directory: directory.path,
          environment: {'TABRYO_SYNTHETIC': 'ação & space'},
          unsetEnvironment: ['LANG'],
        ),
      );
      addTearDown(pty.close);
      final output = await collect(pty, exit: 0);
      expect(output, contains('ação & space'));
      expect(
        output.toLowerCase(),
        contains((await directory.resolveSymbolicLinks()).toLowerCase()),
      );
    },
  );

  testWidgets('delivers accepted interactive input and supports resize', (
    _,
  ) async {
    final pty = TerminalPty.start(
      command(
        r"[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false);$v=[Console]::ReadLine();[Console]::WriteLine('INPUT:'+ $v);[Console]::WriteLine('SIZE:'+ [Console]::WindowWidth+'x'+[Console]::WindowHeight)",
        r'''read -r value; printf 'INPUT:%s\n' "$value"; stty size''',
      ),
    );
    addTearDown(pty.close);
    final collected = collect(pty, exit: 0);
    pty.resize(31, 92);
    expect(pty.write(Uint8List.fromList(utf8.encode('hello PTY\r'))), isTrue);
    final output = await collected;
    expect(output, contains('INPUT:hello PTY'));
    expect(output, contains(Platform.isWindows ? 'SIZE:92x31' : '31 92'));
  });

  testWidgets(
    'paused output resumes without loss or unbounded queued messages',
    (_) async {
      final pty = TerminalPty.start(
        command(
          r"1..3000|ForEach-Object{[Console]::WriteLine('line-'+$_)};[Console]::WriteLine('LAST_MARKER')",
          r"i=1; while [ $i -le 3000 ]; do printf 'line-%s\n' $i; i=$((i+1)); done; printf 'LAST_MARKER\n'",
        ),
      );
      addTearDown(pty.close);
      final bytes = BytesBuilder();
      final sub = pty.output.listen(bytes.add);
      final done = sub.asFuture<void>();
      sub.pause();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(bytes.length, 0);
      sub.resume();
      expect(await pty.exitCode.timeout(const Duration(seconds: 20)), 0);
      await done.timeout(const Duration(seconds: 20));
      expect(utf8.decode(bytes.takeBytes()), contains('LAST_MARKER'));
      await pty.close();
    },
  );

  testWidgets('close drains paused and unobserved output and is idempotent', (
    _,
  ) async {
    for (final observed in [false, true]) {
      final pty = TerminalPty.start(
        command(
          r"while($true){[Console]::WriteLine('tick');Start-Sleep -Milliseconds 5}",
          r"while :; do printf 'tick\n'; sleep 0.01; done",
        ),
      );
      addTearDown(pty.close);
      if (observed) pty.output.listen((_) {}).pause();
      expect(pty.write(Uint8List(sessionInputLimit + 1)), isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await pty.close().timeout(const Duration(seconds: 10));
      await pty.close().timeout(const Duration(seconds: 1));
      expect(pty.write(Uint8List.fromList([1])), isFalse);
      pty.resize(24, 80);
      expect(pty.pid, greaterThan(0));
    }
  });

  testWidgets('reports spawn failure and rejects invalid launch data', (
    _,
  ) async {
    expect(
      () => TerminalPty.start(
        TerminalLaunchSpec(
          executable: '${Directory.current.path}/missing',
          workingDirectory: Directory.current.path,
        ),
      ),
      throwsStateError,
    );
    expect(
      () => TerminalPty.start(
        const TerminalLaunchSpec(executable: 'relative', workingDirectory: '.'),
      ),
      throwsArgumentError,
    );
    final spec = command('exit 0', 'exit 0');
    expect(
      () => TerminalPty.start(
        TerminalLaunchSpec(
          executable: spec.executable,
          workingDirectory: spec.workingDirectory,
          arguments: ['\x00'],
        ),
      ),
      throwsArgumentError,
    );
  });

  if (Platform.isWindows) {
    testWidgets(
      'launches cmd and bat paths with literal spaces and shell metacharacters',
      (_) async {
        final parent = await Directory.systemTemp.createTemp('tabryo-script-');
        addTearDown(() => parent.delete(recursive: true));
        for (final extension in ['cmd', 'bat']) {
          final file = File('${parent.path}/ação & command.$extension');
          await file.writeAsString(
            '@echo off\r\nchcp 65001 >nul\r\necho "%~1"\r\nexit /b 3\r\n',
          );
          final pty = TerminalPty.start(
            TerminalLaunchSpec(
              executable: file.path,
              arguments: ['space & pipe | caret ^ bang !'],
              workingDirectory: parent.path,
            ),
          );
          addTearDown(pty.close);
          expect(
            await collect(pty, exit: 3),
            contains('space & pipe | caret ^ bang !'),
          );
        }
      },
    );
  }

  testWidgets(
    '100 sessions finish and release without accumulating owned child processes',
    (_) async {
      // Initialize the SDK/ConPTY thread pools before measuring retained owners.
      final warmup = TerminalPty.start(
        command("[Console]::WriteLine('warmup')", "printf 'warmup\\n'"),
      );
      expect(await collect(warmup, exit: 0), contains('warmup'));
      final before = Platform.isLinux
          ? await Directory('/proc/self/fd').list().length
          : await windowsHandleCount();
      final childPids = <int>[];
      for (var index = 0; index < 100; index++) {
        final spec = Platform.isWindows
            ? TerminalLaunchSpec(
                executable:
                    Platform.environment['ComSpec'] ??
                    r'C:\Windows\System32\cmd.exe',
                arguments: ['/d', '/c', 'echo cycle-$index'],
                workingDirectory: Directory.current.path,
              )
            : command('', "printf 'cycle-$index\\n'");
        final pty = TerminalPty.start(spec);
        childPids.add(pty.pid);
        expect(await collect(pty, exit: 0), contains('cycle-$index'));
        await pty.close();
      }
      if (Platform.isLinux) {
        expect(
          await Directory('/proc/self/fd').list().length,
          lessThanOrEqualTo(before + 3),
        );
        for (final child in childPids) {
          expect(await Directory('/proc/$child').exists(), isFalse);
        }
      } else {
        final after = await windowsHandleCount();
        debugPrint(
          'Windows process handles after warmup: $before; after 100 closed sessions: $after',
        );
        expect(after, lessThanOrEqualTo(before + 4));
        final alive = await Process.run(command('', '').executable, [
          '-NoLogo',
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          'Get-Process -Id ${childPids.join(',')} -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id',
        ]);
        expect('${alive.stdout}'.trim(), isEmpty);
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
