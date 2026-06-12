#!/bin/bash
# Paperclip post-deploy bootstrap:
#   1. Ensure the 'paperclip' database on bento's shared postgres.
#   2. Seed paperclip's CLI config (the bundled `paperclipai` CLI refuses
#      to run without it; we write directly to skip its `onboard -y` flow
#      which tries to start a second server on 3100).
#   3. Mint the bootstrap-ceo invite URL (only path to the first admin
#      in authenticated/public mode), persist for the handoff HTML.
#   4. Install the two adapter plugins (hermes_local, hermes_gateway) and
#      graft the hermes stack's volumes if it's deployed alongside.

set -euo pipefail
source "${BENTO_REPO_ROOT}/lib/install-helpers.sh"

ensure_database paperclip

if ! wait_for_service paperclip_paperclip 240; then
    echo "paperclip did not reach 1/1 within 240s — skipping bootstrap-ceo." >&2
    echo "Recover later via: docker exec <container> node cli/node_modules/tsx/dist/cli.mjs cli/src/index.ts auth bootstrap-ceo" >&2
    exit 0
fi

cid=$(_find_container 'paperclip_paperclip')
paperclip_host="${PAPERCLIP_HOST:-paperclip.localhost}"
db_url="postgresql://postgres:${POSTGRES_PASSWORD}@postgres:5432/paperclip"
# Path matches PAPERCLIP_INSTANCE_ID=production from the compose env.
# Both the running server AND the bootstrap-ceo CLI (when invoked
# with `--config`) read from here.
config_path="/paperclip/instances/production/config.json"

# Seed the CLI's config file. We race the server's first-boot mkdir, so
# create the dir up front and chown to node. `\$meta` is escaped once so
# bash leaves the literal key (its schema validator requires it).
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

# Mint the bootstrap-ceo invite. Re-deploy fast-path: if an instance_admin
# already exists, skip the retry loop (saves up to ~180s on edge cases
# where the CLI doesn't print the canonical 'admin already exists' marker).
pg_cid=$(postgres_container 2>/dev/null || true)
admin_exists=""
if [[ -n "$pg_cid" ]]; then
    admin_exists=$(sudo docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$pg_cid" \
        psql -U postgres -d paperclip -tA \
        -c "SELECT 1 FROM instance_user_roles WHERE role = 'instance_admin' LIMIT 1" \
        2>/dev/null | tr -d '[:space:]' || true)
fi

invite_output=""
if [[ "$admin_exists" == "1" ]]; then
    echo "Paperclip already has an instance_admin — skipping bootstrap-ceo."
    invite_output="admin already exists"
else
    # Migrations take 20-60s on a CX22 to populate instance_user_roles;
    # the CLI needs them. Retry every 3s, stop on URL or admin-exists.
    echo "Waiting for paperclip migrations to settle before minting bootstrap-ceo invite…"
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
fi

# Strip ANSI styling from the CLI's output before grepping the URL. The
# trailing `|| true` matters: grep -oE returns 1 when no match → pipefail
# would abort install.sh silently and hide the bootstrap-ceo error below.
invite_url=$(printf '%s\n' "$invite_output" \
    | sed 's/\x1b\[[0-9;]*m//g' \
    | grep -oE 'https?://[^[:space:]]+/invite/pcp_bootstrap_[A-Za-z0-9]+' \
    | head -1 || true)

state_dir="$(dirname "$BENTO_STATE_FILE")"
marker="${state_dir}/paperclip-invite-url.txt"

if [[ -n "$invite_url" ]]; then
    # Persisted so the handoff HTML can recover it if the install terminal closes.
    printf '%s\n' "$invite_url" > "$marker"
    chmod 600 "$marker"
    echo
    echo "Paperclip first-admin claim (24h): ${invite_url}"
    echo "(saved at ${marker}; first signup via this URL becomes instance_admin)"
    echo
else
    rm -f "$marker"
    if printf '%s' "$invite_output" | grep -qiE 'admin already exists|already claim'; then
        : # already reported above
    else
        echo "bootstrap-ceo did not produce an invite URL:" >&2
        printf '%s\n' "$invite_output" | sed 's/^/  /' >&2
    fi
fi

# -----------------------------------------------------------------------------
# Hermes integration: register both adapter plugins + graft the hermes stack's
# volumes if it's deployed alongside. The grafts are idempotent no-ops when
# the hermes stack isn't around, so a paperclip-only install lands cleanly.
# -----------------------------------------------------------------------------

# Two adapter plugins: subprocess (hermes_local) + HTTP passthrough
# (hermes_gateway). Both come from npm; both register the same way.
# `latest` resolves at install time. `npm install --no-save` puts the
# package under <base>/node_modules/<pkg>, which is what the registry
# entry's localPath points at.
for spec in \
    "@felipefontoura/paperclip-adapter-hermes-local-plus:${HERMES_LOCAL_PLUS_VERSION:-latest}:hermes_local" \
    "@felipefontoura/paperclip-adapter-hermes-gateway:0.1.0:hermes_gateway"
do
    IFS=':' read -r pkg version type <<<"$spec"
    base="/paperclip/adapter-plugins/${type//_/-}-${version}"
    dir="${base}/node_modules/${pkg}"

    echo "Installing Paperclip adapter ${pkg}@${version}…"
    sudo docker exec -u node "$cid" sh -c "
        set -e
        mkdir -p '${base}'
        cd '${base}'
        npm install --no-save --silent '${pkg}@${version}'
    " || { echo "[paperclip] ${pkg} install failed — register via UI later." >&2; continue; }

    sudo docker exec -u node -i "$cid" node - <<NODEJS || true
const fs = require('fs');
const path = '/paperclip/adapter-plugins.json';
const entry = { packageName: '${dir}', localPath: '${dir}', version: '${version}', type: '${type}', installedAt: new Date().toISOString() };
let current = [];
try { current = JSON.parse(fs.readFileSync(path, 'utf8')); if (!Array.isArray(current)) current = []; } catch (_) {}
fs.writeFileSync(path, JSON.stringify(current.filter(p => p && p.type !== entry.type).concat(entry), null, 2));
console.log('[paperclip] adapter-plugins.json updated with ' + entry.type);
NODEJS
done

# Cross-stack mounts come AFTER plugin installs — the graft fires a
# rolling restart of paperclip_paperclip, and a `docker exec` racing
# that restart returns "container is not running". Plugins write into
# the paperclip-data volume and don't depend on the mounts existing at
# install time; the mounts only matter at wake time.
#
# Batched into ONE `docker service update` so the operator pays for a
# single rolling restart instead of one per mount (~30s of `update_config
# .delay` per extra graft on top of the actual restart).
graft_external_volumes_to_service \
    paperclip_paperclip \
    hermes_hermes-bin:/opt/hermes:readonly \
    hermes_hermes-data:/opt/hermes-shared:readonly

# Wait for the service to settle after the graft before exec'ing again.
wait_for_service paperclip_paperclip 120 || true

# Re-locate the container (it may have a new ID after the rolling restart).
cid=$(_find_container 'paperclip_paperclip')

# Symlink config.yaml + auth.json from the hermes-shared mount.
if [[ -n "$cid" ]]; then
    sudo docker exec -u node "$cid" sh -c '
        mkdir -p /paperclip/.hermes
        if [ -d /opt/hermes-shared ]; then
            if [ -f /paperclip/.hermes/config.yaml ] && [ ! -L /paperclip/.hermes/config.yaml ]; then
                mv /paperclip/.hermes/config.yaml "/paperclip/.hermes/config.yaml.local-backup-$(date +%s)"
            fi
            if [ -f /paperclip/.hermes/auth.json ] && [ ! -L /paperclip/.hermes/auth.json ]; then
                mv /paperclip/.hermes/auth.json "/paperclip/.hermes/auth.json.local-backup-$(date +%s)"
            fi
            ln -sfn /opt/hermes-shared/config.yaml /paperclip/.hermes/config.yaml
            ln -sfn /opt/hermes-shared/auth.json   /paperclip/.hermes/auth.json
            echo "[paperclip] hermes config.yaml + auth.json symlinked to shared mount."
        else
            echo "[paperclip] hermes-shared mount not present yet."
        fi
    ' || echo "[paperclip] symlink step skipped — container not exec-ready." >&2
fi

# The graft rolled the service; its new container reads
# adapter-plugins.json on boot. No extra force-restart needed.
