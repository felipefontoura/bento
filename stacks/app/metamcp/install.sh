#!/bin/bash
# MetaMCP post-deploy bootstrap.
#
# MetaMCP keeps all state in Postgres and runs its own Drizzle migrations on
# first start, so the only database bootstrap needed here is creating the
# `metamcp` database in the shared `postgres` stack.
#
# The admin user and the "public signup disabled" config are bootstrapped by
# the container itself from the BOOTSTRAP_* env (see compose.yml). We surface
# the generated admin credentials below so the operator can log in.
set -euo pipefail
source "${BENTO_REPO_ROOT}/lib/install-helpers.sh"

ensure_database metamcp

# Surface the generated admin credentials. Saved to a 0600 marker next to the
# bento state and echoed once, mirroring paperclip's first-admin invite.
marker="$(dirname "$BENTO_STATE_FILE")/metamcp-admin.txt"
{
    echo "MetaMCP admin login (https://${METAMCP_HOST:-metamcp}):"
    echo "  email:    ${METAMCP_ADMIN_EMAIL:-}"
    echo "  password: ${METAMCP_ADMIN_PASSWORD:-}"
    echo "Public signup is disabled — this is the only account."
} > "$marker"
chmod 600 "$marker"

echo
echo "MetaMCP admin: ${METAMCP_ADMIN_EMAIL:-} / ${METAMCP_ADMIN_PASSWORD:-}"
echo "(saved at ${marker} — public signup is OFF)"
echo
