#!/usr/bin/env bash
# Starts lldap (the member directory) and creates the shared podman network
# everything else attaches to. Run 00 and 01 first.
set -euo pipefail
BUNDLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$BUNDLE_DIR"

podman network exists sdicnet || podman network create sdicnet

mkdir -p data/lldap

podman rm -f lldap 2>/dev/null || true
podman run -d --name lldap \
  --restart unless-stopped \
  --network sdicnet \
  -p 127.0.0.1:3890:3890 \
  -p 127.0.0.1:17170:17170 \
  -v "${BUNDLE_DIR}/data/lldap:/data:Z" \
  --env-file rendered/lldap.env \
  docker.io/lldap/lldap:stable

echo "==> lldap starting. Web UI stays loopback-only (127.0.0.1:17170) — see README for how to reach it via SSH tunnel."
echo "==> Wait ~5s for it to finish booting, then run 04-bootstrap-lldap.sh."
