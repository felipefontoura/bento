#!/bin/bash
# SearXNG post-deploy bootstrap.
#
# The stock image ships HTML-only output, which an MCP/agent cannot parse.
# Seed a settings.yml (layered on top of SearXNG defaults) that sets the
# secret_key, enables the JSON output format, and disables the bot-limiter
# (this is an internal API consumer with no Redis). Then force a restart so
# it is picked up.
set -euo pipefail
source "${BENTO_REPO_ROOT}/lib/install-helpers.sh"

wait_for_service searxng_searxng 120 || true

SECRET="$(jq -r '.envs.searxng.SEARXNG_SECRET' "$HOME/.config/bento/state.json")"

TMP="$(mktemp)"
cat > "$TMP" <<EOF
# Managed by bento — overrides layered on top of SearXNG defaults.
use_default_settings: true
server:
  secret_key: "${SECRET}"
  limiter: false
  image_proxy: true
search:
  formats:
    - html
    - json
EOF

# Copy into the named volume via a throwaway container (the volume is not a
# host path), then make it world-readable for the searxng user.
docker run --rm \
  -v searxng_searxng-config:/dst \
  -v "${TMP}:/src.yml:ro" \
  busybox sh -c "cp /src.yml /dst/settings.yml && chmod 0644 /dst/settings.yml"

rm -f "$TMP"

docker service update --force searxng_searxng >/dev/null 2>&1 || true
