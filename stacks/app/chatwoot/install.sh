#!/bin/bash
# Chatwoot post-deploy bootstrap:
#   1. Ensure the 'chatwoot' database exists.
#   2. Wait for chatwoot_web to be running.
#   3. Run `rails db:chatwoot_prepare` to migrate + seed.

set -euo pipefail
source "${BENTO_REPO_ROOT}/lib/install-helpers.sh"

ensure_database chatwoot

echo "Waiting for chatwoot_web to come up…"
wait_for_service chatwoot_chatwoot_web 240 || {
    echo "chatwoot_web did not become healthy; skipping rails db:chatwoot_prepare." >&2
    exit 1
}

cid=$(_find_container 'chatwoot_chatwoot_web')
echo "Running rails db:chatwoot_prepare inside $cid…"
sudo docker exec "$cid" bundle exec rails db:chatwoot_prepare
echo "Chatwoot database prepared."
