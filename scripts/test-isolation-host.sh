#!/bin/bash
# Run on the HOST, in the shell you ran ./up.sh from. Proves the isolation Docker enforces from
# outside the agent: a throwaway container with NO in-container firewall, on the same `sandbox`
# network, still reaches nothing but the proxy, and the proxy still refuses non-allowlisted hosts.
set -uo pipefail
cd "$(dirname "$0")/.."
cid=$(docker compose ps -q agent) && [ -n "$cid" ] || { echo "agent is not running; ./up.sh first"; exit 1; }
img=$(docker inspect -f '{{.Config.Image}}' "$cid")
net=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' "$cid")
fail=0
check() {
  if docker run --rm --network "$net" --add-host proxy:172.30.0.2 --entrypoint timeout "$img" 15 bash -c "$2" >/dev/null 2>&1; then r=allowed; else r=blocked; fi
  if [ "$r" = "$1" ]; then echo "ok    $r: $2"; else echo "FAIL  $r (expected $1): $2"; fail=1; fi
}
docker network inspect -f '{{.Internal}}' "$net" | grep -qx true && echo "ok    network $net is internal (Docker, host side)" \
  || { echo "FAIL  network $net is not internal"; fail=1; }
check blocked "curl -sf --max-time 5 https://1.1.1.1"
check blocked "curl -sf --max-time 5 https://pypi.org"
check blocked "getent hosts example.com"
check blocked "curl -sf -x http://proxy:8888 https://example.com"
check allowed "curl -sf -x http://proxy:8888 https://pypi.org/simple/ruff/"
exit $fail
