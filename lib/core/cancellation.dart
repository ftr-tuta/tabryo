import 'dart:async';

final class Cancelled implements Exception {
  const Cancelled();
  @override
  String toString() => 'Operation cancelled.';
}

final class Cancellation {
  bool _cancelled = false;
  final _signal = Completer<void>();
  bool get isCancelled => _cancelled;
  Future<void> get whenCancelled => _signal.future;
  void cancel() {
    if (!_cancelled) {
      _cancelled = true;
      _signal.complete();
    }
  }

  void check() {
    if (_cancelled) throw const Cancelled();
  }
}

final class AsyncGate {
  AsyncGate(this.capacity);
  final int capacity;
  int _active = 0;
  final _queue = <Completer<void>>[];
  Future<void Function()> acquire() async {
    if (_active >= capacity) {
      final pending = Completer<void>();
      _queue.add(pending);
      await pending.future;
    } else {
      _active++;
    }
    var released = false;
    return () {
      if (released) return;
      released = true;
      if (_queue.isNotEmpty) {
        _queue.removeAt(0).complete();
      } else {
        _active--;
      }
    };
  }
}
