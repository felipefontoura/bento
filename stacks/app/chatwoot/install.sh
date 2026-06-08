#!/bin/bash
# Chatwoot post-deploy bootstrap:
#   1. Ensure the 'chatwoot' database exists.
#   2. Run `rails db:chatwoot_prepare` in a one-shot container.
#
# We can't wait for chatwoot_web to become healthy first: the web container
# crashes until migrations have run, so we'd deadlock. Instead we run the
# migration in a throwaway container with the same env, then Swarm's
# restart_policy brings chatwoot_web back up on its own.

set -euo pipefail
source "${BENTO_REPO_ROOT}/lib/install-helpers.sh"

ensure_database chatwoot

# Pull the same env we passed to the stack from bento's state. The stacks
# library exports these to the install script when present in state.envs.
chatwoot_secret="${CHATWOOT_SECRET_KEY_BASE:-}"
if [[ -z "$chatwoot_secret" ]]; then
    chatwoot_secret=$(jq -r '.envs.chatwoot.CHATWOOT_SECRET_KEY_BASE // empty' \
        "${BENTO_STATE_FILE}")
fi

if [[ -z "$chatwoot_secret" ]]; then
    echo "CHATWOOT_SECRET_KEY_BASE not found in state — aborting." >&2
    exit 1
fi

echo "Running rails db:chatwoot_prepare in a one-shot container…"
sudo docker run --rm \
    --network network_public \
    --entrypoint docker/entrypoints/rails.sh \
    -e RAILS_ENV=production \
    -e NODE_ENV=production \
    -e INSTALLATION_ENV=docker \
    -e POSTGRES_HOST=postgres \
    -e POSTGRES_DATABASE=chatwoot \
    -e POSTGRES_USERNAME=postgres \
    -e POSTGRES_PASSWORD="${POSTGRES_PASSWORD}" \
    -e REDIS_URL=redis://redis:6379/3 \
    -e SECRET_KEY_BASE="${chatwoot_secret}" \
    -e FRONTEND_URL="https://${CHATWOOT_HOST:-chatwoot.local}" \
    chatwoot/chatwoot:latest \
    bundle exec rails db:chatwoot_prepare

echo "Chatwoot database prepared."
