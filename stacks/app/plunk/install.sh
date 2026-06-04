#!/bin/bash
# Post-deploy bootstrap for the plunk stack.
# Ensures the 'plunk' database exists in the shared postgres service.

set -euo pipefail
source "${BENTO_REPO_ROOT}/lib/install-helpers.sh"

ensure_database plunk
