#!/bin/bash
# Paperclip post-deploy bootstrap.
set -euo pipefail
source "${BENTO_REPO_ROOT}/lib/install-helpers.sh"

ensure_database paperclip

wait_for_service paperclip_paperclip 240 || exit 0
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

# Install the hermes_local plugin from npm. `latest` resolves at install
# time; the registry localPath points at the extracted package under
# <base>/node_modules/<pkg>.
pkg="@felipefontoura/paperclip-adapter-hermes-local-plus"
version="${HERMES_LOCAL_PLUS_VERSION:-latest}"
base="/paperclip/adapter-plugins/hermes-local-${version}"
dir="${base}/node_modules/${pkg}"

echo "Installing Paperclip adapter ${pkg}@${version}…"
sudo docker exec -u node "$cid" sh -c "
    mkdir -p '${base}' && cd '${base}' && npm install --no-save --silent '${pkg}@${version}'
" && sudo docker exec -u node -i "$cid" node - <<NODEJS || true
const fs = require('fs');
const path = '/paperclip/adapter-plugins.json';
const entry = { packageName: '${dir}', localPath: '${dir}', version: '${version}', type: 'hermes_local', installedAt: new Date().toISOString() };
let current = [];
try { current = JSON.parse(fs.readFileSync(path, 'utf8')); if (!Array.isArray(current)) current = []; } catch (_) {}
fs.writeFileSync(path, JSON.stringify(current.filter(p => p && p.type !== entry.type).concat(entry), null, 2));
console.log('[paperclip] adapter-plugins.json updated with ' + entry.type);
NODEJS

# Cross-stack: hermes binary + data volume (RO) so the plugin can spawn
# `hermes chat` reading the same config.yaml + auth.json the hermes
# daemon renders. Idempotent no-op when the hermes stack isn't deployed.
graft_external_volumes_to_service \
    paperclip_paperclip \
    hermes_hermes-bin:/opt/hermes:readonly \
    hermes_hermes-data:/opt/hermes-shared:readonly

wait_for_service paperclip_paperclip 120 || true
cid=$(_find_container 'paperclip_paperclip')

# Symlink ~/.hermes/{config.yaml,auth.json} to the cross-stack mount.
# `ln -sfn` replaces existing symlinks atomically; if /opt/hermes-shared
# isn't grafted, the dangling symlinks just stay until the hermes stack
# lands.
sudo docker exec -u node "$cid" sh -c '
    mkdir -p /paperclip/.hermes
    ln -sfn /opt/hermes-shared/config.yaml /paperclip/.hermes/config.yaml
    ln -sfn /opt/hermes-shared/auth.json   /paperclip/.hermes/auth.json
' || true
