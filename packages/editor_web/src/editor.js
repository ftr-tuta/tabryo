import * as monaco from 'monaco-editor/editor/editor.main.js';
import './editor.css';

self.MonacoEnvironment = {
  getWorker: (_module, label) => {
    const name = ({ json: 'json', css: 'css', scss: 'css', less: 'css', html: 'html', handlebars: 'html', razor: 'html', typescript: 'ts', javascript: 'ts' })[label] ?? 'editor';
    return new Worker(new URL(`${name}.worker.js`, location.href));
  },
};
const token = location.hash.slice(1);
const documents = new Map();
let active = null;
let changing = false;
let diff = null;
let diskModel = null;
const container = document.getElementById('editor');
const editor = monaco.editor.create(container, {
  theme: 'vs-dark', automaticLayout: true, minimap: { enabled: false },
  fontFamily: 'Consolas, "DejaVu Sans Mono", monospace', fontSize: 14,
  scrollBeyondLastLine: false, fixedOverflowWidgets: false,
  accessibilitySupport: 'auto', ariaLabel: 'Tabryo code editor',
  // Consistent textarea/IME behavior in WebView2 and WebKitGTK.
  editContext: false,
  unicodeHighlight: { ambiguousCharacters: false },
});

function emit(packet) {
  if (!packet) return;
  TabryoEditor.postMessage(JSON.stringify({ token, ...packet }));
}
function validText(doc, text) {
  return text.length <= 512 * 1024 && text.isWellFormed() && !text.includes('\0') &&
    new TextEncoder().encode(text.replaceAll('\n', doc.newline)).length + (doc.bom ? 3 : 0) <= 512 * 1024;
}
function permitsInsert(text) {
  if (!active) return false;
  let candidate = active.model.getValue();
  const ranges = editor.getSelections().map(selection => [
    active.model.getOffsetAt(selection.getStartPosition()),
    active.model.getOffsetAt(selection.getEndPosition()),
  ]).sort((a, b) => b[0] - a[0]);
  for (const [start, end] of ranges) candidate = candidate.slice(0, start) + text.replaceAll('\r\n', '\n') + candidate.slice(end);
  return validText(active, candidate);
}
function rejectInsert(event, text) {
  if (!event.cancelable || permitsInsert(text)) return;
  event.preventDefault();
  event.stopImmediatePropagation();
  emit({ type: 'rejected', id: active.id });
}
container.addEventListener('paste', event => {
  if (active && event.clipboardData) rejectInsert(event, event.clipboardData.getData('text/plain'));
}, true);
container.addEventListener('beforeinput', event => {
  if (active && event.inputType?.startsWith('insert') && typeof event.data === 'string') rejectInsert(event, event.data);
}, true);
function snapshot(doc, extra = {}) {
  if (doc.repair || !validText(doc, doc.model.getValue())) return null;
  const selection = active === doc ? editor.getSelection() : null;
  return {
    type: 'change', id: doc.id, generation: doc.generation,
    sequence: doc.model.getVersionId(), text: doc.model.getValue(),
    start: selection ? doc.model.getOffsetAt(selection.getSelectionStart()) : (doc.selection?.start ?? 0),
    end: selection ? doc.model.getOffsetAt(selection.getPosition()) : (doc.selection?.end ?? 0),
    canUndo: doc.model.canUndo(), canRedo: doc.model.canRedo(), ...extra,
  };
}
function changed(doc, event) {
  if (changing || doc.repair) return;
  const text = doc.model.getValue();
  if (!validText(doc, text)) {
    if (active === doc) editor.updateOptions({ readOnly: true });
    // Wait until Monaco finishes the input transaction before touching its undo
    // stack. Never send an invalid intermediate model over the native channel.
    doc.repair = Promise.resolve().then(async () => {
      await (event.isUndoing ? doc.model.redo() : doc.model.undo());
      if (doc.model.getValue() !== doc.acceptedText) {
        doc.model.pushStackElement();
        doc.model.pushEditOperations([], [{ range: doc.model.getFullModelRange(), text: doc.acceptedText }], () => null);
        doc.model.pushStackElement();
      }
      doc.repair = null;
      if (active === doc) editor.updateOptions({ readOnly: doc.readOnly });
      emit(snapshot(doc));
      emit({ type: 'rejected', id: doc.id });
    }).catch(() => emit({ type: 'failed' }));
    return;
  }
  doc.acceptedText = text;
  emit(snapshot(doc));
}
function closeDiff() {
  if (!diff) return;
  diff.dispose(); diff = null;
  diskModel?.dispose(); diskModel = null;
  container.replaceChildren(editor.getDomNode());
  editor.layout();
}
function activate(doc) {
  if (active === doc) return;
  closeDiff();
  if (active) {
    active.view = editor.saveViewState();
    active.selection = snapshot(active);
  }
  active = doc;
  editor.setModel(doc?.model ?? null);
  if (doc?.view) editor.restoreViewState(doc.view);
}

window.tabryoReceive = (packet) => {
  if (packet.token !== token) return;
  changing = true;
  try {
    switch (packet.type) {
      case 'sync': {
        const keep = new Set(packet.documents.map(d => d.id));
        for (const [id, doc] of documents) {
          if (!keep.has(id)) {
            if (active === doc) activate(null);
            doc.listener.dispose(); doc.model.dispose(); documents.delete(id);
          }
        }
        for (const input of packet.documents) {
          let doc = documents.get(input.id);
          if (!doc) {
            const model = monaco.editor.createModel(input.text, input.language, monaco.Uri.parse(input.uri));
            doc = { id: input.id, model, acceptedText: input.text, generation: input.generation, readOnly: input.readOnly };
            doc.listener = model.onDidChangeContent(event => changed(doc, event));
            documents.set(input.id, doc);
          } else if (doc.generation !== input.generation) {
            doc.generation = input.generation;
            doc.acceptedText = input.text;
            if (doc.model.getValue() !== input.text) {
              doc.model.pushStackElement();
              doc.model.pushEditOperations([], [{ range: doc.model.getFullModelRange(), text: input.text }], () => null);
              doc.model.pushStackElement();
            }
          }
          doc.readOnly = input.readOnly;
          doc.newline = input.newline;
          doc.bom = input.bom;
        }
        activate(documents.get(packet.active) ?? null);
        monaco.editor.setTheme(packet.dark ? 'vs-dark' : 'vs');
        editor.updateOptions({ readOnly: active?.repair ? true : (active?.readOnly ?? true) });
        if (active) emit(snapshot(active, { type: 'state' }));
        break;
      }
      case 'flush': {
        const doc = documents.get(packet.id);
        if (doc) {
          if (doc.repair) doc.repair.then(() => emit(snapshot(doc, { type: 'flushed', request: packet.request })));
          else emit(snapshot(doc, { type: 'flushed', request: packet.request }));
        }
        break;
      }
      case 'command': {
        if (packet.command === 'focus') editor.focus();
        else if (packet.command === 'undo' || packet.command === 'redo') {
          changing = false;
          editor.trigger('tabryo', packet.command);
        } else if (packet.command === 'find') editor.getAction('actions.find').run();
        else if (packet.command === 'replace') editor.getAction('editor.action.startFindReplaceAction').run();
        else if (packet.command === 'closeDiff') closeDiff();
        break;
      }
      case 'compare': {
        closeDiff();
        if (!active) break;
        container.replaceChildren();
        diskModel = monaco.editor.createModel(packet.text, active.model.getLanguageId());
        diff = monaco.editor.createDiffEditor(container, {
          automaticLayout: true, readOnly: true, originalEditable: false,
          renderSideBySide: true, minimap: { enabled: false },
        });
        diff.setModel({ original: diskModel, modified: active.model });
        break;
      }
    }
  } finally { changing = false; }
};

editor.onDidChangeCursorSelection(() => { if (active && !changing) emit(snapshot(active, { type: 'selection' })); });
editor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyS,
  () => { if (active) emit({ type: 'save', id: active.id }); });
for (const [key, command] of [
  [monaco.KeyMod.CtrlCmd | monaco.KeyMod.Shift | monaco.KeyCode.KeyP, 'palette'],
  [monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyO, 'open'],
  [monaco.KeyMod.CtrlCmd | monaco.KeyCode.Tab, 'nextTab'],
  [monaco.KeyMod.CtrlCmd | monaco.KeyMod.Shift | monaco.KeyCode.Tab, 'previousTab'],
]) editor.addCommand(key, () => emit({ type: 'workbench', command }));
emit({ type: 'ready' });
