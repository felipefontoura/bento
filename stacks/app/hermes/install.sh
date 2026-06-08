#!/usr/bin/env bash
# =============================================================================
# stacks/app/hermes/install.sh
# =============================================================================
#
# Post-deploy hook for the `hermes` stack. Runs after `docker stack deploy
# hermes` succeeds and the seeded `hermes_hermes-bin` volume exists.
#
# Job: graft a read-only mount of that volume onto the running
# `paperclip_paperclip` service so its bundled `hermes_local` Paperclip
# adapter can exec `/opt/hermes/bin/hermes`.
#
# This is the cross-stack coupling point. The paperclip stack's compose.yml
# deliberately does NOT declare the hermes-bin volume — that keeps it portable
# to deployments that don't want Hermes (e.g. someone forking bento and only
# running Paperclip with Claude/Codex/OpenCode CLIs). When operators DO deploy
# hermes, we patch the mount onto the running paperclip service here.
#
# Idempotent — if the mount is already present, `service update --mount-add`
# fails fast (duplicate mount target rejected) and we treat that as success.
# =============================================================================

set -euo pipefail

ui_info() { printf "ℹ %s\n" "$*"; }
ui_warn() { printf "⚠ %s\n" "$*" >&2; }
ui_success() { printf "✓ %s\n" "$*"; }

readonly PAPERCLIP_SERVICE="paperclip_paperclip"
readonly HERMES_VOLUME="hermes_hermes-bin"
readonly HERMES_MOUNT_TARGET="/opt/hermes"

if ! command -v docker >/dev/null 2>&1; then
    ui_warn "docker not on PATH — skipping hermes→paperclip mount graft"
    exit 0
fi

if ! docker service inspect "$PAPERCLIP_SERVICE" >/dev/null 2>&1; then
    ui_info "paperclip service not running (yet) — hermes binary mount will be applied next time paperclip is deployed via this install.sh's twin path"
    ui_info "to attach now: deploy paperclip, then re-run hermes install"
    exit 0
fi

# Check whether the mount already exists. `service inspect --format` walks the
# task template mounts — if any target matches /opt/hermes we're already wired.
existing=$(docker service inspect "$PAPERCLIP_SERVICE" \
    --format '{{range .Spec.TaskTemplate.ContainerSpec.Mounts}}{{.Target}}{{"\n"}}{{end}}' \
    2>/dev/null | grep -Fx "$HERMES_MOUNT_TARGET" || true)

if [[ -n "$existing" ]]; then
    ui_success "paperclip already mounts ${HERMES_MOUNT_TARGET} — no change"
    exit 0
fi

ui_info "grafting ${HERMES_VOLUME}:${HERMES_MOUNT_TARGET}:ro onto ${PAPERCLIP_SERVICE}"

if docker service update \
    --mount-add "type=volume,source=${HERMES_VOLUME},target=${HERMES_MOUNT_TARGET},readonly" \
    "$PAPERCLIP_SERVICE" >/dev/null; then
    ui_success "mount grafted — Paperclip will see /opt/hermes/bin/hermes after the service restarts (start-first rolling update is already in flight)"
else
    ui_warn "docker service update failed — inspect manually with:"
    ui_warn "  docker service inspect ${PAPERCLIP_SERVICE}"
    exit 1
fi
