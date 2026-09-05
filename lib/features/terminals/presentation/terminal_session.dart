import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:xterm2/xterm.dart';

import '../domain/terminal_ports.dart';

enum SessionStatus { running, closing, exited, failed }

final class TerminalSession extends ChangeNotifier {
  TerminalSession({
    required this.id,
    required this.title,
    required this.spec,
    required PtyHost host,
    Future<void> Function()? onFinished,
  }) : _process = host.start(spec),
       terminal = BoundedTerminal(
         maxLines: 2000,
         onClipboardStore: (_, _) {},
         onClipboardQuery: (_) => null,
         onOpenUrl: (_) {},
         onFocusRequest: () {},
         onNotification: (_, _) {},
       ) {
    terminal.onOutput = _send;
    terminal.onResize = (columns, rows, _, _) => _process.resize(rows, columns);
    _outputDone = _process.output
        .cast<List<int>>()
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(
          (value) {
            terminal.write(value);
            if (!visible) {
              unseenOutput = true;
              notifyListeners();
            }
          },
          onError: (Object error) {
            message = '$error';
          },
        )
        .asFuture<void>();
    _finished = () async {
      try {
        exitCode = await _process.exitCode;
        await _process.drained;
        await _outputDone;
        await _process.close();
        status = SessionStatus.exited;
        terminal.write('\r\n[Process exited: $exitCode]\r\n');
      } catch (error) {
        status = SessionStatus.failed;
        message = '$error';
      } finally {
        try {
          await onFinished?.call();
        } catch (error) {
          message = '$error';
        }
        if (!_disposed) notifyListeners();
      }
    }();
  }

  final int id;
  final String title;
  final LaunchSpec spec;
  final PtyProcess _process;
  final Terminal terminal;
  late final Future<void> _outputDone;
  late final Future<void> _finished;
  SessionStatus status = SessionStatus.running;
  int? exitCode;
  String? message;
  bool unseenOutput = false;
  bool visible = true;
  bool _disposed = false;
  Future<void>? _closing;
  int get pid => _process.pid;
  Future<void> get finished => _finished;

  void _send(String value) {
    if (status != SessionStatus.running) return;
    final bytes = Uint8List.fromList(utf8.encode(value));
    if (!_process.write(bytes)) {
      message = 'Input was not accepted: the terminal input queue is full. Retry a smaller paste.';
      notifyListeners();
    }
  }

  void markVisible(bool value) {
    visible = value;
    if (value) unseenOutput = false;
  }

  Future<void> close() => _closing ??= () async {
    if (status == SessionStatus.running) status = SessionStatus.closing;
    await _process.close();
    await _finished;
  }();

  @override
  void dispose() {
    _disposed = true;
    terminal.onOutput = null;
    terminal.onResize = null;
    terminal.dispose();
    super.dispose();
  }
}

// Four Uint32 values per cell in xterm2. Bounding both dimensions limits the
// main and alternate buffers even after a very wide window has been resized.
final class BoundedTerminal extends Terminal {
  BoundedTerminal({
    super.maxLines = 2000,
    super.onClipboardStore,
    super.onClipboardQuery,
    super.onOpenUrl,
    super.onFocusRequest,
    super.onNotification,
  });
  static const maxColumns = 160;
  static const maxRows = 100;
  @override
  void resize(
    int newWidth,
    int newHeight, [
    int? pixelWidth,
    int? pixelHeight,
  ]) => super.resize(
    newWidth.clamp(1, maxColumns),
    newHeight.clamp(1, maxRows),
    pixelWidth,
    pixelHeight,
  );
}
