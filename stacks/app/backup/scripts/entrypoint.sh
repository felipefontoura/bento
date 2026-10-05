#!/bin/bash
# entrypoint.sh — render the crontab from BACKUP_CRON, then hand off to
# supercronic. Runs in the foreground so Swarm sees PID 1 alive; SIGTERM
# is handled cleanly via tini → supercronic.

set -euo pipefail

# Default schedule: 03:00 every day. Operator overrides via env.
: "${BACKUP_CRON:=0 3 * * *}"

# Render template — supercronic doesn't do env substitution itself.
mkdir -p /etc/supercronic
sed "s|\${BACKUP_CRON}|${BACKUP_CRON}|" \
    /etc/supercronic/crontab.tpl > /etc/supercronic/crontab

echo "[backup] scheduling: ${BACKUP_CRON}"

# supercronic forwards SIGTERM to the spawned job and exits cleanly,
# so Swarm rolling-updates don't kill an in-flight `restic backup`.
exec supercronic /etc/supercronic/crontab
