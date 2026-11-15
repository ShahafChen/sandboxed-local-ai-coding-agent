# Sandboxed local AI coding agent

A single Docker dev container that runs a local [Ollama](https://ollama.com) with a Qwen coder model, for
**pre-commit review** against your own rules and past PR comments (the things ruff can't check) and for
**documentation suggestions**. The container can't reach the internet: a default-deny firewall lets out only
pypi, through an allowlisting proxy. You connect to it from VS Code over SSH and chat through a tiny, auditable
extension that only shows suggestions and never edits your files.

```
 your Mac ── ssh :2222 ──► container ── 127.0.0.1:11434 ──► ollama (model baked into the image)
                             │
                             └─ egress: iptables DROP, except tinyproxy ─► pypi.org, files.pythonhosted.org
```

## Quick start

```bash
export SSH_PUBKEY="$(cat ~/.ssh/id_ed25519.pub)"
export WORKSPACE=~/code            # host folder mounted at /workspace
MODEL_PROFILE=8gb  MEM_LIMIT=8g  docker compose up -d --build    # qwen2.5-coder:7b  (~4.7 GB)
MODEL_PROFILE=16gb MEM_LIMIT=16g docker compose up -d --build    # qwen2.5-coder:14b (~9 GB)
OLLAMA_MODEL=qwen3:8b docker compose up -d --build               # any other Ollama tag
```

The model is pulled **at build time**, because at runtime the firewall blocks the Ollama registry. To change
the model, rebuild.

Check the sandbox (expects pypi allowed, everything else blocked):

```bash
docker compose exec -u dev agent test-firewall.sh
```

## Connect VS Code

`~/.ssh/config`:

```
Host local-agent
  HostName 127.0.0.1
  Port 2222
  User dev
  IdentityFile ~/.ssh/id_ed25519
```

VS Code user settings. These are required, because the container can't download the VS Code server or
extensions itself:

```json
"remote.SSH.localServerDownload": "always",
"remote.downloadExtensionsLocally": true,
"telemetry.telemetryLevel": "off"
```

Then run **Remote-SSH: Connect to Host… → local-agent** and open `/workspace/<repo>`.

## The extension

The source is two files in [`extension/`](extension), about 150 lines with no dependencies. The image packs it
into `/opt/agent/local-agent-chat.vsix`. Install it once, from the remote window's terminal:

```bash
code --install-extension /opt/agent/local-agent-chat.vsix
```

Commands (Cmd+Shift+P):

- **Local Agent: Open Chat**: a free-form chat with the model.
- **Local Agent: Review Staged Changes**: runs `agent-review` on the `git diff --cached` of the open folder.
- **Local Agent: Suggest Docs for Selection**: also in the editor's right-click menu.

All output is plain text in a side panel. Nothing is inserted into your files.

**Audit it.** `scripts/audit-extension.sh` fails if the extension gains a file, a dependency, a new `require`, a
URL, or a network call other than the single loopback `http.request` to `127.0.0.1:11434`. The webview's CSP has
no `connect-src`, so the webview can't make requests either. The extension runs on the remote
(`extensionKind: workspace`), so even a bug would hit the container firewall.

## Rules and past PR comments

`agent-review` (the same script the extension runs) reads, from the repo root:

| File | Purpose |
|---|---|
| `.agent/rules.md` | Your team rules. Falls back to [`agent/rules.md`](agent/rules.md). |
| `.agent/pr-comments.md` | Past review comments, used as examples of what reviewers flag. Optional. |

The container can't reach GitHub, so export the comments **on the host**:

```bash
gh api "repos/OWNER/REPO/pulls/comments?per_page=100" --paginate \
  --jq '.[] | "- \(.path): \(.body | gsub("\n"; " "))"' | tail -300 > .agent/pr-comments.md
```

Keep the file short (the `tail -300` above does that). It shares an 8k-token context with the diff, and the
diff is truncated at 24k characters.

Optional pre-commit hook, for commits made inside the container. It's advisory and never blocks a commit:

```bash
printf '#!/bin/sh\nagent-review || true\n' > .git/hooks/pre-commit && chmod +x .git/hooks/pre-commit
```

CLI: `agent-review` reviews staged changes. `agent-review --rev origin/dev..HEAD` reviews a range.

## Security model

- **Egress.** iptables in the container sets `OUTPUT` to DROP. Only the `tinyproxy` user may connect out, only
  on 443. tinyproxy only forwards to the hosts in [`config/allowlist`](config/allowlist). To allow more, add a
  regex line there and rebuild. Filtering by domain works where filtering by IP can't: pypi sits behind a
  shared CDN.
- **DNS.** The dev user can't resolve names at all, which closes DNS exfiltration. Only the proxy can query
  Docker's resolver, and only root can do upstream DNS (that is what Docker's embedded resolver forwards as).
- **Privileges.** The container gets `NET_ADMIN` only to install the firewall at startup. The dev user is not
  root and has no sudo, so it can't change the firewall. `no-new-privileges` is set. If the firewall fails to
  install, the container exits before sshd starts.
- **SSH.** Key-only, `dev` user only, bound to `127.0.0.1:2222` on the host. Remote (`-R`) forwarding is
  disabled, because it would give the container a path out through your Mac. Local forwarding stays on because
  VS Code needs it.
- **Ollama** listens on `127.0.0.1` inside the container and isn't published.

Known limits:

- Root processes in the container (sshd, ollama) can do upstream DNS.
- Anything installed from pypi runs inside the sandbox. It can't phone home, but it can read `/workspace`.
- The workspace mount is read-write: commit from inside the container or on the host, as you prefer. Pushing
  must happen on the host.
