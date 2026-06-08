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
#      ${state_dir}/paperclip-invite-url.txt so the handoff HTML
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
# Path matches PAPERCLIP_INSTANCE_ID=production from the compose env.
# Both the running server AND the bootstrap-ceo CLI (when invoked
# with `--config`) read from here.
config_path="/paperclip/instances/production/config.json"

# Seed the CLI's config file inside the container. On a fresh deploy
# /paperclip/instances/production may not exist yet — paperclip's
# server creates it on first boot, but install.sh races against the
# postgres-TCP wait wrapper inside the container's command, so we
# mkdir up front and chown back to node (the CLI runs as node).
#
# Schema requirements verified against upstream's onboard output:
#   - $meta { version, source }       (required)
#   - logging { mode, logDir }        (required)
#   - database { mode, connectionString }
#   - server, auth
#
# The literal '\$meta' below escapes once for the bash heredoc so
# the JSON written to disk has the literal key '\$meta'. Without
# the escape bash would interpolate \$meta as an empty variable
# and the schema validator would reject the file with
# '\$meta: Required'.
now_iso=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)

sudo docker exec -i -u root "$cid" sh -c "
    mkdir -p /paperclip/instances/production/logs
    cat > ${config_path}
    chown -R node:node /paperclip/instances/production
" <<EOF
{
  "\$meta": { "version": 1, "updatedAt": "${now_iso}", "source": "onboard" },
  "database": {
    "mode": "postgres",
    "connectionString": "${db_url}"
  },
  "logging": {
    "mode": "file",
    "logDir": "/paperclip/instances/production/logs"
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

# Mint the bootstrap-ceo invite. We pass --config explicitly because
# without it the CLI defaults to /paperclip/instances/default/config.json
# (the CLI's notion of "default" instance is independent of the
# server's PAPERCLIP_INSTANCE_ID env, so it would not find our
# production/config.json without the flag).
#
# Idempotent on re-deploy: CLI returns non-zero with "admin already
# exists" once first claim happened. `|| true` keeps us from
# tripping set -e.
# wait_for_service returns when Swarm sees the container running.
# That fires BEFORE paperclip's node process has finished migrating
# the shared postgres schema (instance_user_roles, invites, etc. —
# the very tables bootstrap-ceo writes to). Without this loop, the
# CLI bombs with:
#
#   Could not create bootstrap invite: Failed query: select … from
#   "instance_user_roles" … "If using embedded-postgres, start the
#   Paperclip server and run this command again."
#
# Migrations take 20-60s on a CX22. Retry every 3s for 3 minutes;
# stop early on either success (URL produced) or 'admin already
# exists' (idempotent re-deploy).
echo "Waiting for paperclip migrations to settle before minting bootstrap-ceo invite…"
invite_output=""
attempts=0
while (( attempts < 60 )); do
    invite_output=$(sudo docker exec "$cid" sh -c "
        cd /app && node cli/node_modules/tsx/dist/cli.mjs cli/src/index.ts \\
            auth bootstrap-ceo --config ${config_path} --expires-hours 24
    " 2>&1 || true)
    if printf '%s' "$invite_output" \
        | grep -qE 'pcp_bootstrap_|admin already exists|already claim'; then
        break
    fi
    sleep 3
    attempts=$((attempts + 1))
done

# Strip ANSI colour codes before grep — bootstrap-ceo output wraps
# the URL in clack/prompt styling (\\e[36m … \\e[39m) which can
# otherwise embed inside the captured string.
#
# `|| true` on the grep pipeline is CRITICAL: grep -oE exits 1 when
# no match, pipefail propagates that, set -e then aborts install.sh
# silently — which previously hid the bootstrap-ceo error AND
# skipped the "already-claimed" branch below, so the operator
# never saw anything between "Database 'paperclip' …" and the
# "paperclip is ready" success box.
invite_url=$(printf '%s\n' "$invite_output" \
    | sed 's/\x1b\[[0-9;]*m//g' \
    | grep -oE 'https?://[^[:space:]]+/invite/pcp_bootstrap_[A-Za-z0-9]+' \
    | head -1 || true)

# Derive the state dir from BENTO_STATE_FILE (the only state-related
# var bento's contract guarantees to install.sh — see CLAUDE.md).
# `lib/stacks.sh` invokes us via `env VAR=val …` and does NOT pass
# BENTO_STATE_DIR, so referencing it directly trips set -u.
state_dir="$(dirname "$BENTO_STATE_FILE")"
marker="${state_dir}/paperclip-invite-url.txt"

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
    # Two reasons we land here:
    #   1. Re-deploy and CLI refused because admin already exists.
    #   2. Genuine error from the CLI (bad config, DB unreachable, …).
    # The user needs to know which. Drop any stale marker either way,
    # then surface bootstrap-ceo's full stderr so the operator can act.
    rm -f "$marker"
    if printf '%s' "$invite_output" | grep -qiE 'admin already exists|already claim'; then
        echo "Paperclip already has an instance_admin; skipping bootstrap-ceo."
    else
        echo "bootstrap-ceo did not produce an invite URL. CLI output:" >&2
        printf '%s\n' "$invite_output" | sed 's/^/  /' >&2
        echo "" >&2
        echo "Recover manually inside the container:" >&2
        echo "  sudo docker exec -it <paperclip-container> sh -c '\\" >&2
        echo "    cd /app && node cli/node_modules/tsx/dist/cli.mjs cli/src/index.ts \\\\" >&2
        echo "      auth bootstrap-ceo --config ${config_path} --expires-hours 24 --force'" >&2
    fi
fi
