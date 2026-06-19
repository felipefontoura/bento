#!/bin/bash
# Crawl4AI post-deploy bootstrap.
#
# crawl4ai reads /app/config.yml from a hardcoded path (no env override for the
# pool/memory knobs). The stock image ships pool.max_pages=40, which lets ~40
# headless Chromium pages run at once and OOM-kills a small VPS. Seed our
# queue-tuned config.yml into the persistent crawl4ai-config volume; the compose
# `command` copies it onto /app/config.yml at boot. Force a restart to apply it.
#
# Mirrors the searxng pattern: the volume is not a host path, so we copy the
# repo file into it via a throwaway busybox container. Re-running is idempotent.
set -euo pipefail
source "${BENTO_REPO_ROOT}/lib/install-helpers.sh"

wait_for_service crawl4ai_crawl4ai 120 || true

SRC="${BENTO_REPO_ROOT}/stacks/app/crawl4ai/config.yml"

docker run --rm \
  -v crawl4ai_crawl4ai-config:/dst \
  -v "${SRC}:/src.yml:ro" \
  busybox sh -c "cp /src.yml /dst/config.yml && chmod 0644 /dst/config.yml"

docker service update --force crawl4ai_crawl4ai >/dev/null 2>&1 || true
