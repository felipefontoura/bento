#!/bin/bash
# Paperclip post-deploy bootstrap:
#   Ensure the 'paperclip' database exists on bento's shared postgres
#   stack. Without it paperclip's DATABASE_URL points at a database the
#   operator never created, and migrations fail at first boot.
#
#   Falling back to the embedded postgres on :54329 inside the paperclip
#   container is what happens when DATABASE_URL is unset — wasteful when
#   bento already runs a postgres on the overlay.

set -euo pipefail
source "${BENTO_REPO_ROOT}/lib/install-helpers.sh"

ensure_database paperclip
