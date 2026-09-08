import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../domain/document_files.dart';
import 'editor_view_model.dart';

/// The caller closes only after this returns true; Cancel never drops a buffer.
Future<bool> confirmDocumentClose(
  BuildContext context,
  EditorViewModel editor,
  List<EditorBuffer> buffers,
) async {
  if (buffers.any((b) => b.saving)) return false;
  final dirty = buffers.where((b) => b.dirty).toList();
  if (dirty.isEmpty) return true;
  final choice = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Unsaved changes'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Text(
            'Save these documents before closing?\n\n${dirty.map((b) => b.path).join('\n')}',
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, 'discard'),
          child: const Text('Discard changes'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, 'save'),
          child: const Text('Save changes'),
        ),
      ],
    ),
  );
  if (choice == 'discard') return true;
  if (choice != 'save') return false;
  for (final buffer in dirty) {
    if (!await editor.save(buffer)) {
      editor.select(buffer);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${buffer.path}: ${buffer.error ?? 'Unsaved changes remain.'}',
            ),
          ),
        );
      }
      return false;
    }
  }
  return !buffers.any((b) => b.dirty || b.saving);
}

final class EditorPane extends StatelessWidget {
  const EditorPane({required this.model, super.key});
  final EditorViewModel model;

  Future<void> _close(BuildContext context, EditorBuffer buffer) async {
    if (await confirmDocumentClose(context, model, [buffer])) {
      model.close(buffer, discard: true);
    }
  }

  Future<void> _reload(BuildContext context, EditorBuffer buffer) async {
    if (buffer.dirty) {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Reload from disk?'),
          content: const Text(
            'This replaces the unsaved text in this tab with the current file on disk.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Reload'),
            ),
          ],
        ),
      );
      if (accepted != true) return;
    }
    await model.reload(buffer);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model,
    builder: (context, _) {
      final active = model.active;
      return Column(
        children: [
          SizedBox(
            height: 42,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final buffer in model.inWorkspace(model.workspace))
                  Material(
                    color: identical(active, buffer)
                        ? Theme.of(context).colorScheme.secondaryContainer
                        : Theme.of(context).colorScheme.surface,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextButton(
                          onPressed: () => model.select(buffer),
                          child: Tooltip(
                            message: buffer.path,
                            child: Text(
                              '${buffer.dirty ? '● ' : ''}${p.basename(buffer.path)}',
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Close ${p.basename(buffer.path)}',
                          onPressed: buffer.saving
                              ? null
                              : () => _close(context, buffer),
                          icon: const Icon(Icons.close, size: 16),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          if (active != null) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      p.relative(active.path, from: active.root),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Save document (Ctrl+S)',
                    onPressed: active.saving || !active.dirty
                        ? null
                        : () => model.save(active),
                    icon: const Icon(Icons.save_outlined),
                  ),
                  ValueListenableBuilder<UndoHistoryValue>(
                    valueListenable: active.undo,
                    builder: (context, value, _) => Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: 'Undo (Ctrl+Z)',
                          onPressed: value.canUndo && !active.saving
                              ? active.undo.undo
                              : null,
                          icon: const Icon(Icons.undo),
                        ),
                        IconButton(
                          tooltip: 'Redo (Ctrl+Y)',
                          onPressed: value.canRedo && !active.saving
                              ? active.undo.redo
                              : null,
                          icon: const Icon(Icons.redo),
                        ),
                      ],
                    ),
                  ),
                  PopupMenuButton<String>(
                    tooltip: 'Document actions',
                    enabled: !active.saving,
                    onSelected: (value) => value == 'compare'
                        ? model.compare(active)
                        : _reload(context, active),
                    itemBuilder: (_) => const [
                      PopupMenuItem(
                        value: 'compare',
                        child: Text('Compare with disk'),
                      ),
                      PopupMenuItem(
                        value: 'reload',
                        child: Text('Reload from disk'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (active.saving) const LinearProgressIndicator(minHeight: 2),
            if (active.error != null)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  active.error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(6),
              child: Text(
                'UTF-8${active.baseline.bom ? ' BOM' : ''} · ${active.baseline.newline == '\r\n' ? 'CRLF' : 'LF'} · ${active.dirty ? 'Unsaved' : 'Saved'}',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
          ],
          Expanded(
            child: IndexedStack(
              index: active == null
                  ? model.buffers.length
                  : model.buffers.indexOf(active),
              children: [
                for (final buffer in model.buffers)
                  KeyedSubtree(
                    key: ObjectKey(buffer),
                    child: ExcludeFocus(
                      excluding: !identical(buffer, active),
                      child: _document(buffer),
                    ),
                  ),
                const Center(
                  child: Text('Open a text file from Files to edit it.'),
                ),
              ],
            ),
          ),
        ],
      );
    },
  );
  Widget _document(EditorBuffer active) => Shortcuts(
    shortcuts: const {
      SingleActivator(LogicalKeyboardKey.keyS, control: true):
          _SaveDocumentIntent(),
    },
    child: Actions(
      actions: {
        _SaveDocumentIntent: CallbackAction<_SaveDocumentIntent>(
          onInvoke: (_) {
            model.save(active);
            return null;
          },
        ),
      },
      child: Column(
        children: [
          Expanded(
            child: TextField(
              key: ObjectKey(active),
              controller: active.controller,
              undoController: active.undo,
              readOnly: active.saving,
              autofocus: true,
              expands: true,
              maxLines: null,
              minLines: null,
              autocorrect: false,
              enableSuggestions: false,
              smartDashesType: SmartDashesType.disabled,
              smartQuotesType: SmartQuotesType.disabled,
              keyboardType: TextInputType.multiline,
              inputFormatters: [
                TextInputFormatter.withFunction((previous, next) {
                  if (utf8.encode(next.text).length +
                          (active.baseline.bom ? 3 : 0) >
                      DocumentFiles.byteLimit) {
                    model.rejectInput(active);
                    return previous;
                  }
                  return next;
                }),
              ],
              style: const TextStyle(
                fontFamily: 'Consolas',
                fontFamilyFallback: ['DejaVu Sans Mono', 'monospace'],
                fontSize: 13,
                height: 1.5,
              ),
              textAlignVertical: TextAlignVertical.top,
              decoration: const InputDecoration(
                border: InputBorder.none,
                contentPadding: EdgeInsets.all(16),
                hintText: 'Empty document',
              ),
            ),
          ),
          if (active.diskText != null) ...[
            const Divider(height: 1),
            const Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: EdgeInsets.all(8),
                child: Text('Disk version · read only'),
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: SelectableText(
                  active.diskText!,
                  style: const TextStyle(
                    fontFamily: 'Consolas',
                    fontFamilyFallback: ['DejaVu Sans Mono', 'monospace'],
                    fontSize: 13,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    ),
  );
}

final class _SaveDocumentIntent extends Intent {
  const _SaveDocumentIntent();
}
