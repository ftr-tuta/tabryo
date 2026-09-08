import 'package:dartitect_flutter/dartitect_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

import '../domain/document_files.dart';
import '../domain/editor_assets.dart';

final class EditorBuffer {
  EditorBuffer(this.baseline)
    : controller = TextEditingController.fromValue(
        // Flutter editing state is presentation state, not an infrastructure model.
        // ignore: dartitect_dt3121
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
  EditorViewModel(this.files, {this.webAssets});
  final DocumentFiles files;
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
  String? workspace;
  String? message;
  EditorBuffer? get active => _selected[workspace];
  List<EditorBuffer> inWorkspace(String? root) =>
      _buffers.where((b) => root == null || p.equals(b.root, root)).toList();
  bool get hasDirty => _buffers.any((b) => b.dirty);

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

  Future<bool> save(EditorBuffer buffer) async {
    if (!_buffers.contains(buffer) || buffer.saving) return false;
    if (!await synchronizeBuffer(buffer)) return false;
    if (!_buffers.contains(buffer) || buffer.saving) return false;
    if (!buffer.dirty) return true;
    buffer.saving = true;
    buffer.error = null;
    final text = buffer.controller.text;
    notifyListeners();
    try {
      final saved = await files.save(buffer.baseline, text);
      if (_closed) return false;
      buffer.baseline = saved;
      buffer.diskText = null;
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

  void rejectInput(EditorBuffer buffer) {
    buffer.error = 'This edit exceeds 512 KiB and was not applied. The existing buffer is preserved.';
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
    buffer.saving = true;
    notifyListeners();
    try {
      final disk = await files.open(buffer.root, buffer.path);
      if (_closed || !_buffers.contains(buffer)) return false;
      buffer.baseline = disk;
      buffer.controller.text = disk.text;
      buffer.diskText = null;
      buffer.error = null;
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
    _closed = true;
    await webAssets?.close();
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
