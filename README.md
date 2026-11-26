# Sandboxed local AI coding agent

A single Docker dev container that runs a local [Ollama](https://ollama.com) with a Qwen, Gemma or Devstral
model, for **pre-commit review** against your own rules and past PR comments (the things ruff can't check) and
for **general code review** (clarity, organization, comments, docstrings). The container can't reach the
internet: a default-deny firewall lets out only pypi, through an allowlisting proxy. You connect to it from VS
Code over SSH; a tiny, auditable extension shows the model's suggestions as a VS Code diff and writes nothing
until you click Apply.

```
 your Mac ── ssh :2222 ──► container ── 127.0.0.1:11434 ──► ollama (model baked into the image)
                             │
                             └─ egress: iptables DROP, except tinyproxy ─► pypi.org, files.pythonhosted.org
```

## Quick start

```bash
export SSH_PUBKEY="$(cat ~/.ssh/id_ed25519.pub)"
export WORKSPACE=~/code            # host folder mounted at /workspace
MODEL_FAMILY=qwen     MODEL_PROFILE=8gb  MEM_LIMIT=8g  docker compose up -d --build   # qwen2.5-coder:7b (default)
MODEL_FAMILY=qwen     MODEL_PROFILE=16gb MEM_LIMIT=16g docker compose up -d --build   # qwen2.5-coder:14b
MODEL_FAMILY=gemma    MODEL_PROFILE=8gb  MEM_LIMIT=8g  docker compose up -d --build   # gemma3:4b
MODEL_FAMILY=gemma    MODEL_PROFILE=16gb MEM_LIMIT=16g docker compose up -d --build   # gemma3:12b
MODEL_FAMILY=devstral MODEL_PROFILE=16gb MEM_LIMIT=20g docker compose up -d --build   # devstral-small-2:24b (16gb only)
OLLAMA_MODEL=qwen3:8b docker compose up -d --build                                     # any other Ollama tag
```

The table lives in [`config/models`](config/models); [`docs/models.md`](docs/models.md) compares the three
families (best for, pros, cons, resources). The model is pulled **at build time**, because at runtime the
firewall blocks the Ollama registry. To change the model, rebuild. `OLLAMA_CONTEXT_LENGTH` (default 8192)
can be raised in the environment if you have RAM to spare.

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

The source is two files in [`extension/`](extension), about 120 lines with no dependencies and **no network
code at all**: it runs `/opt/agent/review.py` and shows the output. The image packs it into
`/opt/agent/local-agent-chat.vsix`. Install it once, from the remote window's terminal:

```bash
code --install-extension /opt/agent/local-agent-chat.vsix
```

**Local Agent: Open** (Cmd+Shift+P) opens a tab with two buttons. Both act on the file you last clicked into,
run only when clicked (nothing runs in the background), and open the result as a VS Code diff, current file on
the left, suggestions on the right, like a git diff:

- **CR against team rules**: fixes violations of `.agent/rules.md` and past PR comments. Each change carries a
  `CR: <rule> - <why>` comment so you can see which rule triggered it.
- **General CR**: the model's own suggestions, not tied to the rules: clearer names, organization, comments
  that explain why, docstrings.

Nothing touches your file until you click **Apply suggestions to file** in the tab; **Discard** drops them. The
file is saved before the review, and the rewrite needs the file twice in the model context, so files over
~12k characters are refused (raise `OLLAMA_CONTEXT_LENGTH` and `MAX_FILE_CHARS` in `review.py` if needed).

**Audit it.** `scripts/audit-extension.sh` fails if the extension gains a file, a dependency, a new `require`, a
URL, any network-looking code, or a second subprocess. The webview's CSP has no `connect-src`, so the webview
can't make requests either. The extension runs on the remote (`extensionKind: workspace`), so even a bug would
hit the container firewall.

## Rules and past PR comments

`agent-review` (the same script behind the tab's buttons) reads, from the repo root:

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
`agent-review --rewrite FILE --mode rules|general` prints the rewritten file (what the tab diffs).

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
