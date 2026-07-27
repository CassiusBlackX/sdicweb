#!/usr/bin/env bash
# Loads every image tarball in ../images into podman's local store.
set -euo pipefail
cd "$(dirname "$0")/../images"

for f in *.tar.gz; do
  echo "==> Loading $f"
  podman load -i "$f"
done

podman images | grep -E "server-info|weekly-report|galene|authelia|lldap"
