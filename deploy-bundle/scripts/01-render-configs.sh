#!/usr/bin/env bash
# Renders every config file needed by the containers, using secrets.env
# (run 00-generate-secrets.sh first) plus the deployment-specific variables
# below. Edit DOMAIN/ADMIN_USERNAME/ADMIN_EMAIL, or export them before
# calling this script, then run it. Idempotent: safe to re-run after
# editing the variables (it always regenerates ./rendered from scratch).
set -euo pipefail
cd "$(dirname "$0")/.."

: "${DOMAIN:=sdic.sjtu.edu.cn}"
: "${ADMIN_USERNAME:?Set ADMIN_USERNAME to the lab admin login name, e.g. ADMIN_USERNAME=zhang_wei ./01-render-configs.sh — do not use admin.}"
: "${ADMIN_EMAIL:=${ADMIN_USERNAME}@${DOMAIN}}"

# server_info's "someone edited the shared doc" notification. Recipient
# defaults to ADMIN_EMAIL above; SMTP_* are blank (no notification sent —
# server_info logs a warning instead) unless you set them. Example:
#   SERVER_INFO_SMTP_HOST=smtp.qq.com SERVER_INFO_SMTP_USER=lab@qq.com \
#   SERVER_INFO_SMTP_PASS=xxxx ADMIN_USERNAME=zhang_wei ./01-render-configs.sh
: "${SERVER_INFO_ADMIN_EMAIL:=${ADMIN_EMAIL}}"
: "${SERVER_INFO_SMTP_HOST:=}"
: "${SERVER_INFO_SMTP_PORT:=465}"
: "${SERVER_INFO_SMTP_SECURE:=true}"
: "${SERVER_INFO_SMTP_USER:=}"
: "${SERVER_INFO_SMTP_PASS:=}"
: "${SERVER_INFO_SMTP_FROM:=}"

if [ "$ADMIN_USERNAME" = "admin" ]; then
  echo "Refusing to use 'admin' as ADMIN_USERNAME — that's exactly the default-credential pattern this deployment is meant to avoid. Pick a real name." >&2
  exit 1
fi

if [ ! -f secrets.env ]; then
  echo "secrets.env not found — run 00-generate-secrets.sh first." >&2
  exit 1
fi
source secrets.env

rm -rf rendered
mkdir -p rendered/authelia rendered/galene/groups rendered/galene/data

# ---- lldap ----------------------------------------------------------------
cat > rendered/lldap.env <<EOF
LLDAP_JWT_SECRET=${LLDAP_JWT_SECRET}
LLDAP_KEY_SEED=${LLDAP_KEY_SEED}
LLDAP_LDAP_BASE_DN=dc=sdic,dc=local
LLDAP_LDAP_USER_PASS=${LLDAP_ADMIN_PASS}
LLDAP_LDAP_USER_DN=${ADMIN_USERNAME}
LLDAP_LDAP_USER_EMAIL=${ADMIN_EMAIL}
TZ=Asia/Shanghai
EOF

# ---- Authelia ---------------------------------------------------------------
cat > rendered/authelia/configuration.yml <<EOF
---
theme: light

server:
  address: 'tcp://:9091/authelia'
  buffers:
    read: 8192
    write: 8192

log:
  level: info

totp:
  disable: true

webauthn:
  disable: true

identity_validation:
  reset_password:
    jwt_secret: '${AUTHELIA_RESET_PASSWORD_JWT_SECRET}'

authentication_backend:
  password_reset:
    disable: true
  password_change:
    # The built-in Change Password dialog requires "session elevation" —
    # an emailed one-time code — unconditionally (hardcoded into the
    # /api/change-password route, not config-conditional; the only
    # email-free path is TOTP/WebAuthn 2FA, which this deployment doesn't
    # run). Directory emails are typically placeholders, not real
    # mailboxes, so that code can never arrive. Disabled here; /account/
    # (password-change-bridge) is the working replacement.
    disable: true
  ldap:
    implementation: 'lldap'
    address: 'ldap://lldap:3890'
    base_dn: 'dc=sdic,dc=local'
    user: 'uid=authelia-svc,ou=people,dc=sdic,dc=local'
    password: '${AUTHELIA_LDAP_BIND_PASS}'

access_control:
  default_policy: 'deny'
  rules:
    - domain: '${DOMAIN}'
      resources:
        - '^/server_info(/.*)?\$'
      policy: 'one_factor'
    - domain: '${DOMAIN}'
      resources:
        - '^/weekly_report(/.*)?\$'
      policy: 'one_factor'
    - domain: '${DOMAIN}'
      resources:
        - '^/meetings(/.*)?\$'
        - '^/meetings-auth\$'
        - '^/group(/.*)?\$'
        - '^/public-groups\.json\$'
      policy: 'one_factor'
    - domain: '${DOMAIN}'
      resources:
        - '^/account(/.*)?\$'
      policy: 'one_factor'

session:
  secret: '${AUTHELIA_SESSION_SECRET}'
  cookies:
    - domain: '${DOMAIN}'
      authelia_url: 'https://${DOMAIN}/authelia'
      default_redirection_url: 'https://${DOMAIN}/'
      name: 'authelia_session'
      expiration: '12h'
      inactivity: '1h'

regulation:
  max_retries: 5
  find_time: '2m'
  ban_time: '5m'

storage:
  encryption_key: '${AUTHELIA_STORAGE_ENCRYPTION_KEY}'
  local:
    path: '/config/db.sqlite3'

notifier:
  disable_startup_check: true
  filesystem:
    filename: '/config/notification.txt'
EOF

# ---- server_info ------------------------------------------------------------
cat > rendered/server_info.env <<EOF
PORT=3000
BASE_PATH=/server_info
DATA_DIR=/app/data
SITE_TITLE=实验室服务器信息
SESSION_SECRET=${SERVER_INFO_SESSION_SECRET}
COOKIE_SECURE=true
ADMIN_EMAIL=${SERVER_INFO_ADMIN_EMAIL}
SMTP_HOST=${SERVER_INFO_SMTP_HOST}
SMTP_PORT=${SERVER_INFO_SMTP_PORT}
SMTP_SECURE=${SERVER_INFO_SMTP_SECURE}
SMTP_USER=${SERVER_INFO_SMTP_USER}
SMTP_PASS=${SERVER_INFO_SMTP_PASS}
SMTP_FROM=${SERVER_INFO_SMTP_FROM}
EOF

# ---- weekly_report ------------------------------------------------------------
# ADMIN_USERNAME matches the lldap admin login on purpose: this pre-seeds a
# role=admin row so your FIRST SSO login (as that same username) lands you
# in it directly. See 04-bootstrap-lldap.sh for why lldap needs this same
# username.
cat > rendered/weekly_report.env <<EOF
SECRET_KEY=${WEEKLY_REPORT_SECRET_KEY}
ADMIN_USERNAME=${ADMIN_USERNAME}
ADMIN_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)
TZ=Asia/Shanghai
COOKIE_SECURE=true
EOF

# ---- galene -------------------------------------------------------------
cat > rendered/galene/data/config.json <<EOF
{
    "proxyURL": "https://${DOMAIN}/meetings"
}
EOF

# GALENE_JWT_SECRET is plain base64url (alphabet A-Za-z0-9-_), so it needs
# no JSON escaping and this can just be a heredoc rather than a JSON library.
for room_spec in "room0:实验室大组会" "room1:临时会议室 1" "room2:临时会议室 2" "room3:临时会议室 3"; do
  room="${room_spec%%:*}"
  desc="SDIC ${room_spec#*:}"
  cat > "rendered/galene/groups/${room}.json" <<EOF
{
    "description": "${desc}",
    "public": false,
    "authServer": "/meetings-auth",
    "authKeys": [
        {
            "kty": "oct",
            "alg": "HS256",
            "k": "${GALENE_JWT_SECRET}"
        }
    ]
}
EOF
done

# ---- galene-auth-bridge ------------------------------------------------------
cat > rendered/galene-auth-bridge.env <<EOF
PORT=8090
GALENE_JWT_SECRET=${GALENE_JWT_SECRET}
GALENE_AUD_HOST=${DOMAIN}
EOF

# ---- password-change-bridge --------------------------------------------------
# Uses the dedicated password-bridge-svc account (04-bootstrap-lldap.sh),
# NOT the real admin login — that account is scoped to lldap_password_manager
# only, so it can reset regular members' passwords but is refused against
# admin accounts (verified: lldap returns 401 for that case).
cat > rendered/password-change-bridge.env <<EOF
PORT=8095
LLDAP_BASE_URL=http://lldap:17170
LLDAP_ADMIN_USERNAME=password-bridge-svc
LLDAP_ADMIN_PASSWORD=${PASSWORD_BRIDGE_LDAP_PASS}
EOF

chmod -R go-rwx rendered
echo "Rendered configs into ./rendered for DOMAIN=${DOMAIN}, ADMIN_USERNAME=${ADMIN_USERNAME}."
