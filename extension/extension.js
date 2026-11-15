// Local Agent Chat. No dependencies. The only network call is http.request to 127.0.0.1:11434 (see chat()).
// Suggestions are shown as plain text in a webview; nothing is ever written into your files.
const vscode = require('vscode');
const http = require('http');
const fs = require('fs');
const crypto = require('crypto');
const { spawn } = require('child_process');

const OLLAMA_HOST = '127.0.0.1';
const OLLAMA_PORT = 11434;

let panel;
const history = [];

function model() {
  return process.env.OLLAMA_MODEL || fs.readFileSync('/etc/agent-model', 'utf8').trim();
}

function post(msg) {
  if (panel) panel.webview.postMessage(msg);
}

function openPanel() {
  if (panel) { panel.reveal(); return; }
  panel = vscode.window.createWebviewPanel('localAgent', 'Local Agent', vscode.ViewColumn.Beside,
    { enableScripts: true, retainContextWhenHidden: true, localResourceRoots: [] });
  panel.webview.html = html();
  panel.onDidDispose(() => { panel = undefined; });
  panel.webview.onDidReceiveMessage((m) => { if (m.type === 'ask' && m.text.trim()) ask(m.text); });
}

function ask(text) {
  openPanel();
  history.push({ role: 'user', content: text });
  post({ type: 'user', text });
  post({ type: 'start' });
  let reply = '';
  chat(history, (chunk) => { reply += chunk; post({ type: 'chunk', text: chunk }); },
    (err) => {
      if (err) post({ type: 'chunk', text: `\n[error: ${err.message}]` });
      else history.push({ role: 'assistant', content: reply });
      post({ type: 'end' });
    });
}

// Streams /api/chat from the local Ollama. Hardcoded loopback host: this is the extension's only outbound I/O.
function chat(messages, onChunk, onDone) {
  const body = JSON.stringify({ model: model(), stream: true, messages });
  const req = http.request({ host: OLLAMA_HOST, port: OLLAMA_PORT, path: '/api/chat', method: 'POST',
    headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) } }, (res) => {
    let buf = '';
    res.on('data', (d) => {
      buf += d;
      let i;
      while ((i = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, i); buf = buf.slice(i + 1);
        if (line.trim()) onChunk((JSON.parse(line).message || {}).content || '');
      }
    });
    res.on('end', () => onDone());
  });
  req.on('error', onDone);
  req.end(body);
}

function reviewStaged() {
  const folder = vscode.workspace.workspaceFolders && vscode.workspace.workspaceFolders[0];
  if (!folder) { vscode.window.showWarningMessage('Open a git repository folder first.'); return; }
  openPanel();
  post({ type: 'user', text: 'Review staged changes' });
  post({ type: 'start' });
  const p = spawn('/opt/agent/review.py', [], { cwd: folder.uri.fsPath });
  p.stdout.on('data', (d) => post({ type: 'chunk', text: d.toString() }));
  p.stderr.on('data', (d) => post({ type: 'chunk', text: d.toString() }));
  p.on('close', () => post({ type: 'end' }));
}

function documentSelection() {
  const ed = vscode.window.activeTextEditor;
  const code = ed && ed.document.getText(ed.selection);
  if (!code) { vscode.window.showWarningMessage('Select some code first.'); return; }
  ask(`Suggest documentation (docstrings / comments explaining why) for this ${ed.document.languageId} code. ` +
    `Show the suggested text only; do not rewrite the logic.\n\n${code}`);
}

function html() {
  const nonce = crypto.randomBytes(16).toString('hex');
  // CSP has no connect-src, so the webview itself cannot make any network request.
  return `<!DOCTYPE html><html><head><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'nonce-${nonce}';">
<style>
body{font-family:var(--vscode-font-family);color:var(--vscode-foreground);display:flex;flex-direction:column;height:100vh;margin:0}
#log{flex:1;overflow:auto;padding:8px}
.m{white-space:pre-wrap;font-family:var(--vscode-editor-font-family);margin:6px 0;padding:6px;border-radius:4px;user-select:text}
.user{background:var(--vscode-input-background)}
.bot{border-left:3px solid var(--vscode-focusBorder)}
form{display:flex;gap:4px;padding:8px}
textarea{flex:1;background:var(--vscode-input-background);color:var(--vscode-input-foreground);border:1px solid var(--vscode-input-border)}
</style></head><body>
<div id="log"></div>
<form id="f"><textarea id="q" rows="3" placeholder="Ask the local agent (Enter to send, Shift+Enter for newline)" aria-label="Message"></textarea><button>Send</button></form>
<script nonce="${nonce}">
const vscode = acquireVsCodeApi(), log = document.getElementById('log'), q = document.getElementById('q');
let cur;
function add(cls, text){ const d=document.createElement('div'); d.className='m '+cls; d.textContent=text; log.appendChild(d); log.scrollTop=log.scrollHeight; return d; }
window.addEventListener('message', e => { const m = e.data;
  if (m.type==='user') add('user', m.text);
  if (m.type==='start') cur = add('bot', '');
  if (m.type==='chunk' && cur) { cur.textContent += m.text; log.scrollTop=log.scrollHeight; }
  if (m.type==='end') cur = null; });
function send(){ vscode.postMessage({type:'ask', text:q.value}); q.value=''; }
document.getElementById('f').addEventListener('submit', e => { e.preventDefault(); send(); });
q.addEventListener('keydown', e => { if (e.key==='Enter' && !e.shiftKey) { e.preventDefault(); send(); } });
</script></body></html>`;
}

function activate(context) {
  context.subscriptions.push(
    vscode.commands.registerCommand('localAgent.openChat', openPanel),
    vscode.commands.registerCommand('localAgent.reviewStaged', reviewStaged),
    vscode.commands.registerCommand('localAgent.documentSelection', documentSelection));
}

module.exports = { activate, deactivate() {} };
