#!/bin/bash
# Paperclip post-deploy bootstrap.
set -euo pipefail
source "${BENTO_REPO_ROOT}/lib/install-helpers.sh"

ensure_database paperclip

wait_for_service paperclip_paperclip 240 || exit 0

# `_find_container` is re-called at every fresh use throughout this script.
# Anything that touches `docker service update --force` recreates the task
# and the previously-captured cid goes stale. Lookups stay cheap so we just
# resolve right before each docker exec.
cid=$(_find_container 'paperclip_paperclip')
paperclip_host="${PAPERCLIP_HOST:-paperclip.localhost}"
config_path="/paperclip/instances/production/config.json"

# Seed the CLI config. `\$meta` is escaped so the literal key reaches disk.
sudo docker exec -i -u root "$cid" sh -c "
    mkdir -p /paperclip/instances/production/logs
    cat > ${config_path}
    chown -R node:node /paperclip/instances/production
" <<EOF
{
  "\$meta": { "version": 1, "updatedAt": "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)", "source": "onboard" },
  "database": { "mode": "postgres", "connectionString": "postgresql://postgres:${POSTGRES_PASSWORD}@postgres:5432/paperclip" },
  "logging":  { "mode": "file", "logDir": "/paperclip/instances/production/logs" },
  "server":   { "deploymentMode": "authenticated", "exposure": "public", "host": "0.0.0.0", "port": 3100, "allowedHostnames": ["${paperclip_host}"], "serveUi": true },
  "auth":     { "baseUrlMode": "explicit", "publicBaseUrl": "https://${paperclip_host}", "disableSignUp": false }
}
EOF

# Mint the bootstrap-ceo invite. Skip the 3-minute CLI retry if the admin
# row is already in postgres (saves ~180s on re-deploy).
pg_cid=$(postgres_container 2>/dev/null || true)
admin_exists=$([[ -n "$pg_cid" ]] && sudo docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$pg_cid" \
    psql -U postgres -d paperclip -tA \
    -c "SELECT 1 FROM instance_user_roles WHERE role='instance_admin' LIMIT 1" 2>/dev/null \
    | tr -d '[:space:]' || true)

invite_output=""
if [[ "$admin_exists" == "1" ]]; then
    echo "Paperclip already has an instance_admin — skipping bootstrap-ceo."
else
    echo "Waiting for paperclip migrations…"
    cid=$(_find_container 'paperclip_paperclip')
    for _ in $(seq 60); do
        invite_output=$(sudo docker exec "$cid" sh -c "
            cd /app && node cli/node_modules/tsx/dist/cli.mjs cli/src/index.ts \
                auth bootstrap-ceo --config ${config_path} --expires-hours 24
        " 2>&1 || true)
        grep -qE 'pcp_bootstrap_|admin already (exists|claim)' <<< "$invite_output" && break
        sleep 3
    done
fi

invite_url=$(sed 's/\x1b\[[0-9;]*m//g' <<< "$invite_output" \
    | grep -oE 'https?://[^[:space:]]+/invite/pcp_bootstrap_[A-Za-z0-9]+' \
    | head -1 || true)

marker="$(dirname "$BENTO_STATE_FILE")/paperclip-invite-url.txt"
if [[ -n "$invite_url" ]]; then
    printf '%s\n' "$invite_url" > "$marker"
    chmod 600 "$marker"
    echo
    echo "Paperclip first-admin claim (24h): ${invite_url}"
    echo "(saved at ${marker})"
    echo
else
    rm -f "$marker"
fi

# Cross-stack: hermes binary (RO) + hermes data dir (RO) so the
# hermes_local plugin can spawn `hermes chat` reading the same
# config.yaml + auth.json the daemon manages via its dashboard.
# Idempotent no-op when the hermes stack isn't deployed.
#
# Grafts run BEFORE the npm-install block below so a registry hiccup
# can never strand the stack without its cross-stack mounts. The
# plugin install is "soft" — paperclip's built-in hermes_local kicks
# in if our override fails — but `/opt/hermes` and `/opt/hermes-shared`
# being absent breaks every wake regardless of which adapter loads.
graft_external_volumes_to_service \
    paperclip_paperclip \
    hermes_hermes-bin:/opt/hermes:readonly \
    hermes_hermes-data:/opt/hermes-shared:readonly

# Symlink ~/.hermes/{config.yaml,auth.json} to the cross-stack mount so
# the subprocess hermes (HOME=/paperclip) resolves them from there.
# `ln -sfn` replaces existing symlinks atomically; if /opt/hermes-shared
# isn't grafted, the dangling symlinks stay quiet until hermes lands.
wait_for_service paperclip_paperclip 120 || true
cid=$(_find_container 'paperclip_paperclip')
sudo docker exec -u node "$cid" sh -c '
    mkdir -p /paperclip/.hermes
    ln -sfn /opt/hermes-shared/config.yaml /paperclip/.hermes/config.yaml
    ln -sfn /opt/hermes-shared/auth.json   /paperclip/.hermes/auth.json
' || true

# Install the hermes_local plugin from npm. `latest` resolves at install
# time; the registry localPath points at the extracted package under
# <base>/node_modules/<pkg>.
pkg="@felipefontoura/paperclip-adapter-hermes-local-plus"
version="latest"
base="/paperclip/adapter-plugins/hermes-local-${version}"
dir="${base}/node_modules/${pkg}"

echo "Installing Paperclip adapter ${pkg}@${version}…"
# Retry up to 3 times with backoff. `npm install` can return exit 0 with an
# empty node_modules on transient registry hiccups (slow CDN, packument
# refresh races) — the file-existence test below is the authoritative
# "did the install actually land" check. Each attempt's npm log goes
# to a tmpfile we tail on failure, so the operator sees the real error
# rather than a silent fallback to the built-in hermes_local.
#
# Re-resolve `cid` inside the loop. Anything earlier that triggered a
# `docker service update` (e.g. the cross-stack graft above) recreated
# the task and the old cid is stale — `docker exec` then errors with
# "container is not running" and every retry repeats the lie.
install_ok=0
install_log=$(mktemp)
trap 'rm -f "$install_log"' EXIT
for attempt in 1 2 3; do
    cid=$(_find_container 'paperclip_paperclip')
    # SC2024 false positive on the `… >"$install_log"` redirect in the elif
    # below: $install_log is a user-owned mktemp, so the shell (not root)
    # performing the redirect is exactly what we want — the log must stay
    # readable by this script for the failure dump. The directive must sit on
    # the whole `if` (SC1123 forbids it on an individual elif branch).
    # shellcheck disable=SC2024
    if [[ -z "$cid" ]]; then
        echo "[paperclip] no running container on attempt $attempt — retrying" >&2
    elif sudo docker exec -u node "$cid" sh -c "
        set -e
        mkdir -p '${base}' && cd '${base}'
        rm -rf node_modules package.json package-lock.json
        npm install --no-save --no-progress --loglevel=warn '${pkg}@${version}'
        test -f '${dir}/dist/index.js'
    " >"$install_log" 2>&1; then
        install_ok=1
        break
    fi
    if (( attempt < 3 )); then
        sleep_s=$(( attempt * 10 ))
        echo "[paperclip] install attempt $attempt failed — retrying in ${sleep_s}s" >&2
        sleep "$sleep_s"
    fi
done

if (( install_ok )); then
    # Replace the prior hermes_local entry (if any) so re-installs don't
    # stack duplicates. Paperclip's plugin loader gives the JSON entry
    # precedence over the built-in hermes_local, so a single entry is
    # the override.
    cid=$(_find_container 'paperclip_paperclip')
    current=$(sudo docker exec "$cid" cat /paperclip/adapter-plugins.json 2>/dev/null || true)
    [[ -z "$current" ]] && current='[]'
    updated=$(jq --arg dir "$dir" \
                 --arg version "$version" \
                 --arg ts "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" '
        (. // [])
        | map(select(.type != "hermes_local"))
        + [{ packageName: $dir, localPath: $dir, version: $version, type: "hermes_local", installedAt: $ts }]
    ' <<< "$current")
    sudo docker exec -u node -i "$cid" sh -c 'cat > /paperclip/adapter-plugins.json' <<< "$updated"
    echo "[paperclip] adapter-plugins.json updated with hermes_local"
else
    echo "[paperclip] ${pkg} install failed after 3 attempts. Last npm output:" >&2
    sed 's/^/[paperclip]   /' "$install_log" >&2
    echo "[paperclip] Paperclip will fall back to the built-in hermes_local." >&2
    echo "[paperclip] Re-run \`bento install\` once the registry/network is reachable." >&2
    # Do NOT exit 1 here: the cross-stack grafts above already ran, so the
    # stack is functionally complete. The operator still has the built-in
    # hermes_local available and can re-run install to retry the override.
fi
