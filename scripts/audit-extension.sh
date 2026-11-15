#!/bin/bash
# Fails if the extension gains a dependency, a new module import, or a network target other than loopback.
set -euo pipefail
cd "$(dirname "$0")/../extension"
fail=0
[ "$(ls)" = "$(printf 'extension.js\npackage.json')" ] || { echo "FAIL: unexpected files: $(ls | tr '\n' ' ')"; fail=1; }
grep -q '"dependencies"' package.json && { echo "FAIL: package.json declares dependencies"; fail=1; }
mods=$(grep -oE "require\('[^']+'\)" extension.js | sort -u | tr '\n' ' ')
[ "$mods" = "require('child_process') require('crypto') require('fs') require('http') require('vscode') " ] \
  || { echo "FAIL: imports changed: $mods"; fail=1; }
grep -nE "https?://|fetch\(|XMLHttpRequest|WebSocket|net\.|dgram|tls\.|https\b" extension.js \
  && { echo "FAIL: network-looking code above"; fail=1; }
[ "$(grep -c 'http.request(' extension.js)" = 1 ] || { echo "FAIL: expected exactly one http.request"; fail=1; }
grep -q "const OLLAMA_HOST = '127.0.0.1';" extension.js || { echo "FAIL: OLLAMA_HOST is not loopback"; fail=1; }
[ $fail = 0 ] && echo "extension audit: ok (only loopback http to Ollama)"
exit $fail
