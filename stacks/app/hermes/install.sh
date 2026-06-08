#!/usr/bin/env bash
# Post-deploy: mount the seeded /opt/hermes tree onto the paperclip service so
# Paperclip's `hermes_local` adapter can exec /opt/hermes/bin/hermes locally.
# See lib/install-helpers.sh::graft_external_volume_to_service for the helper
# contract and docs/architecture/cross-stack-volume-graft.md for the pattern.
set -euo pipefail
source "${BENTO_REPO_ROOT}/lib/install-helpers.sh"

graft_external_volume_to_service paperclip_paperclip hermes_hermes-bin /opt/hermes
