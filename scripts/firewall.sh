#!/bin/bash
# Defence in depth inside the agent container. The host already isolates it (the `sandbox` network is
# `internal`, so there is no route out); these rules repeat that from the inside and apply to EVERY
# user, root included: the only destination any process may open is the proxy, and only on 8888.
set -euo pipefail

iptables -F
iptables -X
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -p tcp --dport 22 -s proxy -j ACCEPT   # ssh arrives only through the sidecar

# Docker's embedded DNS (127.0.0.11) would forward lookups upstream, so it is an exfil path: drop it
# before the loopback rule. `proxy` is in /etc/hosts, so nothing here needs DNS.
iptables -A OUTPUT -d 127.0.0.11 -j DROP
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -d proxy -p tcp --dport 8888 -j ACCEPT

# IPv6 may be disabled in the container; if it exists, drop everything but loopback.
if ip6tables -L >/dev/null 2>&1; then
  ip6tables -F
  ip6tables -P INPUT DROP
  ip6tables -P FORWARD DROP
  ip6tables -P OUTPUT DROP
  ip6tables -A INPUT -i lo -j ACCEPT
  ip6tables -A OUTPUT -o lo -j ACCEPT
fi
echo "firewall: all users (root included) may reach only proxy:8888; ssh accepted from the proxy only"
