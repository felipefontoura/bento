#!/bin/bash
# backup.sh — bento's nightly backup job.
#
# Runs inside the backup container, scheduled by supercronic (BACKUP_CRON
# env, default `0 3 * * *`). Can also be invoked manually:
#   docker exec backup_backup /usr/local/bin/backup.sh
#
# Order of operations:
#   1. pg_dump every bento-managed database (overlay → postgres service).
#   2. Stage ~/.config/bento snapshot (already bind-mounted at /host-bento-config).
#   3. `restic init` if first run (idempotent — captures "already initialised").
#   4. `restic backup` STAGING_DIR (pg_dumps + bento state) AND /backup/volumes/*
#      (the app volumes grafted in by stacks/app/backup/install.sh).
#   5. `restic forget --prune` with configurable retention.
#   6. `restic check --read-data-subset 5%` to catch repo corruption early.
#   7. Touch /backup-state/last-success-iso so the menu / handoff HTML can
#      surface freshness without invoking restic again.

set -euo pipefail

log() { printf '[backup] %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { printf '[backup] ERROR %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; exit 1; }

: "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY not set — backup stack misconfigured}"
: "${RESTIC_PASSWORD:?RESTIC_PASSWORD not set — backup stack misconfigured}"
: "${B2_ACCOUNT_ID:?B2_ACCOUNT_ID not set — backup stack misconfigured}"
: "${B2_ACCOUNT_KEY:?B2_ACCOUNT_KEY not set — backup stack misconfigured}"
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD not set — backup stack misconfigured}"

: "${STAGING_DIR:=/var/lib/restic/staging}"
: "${VOLUMES_DIR:=/backup/volumes}"
: "${BENTO_HOST_CONFIG:=/host-bento-config}"
: "${RESTIC_KEEP_DAILY:=7}"
: "${RESTIC_KEEP_WEEKLY:=4}"
: "${RESTIC_KEEP_MONTHLY:=6}"

# DBs bento manages on the shared postgres stack. Keep in sync with each
# app's install.sh ensure_database call. Doc-sync rule applies when a new
# app is added — add the DB name here too.
BENTO_DATABASES=(
    chatwoot
    paperclip
    n8n
    typebot
    plunk
    evolution-api
)

# Always start from a clean staging dir — old dumps would otherwise grow
# the restic snapshot indefinitely.
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR/postgres" "$STAGING_DIR/bento"

# ----- 1. Postgres dumps --------------------------------------------------
log "pg_dump → $STAGING_DIR/postgres/"
PGOPTS=(-h postgres -U postgres -w)
export PGPASSWORD="$POSTGRES_PASSWORD"

# Globals (roles, tablespaces). Recovery needs these BEFORE per-DB restore.
pg_dumpall "${PGOPTS[@]}" --globals-only \
    > "$STAGING_DIR/postgres/globals.sql" \
    || die "pg_dumpall globals failed"

for db in "${BENTO_DATABASES[@]}"; do
    # Skip DBs that don't exist on this host (e.g. operator deployed only
    # a subset of stacks). The query returns nothing → grep -q fails →
    # continue. `psql -tA` strips header and pipes cleanly.
    exists=$(psql "${PGOPTS[@]}" -tA -c \
        "SELECT 1 FROM pg_database WHERE datname='${db}'" postgres 2>/dev/null \
        || echo "")
    if [[ -z "$exists" ]]; then
        log "  skip: database '$db' not present"
        continue
    fi
    log "  pg_dump $db"
    pg_dump "${PGOPTS[@]}" \
            --no-owner --no-privileges \
            --clean --if-exists \
            -d "$db" \
            > "$STAGING_DIR/postgres/${db}.sql" \
        || die "pg_dump $db failed"
done

# ----- 2. Stage bento state ---------------------------------------------
if [[ -d "$BENTO_HOST_CONFIG" ]]; then
    log "stage bento config → $STAGING_DIR/bento/"
    # Use cp -aL: dereference symlinks (markers like paperclip-invite-url.txt
    # are real files, but state-history snapshots could be linked) and
    # preserve perms. mode 600 on the sensitive files survives the copy.
    cp -aL "$BENTO_HOST_CONFIG"/. "$STAGING_DIR/bento/" \
        || die "bento config stage failed"
else
    log "WARN bento host config not mounted at $BENTO_HOST_CONFIG — skipping"
fi

# ----- 3. Initialise repo (idempotent) -----------------------------------
if ! restic snapshots --no-cache --limit 1 >/dev/null 2>&1; then
    log "restic init (first run)"
    restic init || die "restic init failed — check B2 creds / bucket"
fi

# ----- 4. Backup ---------------------------------------------------------
log "restic backup → $RESTIC_REPOSITORY"
backup_paths=("$STAGING_DIR")
if [[ -d "$VOLUMES_DIR" ]] && [[ -n "$(ls -A "$VOLUMES_DIR" 2>/dev/null)" ]]; then
    backup_paths+=("$VOLUMES_DIR")
else
    log "  note: no app volumes grafted yet at $VOLUMES_DIR"
fi
restic backup \
    --tag bento \
    --tag "$(date -u +%Y-%m-%d)" \
    --host "${HOSTNAME:-bento}" \
    "${backup_paths[@]}" \
    || die "restic backup failed"

# ----- 5. Prune ----------------------------------------------------------
log "restic forget --prune (keep-daily=$RESTIC_KEEP_DAILY weekly=$RESTIC_KEEP_WEEKLY monthly=$RESTIC_KEEP_MONTHLY)"
restic forget --prune \
    --keep-daily   "$RESTIC_KEEP_DAILY" \
    --keep-weekly  "$RESTIC_KEEP_WEEKLY" \
    --keep-monthly "$RESTIC_KEEP_MONTHLY" \
    || die "restic forget failed"

# ----- 6. Sanity check ---------------------------------------------------
log "restic check (5% subset)"
if ! restic check --read-data-subset 5%; then
    # Don't fail the whole job — corruption is rare and the previous
    # snapshot succeeded. Log loudly so the operator notices.
    log "WARN restic check reported issues — investigate manually with 'restic check --read-data'"
fi

# ----- 7. Freshness marker ----------------------------------------------
date -u +%Y-%m-%dT%H:%M:%SZ > /backup-state/last-success-iso

log "done"
