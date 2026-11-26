#!/bin/bash
# Fails if the extension gains a file, a dependency, a new module import, any network code,
# or a second subprocess. Its only I/O is running /opt/agent/review.py and showing the result.
set -euo pipefail
cd "$(dirname "$0")/../extension"
fail=0
[ "$(ls)" = "$(printf 'extension.js\npackage.json')" ] || { echo "FAIL: unexpected files: $(ls | tr '\n' ' ')"; fail=1; }
grep -q '"dependencies"' package.json && { echo "FAIL: package.json declares dependencies"; fail=1; }
mods=$(grep -oE "require\('[^']+'\)" extension.js | sort -u | tr '\n' ' ')
[ "$mods" = "require('child_process') require('crypto') require('path') require('vscode') " ] \
  || { echo "FAIL: imports changed: $mods"; fail=1; }
grep -nE "https?://|fetch\(|XMLHttpRequest|WebSocket|\bnet\.|\bdns\.|\btls\." extension.js \
  && { echo "FAIL: network-looking code above"; fail=1; }
[ "$(grep -cE "\b(exec|execFile|spawn|execSync|spawnSync|fork)\(" extension.js)" = 1 ] \
  && grep -q "execFile('/opt/agent/review.py'" extension.js \
  || { echo "FAIL: expected exactly one subprocess call, to /opt/agent/review.py"; fail=1; }
[ $fail = 0 ] && echo "extension audit: ok (no network code; one subprocess: /opt/agent/review.py)"
exit $fail
