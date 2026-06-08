#!/bin/bash
set -euo pipefail
source "${BENTO_REPO_ROOT}/lib/install-helpers.sh"
ensure_database evolution
