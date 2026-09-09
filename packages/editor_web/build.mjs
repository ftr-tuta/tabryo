import { build } from 'esbuild';
import { copyFile, mkdir, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';

const outdir = fileURLToPath(new URL('../../assets/editor/', import.meta.url));
await mkdir(outdir, { recursive: true });
for (const [source, target] of [['LICENSE', 'MONACO-LICENSE.txt'], ['ThirdPartyNotices.txt', 'MONACO-ThirdPartyNotices.txt']]) {
  await copyFile(new URL(`node_modules/monaco-editor/${source}`, import.meta.url), new URL(`../../assets/editor/${target}`, import.meta.url));
}
await build({
  absWorkingDir: fileURLToPath(new URL('.', import.meta.url)),
  entryPoints: {
    bootstrap: 'src/bootstrap.js',
    editor: 'src/editor.js',
    'editor.worker': 'node_modules/monaco-editor/esm/vs/editor/editor.worker.js',
    'json.worker': 'node_modules/monaco-editor/esm/vs/languages/features/json/json.worker.js',
    'css.worker': 'node_modules/monaco-editor/esm/vs/languages/features/css/css.worker.js',
    'html.worker': 'node_modules/monaco-editor/esm/vs/languages/features/html/html.worker.js',
    'ts.worker': 'node_modules/monaco-editor/esm/vs/languages/features/typescript/ts.worker.js',
  },
  bundle: true,
  format: 'iife',
  target: ['es2022'],
  minify: true,
  legalComments: 'linked',
  loader: { '.ttf': 'file' },
  outdir,
});
await writeFile(new URL('../../assets/editor/index.html', import.meta.url), `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Tabryo editor</title><link rel="stylesheet" href="editor.css"></head>
<body><main id="editor" aria-label="Code editor"></main><script src="bootstrap.js"></script><script src="editor.js"></script></body></html>`);
