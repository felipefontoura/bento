#!/bin/bash
# Backup post-deploy bootstrap:
#
#   1. Wait for the backup service to come up (image build can take a
#      minute on a fresh VPS — Alpine + restic + postgres-client + …).
#
#   2. Graft every bento-managed app data volume into the backup container
#      at /backup/volumes/<volume-name>:ro via the same cross-stack helper
#      that hermes ↔ paperclip uses. Each call is idempotent and a soft
#      no-op when either the peer service or the volume is absent.
#
#      Adding a new app to bento? Add a graft line below + add the
#      database name to BENTO_DATABASES in scripts/backup.sh. The
#      CLAUDE.md doc-sync rule covers it.
#
#   3. Trigger the first backup synchronously so the operator sees a
#      pass/fail signal in the Step 3 output, NOT a delayed surprise
#      next morning when the cron fires for the first time.

set -euo pipefail
source "${BENTO_REPO_ROOT}/lib/install-helpers.sh"

# Backup image build is ~60s on a cold VPS (apk add restic + downloads
# supercronic). Once up, supercronic sleeps until BACKUP_CRON ticks.
if ! wait_for_service backup_backup 240; then
    echo "backup did not reach 1/1 within 240s — skipping graft + first backup." >&2
    echo "Recover later: re-run Step 3 for backup, or check 'docker service ps backup_backup'." >&2
    exit 0
fi

# ----- Graft per-app data volumes ------------------------------------------
# Pattern: <volume-as-docker-sees-it>  →  /backup/volumes/<readable-name>:ro
#
# Swarm volume names are <stack>_<volume-declared-in-compose>. The
# graft helper soft-skips when the volume isn't present, so apps the
# operator didn't deploy don't produce warnings here.

graft_external_volume_to_service backup_backup paperclip_paperclip-data    /backup/volumes/paperclip-data        readonly
graft_external_volume_to_service backup_backup n8n_n8n-data                /backup/volumes/n8n-data              readonly
graft_external_volume_to_service backup_backup chatwoot_chatwoot_data      /backup/volumes/chatwoot-data         readonly
graft_external_volume_to_service backup_backup evolution-api_evolution_instances /backup/volumes/evolution-instances readonly
graft_external_volume_to_service backup_backup evolution-api_evolution_store     /backup/volumes/evolution-store     readonly
graft_external_volume_to_service backup_backup openclaw_openclaw-config    /backup/volumes/openclaw-config       readonly
graft_external_volume_to_service backup_backup openclaw_openclaw-workspace /backup/volumes/openclaw-workspace    readonly
graft_external_volume_to_service backup_backup openclaw_openclaw-oauth     /backup/volumes/openclaw-oauth        readonly
graft_external_volume_to_service backup_backup rabbitmq_rabbitmq-data      /backup/volumes/rabbitmq-data         readonly
graft_external_volume_to_service backup_backup n8n-mcp_n8n-mcp-data        /backup/volumes/n8n-mcp-data          readonly

# Wait for the graft-induced rolling restart to converge so the next
# step finds the container with the new mounts.
sleep 5
wait_for_service backup_backup 120 || {
    echo "backup did not re-converge after graft — skipping first backup." >&2
    exit 0
}

# ----- First backup ---------------------------------------------------------
# Synchronous, so the operator gets the B2-creds-actually-work signal
# immediately. Subsequent backups fire from supercronic on the cron.
echo "Triggering first backup synchronously (validates B2 credentials)…"
cid=$(_find_container 'backup_backup')
if sudo docker exec "$cid" /usr/local/bin/backup.sh; then
    echo "First backup completed."
else
    rc=$?
    echo "First backup failed (exit $rc). Tail the logs:" >&2
    echo "  sudo docker service logs --tail 80 backup_backup" >&2
    echo "Common causes: invalid B2 application key, bucket name mismatch, network egress blocked." >&2
    # Don't fail Step 3 over a backup misconfig — the stack still runs,
    # operator can fix env + retry via the bento menu.
fi
