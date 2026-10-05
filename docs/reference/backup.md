# Backups — restic → Backblaze B2

bento's `backup` stack runs **restic** inside a small Alpine container scheduled by **supercronic**. On each cron tick it:

1. `pg_dump`s every bento-managed database (chatwoot, paperclip, n8n, typebot, plunk, evolution-api — soft-skipping any DB that isn't deployed) into a staging directory.
2. Copies `~/.config/bento/` (bind-mounted read-only) into the same staging dir — this includes `state.json` with the operator's `state.providers` OAuth tokens.
3. `restic backup` the staging dir + every grafted app data volume (`paperclip-data`, `n8n-data`, `chatwoot_data`, `evolution_instances`, `evolution_store`, `openclaw-*`, `rabbitmq-data`, `n8n-mcp-data`).
4. `restic forget --prune` with operator-configured retention.
5. `restic check --read-data-subset 5%` for early corruption detection.
6. Touches `/backup-state/last-success-iso` so the menu + handoff HTML can surface freshness.

All snapshots are **encrypted client-side with `RESTIC_PASSWORD`**. Bento generates this once and shows it in the handoff HTML. **If you lose it, the snapshots are unrecoverable.** Save it offsite immediately.

---

## Configuration

Set during Step 3 when you pick `backup`. All envs land in `state.envs.backup` and can be edited later via Portainer's `Stacks → backup → Environment variables`.

| Env | Required | Default | Notes |
|---|---|---|---|
| `B2_ACCOUNT_ID` | yes | — | Application key ID from [secure.backblaze.com](https://secure.backblaze.com/b2_buckets.htm) |
| `B2_ACCOUNT_KEY` | yes | — | Application key secret; scope it to the bucket below |
| `B2_BUCKET` | yes | `bento-${BASE_DOMAIN}` | Create the bucket in B2 first; default name is just a convention |
| `RESTIC_PASSWORD` | auto | `openssl rand -hex 32` | Bento generates once; surfaced in handoff HTML; **save offsite** |
| `BACKUP_CRON` | no | `0 3 * * *` | Standard cron syntax. Honored by supercronic at container start. |
| `RESTIC_KEEP_DAILY` | no | `7` | Daily snapshots kept |
| `RESTIC_KEEP_WEEKLY` | no | `4` | Weekly snapshots kept |
| `RESTIC_KEEP_MONTHLY` | no | `6` | Monthly snapshots kept |
| `POSTGRES_PASSWORD` | auto | from state | Reused from the postgres stack via `from_state` |

The container's `RESTIC_REPOSITORY` is built as `b2:${B2_BUCKET}:/bento`.

---

## Menu (`bash ~/.local/share/bento/install.sh` → `Backup`)

Submenu options (all read-only except "Run backup now"):

| Option | What it does |
|---|---|
| **Run backup now** | `docker exec backup_backup /usr/local/bin/backup.sh`. Same path as the cron uses. Surfaces exit code. |
| **List snapshots** | `restic snapshots --json` formatted as a fixed-width table (short_id, time, paths, tags). |
| **Show backup status** | Last-success timestamp + snapshot count + `restic stats --mode raw-data` for repo size. |
| **Restore (show command)** | DESTRUCTIVE. Guarded behind a confirm. Lets you pick a snapshot from a list, then **prints the exact restore commands** for that snapshot. Never runs anything. |
| **Test B2 connectivity** | `restic snapshots --no-cache --limit 1`. Validates credentials and network egress in ~2s without touching snapshot data. |

The menu skips itself under `BENTO_UNATTENDED=1` — the backup stack runs its own internal cron once deployed, no menu interaction needed.

---

## Restore procedure

Restore is destructive. Read this section end to end before running anything.

### 0. Pick the snapshot

Either pick from the menu's `Backup → Restore (show command)` (it'll print the commands with the snapshot ID filled in), or run on the host:

```bash
cid=$(sudo docker ps -q -f name=backup_backup)
sudo docker exec "$cid" restic snapshots
```

For the rest of this guide, replace `<SHORT_ID>` with the 8-character hash from the snapshots list.

### 1. Restore the staging dir

```bash
cid=$(sudo docker ps -q -f name=backup_backup)
sudo docker exec "$cid" restic restore <SHORT_ID> \
    --target /backup-state/restore \
    --include /var/lib/restic/staging
```

This recreates `/backup-state/restore/var/lib/restic/staging/` inside the backup container with:

- `postgres/globals.sql` — roles, tablespaces (restore these first)
- `postgres/<db>.sql` — one per database
- `bento/` — a copy of `~/.config/bento/` at backup time

### 2. Restore postgres

Restore globals first, then each DB. **Order matters** — per-DB dumps reference roles that globals defines.

```bash
pg=$(sudo docker ps -q -f name=postgres_postgres)

# Globals (roles, permissions)
sudo docker exec -i "$pg" psql -U postgres \
    < /backup-state/restore/var/lib/restic/staging/postgres/globals.sql

# Per-DB. Adjust the list to whatever was deployed at backup time —
# the staging dir only contains dumps for DBs that existed.
for db in chatwoot paperclip n8n typebot plunk evolution-api; do
    sql=/backup-state/restore/var/lib/restic/staging/postgres/${db}.sql
    [[ -f "$sql" ]] || continue
    sudo docker exec -i "$pg" psql -U postgres -d "$db" < "$sql"
done
```

The per-DB dumps were created with `--clean --if-exists`, so they drop and recreate tables as they go. If you're restoring onto a fresh postgres, you may need to `CREATE DATABASE` first:

```bash
sudo docker exec "$pg" psql -U postgres -c \
    'CREATE DATABASE chatwoot;'  # repeat per DB
```

### 3. Restore bento state

Stop the bento menu if running, then:

```bash
sudo cp -aL \
    /backup-state/restore/var/lib/restic/staging/bento/. \
    ~/.config/bento/
```

`state.json` is back, including `state.providers` with your AI provider OAuth tokens. Tokens may be expired (10-day window) — re-run `bento-auth` to refresh.

### 4. Restore app volumes

For each app volume you want back, restore from the backup container's `/backup/volumes/<name>/` snapshot and copy into a freshly created Docker volume.

Example: paperclip-data

```bash
# Restore the volume's snapshot into a temp path.
sudo docker exec "$cid" restic restore <SHORT_ID> \
    --target /backup-state/restore \
    --include /backup/volumes/paperclip-data

# Copy the contents into a fresh named volume the new paperclip stack will mount.
sudo docker volume create paperclip_paperclip-data
sudo docker run --rm \
    -v paperclip_paperclip-data:/dst \
    -v /var/lib/docker/volumes/backup_backup-state/_data/restore/backup/volumes/paperclip-data:/src:ro \
    alpine sh -c 'cp -a /src/. /dst/'
```

Repeat per volume. Volume names in the staging dir match Swarm's internal naming (`<stack>_<volume>`). The list of bento-managed volumes is in `stacks/app/backup/install.sh` — keep it in sync when you add a new stack.

### 5. Re-deploy bento

With `state.json` restored, `~/.config/bento/` should have everything Step 1/2/3 need. Run:

```bash
bash ~/.local/share/bento/install.sh
```

The menu detects each step is done from state. Re-pick the apps in Step 3 to push them out to Portainer + Swarm against the restored DB + volumes.

---

## Sanity check the restore on a staging VPS

Don't trust a restore plan you've never executed.

1. Provision a fresh VPS in the same provider region.
2. Install bento normally (no app picks needed yet).
3. Deploy `backup` and feed it the SAME B2 credentials + `RESTIC_PASSWORD` you have backed up from production.
4. Run the menu's `Test B2 connectivity` — must succeed.
5. Walk through the restore procedure above for a single app (paperclip is the heaviest test — covers postgres + named volume + bento state).
6. Open the app's URL on the staging domain (point `*.staging.<base>` at the staging VPS first). Confirm your data is there: a workflow in n8n, a paperclip instance_admin login, etc.
7. Tear the staging VPS down.

Done quarterly is reasonable for a production deploy. Done at least once before you'd ever need to do it for real is non-negotiable.

---

## Common failure modes

| Symptom | Probable cause | Fix |
|---|---|---|
| `restic init` aborts with "config file decryption failed" | Wrong `RESTIC_PASSWORD` against an existing repo | Recover the original password (you saved it offsite, right?) — there is no other way |
| First backup fails with `Authorization failed` | B2 app key revoked or scoped wrong | Recreate the key in the B2 console, restricted to the bucket name; update env via Portainer |
| Backup container in CrashLoopBackOff | Image build failed during Step 3 | `sudo docker service logs backup_backup` will show the apk / curl error. Most common: network egress blocked in Hetzner Cloud Firewall rules. |
| Snapshot count never grows | supercronic isn't ticking | `sudo docker service logs backup_backup` should show `[backup] scheduling: …` at start; if missing, the entrypoint failed. Often `BACKUP_CRON` is invalid (5-field cron required). |
| `restic check` reports corruption | B2 ate a chunk OR your `RESTIC_CACHE_DIR` is stale | Run `sudo docker exec backup_backup restic check --read-data` (full check, slow). If still bad, restore from the snapshot BEFORE corruption was introduced. |

---

## Out of scope (today)

- **Auto-restore from the menu.** v1 makes restore deliberate. Operator pastes the commands and watches each one — defence against the accidental click.
- **WAL-G for postgres point-in-time recovery.** v1 ships a once-a-day `pg_dump`. PITR with WAL streaming is a future enhancement for production-critical postgres workloads.
- **Multi-bucket / multi-region replication.** YAGNI today; B2 already replicates inside its region.
- **Backup health endpoint for Portainer healthcheck.** Bento's app stacks don't use Swarm healthchecks (see the n8n compose comment for why); the backup stack stays consistent with that.
