# Sandboxed local AI coding agent

An AI coding assistant that runs **entirely on your machine, inside a sandbox that cannot talk to the
internet**. Your code, your review rules and the model's output never leave the container. It is a Docker
dev container with a local [Ollama](https://ollama.com) (Qwen, Gemma or Devstral), an SSH server for VS Code,
and a two-layer firewall that is the whole point of the project: one enforced by Docker on the host, one
inside the container.

## Goals

1. **Local assistant, not a cloud service.** The model runs on CPU inside the container; the weights are baked
   into the image at build time. No API key, no account, no telemetry, nothing to subscribe to.
2. **Sandboxed by construction.** The agent container has no route to the internet at all. The only way out
   is a separate proxy container with a **configurable whitelist** of hostnames, which by default holds
   nothing but pypi, so Python packages can still be installed. Everything inside the agent container, the
   model, the review script, the VS Code extension, anything you `pip install`, and the root user too, is cut
   off from the network. [The sandbox](#the-sandbox) below explains each layer and how to verify it.
3. **Assist, never act.** The agent reviews code against your team's rules and past PR comments (the things ruff
   can't check) and suggests clarity, organization and documentation improvements. It shows every suggestion
   as a VS Code diff and writes nothing to your files until you click Apply. It never commits, never pushes,
   never runs in the background.

```
 your Mac ── ssh 127.0.0.1:2222 ──► proxy container ── socat ──► agent container ── 127.0.0.1:11434 ──► ollama
                                    │  (egress + sandbox nets)      (sandbox net ONLY: Docker gives it no route out)
                                    │                               in-container iptables: all users, root too,
                                    │                               may reach proxy:8888 and nothing else
                                    └─ tinyproxy whitelist ──► pypi.org, files.pythonhosted.org   (that's the list)
```

## Quick start

```bash
export SSH_PUBKEY="$(cat ~/.ssh/id_ed25519.pub)"
export WORKSPACE=~/code                      # host folder mounted at /workspace
./up.sh                                      # qwen2.5-coder:7b, 8 GB
OLLAMA_MODEL=qwen2.5-coder:14b ./up.sh       # the table below sets MODEL_PROFILE=16gb and MEM_LIMIT=16g for you
MODEL_FAMILY=gemma MODEL_PROFILE=8gb ./up.sh # or pick by family/profile
```

`up.sh` looks the model up in [`config/models`](config/models), derives the defaults, and runs
`docker compose up -d --build`. Anything you export yourself wins, e.g. `MEM_LIMIT=20g` for Devstral.

| Build arg / env | Values | Default | Notes |
|---|---|---|---|
| `MODEL_FAMILY` | `qwen`, `gemma`, `devstral` | `qwen` | Docker build arg and compose env |
| `MODEL_PROFILE` | `8gb`, `16gb` | `8gb` | container RAM class; `devstral` exists for `16gb` only |
| `OLLAMA_MODEL` | any Ollama tag, e.g. `qwen2.5-coder:14b`, `gemma4:12b`, `devstral-small-2:24b` | from the table | overrides family/profile; `up.sh` derives the profile from it |
| `MEM_LIMIT` | e.g. `8g`, `16g`, `20g` | `MODEL_PROFILE` as `g` | hard memory cap of the agent container |
| `OLLAMA_CONTEXT_LENGTH` | tokens | `8192` | raise if you have RAM to spare |
| `WORKSPACE`, `SSH_PORT` | path, port | `./workspace`, `2222` | |

Model defaults (`config/models`):

| `MODEL_FAMILY` | `8gb` | `16gb` |
|---|---|---|
| `qwen` | `qwen2.5-coder:7b` | `qwen2.5-coder:14b` |
| `gemma` | `gemma4:e2b` | `gemma4:12b` |
| `devstral` | — | `devstral-small-2:24b` |

[`docs/models.md`](docs/models.md) compares the families (best for, pros, cons, resources). The model is
pulled **at build time**, because at runtime the sandbox cannot reach the Ollama registry. To change the
model, rebuild. Plain `docker compose` works too (`MODEL_FAMILY=gemma MODEL_PROFILE=16gb MEM_LIMIT=16g
docker compose up -d --build`); `up.sh` only fills in the defaults.

Then verify the sandbox from both sides (see [Verify it yourself](#verify-it-yourself)):

```bash
scripts/test-isolation-host.sh                          # host side: Docker's isolation
docker compose exec -u dev agent test-firewall.sh       # inside, as dev
docker compose exec agent test-firewall.sh              # inside, as root
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
`/opt/agent/local-agent-chat.vsix` ([how](extension/README.md)). Install it once, from the remote window's
terminal:

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
hit the sandbox.

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

The threat we defend against: *something inside the agent container tries to send your code, or anything
else, to the internet.* "Something" is the model, the review script, the extension, a package installed from
pypi, a malicious prompt that talks any of them into it, or a process that has become root. The defence is a
**configurable whitelist firewall**: everything is denied unless a hostname is on the list, and the list
ships with pypi only ([`proxy/allowlist`](proxy/allowlist)). It is enforced twice, from outside the agent
container and from inside it, so that neither layer has to be perfect.

### Layer 0: isolation managed from the host (Docker `internal` network)

[`docker-compose.yml`](docker-compose.yml) puts the agent container on exactly one network, `sandbox`,
declared `internal: true`. Docker, running on the host, creates that network with no gateway, no NAT and
no route to anything outside it. This is not a rule inside the container: nothing that runs in the
container, root included, can see or change it. If you flushed every iptables rule inside the agent, it
would still have nowhere to go. The container also publishes no ports.

The only other member of `sandbox` is the `proxy` container, which is also on an ordinary bridge network
and is therefore the single path out. `scripts/test-isolation-host.sh` proves this from the host by starting
a throwaway container on `sandbox` with no firewall of its own and showing it reaches nothing but the proxy.

### Layer 1: the whitelist proxy ([`proxy/`](proxy))

The proxy container is Alpine with two processes and no user code: `socat`, which forwards port 2222 to the
agent's SSH, and `tinyproxy`, which accepts clients from the `sandbox` subnet only, `FilterDefaultDeny Yes`,
and forwards `CONNECT` on port 443 to hostnames matching the whitelist:

```
^pypi\.org$
^files\.pythonhosted\.org$
```

Read that as "the complete list of places the sandbox can reach". `/etc/pip.conf` in the agent points pip at
`proxy:8888`, so `pip install` works and nothing else does. Filtering by hostname is deliberate: pypi sits
behind a shared CDN, so allowing its IP addresses would allow thousands of other sites on the same CDN. To
allow another host, add a regex line and rebuild the proxy (`docker compose up -d --build proxy`). Every
line you add is a hole; keep the list short.

### Layer 2: the firewall inside the agent ([`scripts/firewall.sh`](scripts/firewall.sh))

Defence in depth: the same policy again, from the inside, and it **applies to every user, root included**.
Installed by the entrypoint before anything else starts; if it fails to install, the container exits and
sshd never comes up, so a broken firewall means no container, not an open one.

- `INPUT`, `FORWARD` and `OUTPUT` all default to `DROP`.
- Outbound, the single destination any process may open is `proxy:8888`. There is no per-user exception
  any more: a root shell in the container is as cut off as the `dev` user.
- Inbound, port 22 is accepted only from the proxy, so SSH can arrive only through the sidecar.
- **DNS is closed.** Resolving a name is itself an exfiltration channel (`secret.attacker.com`), and Docker's
  embedded resolver at `127.0.0.11` would forward lookups upstream, so it is dropped explicitly. The proxy's
  address is pinned in `/etc/hosts`, so nothing inside ever needs DNS; `getent hosts example.com` fails.
- IPv6 is dropped except loopback, so there is no second stack to leak through.

### Layer 3: privileges

- The agent container needs `NET_ADMIN` only for the firewall script, which runs as root at startup. You log
  in as `dev`: not root, no sudo installed, so the rules cannot be changed from a session. And even root
  changing them would only reach Layer 0.
- `no-new-privileges` is set, so no binary can gain capabilities through setuid.
- Memory is capped (`MEM_LIMIT`), so a runaway model is contained too.

### Layer 4: SSH ([`config/sshd.conf`](config/sshd.conf))

SSH is the only door in, and it is shaped so it can't become a door out:

- Key-only, user `dev` only, published on `127.0.0.1:2222` by the proxy, so nothing else on your network
  can reach it, and the agent container itself publishes nothing.
- **Remote port forwarding (`-R`) is disabled.** With it, a process in the container could open a listener on
  your Mac and tunnel through your Mac's internet access, defeating every layer above. Local forwarding (`-L`)
  stays on because VS Code Remote-SSH needs it, and it only lets your Mac reach into the container, not the
  reverse.
- No agent forwarding, no X11, no tunnels, no gateway ports, no reverse DNS on login.

### Layer 5: the model and the tooling have no network code

Ollama listens on `127.0.0.1:11434` inside the agent and is not published. The review script talks to it over
loopback with the standard library and nothing else. The VS Code extension runs on the remote side and
contains **no network code at all**: it runs the review script and shows the result;
[`scripts/audit-extension.sh`](scripts/audit-extension.sh) fails if that ever changes. The model weights are
pulled at build time, so at runtime there is nothing left that *needs* the internet.

### Verify it yourself

```bash
scripts/test-isolation-host.sh                          # Layer 0 + 1, from the host
docker compose exec -u dev agent test-firewall.sh       # Layer 2, as dev
docker compose exec agent test-firewall.sh              # Layer 2, as root
```

The host script checks that the `sandbox` network is `internal` and that a fresh, unfirewalled container on
it cannot reach a raw IP, pypi directly, or DNS, cannot get example.com through the proxy, and can get pypi
through the proxy. The in-container script must print `ok` for all eight checks for both users: pypi
through the proxy, `pip download`, Ollama on loopback, and example.com, github.com, pypi without the proxy,
a raw IP and a DNS lookup all blocked. Run them after every rebuild and after any change to the whitelist.
For a second opinion, `docker compose exec agent iptables -L -v -n` shows the rules and their packet
counters, and `docker network inspect` shows `"Internal": true`.

### What the sandbox does not do

- Packages installed from pypi run inside the sandbox: they can't phone home, but they can read `/workspace`.
  Pin what you install.
- The proxy container is trusted: it runs no user code, but it is the one place with a route out, so keep
  the whitelist short and rebuild it from this repo only.
- The workspace mount is read-write by design, so the agent's suggestions can be applied. Commit inside the
  container or on the host as you prefer; pushing has to happen on the host, because the container can't
  reach your git remote.
- It is a container, not a VM. A kernel escape would bypass all of this. If that is in your threat model, run
  the whole stack inside a VM.
