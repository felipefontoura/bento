# bento backup image: restic + Backblaze B2 + postgres/redis clients + cron.
#
# CLAUDE.md says "Dockerfile almost never" — backup is one of the legitimate
# exceptions. No upstream image bundles restic + supercronic + psql + redis-cli
# together; the alternatives all require runtime `apk add` which is brittle
# (adds ~10s per container restart, fails outright without internet).
#
# Built locally by bento via lib/stacks.sh's build-first path; never published.

FROM alpine:3.20

# restic — the backup engine
# postgresql-client17 — pg_dump / pg_dumpall against the bento postgres stack
# redis — redis-cli for BGSAVE before snapshotting redis-data (if/when in scope)
# bash — backup.sh uses bash features (arrays, `[[ … ]]`)
# coreutils — `date -u +…`, `cp -a`, deterministic flags vs busybox
# jq — used by `bento backup` menu helpers (parsing `restic snapshots --json`)
# curl — health pokes against B2 / pg_isready style checks
# tini — small init that reaps zombies + handles SIGTERM cleanly
RUN apk add --no-cache \
        restic \
        postgresql17-client \
        redis \
        bash \
        coreutils \
        jq \
        curl \
        tini

# supercronic — cron with proper SIGTERM handling for containerised workloads.
# Pinned to a recent release; bump when restic / postgres-client roll.
ARG SUPERCRONIC_VERSION=v0.2.33
ARG SUPERCRONIC_SHA256=71b0d58cc53f6bd72cf2f293e09e294b79c666d8f25eafe2a11f9d597e3636f4
RUN curl -fsSL -o /usr/local/bin/supercronic \
        "https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-amd64" \
    && echo "${SUPERCRONIC_SHA256}  /usr/local/bin/supercronic" | sha256sum -c - \
    && chmod +x /usr/local/bin/supercronic

# Scripts live under /usr/local/bin so they're on PATH.
COPY scripts/backup.sh    /usr/local/bin/backup.sh
COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY scripts/crontab.tpl  /etc/supercronic/crontab.tpl
RUN chmod +x /usr/local/bin/backup.sh /usr/local/bin/entrypoint.sh

# Where restic caches its index. Mounted from the backup-state volume so
# subsequent boots reuse it (saves bandwidth on every snapshot).
ENV RESTIC_CACHE_DIR=/var/cache/restic
ENV STAGING_DIR=/var/lib/restic/staging
RUN mkdir -p "$RESTIC_CACHE_DIR" "$STAGING_DIR"

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]
