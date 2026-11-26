# Sandboxed local AI coding agent

An AI coding assistant that runs **entirely on your machine, inside a sandbox that cannot talk to the
internet**. Your code, your review rules and the model's output never leave the container. It is a single
Docker dev container: a local [Ollama](https://ollama.com) with a Qwen, Gemma or Devstral model, an SSH
server for VS Code, and a firewall that is the whole point of the project.

## Goals

1. **Local assistant, not a cloud service.** The model runs on CPU inside the container; the weights are baked
   into the image at build time. No API key, no account, no telemetry, nothing to subscribe to.
2. **Sandboxed by construction.** The container is default-deny for outbound traffic. The only exception is
   pypi, through a proxy that only knows two hostnames, so Python packages can still be installed. Everything
   else — the model, the review script, the VS Code extension, anything you `pip install` — is cut off from the
   network, and the user you log in as cannot lift that restriction. [The sandbox](#the-sandbox) below explains
   each layer and how to verify it.
3. **Assist, never act.** The agent reviews code against your team's rules and past PR comments (the things ruff
   can't check) and suggests clarity, organization and documentation improvements. It shows every suggestion
   as a VS Code diff and writes nothing to your files until you click Apply. It never commits, never pushes,
   never runs in the background.

```
 your Mac ── ssh 127.0.0.1:2222 ──► container ── 127.0.0.1:11434 ──► ollama (model baked into the image)
                                      │
                                      └─ egress: iptables DROP for everyone,
                                         except the proxy user ─► tinyproxy ─► pypi.org, files.pythonhosted.org
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

Then verify the sandbox: `docker compose exec -u dev agent test-firewall.sh` (see
[Verify it yourself](#verify-it-yourself)).

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

## The sandbox

The threat we defend against: *something inside the container tries to send your code, or anything else,
to the internet.* "Something" is the model, the review script, the extension, a package installed from pypi,
or a malicious prompt that talks any of them into it. The defence is layered: each layer is independent, and
the one you log in as can't change any of them.

### Layer 1: the firewall (iptables, [`scripts/firewall.sh`](scripts/firewall.sh))

Installed by the entrypoint before anything else starts. If it fails to install, the container exits and sshd
never comes up: a broken firewall means no container, not an open one.

- **Default deny.** `INPUT`, `FORWARD` and `OUTPUT` chains all have policy `DROP`. Inbound allows only loopback,
  established connections and port 22. Outbound allows only loopback, established connections, and one
  exception below.
- **Egress is tied to a Linux user, not to a port.** The single outbound rule is
  `--uid-owner tinyproxy --dport 443 ACCEPT`. Processes running as `dev` (you, VS Code, the model, pip, anything
  you install) have no rule that matches them, so every packet they send to the outside is dropped. Even a
  process that knows the proxy's upstream address can't bypass the proxy, because it is not the proxy user.
- **DNS is closed too.** Resolving a name is itself an exfiltration channel (`secret.attacker.com`), so the
  rules allow DNS only for the proxy user and for root. Docker's embedded resolver at `127.0.0.11` is also
  blocked for everyone else. As `dev`, `getent hosts example.com` fails.
- **IPv6** is dropped except loopback, so there is no second stack to leak through.

### Layer 2: the allowlisting proxy (tinyproxy, [`config/tinyproxy.conf`](config/tinyproxy.conf))

The firewall says *who* may go out (one user); the proxy says *where*. tinyproxy listens on `127.0.0.1:8888`,
`FilterDefaultDeny Yes`, and only forwards `CONNECT` on port 443 to hostnames matching
[`config/allowlist`](config/allowlist):

```
^pypi\.org$
^files\.pythonhosted\.org$
```

`/etc/pip.conf` points pip at the proxy, so `pip install` works and nothing else does. Filtering by hostname
is deliberate: pypi sits behind a shared CDN, so allowing its IP addresses would allow thousands of other
sites on the same CDN. To allow another host, add a regex line and rebuild; keep the list short and read it
as "the complete list of places this container can reach".

### Layer 3: privileges

- The container needs `NET_ADMIN` only for the firewall script, which runs as root at startup. You log in as
  `dev`: not root, no sudo installed, so `iptables` says "permission denied" and the rules cannot be changed
  from inside a session.
- `no-new-privileges` is set, so no binary can gain capabilities through setuid.
- Memory is capped (`MEM_LIMIT`), so a runaway model is contained too.

### Layer 4: SSH ([`config/sshd.conf`](config/sshd.conf))

SSH is the only door in, and it is shaped so it can't become a door out:

- Key-only, user `dev` only, published on `127.0.0.1:2222` so nothing else on your network can reach it.
- **Remote port forwarding (`-R`) is disabled.** With it, a process in the container could open a listener on
  your Mac and tunnel through your Mac's internet access, defeating every layer above. Local forwarding (`-L`)
  stays on because VS Code Remote-SSH needs it, and it only lets your Mac reach into the container, not the
  reverse.
- No agent forwarding, no X11, no tunnels, no gateway ports.

### Layer 5: the model and the tooling have no network code

Ollama listens on `127.0.0.1:11434` inside the container and is not published. The review script talks to it
over loopback with the standard library and nothing else. The VS Code extension runs on the remote side and
contains **no network code at all**: it runs the review script and shows the result;
[`scripts/audit-extension.sh`](scripts/audit-extension.sh) fails if that ever changes. The model weights are
pulled at build time, so at runtime there is nothing left that *needs* the internet.

### Verify it yourself

```bash
docker compose exec -u dev agent test-firewall.sh
```

It must print `ok` for all eight checks: pypi reachable through the proxy, `pip download` works, Ollama
answers on loopback, and example.com, github.com, pypi without the proxy, a raw IP, and a DNS lookup are all
blocked. Run it after every rebuild and after any change to the firewall or the allowlist. For a second
opinion, `docker compose exec agent iptables -L OUTPUT -v -n` shows the rules and their packet counters.

### What the sandbox does not do

- Root processes in the container (sshd, Ollama) can do upstream DNS. They have no reason to, but the
  firewall doesn't stop them.
- Packages installed from pypi run inside the sandbox: they can't phone home, but they can read `/workspace`.
  Pin what you install.
- The workspace mount is read-write by design, so the agent's suggestions can be applied. Commit inside the
  container or on the host as you prefer; pushing has to happen on the host, because the container can't
  reach your git remote.
- It is a container, not a VM. A kernel escape would bypass all of this. If that is in your threat model, run
  the container inside a VM.
