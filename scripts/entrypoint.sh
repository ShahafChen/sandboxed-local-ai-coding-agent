#!/bin/bash
set -euo pipefail
: "${SSH_PUBKEY:?SSH_PUBKEY must be set to your public key}"

# Firewall first: if it fails, set -e stops the container before anything can talk.
/usr/local/bin/firewall.sh

install -d -m 700 -o dev -g dev /home/dev/.ssh
printf '%s\n' "$SSH_PUBKEY" > /home/dev/.ssh/authorized_keys
chown dev:dev /home/dev/.ssh/authorized_keys
chmod 600 /home/dev/.ssh/authorized_keys

ollama serve >/var/log/ollama.log 2>&1 &

exec /usr/sbin/sshd -D -e
