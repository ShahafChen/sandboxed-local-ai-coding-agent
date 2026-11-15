# Default review rules

Copy this file to `<repo>/.agent/rules.md` and edit it per repo. Only list things a linter can't check.

- Validate input at trust boundaries (HTTP handlers, queue consumers, CLI args); internal code may trust its callers.
- Never log secrets, tokens, passwords or full request bodies.
- No hardcoded credentials, hostnames or environment-specific URLs; read them from config.
- Errors that can lose data must be handled or re-raised, never swallowed with a bare `except: pass`.
- Database migrations on large tables must not take long locks (e.g. create indexes concurrently).
- Public functions and classes need a docstring that says *why*, not what.
- New non-trivial logic needs at least one test.
- Prefer existing helpers in the codebase over new near-duplicates.
