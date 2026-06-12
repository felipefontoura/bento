#!/bin/bash
# Hermes post-deploy bootstrap.
#
# 1. Wait for the hermes service to converge.
# 2. Render /opt/data/config.yaml inside the container from
#    reference/hermes-config.yaml, substituting ${VAR} provider keys with
#    whatever is currently in state.providers (empty entries are silently
#    ignored by Hermes — leaving every provider in the template uncommented
#    is intentional).
# 3. SIGHUP the running gateway so it picks the new config without losing
#    in-flight requests; falls back to `docker service update --force` if
#    the process doesn't accept SIGHUP.
#
# Idempotent on re-deploy: writing the same config + sending SIGHUP is a
# no-op when nothing changed.

set -euo pipefail
source "${BENTO_REPO_ROOT}/lib/install-helpers.sh"

if ! wait_for_service hermes_hermes 180; then
    echo "hermes did not reach 1/1 within 180s — skipping config.yaml render." >&2
    echo "Recover later by re-running 'bento install' once the service is healthy." >&2
    exit 0
fi

cid=$(_find_container 'hermes_hermes')

template_path="${BENTO_REPO_ROOT}/stacks/app/hermes/reference/hermes-config.yaml"
if [[ ! -f "$template_path" ]]; then
    echo "hermes template missing at $template_path — aborting." >&2
    exit 1
fi

# `envsubst` only expands the variables it sees in the environment — every
# provider key the template references must be available here. We pull from
# the environment (set by lib/stacks.sh from state.envs[hermes].*) and fall
# back to empty so missing keys produce empty strings rather than literal
# "${VAR}" lines that would break Hermes' YAML parser.
rendered=$(
    OPENAI_API_KEY="${OPENAI_API_KEY:-}" \
    ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}" \
    OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-}" \
    GOOGLE_API_KEY="${GOOGLE_API_KEY:-}" \
    ZAI_API_KEY="${ZAI_API_KEY:-}" \
    GROQ_API_KEY="${GROQ_API_KEY:-}" \
    DEEPSEEK_API_KEY="${DEEPSEEK_API_KEY:-}" \
    MISTRAL_API_KEY="${MISTRAL_API_KEY:-}" \
    XAI_API_KEY="${XAI_API_KEY:-}" \
    CEREBRAS_API_KEY="${CEREBRAS_API_KEY:-}" \
        envsubst < "$template_path"
)

# Write config.yaml owned by hermes:hermes. The default mode (0640 on
# subsequent atomic_yaml_write passes by the daemon) is fine — paperclip
# reads via the group_add: ["10000"] in its compose.yml, so any file
# group-readable by the hermes group is visible to paperclip's node user.
sudo docker exec -i -u root "$cid" sh -c '
    mkdir -p /opt/data
    cat > /opt/data/config.yaml
    chown -R hermes:hermes /opt/data 2>/dev/null || true
' <<< "$rendered"

# Reload — Hermes' gateway reads config.yaml on SIGHUP. If that fails (older
# images that don't trap HUP), fall through to a graceful service restart.
if ! sudo docker exec "$cid" sh -c 'kill -HUP 1' 2>/dev/null; then
    echo "hermes didn't accept SIGHUP — forcing service restart to reload config." >&2
    sudo docker service update --force hermes_hermes >/dev/null
fi

echo "hermes config.yaml rendered and reloaded."

# Cross-stack push: mirror of the pull in paperclip/install.sh. The pull
# silently skips when hermes deploys after paperclip (the unattended order
# `postgres,paperclip,hermes` does exactly this — paperclip's graft runs
# before hermes_hermes-{bin,data} exist, so nothing mounts). Pushing from
# this side covers that race: hermes runs last, so both paperclip_paperclip
# and the hermes volumes exist now. The helper is idempotent and skips when
# paperclip isn't deployed, so a hermes-only install stays a no-op.
graft_external_volumes_to_service \
    paperclip_paperclip \
    hermes_hermes-bin:/opt/hermes:readonly \
    hermes_hermes-data:/opt/hermes-shared:readonly
