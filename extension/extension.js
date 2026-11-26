// Local Agent tab. No dependencies and no network code: on a button click it runs /opt/agent/review.py
// (which talks to the local Ollama) on the file you were editing and opens the result as a VS Code diff.
// Nothing runs in the background and nothing touches your file until you click Apply.
const vscode = require('vscode');
const crypto = require('crypto');
const path = require('path');
const { execFile } = require('child_process');

const SCHEME = 'local-agent';
const proposals = new Map(); // proposed-uri string -> rewritten file text
const changed = new vscode.EventEmitter();
let panel;
let lastEditor; // the diff tab steals focus, so remember the last real file editor
let pending; // { original: Uri, proposed: Uri } while a diff is open and not yet applied

function post(msg) {
  if (panel) panel.webview.postMessage(msg);
}

function openPanel() {
  if (panel) { panel.reveal(); return; }
  panel = vscode.window.createWebviewPanel('localAgent', 'Local Agent', vscode.ViewColumn.Beside,
    { enableScripts: true, retainContextWhenHidden: true, localResourceRoots: [] });
  panel.webview.html = html();
  panel.onDidDispose(() => { panel = undefined; });
  panel.webview.onDidReceiveMessage((m) => {
    if (m.type === 'run') review(m.mode);
    else if (m.type === 'apply') apply();
    else if (m.type === 'discard') { pending = undefined; post({ type: 'status', text: 'Discarded.' }); }
  });
}

function review(mode) {
  const ed = lastEditor;
  if (!ed) { post({ type: 'status', text: 'Click into a file first, then press the button.' }); return; }
  const name = path.basename(ed.document.fileName);
  ed.document.save().then(() => {
    post({ type: 'busy', text: `Reviewing ${name} (${mode})… this can take a few minutes on CPU.` });
    execFile('/opt/agent/review.py', ['--rewrite', ed.document.fileName, '--mode', mode],
      { maxBuffer: 16 * 1024 * 1024 }, (err, stdout, stderr) => {
        if (err) { post({ type: 'status', text: (stderr || err.message).trim() }); return; }
        if (stdout === ed.document.getText()) { post({ type: 'status', text: `No changes suggested for ${name}.` }); return; }
        const proposed = ed.document.uri.with({ scheme: SCHEME, query: mode });
        proposals.set(proposed.toString(), stdout);
        changed.fire(proposed);
        pending = { original: ed.document.uri, proposed };
        vscode.commands.executeCommand('vscode.diff', ed.document.uri, proposed, `${name}: current ↔ ${mode} suggestions`);
        post({ type: 'ready', text: `Suggestions for ${name} are open in the diff tab. Apply writes them to the file.` });
      });
  });
}

async function apply() {
  if (!pending) return;
  const doc = await vscode.workspace.openTextDocument(pending.original);
  const edit = new vscode.WorkspaceEdit();
  edit.replace(pending.original, new vscode.Range(0, 0, doc.lineCount, 0), proposals.get(pending.proposed.toString()));
  await vscode.workspace.applyEdit(edit);
  await doc.save();
  post({ type: 'status', text: `Applied to ${path.basename(doc.fileName)}.` });
  pending = undefined;
}

function html() {
  const nonce = crypto.randomBytes(16).toString('hex');
  // CSP has no connect-src, so the webview itself cannot make any network request.
  return `<!DOCTYPE html><html><head><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'nonce-${nonce}';">
<style>
body{font-family:var(--vscode-font-family);color:var(--vscode-foreground);padding:12px}
button{background:var(--vscode-button-background);color:var(--vscode-button-foreground);border:0;padding:8px 12px;margin:0 8px 8px 0;cursor:pointer}
button:disabled{opacity:.5;cursor:default}
#apply{background:var(--vscode-button-secondaryBackground);color:var(--vscode-button-secondaryForeground)}
p{margin:4px 0 12px;opacity:.8}
#status{white-space:pre-wrap;font-family:var(--vscode-editor-font-family)}
</style></head><body>
<h3>Local Agent</h3>
<p>Reviews the file you last clicked into. Results open as a diff; nothing changes until you click Apply.</p>
<button id="rules">CR against team rules</button>
<p>Fixes violations of <code>.agent/rules.md</code> and past PR comments, each marked with a <code>CR:</code> comment.</p>
<button id="general">General CR</button>
<p>The model's own suggestions: clarity, organization, comments and docstrings. Not tied to the rules.</p>
<div id="result" hidden><button id="apply">Apply suggestions to file</button><button id="discard">Discard</button></div>
<div id="status" role="status" aria-live="polite"></div>
<script nonce="${nonce}">
const vscode = acquireVsCodeApi(), status = document.getElementById('status'), result = document.getElementById('result');
const buttons = ['rules', 'general'].map(id => document.getElementById(id));
buttons.forEach(b => b.addEventListener('click', () => vscode.postMessage({ type: 'run', mode: b.id })));
document.getElementById('apply').addEventListener('click', () => vscode.postMessage({ type: 'apply' }));
document.getElementById('discard').addEventListener('click', () => vscode.postMessage({ type: 'discard' }));
window.addEventListener('message', e => { const m = e.data;
  status.textContent = m.text;
  buttons.forEach(b => b.disabled = m.type === 'busy');
  result.hidden = m.type !== 'ready'; });
</script></body></html>`;
}

function activate(context) {
  const track = (e) => { if (e && e.document.uri.scheme === 'file') lastEditor = e; };
  track(vscode.window.activeTextEditor);
  context.subscriptions.push(
    vscode.window.onDidChangeActiveTextEditor(track),
    vscode.workspace.registerTextDocumentContentProvider(SCHEME,
      { onDidChange: changed.event, provideTextDocumentContent: (uri) => proposals.get(uri.toString()) || '' }),
    vscode.commands.registerCommand('localAgent.open', openPanel));
}

module.exports = { activate, deactivate() {} };
