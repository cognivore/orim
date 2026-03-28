#!/usr/bin/env bash
# Runs ON the VM via SSH.  Installs Caddy, deploys the dual-origin
# config and corpus, then starts the service.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# ─── Install Caddy from upstream APT repo ──────────────────────────────────────

if ! command -v caddy &>/dev/null; then
  apt-get update -qq
  apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https curl

  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg

  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    | tee /etc/apt/sources.list.d/caddy-stable.list

  apt-get update -qq
  apt-get install -y -qq caddy
fi

# ─── Deploy Caddyfile ──────────────────────────────────────────────────────────

cp /tmp/Caddyfile /etc/caddy/Caddyfile

# ─── Deploy corpus ─────────────────────────────────────────────────────────────

mkdir -p /var/www/corpus
cp /tmp/corpus/* /var/www/corpus/

# ─── Start / restart Caddy ─────────────────────────────────────────────────────

systemctl enable caddy
systemctl restart caddy

sleep 2
if systemctl is-active --quiet caddy; then
  echo "Caddy is running."
else
  echo "ERROR: Caddy failed to start" >&2
  journalctl -u caddy --no-pager -n 30
  exit 1
fi
