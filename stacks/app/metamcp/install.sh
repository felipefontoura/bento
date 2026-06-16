#!/bin/bash
# MetaMCP post-deploy setup.
#
# MetaMCP keeps all state in Postgres and runs its own Drizzle migrations on
# first start, so the only database setup needed here is creating the `metamcp`
# database in the shared `postgres` stack.
#
# No admin user is created here: the published Docker image does not ship the
# BOOTSTRAP_* auto-admin feature, so the first admin is registered through the
# web UI on first visit (see compose.yml). We print the open-signup warning and
# the lock-down step below.
set -euo pipefail
source "${BENTO_REPO_ROOT}/lib/install-helpers.sh"

ensure_database metamcp

cat <<EOF

  MetaMCP — FIRST RUN ACTION REQUIRED
  -----------------------------------
  Public signup is currently OPEN. Open https://${METAMCP_HOST:-metamcp} now and
  register the FIRST account — it becomes your admin.

  Then lock it down: in MetaMCP go to Settings -> "Disable signup" so nobody
  else can self-register on your public endpoint. The setting persists in the
  database, so it survives restarts and redeploys.

EOF
