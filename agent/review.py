#!/usr/bin/env python3
"""Review the staged git diff with the local model against your rules and past PR comments.

Advisory only: prints suggestions, never edits files, always exits 0 so it can't block a commit.
Usage: agent-review [--rev RANGE]   (default: staged changes; e.g. --rev origin/dev..HEAD)
"""

import json
import os
import subprocess
import sys
import urllib.request
from pathlib import Path

OLLAMA = "http://127.0.0.1:11434/api/chat"
MAX_DIFF_CHARS = 24_000  # keeps prompt inside OLLAMA_CONTEXT_LENGTH=8192 tokens

SYSTEM = """You are a senior code reviewer running before a commit.
Ruff already enforces style, formatting and lint, so never comment on those.
Review ONLY the diff against the team rules and past PR review comments given below.
For each finding output: `file:line` - rule violated - what to change (show a short suggested snippet).
Also point out public functions/classes in the diff that lack docstrings and suggest one.
If nothing violates the rules, say "No findings." Do not invent issues."""


def model() -> str:
    return os.environ.get("OLLAMA_MODEL") or Path("/etc/agent-model").read_text().strip()


def read_first(*paths: Path) -> str:
    for p in paths:
        if p.is_file():
            return p.read_text()
    return ""


def main() -> None:
    args = sys.argv[1:]
    git_args = ["diff", args[1]] if args[:1] == ["--rev"] and len(args) > 1 else ["diff", "--cached"]
    try:
        root = Path(subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip())
        diff = subprocess.check_output(["git", *git_args], text=True, cwd=root)
    except (subprocess.CalledProcessError, FileNotFoundError) as e:
        print(f"agent-review: not a git repo or git failed: {e}")
        return
    if not diff.strip():
        print("agent-review: no changes to review (stage files with git add).")
        return
    if len(diff) > MAX_DIFF_CHARS:
        print(f"agent-review: diff truncated to {MAX_DIFF_CHARS} chars; review smaller commits for full coverage.\n")
        diff = diff[:MAX_DIFF_CHARS]

    rules = read_first(root / ".agent/rules.md", Path("/opt/agent/rules.md"))
    comments = read_first(root / ".agent/pr-comments.md")
    prompt = f"## Team rules\n{rules}\n\n## Past PR review comments\n{comments or '(none)'}\n\n## Diff\n```diff\n{diff}\n```"

    body = json.dumps({
        "model": model(),
        "stream": True,
        "messages": [{"role": "system", "content": SYSTEM}, {"role": "user", "content": prompt}],
    }).encode()
    req = urllib.request.Request(OLLAMA, body, {"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=600) as resp:
            for line in resp:
                if line.strip():
                    print(json.loads(line).get("message", {}).get("content", ""), end="", flush=True)
        print()
    except OSError as e:
        print(f"agent-review: Ollama not reachable at {OLLAMA}: {e}")


if __name__ == "__main__":
    main()
