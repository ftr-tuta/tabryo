import * as monaco from 'monaco-editor/editor/editor.main.js';
import './editor.css';
import { installLanguage } from './language.js';

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
let diffVisible = false;
let diskModel = null;
let reviewOriginal = null;
let reviewModified = null;
let reviewMode = false;
let composing = null;
const diffContainer = document.createElement('div');
diffContainer.style.width = '100%';
diffContainer.style.height = '100%';
const container = document.getElementById('editor');
const editor = monaco.editor.create(container, {
  theme: matchMedia('(prefers-color-scheme: dark)').matches ? 'vs-dark' : 'vs', automaticLayout: true, minimap: { enabled: false },
  fontFamily: 'Consolas, "DejaVu Sans Mono", monospace', fontSize: 14,
  scrollBeyondLastLine: false, fixedOverflowWidgets: false,
  accessibilitySupport: 'auto', ariaLabel: 'Tabryo code editor',
  // Consistent textarea/IME behavior in WebView2 and WebKitGTK.
  editContext: false,
  unicodeHighlight: { ambiguousCharacters: false },
});

function emit(packet) {
  if (!packet) return;
  window.tabryoBridge.postMessage(JSON.stringify({ token, ...packet }));
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
  // Composition data replaces the IME's own range, not necessarily the current
  // caret selection. Validate the committed model when composition finishes.
  if (event.isComposing || event.inputType === 'insertCompositionText' || active?.composition) return;
  if (active && event.inputType?.startsWith('insert') && typeof event.data === 'string') rejectInsert(event, event.data);
}, true);
function snapshot(doc, extra = {}) {
  if (doc.composition || doc.repair || !validText(doc, doc.model.getValue())) return null;
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
  if (changing || doc.composition || doc.repair) return;
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
  if (!diffVisible) return;
  diffVisible = false;
  // Monaco 0.56 installs shared hover/render factories from the last standalone
  // editor. Keep this one comparison editor alive for the page, but release its
  // models on close so later completion/hover cannot use a disposed service.
  diff.setModel(null);
  diskModel?.dispose(); diskModel = null;
  container.replaceChildren(editor.getDomNode());
  editor.layout();
}
function activate(doc) {
  if (active === doc) return;
  if (!reviewMode) closeDiff();
  if (active) {
    active.view = editor.saveViewState();
    active.selection = snapshot(active);
  }
  active = doc;
  editor.setModel(doc?.model ?? null);
  if (doc?.view) editor.restoreViewState(doc.view);
}

const language = installLanguage(editor, documents, emit, snapshot);

editor.onDidCompositionStart(() => {
  if (!active || active.composition) return;
  const doc = composing = active;
  doc.composition = new Promise(resolve => { doc.finishComposition = resolve; });
});
editor.onDidCompositionEnd(() => {
  const doc = composing;
  composing = null;
  if (!doc) return;
  const finish = doc.finishComposition;
  queueMicrotask(async () => {
    doc.composition = null;
    if (!doc.model.isDisposed()) {
      changed(doc, { isUndoing: false });
      await doc.repair;
      if (doc.supersededComposition) {
        doc.supersededComposition = false;
        emit(snapshot(doc, { type: 'superseded' }));
      }
    }
    finish();
  });
});

window.tabryoReceive = (packet) => {
  if (packet.token !== token) return;
  changing = true;
  try {
    switch (packet.type) {
      case 'reviewDiff': {
        closeDiff();
        reviewMode = true;
        reviewOriginal?.dispose(); reviewModified?.dispose();
        reviewOriginal = monaco.editor.createModel(packet.original, undefined, monaco.Uri.parse(`tabryo-review://original/${encodeURIComponent(packet.path)}`));
        reviewModified = monaco.editor.createModel(packet.modified, undefined, monaco.Uri.parse(`tabryo-review://modified/${encodeURIComponent(packet.path)}`));
        container.replaceChildren(diffContainer);
        diff ??= monaco.editor.createDiffEditor(diffContainer, {
          automaticLayout: true, readOnly: true, originalEditable: false, minimap: { enabled: false },
          hideUnchangedRegions: { enabled: true },
        });
        diff.updateOptions({renderSideBySide: packet.sideBySide, readOnly: true, originalEditable: false, hideUnchangedRegions: { enabled: true }});
        diff.setModel({ original: reviewOriginal, modified: reviewModified });
        diffVisible = true; diff.layout();
        break;
      }
      case 'diffNavigate': diff?.goToDiff(packet.forward ? 'next' : 'previous'); break;
      case 'closeReview':
        reviewMode = false;
        closeDiff(); reviewOriginal?.dispose(); reviewModified?.dispose();
        reviewOriginal = null; reviewModified = null;
        break;
      case 'theme':
        monaco.editor.defineTheme('tabryo', { base: packet.dark ? 'vs-dark' : 'vs', inherit: true, rules: [], colors: packet.colors });
        monaco.editor.setTheme('tabryo');
        document.body.style.background = packet.colors['editor.background'];
        break;
      case 'languageResult': language.receive(packet); break;
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
            doc = { id: input.id, model, acceptedText: input.text, generation: input.generation, readOnly: input.readOnly,
              hostSequence: model.getVersionId() };
            doc.pendingSelection = { start: input.start, end: input.end };
            doc.listener = model.onDidChangeContent(event => changed(doc, event));
            documents.set(input.id, doc);
          } else if (doc.generation !== input.generation) {
            doc.generation = input.generation;
            if (doc.composition) {
              doc.supersededComposition = true;
              continue;
            }
            // Input may arrive after Flutter's last snapshot but before this
            // replacement crosses the native bridge. Keep that input and
            // report it in the new generation instead of overwriting it.
            // Consecutive host replacements may cross before Flutter receives
            // the first acknowledgement. Only a version produced by actual
            // browser input conflicts; an unchanged host replacement is safe.
            if (input.expectedSequence != null && doc.model.getVersionId() !== input.expectedSequence &&
                doc.model.getVersionId() !== doc.hostSequence) {
              emit(snapshot(doc, { type: 'superseded' }));
              continue;
            }
            doc.acceptedText = input.text;
            doc.pendingSelection = { start: input.start, end: input.end };
            if (doc.model.getValue() !== input.text) {
              doc.model.pushStackElement();
              doc.model.pushEditOperations([], [{ range: doc.model.getFullModelRange(), text: input.text }], () => null);
              doc.model.pushStackElement();
            }
            doc.hostSequence = doc.model.getVersionId();
          }
          doc.readOnly = input.readOnly;
          doc.newline = input.newline;
          doc.bom = input.bom;
          language.sync(doc, input);
        }
        activate(documents.get(packet.active) ?? null);
        if (active?.pendingSelection) {
          const start = active.model.getPositionAt(active.pendingSelection.start);
          const end = active.model.getPositionAt(active.pendingSelection.end);
          editor.setSelection(new monaco.Selection(start.lineNumber, start.column, end.lineNumber, end.column));
          active.pendingSelection = null;
        }
        editor.updateOptions({ readOnly: active?.repair ? true : (active?.readOnly ?? true) });
        if (active) emit(snapshot(active, { type: 'state' }));
        break;
      }
      case 'flush': {
        const doc = documents.get(packet.id);
        if (doc) {
          Promise.resolve(doc.composition).then(() => doc.repair).then(() => {
            if (!doc.model.isDisposed()) emit(snapshot(doc, { type: 'flushed', request: packet.request }));
          });
        }
        break;
      }
      case 'command': {
        if (packet.command === 'focus') (diffVisible ? diff.getModifiedEditor() : editor).focus();
        else if (packet.command === 'undo' || packet.command === 'redo') {
          changing = false;
          editor.trigger('tabryo', packet.command);
        } else if (packet.command === 'find') editor.getAction('actions.find').run();
        else if (packet.command === 'replace') editor.getAction('editor.action.startFindReplaceAction').run();
        else if (packet.command === 'closeDiff') closeDiff();
        else if (({ rename: 'tabryo.rename', completion: 'editor.action.triggerSuggest',
          symbols: 'editor.action.quickOutline', references: 'tabryo.references',
          fixes: 'editor.action.quickFix' })[packet.command]) {
          editor.focus();
          editor.getAction(({ rename: 'tabryo.rename', completion: 'editor.action.triggerSuggest',
            symbols: 'editor.action.quickOutline', references: 'tabryo.references',
            fixes: 'editor.action.quickFix' })[packet.command])?.run();
        }
        else if (packet.command === 'reveal' && active) {
          const input = packet;
          if (input.start != null) {
            const at = active.model.getPositionAt(input.start);
            editor.setPosition(at); editor.revealPositionInCenter(at); editor.focus();
          }
        }
        break;
      }
      case 'compare': {
        closeDiff();
        if (!active) break;
        container.replaceChildren(diffContainer);
        diskModel = monaco.editor.createModel(packet.text, active.model.getLanguageId());
        diff ??= monaco.editor.createDiffEditor(diffContainer, {
          automaticLayout: true, readOnly: true, originalEditable: false,
          renderSideBySide: true, minimap: { enabled: false },
        });
        diff.setModel({ original: diskModel, modified: active.model });
        diffVisible = true;
        diff.layout();
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
