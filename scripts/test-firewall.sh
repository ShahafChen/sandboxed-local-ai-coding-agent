#!/bin/bash
# Run inside the container (as dev or root). Exits non-zero if the sandbox leaks or pypi is unreachable.
P=http://127.0.0.1:8888
fail=0
check() {
  if timeout 15 bash -c "$2" >/dev/null 2>&1; then r=allowed; else r=blocked; fi
  if [ "$r" = "$1" ]; then echo "ok    $r: $2"; else echo "FAIL  $r (expected $1): $2"; fail=1; fi
}
check allowed "curl -sf -x $P https://pypi.org/simple/ruff/"
check allowed "python3 -m pip download -q --no-deps -d \$(mktemp -d) six"
check allowed "curl -sf http://127.0.0.1:11434/api/tags"
check blocked "curl -sf -x $P https://example.com"
check blocked "curl -sf -x $P https://github.com"
check blocked "curl -sf --max-time 5 https://pypi.org"
check blocked "curl -sf --max-time 5 https://1.1.1.1"
check blocked "getent hosts example.com"
exit $fail
