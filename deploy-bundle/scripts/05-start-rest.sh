#!/usr/bin/env bash
# Starts everything else: Authelia, server_info, weekly_report, galene,
# galene-auth-bridge, password-change-bridge. Run 03 + 04 first (Authelia
# needs the authelia-svc account 04 creates; password-change-bridge needs
# the password-bridge-svc account 04 also creates).
set -euo pipefail
BUNDLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$BUNDLE_DIR"

mkdir -p data/galene/recordings

# Named podman volumes (not host-directory bind mounts) for server_info and
# weekly_report: both containers run as a non-root user baked into the
# image, and a bind-mounted host directory keeps the host user's ownership,
# which that in-container user can't write to. A named volume gets
# initialized with the image's own baked-in ownership on first use instead.
podman volume inspect server_info_data >/dev/null 2>&1 || podman volume create server_info_data
podman volume inspect weekly_report_data >/dev/null 2>&1 || podman volume create weekly_report_data

# ---- Authelia ---------------------------------------------------------------
podman rm -f authelia 2>/dev/null || true
podman run -d --name authelia \
  --restart unless-stopped \
  --network sdicnet \
  -p 127.0.0.1:9091:9091 \
  -v "${BUNDLE_DIR}/rendered/authelia:/config:Z" \
  docker.io/authelia/authelia:latest

# ---- server_info ------------------------------------------------------------
podman rm -f server-info 2>/dev/null || true
podman run -d --name server-info \
  --restart unless-stopped \
  --network sdicnet \
  -p 127.0.0.1:3000:3000 \
  --env-file rendered/server_info.env \
  -v server_info_data:/app/data:Z \
  localhost/server-info:latest

# ---- weekly_report ------------------------------------------------------------
podman rm -f weekly-report 2>/dev/null || true
podman run -d --name weekly-report \
  --restart unless-stopped \
  --network sdicnet \
  -p 127.0.0.1:8080:8080 \
  --env-file rendered/weekly_report.env \
  -v weekly_report_data:/data:Z \
  localhost/weekly-report:latest

# ---- galene -------------------------------------------------------------
podman rm -f galene 2>/dev/null || true
podman run -d --name galene \
  --restart unless-stopped \
  --network sdicnet \
  -p 127.0.0.1:8180:8080 \
  -v "${BUNDLE_DIR}/rendered/galene/data:/galene/data:Z" \
  -v "${BUNDLE_DIR}/rendered/galene/groups:/galene/groups:Z" \
  -v "${BUNDLE_DIR}/data/galene/recordings:/galene/recordings:Z" \
  --entrypoint /galene/galene \
  localhost/galene-sdic:latest \
  -http :8080 -insecure

# ---- galene-auth-bridge ------------------------------------------------------
podman rm -f galene-auth-bridge 2>/dev/null || true
podman run -d --name galene-auth-bridge \
  --restart unless-stopped \
  --network sdicnet \
  -p 127.0.0.1:8090:8090 \
  --env-file rendered/galene-auth-bridge.env \
  localhost/galene-auth-bridge:latest

# ---- password-change-bridge --------------------------------------------------
podman rm -f password-change-bridge 2>/dev/null || true
podman run -d --name password-change-bridge \
  --restart unless-stopped \
  --network sdicnet \
  -p 127.0.0.1:8095:8095 \
  --env-file rendered/password-change-bridge.env \
  localhost/password-change-bridge:latest

sleep 2
echo "==> Status:"
podman ps --format "{{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -E "lldap|authelia|server-info|weekly-report|galene|password-change-bridge"
