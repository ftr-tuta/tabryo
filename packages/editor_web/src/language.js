import * as monaco from 'monaco-editor/editor/editor.main.js';

export function installLanguage(editor, documents, emit, snapshot) {
  const pending = new Map();
  let sequence = 0;
  const range = r => ({ startLineNumber: r.start.line + 1, startColumn: r.start.character + 1,
    endLineNumber: r.end.line + 1, endColumn: r.end.character + 1 });
  const position = p => ({ line: p.lineNumber - 1, character: p.column - 1 });
  const markdown = value => ({ value: typeof value === 'string' ? value : (value?.value ?? ''),
    isTrusted: false, supportHtml: false });
  const docFor = model => [...documents.values()].find(d => d.model === model);
  const uriFor = uri => [...documents.values()].find(d => d.sourceUri === uri)?.model.uri ?? monaco.Uri.parse(uri);
  const completion = (item, model, fallback) => ({
    label: item.label, kind: completionKind(item.kind), detail: item.detail,
    documentation: markdown(item.documentation), sortText: item.sortText, filterText: item.filterText,
    insertText: item.textEdit?.newText ?? item.insertText ?? item.label,
    insertTextRules: item.insertTextFormat === 2 ? monaco.languages.CompletionItemInsertTextRule.InsertAsSnippet : 0,
    range: item.textEdit?.range ? range(item.textEdit.range) : (item.textEdit?.replace ? range(item.textEdit.replace) : fallback),
    additionalTextEdits: item.additionalTextEdits?.map(edit => ({ range: range(edit.range), text: edit.newText })),
    _ticket: item.ticket, _model: model, _version: model.getVersionId(),
  });
  function request(model, method, params = {}, cancellation, stillValid) {
    const doc = docFor(model);
    if (!doc || doc.composition || doc.repair || !doc.languageEnabled || pending.size >= 32 || cancellation?.isCancellationRequested) return Promise.resolve(null);
    emit(snapshot(doc));
    const request = ++sequence;
    return new Promise(resolve => {
      const version = model.getVersionId();
      const finish = result => {
        if (!pending.has(request)) return;
        pending.delete(request); clearTimeout(timer); subscription?.dispose();
        resolve(!model.isDisposed() && (model.getVersionId() === version || stillValid?.()) ? result : null);
      };
      const timer = setTimeout(() => { emit({ type: 'languageCancel', id: doc.id, request }); finish(null); }, 25000);
      let subscription;
      pending.set(request, finish);
      subscription = cancellation?.onCancellationRequested(() => {
        emit({ type: 'languageCancel', id: doc.id, request }); finish(null);
      });
      emit({ type: 'language', id: doc.id, generation: doc.generation, sequence: version, request, method, params });
    });
  }
  for (const language of ['dart', 'python', 'cpp']) {
    monaco.languages.registerCompletionItemProvider(language, {
      triggerCharacters: ['.', '(', ' '],
      provideCompletionItems: async (model, at, _context, cancel) => {
        const result = await request(model, 'textDocument/completion', { position: position(at) }, cancel);
        const word = model.getWordUntilPosition(at);
        const fallback = { startLineNumber: at.lineNumber, endLineNumber: at.lineNumber,
          startColumn: word.startColumn, endColumn: word.endColumn };
        return { incomplete: result?.isIncomplete ?? false, suggestions: (Array.isArray(result) ? result : result?.items ?? []).slice(0, 200).map(item => completion(item, model, fallback)) };
      },
      resolveCompletionItem: async (item, cancel) => {
        if (item._model.isDisposed() || item._model.getVersionId() !== item._version) return item;
        const before = item._model.getValue();
        const start = item._model.getOffsetAt({lineNumber:item.range.startLineNumber, column:item.range.startColumn});
        const end = item._model.getOffsetAt({lineNumber:item.range.endLineNumber, column:item.range.endColumn});
        const expected = before.slice(0, start) + item.insertText + before.slice(end);
        const result = await request(item._model, 'completionItem/resolve', { ticket: item._ticket }, cancel,
          () => item._model.getVersionId() === item._version + 1 && item._model.getValue() === expected);
        return result ? completion(result, item._model, item.range) : item;
      },
    });
    monaco.languages.registerHoverProvider(language, {
      provideHover: async (model, at, cancel) => {
        const result = await request(model, 'textDocument/hover', { position: position(at) }, cancel);
        if (!result) return null;
        return { range: result.range ? range(result.range) : undefined,
          contents: (Array.isArray(result.contents) ? result.contents : [result.contents]).map(markdown) };
      },
    });
    monaco.languages.registerSignatureHelpProvider(language, {
      signatureHelpTriggerCharacters: ['(', ','],
      provideSignatureHelp: async (model, at, cancel) => {
        const result = await request(model, 'textDocument/signatureHelp', { position: position(at) }, cancel);
        if (!result) return null;
        return { value: { activeSignature: result.activeSignature ?? 0, activeParameter: result.activeParameter ?? 0,
          signatures: result.signatures.map(s => ({ ...s, documentation: markdown(s.documentation),
            parameters: (s.parameters ?? []).map(p => ({ ...p, documentation: markdown(p.documentation) })) })) }, dispose() {} };
      },
    });
    monaco.languages.registerDefinitionProvider(language, {
      provideDefinition: async (model, at, cancel) => {
        const result = await request(model, 'textDocument/definition', { position: position(at) }, cancel);
        return (Array.isArray(result) ? result : result ? [result] : []).slice(0, 200).map(item => ({
          uri: uriFor(item.uri ?? item.targetUri), range: range(item.range ?? item.targetSelectionRange ?? item.targetRange),
        }));
      },
    });
    monaco.languages.registerDocumentSymbolProvider(language, {
      provideDocumentSymbols: async (model, cancel) => {
        const result = await request(model, 'textDocument/documentSymbol', {}, cancel);
        const convert = s => ({ name: s.name, detail: s.detail ?? '', kind: Math.max(0, (s.kind ?? 1) - 1), tags: [],
          range: range(s.range ?? s.location.range), selectionRange: range(s.selectionRange ?? s.range ?? s.location.range),
          children: s.children?.map(convert) });
        return (result ?? []).slice(0, 200).map(convert);
      },
    });
    monaco.languages.registerCodeActionProvider(language, {
      provideCodeActions: async (model, selected, _context, cancel) => {
        const result = await request(model, 'textDocument/codeAction', { range: {
          start: position(selected.getStartPosition()), end: position(selected.getEndPosition()) } }, cancel);
        return { actions: (result ?? []).map(item => ({ title: item.title, kind: item.kind ?? 'quickfix',
          command: { id: reviewCommand, title: item.title, arguments: [docFor(model)?.id, item.id] } })), dispose() {} };
      },
    });
  }
  const reviewCommand = editor.addCommand(0, (_accessor, id, action) => emit({ type: 'languageReview', id, action }));
  editor.addAction({ id: 'tabryo.rename', label: 'Rename symbol',
    keybindings: [monaco.KeyCode.F2], contextMenuGroupId: '1_modification',
    run: () => {
      const doc = docFor(editor.getModel());
      if (!doc?.languageEnabled) return;
      emit(snapshot(doc));
      emit({ type: 'languageRename', id: doc.id, position: position(editor.getPosition()) });
    } });
  editor.addAction({ id: 'tabryo.references', label: 'Find project references',
    keybindings: [monaco.KeyMod.Shift | monaco.KeyCode.F12], contextMenuGroupId: 'navigation',
    run: () => request(editor.getModel(), 'textDocument/references', { position: position(editor.getPosition()), context: { includeDeclaration: true } }) });
  monaco.editor.registerEditorOpener({ openCodeEditor: (_source, resource, selection) => {
    const doc = docFor(editor.getModel());
    if (!doc) return false;
    const target = [...documents.values()].find(d => d.model.uri.toString() === resource.toString());
    emit({ type: 'languageNavigate', id: doc.id, uri: target?.sourceUri ?? resource.toString(),
      position: { line: (selection?.startLineNumber ?? selection?.lineNumber ?? 1) - 1,
        character: (selection?.startColumn ?? selection?.column ?? 1) - 1 } });
    return true;
  } });
  return {
    receive: packet => pending.get(packet.request)?.(packet.result),
    sync: (doc, input) => {
      doc.sourceUri = input.sourceUri;
      doc.languageEnabled = input.languageEnabled;
      const key = JSON.stringify(input.diagnostics ?? []);
      if (doc.diagnosticKey === key) return;
      doc.diagnosticKey = key;
      monaco.editor.setModelMarkers(doc.model, 'tabryo', (input.diagnostics ?? []).map(d => ({
        ...range(d.range), message: d.message, source: d.source, code: d.code == null ? undefined : String(d.code),
        severity: ({ 1: 8, 2: 4, 3: 2, 4: 1 })[d.severity] ?? 2,
      })));
    },
  };
}

function completionKind(kind) {
  const names = ['Text', 'Method', 'Function', 'Constructor', 'Field', 'Variable', 'Class', 'Interface', 'Module', 'Property', 'Unit', 'Value', 'Enum', 'Keyword', 'Snippet', 'Color', 'File', 'Reference', 'Folder', 'EnumMember', 'Constant', 'Struct', 'Event', 'Operator', 'TypeParameter'];
  return monaco.languages.CompletionItemKind[names[(kind ?? 1) - 1]] ?? monaco.languages.CompletionItemKind.Text;
}
