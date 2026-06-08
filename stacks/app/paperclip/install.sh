#!/bin/bash
# Paperclip post-deploy bootstrap:
#
#   1. Ensure the 'paperclip' database exists on bento's shared postgres
#      stack. Without it paperclip's DATABASE_URL points at a database
#      the operator never created, and migrations fail at first boot.
#
#   2. Seed paperclip's CLI config file at
#      /paperclip/instances/production/config.json. The bundled
#      `paperclipai` CLI refuses to run without it ("No config found —
#      Run paperclip onboard first"). We write it directly instead of
#      invoking `paperclipai onboard -y` because onboard tries to start
#      a second paperclip server on port 3100, colliding with the
#      swarm-managed one.
#
#   3. Mint a one-time bootstrap-ceo invite URL and print it to the
#      operator. The URL is the only path to create the first
#      instance_admin in `authenticated/public` mode (browser claim is
#      intentionally disabled upstream). The URL is also persisted to
#      ${BENTO_STATE_DIR}/paperclip-invite-url.txt so the handoff HTML
#      can recover it if the operator loses the install terminal.
#
#      Re-deploy behaviour: `bootstrap-ceo` refuses (non-zero exit) if
#      an instance_admin already exists. We eat the failure quietly so
#      Step 3 re-runs don't re-prompt with a meaningless invite.

set -euo pipefail
source "${BENTO_REPO_ROOT}/lib/install-helpers.sh"

ensure_database paperclip

# Swarm sometimes takes 30-60s to converge after the API create. Also
# the postgres-TCP wait inside paperclip's compose adds a few seconds.
# Bail with a non-fatal warning if it doesn't come up so install.sh
# doesn't block Step 3 forever.
if ! wait_for_service paperclip_paperclip 240; then
    echo "paperclip did not reach 1/1 within 240s — skipping bootstrap-ceo." >&2
    echo "Recover later inside the container:" >&2
    echo "  cd /app && node cli/node_modules/tsx/dist/cli.mjs cli/src/index.ts auth bootstrap-ceo" >&2
    exit 0
fi

cid=$(_find_container 'paperclip_paperclip')
paperclip_host="${PAPERCLIP_HOST:-paperclip.localhost}"
db_url="postgresql://postgres:${POSTGRES_PASSWORD}@postgres:5432/paperclip"

# Seed the CLI's config file inside the container. On a fresh
# deploy the /paperclip/instances/production directory may not exist
# yet — paperclip's server creates it on first boot, but install.sh
# can race against the bash postgres-TCP wait wrapper in the
# container's command, so we mkdir up front and chown back to node
# so the CLI (which runs as node) can read what we wrote.
sudo docker exec -i -u root "$cid" sh -c '
    mkdir -p /paperclip/instances/production
    cat > /paperclip/instances/production/config.json
    chown -R node:node /paperclip/instances/production
' <<EOF
{
  "\$meta": { "version": 1, "source": "bento-install" },
  "database": {
    "mode": "postgres",
    "connectionString": "${db_url}"
  },
  "server": {
    "deploymentMode": "authenticated",
    "exposure": "public",
    "host": "0.0.0.0",
    "port": 3100,
    "allowedHostnames": ["${paperclip_host}"],
    "serveUi": true
  },
  "auth": {
    "baseUrlMode": "explicit",
    "publicBaseUrl": "https://${paperclip_host}",
    "disableSignUp": false
  }
}
EOF

# Mint the bootstrap-ceo invite. Idempotent on re-deploy: CLI returns
# non-zero with "admin already exists" once first claim happened.
# `|| true` so we don't trip set -e on the re-deploy path.
invite_output=$(sudo docker exec "$cid" sh -c \
    'cd /app && node cli/node_modules/tsx/dist/cli.mjs cli/src/index.ts auth bootstrap-ceo --expires-hours 24' \
    2>&1 || true)

invite_url=$(printf '%s\n' "$invite_output" \
    | grep -oE 'https?://[^[:space:]]+/invite/pcp_bootstrap_[A-Za-z0-9]+' \
    | head -1)

marker="${BENTO_STATE_DIR}/paperclip-invite-url.txt"

if [[ -n "$invite_url" ]]; then
    # Persist for the handoff HTML to surface even if the operator
    # loses the install terminal. The state dir is already mode 700
    # in the install path; tighten the marker itself to 600.
    printf '%s\n' "$invite_url" > "$marker"
    chmod 600 "$marker"

    cat <<MSG

═══════════════════════════════════════════════════════════════
 Paperclip first-admin claim — open within 24h
═══════════════════════════════════════════════════════════════

   ${invite_url}

 First signup via this URL becomes instance_admin.
 URL also persisted at ${marker} and in the handoff HTML.

 Public signup is open. Lock it later via Portainer when needed.

═══════════════════════════════════════════════════════════════

MSG
else
    # Re-deploy path: admin exists, CLI refused. Remove any stale
    # marker from a previous install so the handoff HTML doesn't
    # print a long-expired URL.
    rm -f "$marker"
    echo "Paperclip already has an instance_admin; skipping bootstrap-ceo."
fi
