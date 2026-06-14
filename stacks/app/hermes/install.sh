#!/bin/bash
# Hermes post-deploy bootstrap.
#
# Wait for the service to converge, then push the hermes-bin volume into
# paperclip's mount spec so the hermes_local plugin there can spawn
# `hermes chat` against the binary inside it.

set -euo pipefail
source "${BENTO_REPO_ROOT}/lib/install-helpers.sh"

wait_for_service hermes_hermes 180 || true

# Cross-stack push: mirror of the pull in paperclip/install.sh. The pull
# silently skips when hermes deploys after paperclip (the unattended order
# `postgres,paperclip,hermes` does exactly this — paperclip's graft runs
# before hermes_hermes-bin exists, so nothing mounts). Pushing from this
# side covers that race: hermes runs last, so both paperclip_paperclip
# and the hermes-bin volume exist now.
graft_external_volumes_to_service \
    paperclip_paperclip \
    hermes_hermes-bin:/opt/hermes:readonly
