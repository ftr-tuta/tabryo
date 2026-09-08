// Flutter TextEditingValue/UndoHistory are presentation state. Dartitect 1.1.0
// mistakes Flutter's services/ source directory for application infrastructure.
// ignore_for_file: dartitect_dt3121

import 'dart:async';
import 'dart:convert';

import 'package:dartitect_flutter/dartitect_flutter.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

import '../domain/document_files.dart';
import '../domain/document_formatter.dart';
import '../domain/document_recovery.dart';
import '../domain/editor_assets.dart';

final class EditorBuffer {
  EditorBuffer(this.baseline)
    : controller = TextEditingController.fromValue(
        TextEditingValue(
          text: baseline.text,
          selection: const TextSelection.collapsed(offset: 0),
        ),
      );
  DocumentSnapshot baseline;
  final TextEditingController controller;
  final undo = UndoHistoryController();
  int version = 0;
  bool webCanUndo = false;
  bool webCanRedo = false;
  bool saving = false;
  bool reviewRequired = false;
  bool formatFailed = false;
  String? error;
  String? diskText;
  bool get dirty => controller.text != baseline.text;
  String get path => baseline.path;
  String get root => baseline.root;
  void dispose() {
    controller.dispose();
    undo.dispose();
  }
}

final class EditorViewModel extends DartitectViewModel {
  EditorViewModel(this.files, {this.webAssets, this.formatter, this.recovery});
  final DocumentFiles files;
  final DocumentRecovery? recovery;
  bool recoveryEnabled = false;
  String? recoveryError;
  List<RecoveredDocument> recoveries = const [];
  Timer? _recoveryTimer;
  Future<void> _recoveryWrite = Future.value();
  bool _writingRecovery = false;
  bool _recoveryRequested = false;
  bool _recovering = false;

  Future<void> configureRecovery(bool enabled) async {
    if (_closed ||
        recovery == null ||
        (recoveryEnabled == enabled && recoveryError == null)) {
      return;
    }
    recoveryEnabled = enabled;
    _recoveryTimer?.cancel();
    try {
      if (enabled) {
        recoveries = await recovery!.pending();
        if (!await flushRecovery()) return;
      } else {
        await _recoveryWrite;
        await recovery!.save([]);
        for (final document in recoveries) {
          await recovery!.remove(document.id);
        }
        recoveries = const [];
      }
      recoveryError = recovery!.warning;
    } catch (error) {
      recoveryError =
          'Recovery storage failed: $error. Buffers remain in memory.';
    }
    if (!_closed) notifyListeners();
  }

  void _scheduleRecovery() {
    if (!recoveryEnabled || _closed) return;
    // A fixed delay (not a debounce) also checkpoints continuous typing.
    _recoveryTimer ??= Timer(const Duration(milliseconds: 350), () {
      _recoveryTimer = null;
      unawaited(flushRecovery());
    });
  }

  Future<bool> flushRecovery() async {
    if (!recoveryEnabled || recovery == null) return true;
    _recoveryTimer?.cancel();
    _recoveryTimer = null;
    _recoveryRequested = true;
    if (_writingRecovery) {
      await _recoveryWrite;
      return recoveryError == null;
    }
    _writingRecovery = true;
    _recoveryWrite = () async {
      while (_recoveryRequested && recoveryEnabled) {
        _recoveryRequested = false;
        final documents = [
          for (final buffer in _buffers.where((b) => b.dirty))
            RecoveredDocument(
              id: '',
              root: buffer.root,
              path: buffer.path,
              text: buffer.controller.text,
              diskText: buffer.baseline.text,
              newline: buffer.baseline.newline,
              bom: buffer.baseline.bom,
              start: buffer.controller.selection.baseOffset.clamp(
                0,
                buffer.controller.text.length,
              ),
              end: buffer.controller.selection.extentOffset.clamp(
                0,
                buffer.controller.text.length,
              ),
            ),
        ];
        try {
          await recovery!.save(documents);
          recoveryError = null;
        } catch (error) {
          recoveryError =
              'Recovery snapshot could not be saved: $error. Buffers remain in memory.';
        }
        if (!_closed) notifyListeners();
      }
    }();
    await _recoveryWrite;
    _writingRecovery = false;
    return recoveryError == null;
  }

  Future<void> refreshRecovery() async {
    if (!recoveryEnabled || recovery == null || _closed || _recovering) return;
    _recovering = true;
    try {
      recoveries = await recovery!.pending();
      recoveryError = recovery!.warning;
    } catch (error) {
      recoveryError =
          'Could not refresh recovery copies: $error. Existing copies were retained.';
    } finally {
      _recovering = false;
      if (!_closed) notifyListeners();
    }
  }

  Future<bool> restoreDocument(RecoveredDocument document) async {
    if (_recovering || _closed || !recoveries.contains(document)) return false;
    _recovering = true;
    try {
      if (_buffers.any((b) => p.equals(b.path, document.path))) {
        throw const DocumentFailure(
          'Close the existing tab before restoring this copy.',
        );
      }
      // The filesystem adapter reauthorizes the path and compares current disk.
      if (!await open(document.root, document.path)) return false;
      final buffer = _buffers.lastWhere((b) => p.equals(b.path, document.path));
      final changed = !document.matches(buffer.baseline);
      buffer.controller.value = TextEditingValue(
        text: document.text,
        selection: TextSelection(
          baseOffset: document.start,
          extentOffset: document.end,
        ),
      );
      buffer.reviewRequired = changed;
      if (changed) {
        buffer.diskText = buffer.baseline.text;
        buffer.error = 'Disk changed since this recovery copy. Compare and choose Keep local edits or reload before saving.';
      }
      if (!await flushRecovery()) return false;
      await recovery!.remove(document.id);
      recoveries = recoveries.where((d) => d.id != document.id).toList();
      return true;
    } catch (error) {
      recoveryError =
          'Could not restore this copy: $error. The recovery copy is retained.';
      return false;
    } finally {
      _recovering = false;
      if (!_closed) notifyListeners();
    }
  }

  Future<void> discardRecovery(RecoveredDocument document) async {
    try {
      await recovery?.remove(document.id);
      recoveries = recoveries.where((d) => d.id != document.id).toList();
    } catch (error) {
      recoveryError = '$error';
    }
    if (!_closed) notifyListeners();
  }

  /// Only called after the application's Save/Discard confirmation succeeds.
  Future<void> finishRecoverySession() async {
    _recoveryTimer?.cancel();
    _recoveryTimer = null;
    final enabled = recoveryEnabled;
    recoveryEnabled = false;
    await _recoveryWrite;
    if (enabled) await recovery?.save([]);
  }

  final DocumentFormatter? formatter;
  Map<String, String> dartFormatters = const {};
  ({String root, String executable})? _formatterFor(EditorBuffer buffer) {
    final roots =
        dartFormatters.keys
            .where(
              (root) =>
                  (p.equals(root, buffer.root) ||
                      p.isWithin(buffer.root, root)) &&
                  p.isWithin(root, buffer.path),
            )
            .toList()
          ..sort((a, b) => b.length.compareTo(a.length));
    if (roots.isEmpty || dartFormatters[roots.first]!.isEmpty) return null;
    return (root: roots.first, executable: dartFormatters[roots.first]!);
  }

  final EditorAssets? webAssets;
  Future<EditorPage> openWebEditor() => webAssets!.open();
  Future<void> Function(EditorBuffer)? synchronize;
  void Function(String)? webCommand;
  static const documentLimit = 12;
  final _buffers = <EditorBuffer>[];
  final _retired = <EditorBuffer>{};
  List<EditorBuffer> get buffers => List.unmodifiable(_buffers);
  final _selected = <String, EditorBuffer>{};
  final _epochs = <String, int>{};
  int _opening = 0;
  bool get opening => _opening != 0;
  bool _closed = false;
  Timer? _monitor;
  int _monitorEpoch = 0;
  bool _refreshing = false;
  String? workspace;
  String? message;
  EditorBuffer? get active => _selected[workspace];
  List<EditorBuffer> inWorkspace(String? root) =>
      _buffers.where((b) => root == null || p.equals(b.root, root)).toList();
  bool get hasDirty => _buffers.any((b) => b.dirty);

  void monitorExternalChanges(bool enabled) {
    _monitor?.cancel();
    _monitor = null;
    _monitorEpoch++;
    if (enabled && !_closed) {
      // Poll only the bounded set of already authorized open documents. This
      // also detects atomic replacements and nested files on Linux, where a
      // root directory watcher does not report descendant changes.
      _monitor = Timer.periodic(const Duration(seconds: 2), (_) {
        unawaited(refreshOpenFiles());
      });
    }
  }

  Future<void> refreshOpenFiles() async {
    if (_closed || _refreshing || (webAssets != null && synchronize == null)) {
      return;
    }
    _refreshing = true;
    final epoch = _monitorEpoch;
    try {
      for (final buffer in List<EditorBuffer>.of(_buffers)) {
        if (_closed || epoch != _monitorEpoch) return;
        if (!_buffers.contains(buffer) || buffer.saving) continue;
        if (!await synchronizeBuffer(buffer)) continue;
        if (_closed || !_buffers.contains(buffer)) continue;
        final version = buffer.version;
        final baseline = buffer.baseline;
        try {
          final disk = await files.open(buffer.root, buffer.path);
          if (_closed || epoch != _monitorEpoch) return;
          if (!_buffers.contains(buffer) ||
              buffer.saving ||
              version != buffer.version ||
              !identical(baseline, buffer.baseline)) {
            continue;
          }
          final changed =
              disk.text != baseline.text ||
              disk.newline != baseline.newline ||
              disk.bom != baseline.bom;
          if (!changed) {
            // Refresh the adapter's revision even if only metadata changed.
            buffer.baseline = disk;
            continue;
          }
          if (buffer.dirty) {
            buffer.diskText = disk.text;
            buffer.error = const DocumentConflict().message;
          } else {
            final selection = buffer.controller.selection;
            buffer.baseline = disk;
            buffer.controller.value = TextEditingValue(
              text: disk.text,
              selection: TextSelection(
                baseOffset: selection.baseOffset.clamp(0, disk.text.length),
                extentOffset: selection.extentOffset.clamp(0, disk.text.length),
              ),
            );
            buffer.diskText = null;
            buffer.error = null;
          }
          notifyListeners();
        } catch (error) {
          if (_closed || epoch != _monitorEpoch) return;
          if (_buffers.contains(buffer)) {
            buffer.error =
                'Could not refresh this file. Your buffer is preserved. $error';
            notifyListeners();
          }
        }
      }
    } finally {
      _refreshing = false;
    }
  }

  void selectWorkspace(String? root) {
    workspace = root;
    notifyListeners();
  }

  void select(EditorBuffer buffer) {
    if (!_buffers.contains(buffer) ||
        workspace == null ||
        !p.equals(buffer.root, workspace!)) {
      return;
    }
    _selected[buffer.root] = buffer;
    notifyListeners();
  }

  Future<bool> open(String root, String path) async {
    final epoch = _epochs[root] ?? 0;
    final existing = _buffers
        .where((b) => p.equals(b.path, path) && p.equals(b.root, root))
        .firstOrNull;
    if (existing != null) {
      select(existing);
      return true;
    }
    if (_buffers.length + _opening >= documentLimit) {
      throw const DocumentFailure(
        'Close a document before opening more (limit: 12).',
      );
    }
    _opening++;
    try {
      final snapshot = await files.open(root, path);
      if (_closed || epoch != (_epochs[root] ?? 0)) return true;
      var buffer = _buffers
          .where(
            (b) => p.equals(b.path, snapshot.path) && p.equals(b.root, root),
          )
          .firstOrNull;
      if (buffer == null) {
        buffer = EditorBuffer(snapshot);
        final owned = buffer;
        var wasDirty = false;
        var lastText = owned.controller.text;
        owned.controller.addListener(() {
          if (lastText != owned.controller.text) {
            lastText = owned.controller.text;
            owned.version++;
            _scheduleRecovery();
          }
          if (owned.dirty != wasDirty) {
            wasDirty = owned.dirty;
            notifyListeners();
          }
        });
        _buffers.add(buffer);
      }
      _selected[root] = buffer;
      message = null;
      notifyListeners();
      return true;
    } on DocumentReadOnly catch (error) {
      message = error.message;
      notifyListeners();
      return false;
    } finally {
      _opening--;
    }
  }

  void cycle(int direction) {
    final documents = inWorkspace(workspace);
    if (documents.isEmpty || active == null) return;
    select(
      documents[(documents.indexOf(active!) + direction) % documents.length],
    );
  }

  Future<bool> save(
    EditorBuffer buffer, {
    bool withoutFormatting = false,
  }) async {
    if (!_buffers.contains(buffer) || buffer.saving) return false;
    if (buffer.reviewRequired) return false;
    if (!await synchronizeBuffer(buffer)) return false;
    if (!_buffers.contains(buffer) || buffer.saving || buffer.reviewRequired) {
      return false;
    }
    buffer.saving = true;
    buffer.error = null;
    buffer.formatFailed = false;
    notifyListeners();
    try {
      final sdk = _formatterFor(buffer);
      if (!withoutFormatting &&
          sdk != null &&
          p.extension(buffer.path) == '.dart') {
        try {
          final version = buffer.version;
          final selection = buffer.controller.selection;
          final formatted = await formatter!.format(
            executable: sdk.executable,
            root: sdk.root,
            path: buffer.path,
            text: buffer.controller.text,
            start: selection.baseOffset.clamp(0, buffer.controller.text.length),
            end: selection.extentOffset.clamp(0, buffer.controller.text.length),
          );
          if (_closed || !_buffers.contains(buffer)) return false;
          if (!await synchronizeBuffer(buffer)) return false;
          if (buffer.version != version || _formatterFor(buffer) != sdk) {
            throw const DocumentFailure(
              'The document or SDK selection changed during formatting. Retry with the current buffer.',
            );
          }
          final next = TextEditingValue(
            text: formatted.text,
            selection: TextSelection(
              baseOffset: formatted.start,
              extentOffset: formatted.end,
            ),
          );
          if (inputFormatter(buffer)
                  .formatEditUpdate(buffer.controller.value, next) !=
              next) {
            throw const DocumentFailure(
              'Formatted text exceeds the document limit.',
            );
          }
          buffer.controller.value = next;
          notifyListeners();
          if (!await synchronizeBuffer(buffer) || buffer.reviewRequired) {
            return false;
          }
          if (buffer.controller.text != formatted.text) {
            throw const DocumentFailure(
              'New input arrived during formatting. Retry with the current buffer.',
            );
          }
        } catch (error) {
          if (!_closed) {
            buffer.formatFailed = true;
            buffer.error =
                '$error Your buffer was kept. Retry saving or choose Save without formatting.';
          }
          return false;
        }
      }
      if (!buffer.dirty) return true;
      final text = buffer.controller.text;
      final saved = await files.save(buffer.baseline, text);
      if (_closed) return false;
      buffer.baseline = saved;
      buffer.diskText = null;
      _scheduleRecovery();
      return !buffer.dirty;
    } catch (error) {
      if (!_closed) buffer.error = '$error';
      return false;
    } finally {
      buffer.saving = false;
      if (!_closed) notifyListeners();
    }
  }

  Future<bool> synchronizeBuffer(EditorBuffer buffer) async {
    if (_closed || !_buffers.contains(buffer)) return false;
    if (webAssets == null) return true;
    try {
      if (synchronize == null) {
        throw const DocumentFailure(
          'The code editor is not connected. Your buffer is preserved.',
        );
      }
      await synchronize!(buffer);
      return true;
    } catch (_) {
      if (_closed || !_buffers.contains(buffer)) return false;
      buffer.error = 'The code editor did not synchronize. Your buffer is preserved; reconnect before saving or closing.';
      notifyListeners();
      return false;
    }
  }

  void undoBuffer(EditorBuffer buffer) {
    if (webAssets != null) {
      webCommand?.call('undo');
    } else {
      buffer.undo.undo();
    }
  }

  void redoBuffer(EditorBuffer buffer) {
    if (webAssets != null) {
      webCommand?.call('redo');
    } else {
      buffer.undo.redo();
    }
  }

  void webHistoryChanged(EditorBuffer buffer, bool canUndo, bool canRedo) {
    if (buffer.webCanUndo == canUndo && buffer.webCanRedo == canRedo) return;
    buffer.webCanUndo = canUndo;
    buffer.webCanRedo = canRedo;
    notifyListeners();
  }

  void applyWebEdit(
    EditorBuffer buffer,
    String text,
    int start,
    int end,
    bool canUndo,
    bool canRedo,
  ) {
    if (!_buffers.contains(buffer)) return;
    buffer.controller.value = TextEditingValue(
      text: text,
      selection: TextSelection(baseOffset: start, extentOffset: end),
    );
    webHistoryChanged(buffer, canUndo, canRedo);
  }

  TextInputFormatter inputFormatter(EditorBuffer buffer) =>
      TextInputFormatter.withFunction((previous, next) {
        if (utf8
                    .encode(next.text.replaceAll('\n', buffer.baseline.newline))
                    .length +
                (buffer.baseline.bom ? 3 : 0) >
            DocumentFiles.byteLimit) {
          rejectInput(buffer);
          return previous;
        }
        return next;
      });

  void rejectInput(EditorBuffer buffer) {
    buffer.error = 'This edit exceeds 512 KiB and was not applied. The existing buffer is preserved.';
    notifyListeners();
  }

  void replacementSuperseded(EditorBuffer buffer) {
    if (!_buffers.contains(buffer)) return;
    buffer.reviewRequired = true;
    buffer.diskText ??= buffer.baseline.text;
    buffer.error = 'New input arrived before the replacement. Your local edits were kept. Review the comparison and choose Keep local edits, or reload from disk.';
    notifyListeners();
  }

  void keepLocalEdits(EditorBuffer buffer) {
    if (!_buffers.contains(buffer) || buffer.saving) return;
    buffer.reviewRequired = false;
    buffer.error = null;
    buffer.diskText = null;
    notifyListeners();
  }

  Future<void> compare(EditorBuffer buffer) async {
    try {
      final disk = await files.open(buffer.root, buffer.path);
      if (_closed || !_buffers.contains(buffer)) return;
      buffer.diskText = disk.text;
    } catch (error) {
      if (_closed || !_buffers.contains(buffer)) return;
      buffer.error = '$error';
    }
    notifyListeners();
  }

  void closeComparison(EditorBuffer buffer) {
    buffer.diskText = null;
    notifyListeners();
  }

  Future<bool> reload(EditorBuffer buffer) async {
    if (buffer.saving || !_buffers.contains(buffer)) return false;
    final version = buffer.version;
    buffer.saving = true;
    notifyListeners();
    try {
      final disk = await files.open(buffer.root, buffer.path);
      if (_closed || !_buffers.contains(buffer)) return false;
      if (buffer.version != version) {
        buffer.error = 'The document changed while reloading. Your edits are preserved; review the disk version before trying again.';
        return false;
      }
      buffer.baseline = disk;
      buffer.controller.text = disk.text;
      buffer.diskText = null;
      buffer.error = null;
      buffer.reviewRequired = false;
      notifyListeners();
      return true;
    } catch (error) {
      if (!_closed && _buffers.contains(buffer)) {
        buffer.error = '$error';
        notifyListeners();
      }
      return false;
    } finally {
      buffer.saving = false;
      if (!_closed) notifyListeners();
    }
  }

  bool close(EditorBuffer buffer, {bool discard = false}) {
    if (!_buffers.contains(buffer)) return true;
    if (buffer.saving || (buffer.dirty && !discard)) return false;
    _buffers.remove(buffer);
    _scheduleRecovery();
    if (identical(_selected[buffer.root], buffer)) {
      _selected.remove(buffer.root);
      final next = inWorkspace(buffer.root).lastOrNull;
      if (next != null) _selected[buffer.root] = next;
    }
    // Widgets can still be detaching from these controllers this frame.
    _retired.add(buffer);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_retired.remove(buffer)) buffer.dispose();
    });
    notifyListeners();
    return true;
  }

  bool closeWorkspace(String root, {bool discard = false}) {
    final owned = inWorkspace(root);
    if (owned.any((b) => b.saving || (b.dirty && !discard))) return false;
    _epochs[root] = (_epochs[root] ?? 0) + 1;
    for (final buffer in owned) {
      close(buffer, discard: discard);
    }
    return true;
  }

  @override
  Future<void> disposeAsync() async {
    await flushRecovery();
    _recoveryTimer?.cancel();
    _closed = true;
    formatter?.close();
    _monitorEpoch++;
    _monitor?.cancel();
    await webAssets?.close();
    await recovery?.close();
    for (final buffer in _buffers) {
      buffer.dispose();
    }
    _buffers.clear();
    for (final buffer in _retired) {
      buffer.dispose();
    }
    _retired.clear();
    await super.disposeAsync();
  }
}
