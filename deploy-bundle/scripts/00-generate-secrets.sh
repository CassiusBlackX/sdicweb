#!/usr/bin/env bash
# Generates a fresh secrets.env for THIS deployment. Never reuse the dev
# box's secrets in production. Run this once, on the production server,
# before rendering configs. Re-running overwrites secrets.env with a brand
# new set (only do that on a from-scratch deployment, not to "rotate" an
# already-provisioned one, since e.g. Authelia session/storage keys are
# tied to already-written database state).
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -f secrets.env ]; then
  echo "secrets.env already exists. Refusing to overwrite; delete it first if you really want a fresh set." >&2
  exit 1
fi

rand_hex() { openssl rand -hex 32; }
rand_pw()  { openssl rand -base64 24 | tr -d '/+=' | head -c 24; }

cat > secrets.env <<EOF
# Generated $(date -u +%Y-%m-%dT%H:%M:%SZ). Keep this file private (chmod 600)
# and never commit it. It is consumed by 01-render-configs.sh and by
# 04-bootstrap-lldap.sh.

LLDAP_JWT_SECRET=$(rand_hex)
LLDAP_KEY_SEED=$(rand_hex)
LLDAP_ADMIN_PASS=$(rand_pw)

AUTHELIA_SESSION_SECRET=$(rand_hex)
AUTHELIA_STORAGE_ENCRYPTION_KEY=$(rand_hex)
AUTHELIA_RESET_PASSWORD_JWT_SECRET=$(rand_hex)
AUTHELIA_LDAP_BIND_PASS=$(rand_pw)
PASSWORD_BRIDGE_LDAP_PASS=$(rand_pw)

SERVER_INFO_SESSION_SECRET=$(rand_hex)
WEEKLY_REPORT_SECRET_KEY=$(rand_hex)

GALENE_JWT_SECRET=$(node -e "console.log(require('crypto').randomBytes(32).toString('base64url'))" 2>/dev/null || openssl rand -base64 32 | tr '+/' '-_' | tr -d '=')
EOF
chmod 600 secrets.env
echo "Wrote secrets.env (chmod 600)."
