# Local Agent extension

Two files, no dependencies, no network code: [`extension.js`](extension.js) runs `/opt/agent/review.py` on the
file you last clicked into and opens the result as a VS Code diff; [`package.json`](package.json) declares
the one command, `Local Agent: Open`. `scripts/audit-extension.sh` fails if anything network-shaped ever
appears here.

## Building the `.vsix`

A `.vsix` is a zip file with a fixed layout. VS Code only needs three things in it:

```
extension.vsixmanifest        who/what/version, which assets exist
[Content_Types].xml           MIME types per file extension
extension/package.json        the extension itself (plus extension.js next to it)
```

### The way the image does it (no npm, no network)

[`scripts/build-vsix.sh`](../scripts/build-vsix.sh) writes the two XML files and zips them with
`extension/`. It needs only `zip` and `python3`, so it runs inside the sandbox and at image build time:

```bash
scripts/build-vsix.sh extension local-agent-chat.vsix
```

The Dockerfile runs exactly this and leaves the result at `/opt/agent/local-agent-chat.vsix`. The version
in the manifest is read from `package.json`, so bump `"version"` there when you change the code: VS Code
will not reinstall a `.vsix` with the same version over an installed one.

### The standard way (`vsce`, needs internet, run on the host)

```bash
npm install -g @vscode/vsce
cd extension && vsce package --allow-missing-repository
```

Produces `local-agent-chat-<version>.vsix`. `vsce` adds a README and a LICENSE check, which is why the
in-image build skips it: those need a package manager, and the sandbox has none.

## Installing

From the VS Code window that is connected to the container (so it lands on the remote side,
`extensionKind: workspace`):

```bash
code --install-extension /opt/agent/local-agent-chat.vsix
```

or **Extensions → ··· → Install from VSIX…**. To upgrade: bump the version, rebuild, install again.

## Verifying it is still offline

```bash
scripts/audit-extension.sh
```

Checks that the directory still holds exactly these files, that `package.json` has no `dependencies`,
that the only `require`s are `vscode`, `path`, `crypto` and `child_process`, that no URL, `fetch`,
`XMLHttpRequest`, `WebSocket`, `net`, `dns` or `tls` appears, and that the one subprocess call is
`/opt/agent/review.py`. The webview's CSP has no `connect-src`, so the panel cannot make requests either.
