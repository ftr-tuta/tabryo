import 'dart:async';
import 'dart:convert';

import 'package:path/path.dart' as p;

import '../domain/game_workspace.dart';

/// One project lease contains a dependency-ordered group of owned processes.
/// A running editor/server never makes another project build safe to start.
final class GameService {
  GameService(this.files, this.processes);
  final GameWorkspaceFiles files;
  final GameProcesses processes;
  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;
  final List<GameRun> runs = [];
  final _owned = <GameProcessRun, GameProcess>{};
  final _ready = <GameProcessRun, Completer<void>>{};
  final _retiring = <GameProcessRun, Future<void>>{};
  final _stopping = <GameRun, Future<void>>{};
  final _settling = <GameRun>{};
  final _launching = <GameRun, Future<void>>{};
  final _readinessTimers = <GameProcessRun, Timer>{};
  bool _disposed = false;
  Iterable<String> get reservations => runs
      .where((r) => r.active || !r.complete)
      .map((r) => r.plan.workspace.project.directory);
  bool ownsPid(String directory, int pid) => runs.any(
    (run) =>
        !run.stopped &&
        run.error == null &&
        p.equals(run.plan.workspace.project.directory, directory) &&
        run.processes.any(
          (entry) =>
              entry.active && entry.pid == pid && _owned.containsKey(entry),
        ),
  );
  void changed() {
    if (!_disposed) _changes.add(null);
  }

  Future<GameRun> start(GamePlan plan) async {
    if (_disposed) throw const GameFailure('Game service is closed.');
    final root = plan.workspace.project.directory;
    if (reservations.any(
      (r) => p.equals(r, root) || p.isWithin(r, root) || p.isWithin(root, r),
    )) {
      throw const GameFailure(
        'Stop the current game operation before starting another.',
      );
    }
    if (plan.processes.isEmpty ||
        plan.processes.length > 25 ||
        plan.processes.map((p) => p.name).toSet().length !=
            plan.processes.length) {
      throw const GameFailure('Choose 1–25 uniquely named processes.');
    }
    final names = <String>{};
    for (final spec in plan.processes) {
      if (spec.dependsOn.any((name) => !names.contains(name))) {
        throw const GameFailure(
          'Process dependencies must precede their dependents.',
        );
      }
      names.add(spec.name);
    }
    if (runs.length >= 20) {
      final expired = runs.where((r) => r.complete && !r.active).firstOrNull;
      if (expired == null) {
        throw const GameFailure('Close an existing game operation.');
      }
      runs.remove(expired);
      _stopping.remove(expired);
    }
    final run = GameRun(plan);
    runs.add(run);
    changed();
    final launch = _launch(run);
    _launching[run] = launch;
    try {
      await launch;
    } finally {
      _launching.remove(run);
    }
    return run;
  }

  Future<void> _launch(GameRun run) async {
    try {
      await files.validatePlan(run.plan);
      for (final entry in run.processes) {
        for (final dependency in entry.spec.dependsOn) {
          final other = run.processes.firstWhere(
            (r) => r.spec.name == dependency,
          );
          final ready = _ready[other];
          if (ready == null) {
            throw const GameFailure('Dependency was not started.');
          }
          await ready.future.timeout(
            other.spec.readyTimeout,
            onTimeout: () {
              throw GameFailure('${other.spec.name} did not report readiness.');
            },
          );
          if (run.stopped ||
              run.error != null ||
              (!other.active && other.state != GameProcessState.passed)) {
            throw GameFailure('${other.spec.name} is unavailable.');
          }
        }
        if (run.stopped || run.error != null || _disposed) break;
        final child = await processes.start(
          entry.spec.launch,
          environmentScript: entry.spec.environmentScript,
        );
        _owned[entry] = child;
        entry.pid = child.pid;
        entry.state = GameProcessState.running;
        final ready = _ready[entry] = Completer<void>();
        final stdout = StringBuffer();
        var stdoutBytes = 0;
        var line = '';
        var readinessTail = '';
        void output(String text, bool errorStream) {
          if (!errorStream && run.plan.labRequest != null) {
            stdoutBytes += utf8.encode(text).length;
            if (stdoutBytes <= 1024 * 1024) {
              stdout.write(text);
            } else {
              entry.error = 'Native laboratory output exceeds 1 MiB.';
              run.error ??= entry.error;
              unawaited(_stop(run));
            }
          }
          entry.output += text;
          if (entry.output.length > 128 * 1024) {
            entry.output = entry.output.substring(
              entry.output.length - 128 * 1024,
            );
            entry.outputLimited = true;
          }
          final marker = entry.spec.readyText;
          if (!ready.isCompleted && marker != null) {
            readinessTail += text;
            if (readinessTail.contains(marker)) {
              entry.state = GameProcessState.ready;
              _readinessTimers.remove(entry)?.cancel();
              ready.complete();
            }
            if (readinessTail.length > 8192) {
              readinessTail = readinessTail.substring(
                readinessTail.length - 8192,
              );
            }
          }
          line += text;
          final parts = line.split('\n');
          line = parts.removeLast();
          if (line.length > 16384) line = line.substring(line.length - 16384);
          for (final part in parts) {
            final problem = gameProblem(
              part,
              run.plan.workspace.project.directory,
            );
            if (problem != null && run.problems.length < 1000) {
              run.problems.add(problem);
            }
          }
          changed();
        }

        final outDone = child.stdout
            .transform(const Utf8Decoder(allowMalformed: true))
            .listen((s) => output(s, false))
            .asFuture<void>();
        final errDone = child.stderr
            .transform(const Utf8Decoder(allowMalformed: true))
            .listen((s) => output(s, true))
            .asFuture<void>();
        if (entry.spec.readyText == null && entry.spec.persistent) {
          ready.complete();
        }
        _retiring[entry] = _retire(run, entry, child, outDone, errDone, stdout);
        if (entry.spec.readyText != null && !ready.isCompleted) {
          _readinessTimers[entry] = Timer(entry.spec.readyTimeout, () {
            if (!ready.isCompleted && entry.active) {
              entry.error = '${entry.spec.name} did not report readiness.';
              run.error ??= entry.error;
              unawaited(_stop(run));
            }
          });
        }
        if (run.stopped || run.error != null || _disposed) {
          await child.close();
          break;
        }
        try {
          await child.input(entry.spec.input);
        } catch (error) {
          if (entry.spec.input != null) rethrow;
        }
        changed();
      }
    } catch (error) {
      if (!run.stopped) run.error ??= '$error';
      await _stop(run);
    } finally {
      run.starting = false;
      for (final entry in run.processes.where(
        (r) => r.state == GameProcessState.starting,
      )) {
        entry.state = GameProcessState.stopped;
      }
      await _settle(run);
      changed();
    }
  }

  Future<void> _retire(
    GameRun run,
    GameProcessRun entry,
    GameProcess child,
    Future<void> out,
    Future<void> err,
    StringBuffer stdout,
  ) async {
    try {
      entry.exitCode = await child.exitCode;
      // Retire descendants before waiting for inherited output pipes to close.
      await child.close();
      await Future.wait([out, err]);
      if (entry.state != GameProcessState.stopped) {
        if (entry.spec.readyText != null &&
            entry.state != GameProcessState.ready) {
          entry.error ??=
              '${entry.spec.name} exited before reporting readiness.';
        }
        entry.state = entry.exitCode == 0 && entry.error == null
            ? GameProcessState.passed
            : GameProcessState.failed;
        if (entry.state == GameProcessState.failed) {
          run.error ??=
              '${entry.spec.name} exited with ${entry.exitCode}: ${entry.error ?? 'see process output'}';
        }
        if (entry.spec.persistent && run.processes.length > 1 && !run.stopped) {
          run.error ??= '${entry.spec.name} ended during the session.';
        }
      }
      if (run.plan.labRequest != null &&
          entry.state == GameProcessState.passed &&
          run.error == null) {
        final result = LabResult.parse(
          stdout.toString(),
          run.plan.fingerprint!,
        );
        final requested = (run.plan.labRequest!['cases'] as List)
            .map((c) => (c as Map)['id'])
            .toSet();
        if (result.cases.length != requested.length ||
            !result.cases.every((c) => requested.contains(c['id']))) {
          throw const GameFailure(
            'Native laboratory response does not match the requested cases.',
          );
        }
        if (await files.fingerprint(run.plan.workspace) != result.fingerprint) {
          throw const GameFailure(
            'Rules or data changed while the laboratory was running.',
          );
        }
        run.lab = result;
      }
    } catch (error) {
      if (!run.stopped) {
        entry.state = GameProcessState.failed;
        entry.error = '$error';
        run.error ??= '$error';
      }
    } finally {
      _readinessTimers.remove(entry)?.cancel();
      _owned.remove(entry);
      final ready = _ready[entry];
      if (ready != null && !ready.isCompleted) ready.complete();
      if (run.error != null) unawaited(_stop(run));
      await _settle(run);
      changed();
    }
  }

  Future<void> _settle(GameRun run) async {
    if (run.active ||
        run.processes.any(_owned.containsKey) ||
        run.complete ||
        !_settling.add(run)) {
      return;
    }
    try {
      if (!run.stopped && run.error == null) {
        try {
          await files.verifyOutputs(run.plan);
        } catch (error) {
          run.error ??= '$error';
        }
      }
      if (run.plan.testReport && !run.stopped) {
        try {
          run.tests = await files.report(run.plan);
          if (run.tests?.complete != true || run.tests?.successful != true) {
            run.error ??= 'Native tests failed or did not complete.';
          }
        } catch (error) {
          run.error ??= '$error';
        }
      }
      run.complete = true;
      for (final entry in run.processes) {
        _ready.remove(entry);
        _retiring.remove(entry);
      }
    } finally {
      _settling.remove(run);
      changed();
    }
  }

  Future<void> _stop(GameRun run) => _stopping[run] ??= () async {
    for (final entry in run.processes) {
      _readinessTimers.remove(entry)?.cancel();
      if (entry.active) entry.state = GameProcessState.stopped;
      final ready = _ready[entry];
      if (ready != null && !ready.isCompleted) ready.complete();
    }
    for (final entry in run.processes) {
      try {
        await _owned[entry]?.close();
      } catch (error) {
        run.error ??= 'Could not retire ${entry.spec.name}: $error';
      }
    }
    changed();
  }();

  Future<void> stop(GameRun run) async {
    if (run.complete && !run.active) return;
    run.stopped = true;
    await _stop(run);
    await _launching[run];
    await Future.wait([
      for (final entry in run.processes)
        if (_retiring[entry] != null) _retiring[entry]!,
    ]);
    await _settle(run);
  }

  Future<void> stopWorkspace(String root) async {
    for (final run
        in runs
            .where((r) => r.plan.workspace.project.workspace == root)
            .toList()) {
      await stop(run);
    }
  }

  Future<void> dispose() async {
    for (final run in runs.toList()) {
      await stop(run);
    }
    _disposed = true;
    await _changes.close();
  }
}

GameProblem? gameProblem(String line, String root) {
  final windows = RegExp(
    r'^(.+?)\((\d+)(?:,(\d+))?\)\s*:\s*(?:fatal )?(?:error|warning)\b',
    caseSensitive: false,
  ).firstMatch(line);
  final clang = RegExp(
    r'^(.+?):(\d+):(\d+):\s*(?:fatal )?(?:error|warning)\b',
    caseSensitive: false,
  ).firstMatch(line);
  final match = windows ?? clang;
  if (match != null) {
    final path = p.normalize(
      p.isAbsolute(match.group(1)!)
          ? match.group(1)!
          : p.join(root, match.group(1)!),
    );
    return GameProblem(
      line.contains('UnrealHeaderTool') || line.contains('generated.h')
          ? GameProblemKind.unrealHeader
          : GameProblemKind.compiler,
      line,
      path: p.isWithin(root, path) ? path : null,
      line: int.tryParse(match.group(2)!),
      column: int.tryParse(match.group(3) ?? '1') ?? 1,
    );
  }
  if (!RegExp(r'\b(Error|Fatal|Warning):').hasMatch(line)) return null;
  final kind = line.contains('LogAutomation')
      ? GameProblemKind.test
      : line.contains('LogAsset') ||
            line.contains('LogLinker') ||
            line.contains('LogDataValidation')
      ? GameProblemKind.asset
      : line.contains('UnrealHeaderTool')
      ? GameProblemKind.unrealHeader
      : GameProblemKind.runtime;
  return GameProblem(kind, line);
}
