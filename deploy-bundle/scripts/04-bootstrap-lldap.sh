#!/usr/bin/env bash
# One-time setup inside a freshly-started lldap: creates the "lab" group
# (add real members to this) and the "authelia-svc" read/password-manager
# service account Authelia binds as. Safe to re-run (skips what already
# exists) except for setting authelia-svc's password, which it always
# re-applies to match secrets.env.
set -euo pipefail
BUNDLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$BUNDLE_DIR"
source secrets.env
: "${ADMIN_USERNAME:?Set ADMIN_USERNAME the same way you did for 01-render-configs.sh}"

api() {
  curl -sf -X POST http://127.0.0.1:17170/api/graphql \
    -H "Content-Type: application/json" -H "Authorization: Bearer $TOKEN" \
    -d "$1"
}

echo "==> Waiting for lldap to accept connections..."
for i in $(seq 1 30); do
  curl -sf -o /dev/null http://127.0.0.1:17170/ && break
  sleep 1
done

TOKEN=$(curl -sf -X POST http://127.0.0.1:17170/auth/simple/login \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"${ADMIN_USERNAME}\",\"password\":\"${LLDAP_ADMIN_PASS}\"}" \
  | python3 -c "import json,sys;print(json.load(sys.stdin)['token'])")

echo "==> Ensuring 'lab' group exists"
api '{"query":"mutation{createGroup(name:\"lab\"){id}}"}' || true

echo "==> Ensuring 'authelia-svc' service account exists"
api "{\"query\":\"mutation{createUser(user:{id:\\\"authelia-svc\\\",email:\\\"authelia-svc@sdic.local\\\",displayName:\\\"Authelia Service Account\\\"}){id}}\"}" || true

READONLY_GROUP_ID=$(api '{"query":"{groups{id displayName}}"}' | python3 -c "
import json,sys
data = json.load(sys.stdin)
for g in data['data']['groups']:
    if g['displayName'] == 'lldap_strict_readonly':
        print(g['id'])
")
MANAGER_GROUP_ID=$(api '{"query":"{groups{id displayName}}"}' | python3 -c "
import json,sys
data = json.load(sys.stdin)
for g in data['data']['groups']:
    if g['displayName'] == 'lldap_password_manager':
        print(g['id'])
")

echo "==> Granting authelia-svc read + password-manager rights (needed for LDAP bind + in-portal password change)"
api "{\"query\":\"mutation{addUserToGroup(userId:\\\"authelia-svc\\\",groupId:${READONLY_GROUP_ID}){ok}}\"}" || true
api "{\"query\":\"mutation{addUserToGroup(userId:\\\"authelia-svc\\\",groupId:${MANAGER_GROUP_ID}){ok}}\"}" || true

echo "==> Setting authelia-svc's password to match secrets.env"
podman exec lldap /app/lldap_set_password \
  --base-url http://localhost:17170 \
  --admin-username "${ADMIN_USERNAME}" \
  --admin-password "${LLDAP_ADMIN_PASS}" \
  --username authelia-svc \
  --password "${AUTHELIA_LDAP_BIND_PASS}"

echo "==> Ensuring 'password-bridge-svc' service account exists (used by /account/ self-service password change — least-privilege: password-manager only, NOT lldap_admin, so it can reset regular members' passwords but is refused against admin accounts)"
api "{\"query\":\"mutation{createUser(user:{id:\\\"password-bridge-svc\\\",email:\\\"password-bridge-svc@sdic.local\\\",displayName:\\\"Password Bridge Service Account\\\"}){id}}\"}" || true
api "{\"query\":\"mutation{addUserToGroup(userId:\\\"password-bridge-svc\\\",groupId:${MANAGER_GROUP_ID}){ok}}\"}" || true

echo "==> Setting password-bridge-svc's password to match secrets.env"
podman exec lldap /app/lldap_set_password \
  --base-url http://localhost:17170 \
  --admin-username "${ADMIN_USERNAME}" \
  --admin-password "${LLDAP_ADMIN_PASS}" \
  --username password-bridge-svc \
  --password "${PASSWORD_BRIDGE_LDAP_PASS}"

echo "==> Done. Add real lab members via the lldap web UI (see README) — createUser + addUserToGroup(groupId matching 'lab') + lldap_set_password, or just use the web UI which does all three."
