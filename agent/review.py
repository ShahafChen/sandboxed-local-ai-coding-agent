#!/usr/bin/env python3
"""Local code reviewer. Advisory: it never edits files itself.

Usage:
  agent-review                               review staged changes against the rules (prints findings, exit 0)
  agent-review --rev RANGE                   same for a git range, e.g. origin/dev..HEAD
  agent-review --rewrite FILE --mode MODE    print FILE rewritten by the model; the VS Code tab diffs it
                                             MODE = rules   (fix rule / past-PR-comment violations, each marked `CR:`)
                                             MODE = general (clarity, organization, comments, docstrings)
"""

import json
import re
import subprocess
import sys
import os
import urllib.request
from pathlib import Path

OLLAMA = "http://127.0.0.1:11434/api/chat"
MAX_DIFF_CHARS = 24_000  # keeps prompt inside OLLAMA_CONTEXT_LENGTH=8192 tokens
MAX_FILE_CHARS = 12_000  # a rewrite needs the file twice (in and out) in the same context

REVIEW_SYSTEM = """You are a senior code reviewer running before a commit.
Ruff already enforces style, formatting and lint, so never comment on those.
Review ONLY the diff against the team rules and past PR review comments given below.
For each finding output: `file:line` - rule violated - what to change (show a short suggested snippet).
Also point out public functions/classes in the diff that lack docstrings and suggest one.
If nothing violates the rules, say "No findings." Do not invent issues."""

REWRITE_SYSTEM = """You are a senior code reviewer. Ruff handles style and formatting, so never reformat code.
Reply with the complete rewritten file in ONE fenced code block and nothing else.
If nothing should change, return the file unchanged."""

REWRITE_TASK = {
    "rules": "Rewrite the file so it complies with the team rules and the past PR review comments. "
             "Directly above each block you change, add ONE comment line in this file's comment syntax: "
             "`CR: <rule> - <why>`. Change nothing that the rules do not require.",
    "general": "Improve the file for a human reader: clearer names where it is safe, better organization, "
               "comments that explain why, docstrings for public functions and classes. Do not change behavior.",
}


def model() -> str:
    return os.environ.get("OLLAMA_MODEL") or Path("/etc/agent-model").read_text().strip()


def read_first(*paths: Path) -> str:
    for p in paths:
        if p.is_file():
            return p.read_text()
    return ""


def git_root(cwd: Path) -> Path:
    try:
        return Path(subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True, cwd=cwd,
                                            stderr=subprocess.DEVNULL).strip())
    except (subprocess.CalledProcessError, FileNotFoundError):
        return cwd


def rules_section(root: Path) -> str:
    rules = read_first(root / ".agent/rules.md", Path("/opt/agent/rules.md"))
    comments = read_first(root / ".agent/pr-comments.md")
    return f"## Team rules\n{rules}\n\n## Past PR review comments\n{comments or '(none)'}\n\n"


def chat(system: str, user: str, echo: bool) -> str:
    """Stream a chat completion from the local Ollama; returns the full reply, printing it as it comes if echo."""
    body = json.dumps({
        "model": model(),
        "stream": True,
        "options": {"temperature": 0.2},
        "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
    }).encode()
    req = urllib.request.Request(OLLAMA, body, {"Content-Type": "application/json"})
    out = []
    with urllib.request.urlopen(req, timeout=900) as resp:
        for line in resp:
            if line.strip():
                chunk = json.loads(line).get("message", {}).get("content", "")
                out.append(chunk)
                if echo:
                    print(chunk, end="", flush=True)
    return "".join(out)


def review_diff(git_args: list[str]) -> None:
    root = git_root(Path.cwd())
    try:
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
    chat(REVIEW_SYSTEM, rules_section(root) + f"## Diff\n```diff\n{diff}\n```", echo=True)
    print()


def rewrite(path: Path, mode: str) -> None:
    src = path.read_text()
    if len(src) > MAX_FILE_CHARS:
        sys.exit(f"agent-review: {path.name} is {len(src)} chars; the model context fits about {MAX_FILE_CHARS}. "
                 "Split the file or raise OLLAMA_CONTEXT_LENGTH.")
    prompt = rules_section(git_root(path.parent)) if mode == "rules" else ""
    prompt += f"## Task\n{REWRITE_TASK[mode]}\n\n## File `{path.name}`\n```\n{src}\n```"
    reply = chat(REWRITE_SYSTEM, prompt, echo=False)
    m = re.search(r"```[^\n]*\n(.*?)```", reply, re.S)
    body = m.group(1) if m else reply
    sys.stdout.write(body.rstrip("\n") + "\n")


def main() -> None:
    args = sys.argv[1:]
    try:
        if len(args) == 4 and args[0] == "--rewrite" and args[2] == "--mode" and args[3] in REWRITE_TASK:
            rewrite(Path(args[1]), args[3])
        elif args[:1] == ["--rev"] and len(args) > 1:
            review_diff(["diff", args[1]])
        elif not args:
            review_diff(["diff", "--cached"])
        else:
            sys.exit(__doc__)
    except OSError as e:
        sys.exit(f"agent-review: Ollama not reachable at {OLLAMA}: {e}")


if __name__ == "__main__":
    main()
