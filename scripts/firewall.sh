#!/bin/bash
# Default-deny egress. Only the tinyproxy user may leave the container, only on 443,
# and tinyproxy itself only forwards to hosts in /etc/tinyproxy/allowlist.
set -euo pipefail
PROXY_UID=$(id -u tinyproxy)

iptables -F
iptables -X
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -p tcp --dport 22 -j ACCEPT

iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
# Docker's embedded DNS (127.0.0.11) forwards upstream, so DNS is an exfil path: proxy only.
iptables -A OUTPUT -d 127.0.0.11 -m owner --uid-owner "$PROXY_UID" -j ACCEPT
iptables -A OUTPUT -d 127.0.0.11 -j DROP
iptables -A OUTPUT -o lo -j ACCEPT
# Upstream DNS: the proxy (default bridge network) and root, which is what Docker's embedded
# resolver forwards as. The dev user is not root and can't reach 127.0.0.11, so it can't resolve.
for uid in "$PROXY_UID" 0; do
  iptables -A OUTPUT -p udp --dport 53 -m owner --uid-owner "$uid" -j ACCEPT
  iptables -A OUTPUT -p tcp --dport 53 -m owner --uid-owner "$uid" -j ACCEPT
done
iptables -A OUTPUT -p tcp --dport 443 -m owner --uid-owner "$PROXY_UID" -j ACCEPT

# IPv6 may be disabled in the container; if it exists, drop everything but loopback.
if ip6tables -L >/dev/null 2>&1; then
  ip6tables -F
  ip6tables -P INPUT DROP
  ip6tables -P FORWARD DROP
  ip6tables -P OUTPUT DROP
  ip6tables -A INPUT -i lo -j ACCEPT
  ip6tables -A OUTPUT -o lo -j ACCEPT
fi
echo "firewall: egress locked to tinyproxy (uid $PROXY_UID) -> $(paste -sd' ' /etc/tinyproxy/allowlist)"
