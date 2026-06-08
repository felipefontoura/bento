#!/bin/bash
# bento — helpers for AI-provider OAuth / API-key auth
#
# Sourced by scripts/bento-auth and (lazily) by the auth menu hook in
# install.sh. These helpers are intentionally minimal — no `set -e` and
# no global state mutation — so they're safe to source from both
# interactive menus and one-off scripts.
#
# Concerns covered:
#   * locating the paperclip container by its swarm-canonical name
#   * decoding the `exp` claim of a JWT to a human-readable expiry
#   * reading the expiry surfaced by Anthropic's Claude Code credentials
#     JSON (the only non-JWT format we currently support)
#   * registering tokens with hermes via `hermes auth add` AND wiring the
#     correct env var (CLAUDE_CODE_OAUTH_TOKEN for Claude OAuth — never
#     ANTHROPIC_API_KEY, which collides with the Anthropic SDK's implicit
#     env-var read and produces a dual-header 401)

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------

# Anthropic ChatGPT-Plus-style OAuth: the access token lives at
# claudeAiOauth.accessToken inside the Claude Code credentials file. The
# `claude` CLI refreshes this on demand, so the JSON is the source of truth.
# shellcheck disable=SC2034  # consumed by scripts/bento-auth
AUTH_CLAUDE_CREDENTIALS_PATH_IN_CONTAINER="/paperclip/.claude/.credentials.json"

# Codex / openai-codex OAuth: opencode persists the access + refresh tokens
# at this path inside the container after `opencode auth login anthropic`
# (the CLI is reused as a convenience wrapper that runs the same OAuth
# device flow Anthropic publishes for Claude Code).
# shellcheck disable=SC2034  # consumed by scripts/bento-auth
AUTH_OPENCODE_PATH_IN_CONTAINER="/paperclip/.local/share/opencode/auth.json"

# Paperclip container service name — set once by stacks/app/paperclip.
AUTH_PAPERCLIP_SERVICE="paperclip_paperclip"

# -----------------------------------------------------------------------------
# Container discovery
# -----------------------------------------------------------------------------

# Echo the running paperclip container ID, or fail with a clear hint.
# Mirrors lib/install-helpers.sh::_find_container but does not call exit(),
# so callers can short-circuit gracefully (e.g. `bento-auth list` should
# still print SOMETHING when paperclip is down).
auth_find_paperclip_container() {
    local cid
    cid=$(sudo docker ps --filter "name=${AUTH_PAPERCLIP_SERVICE}" --format '{{.ID}}' | head -1)
    if [[ -z "$cid" ]]; then
        return 1
    fi
    printf '%s' "$cid"
}

# -----------------------------------------------------------------------------
# Expiry decoding
# -----------------------------------------------------------------------------

# Decode the `exp` claim of a JWT into an ISO-8601 timestamp. JWT payload
# is the second `.`-separated segment, base64url-encoded. We pad to
# multiples of 4 because some encoders strip trailing `=`, which standard
# base64 cannot decode.
auth_decode_jwt_exp() {
    local jwt="$1"
    local payload exp
    payload="${jwt#*.}"
    payload="${payload%.*}"
    payload="${payload//-/+}"
    payload="${payload//_/\/}"
    # Pad to multiple of 4 — base64 alphabet requires it.
    local pad=$(( (4 - ${#payload} % 4) % 4 ))
    local p
    for ((p = 0; p < pad; p++)); do payload="${payload}="; done
    if ! exp=$(printf '%s' "$payload" | base64 -d 2>/dev/null | jq -r '.exp // empty'); then
        return 1
    fi
    if [[ -z "$exp" ]]; then
        return 1
    fi
    date -u -d "@${exp}" +"%Y-%m-%dT%H:%M:%SZ"
}

# Convert an epoch-ms timestamp (Anthropic's claudeAiOauth.expiresAt) or
# an ISO-8601 string into a relative human label like "expires in 8d 4h"
# or "EXPIRED 2d ago". Returns the label on stdout.
auth_format_relative_expiry() {
    local raw="$1"
    local now epoch
    now=$(date +%s)
    if [[ "$raw" =~ ^[0-9]+$ ]]; then
        # epoch-ms heuristic — Anthropic stores ms, anything <1e12 is seconds
        if (( raw > 1000000000000 )); then
            epoch=$(( raw / 1000 ))
        else
            epoch="$raw"
        fi
    else
        epoch=$(date -d "$raw" +%s 2>/dev/null || echo 0)
    fi
    if (( epoch == 0 )); then
        printf 'unknown'
        return
    fi
    local delta=$(( epoch - now ))
    local sign
    if (( delta < 0 )); then
        sign="EXPIRED "
        delta=$(( -delta ))
    else
        sign="in "
    fi
    local days=$(( delta / 86400 ))
    local hours=$(( (delta % 86400) / 3600 ))
    if (( days > 0 )); then
        printf '%s%dd %dh' "$sign" "$days" "$hours"
    else
        local minutes=$(( (delta % 3600) / 60 ))
        printf '%s%dh %dm' "$sign" "$hours" "$minutes"
    fi
}

# -----------------------------------------------------------------------------
# Provider validation
# -----------------------------------------------------------------------------

AUTH_SUPPORTED_PROVIDERS=("claude" "openai-codex")

auth_is_supported_provider() {
    local needle="$1"
    local p
    for p in "${AUTH_SUPPORTED_PROVIDERS[@]}"; do
        if [[ "$p" == "$needle" ]]; then
            return 0
        fi
    done
    return 1
}

# -----------------------------------------------------------------------------
# state.providers — ambient propagation
# -----------------------------------------------------------------------------

# Persist a (env_var_name, token) pair into ~/.config/bento/state.json so
# every future stack deploy inherits it via stacks_build_env_payload.
# Idempotent: writing the same value twice is a no-op.
auth_state_providers_set() {
    local var="$1"
    local token="$2"
    # state.sh defines state_set_json; load it lazily so this file stays
    # callable from scripts that don't bootstrap the full install env.
    if ! type state_set_json >/dev/null 2>&1; then
        # shellcheck disable=SC1091
        source "${BENTO_REPO_ROOT}/lib/state.sh"
        state_init
    fi
    # Ensure .providers exists so the assignment below doesn't error on
    # an old state.json that pre-dates this feature.
    if ! state_has '.providers'; then
        state_set_json '.providers' '{}'
    fi
    state_set ".providers.\"${var}\"" "$token"
}

# Remove a key from state.providers — used when the operator switches
# from OAuth to API-key (or vice versa) for the same provider, to avoid
# the dual-header trap (PR #20).
auth_state_providers_unset() {
    local var="$1"
    if ! type state_set_json >/dev/null 2>&1; then
        # shellcheck disable=SC1091
        source "${BENTO_REPO_ROOT}/lib/state.sh"
        state_init
    fi
    if state_has ".providers.\"${var}\""; then
        local tmp
        tmp=$(mktemp "${BENTO_STATE_FILE}.XXXXXX")
        jq "del(.providers.\"${var}\")" "$BENTO_STATE_FILE" > "$tmp"
        mv "$tmp" "$BENTO_STATE_FILE"
        chmod 600 "$BENTO_STATE_FILE"
    fi
}

# Propagate every state.providers entry into every running BENTO_MANAGED
# service. Idempotent — Docker drops env-add that's already present at
# the same value, and replaces it when the value changed.
#
# Each --env-add triggers a task replacement (~30s of downtime per
# stack). We accept that cost as the price of refresh propagation; the
# alternative is forcing every stack to read the credentials JSON on
# every request, which not every stack supports.
#
# Optional second arg: env var name to --env-rm BEFORE the adds. Used
# when the operator switches between OAuth (CLAUDE_CODE_OAUTH_TOKEN) and
# API key (ANTHROPIC_API_KEY) for the same provider — the old var has
# to go AWAY before the new one lands or Hermes hits the dual-header
# trap during the brief overlap.
auth_propagate_state_providers() {
    local also_remove="${1:-}"
    local services
    services=$(sudo docker service ls \
        --filter label=BENTO_MANAGED=true \
        --format '{{.Name}}' 2>/dev/null) || return 0
    if [[ -z "$services" ]]; then
        return 0
    fi

    local add_args=()
    while IFS=$'\t' read -r provider_var provider_val; do
        [[ -z "$provider_var" ]] && continue
        add_args+=(--env-add "${provider_var}=${provider_val}")
    done < <(jq -r '.providers // {} | to_entries[] | "\(.key)\t\(.value)"' "$BENTO_STATE_FILE")

    if [[ ${#add_args[@]} -eq 0 && -z "$also_remove" ]]; then
        return 0
    fi

    local svc
    while IFS= read -r svc; do
        [[ -z "$svc" ]] && continue
        # Note: we don't yet know whether this service has BENTO_MANAGED
        # set as an *env* (it does, see stacks_build_env_payload) or as a
        # *label* — `docker service ls --filter label=…` checks the label
        # form, and not every bento stack emits that label today. Filter
        # again on the env to be safe.
        local has_label
        has_label=$(sudo docker service inspect "$svc" \
            --format '{{index .Spec.Labels "BENTO_MANAGED"}}' 2>/dev/null)
        if [[ "$has_label" != "true" ]]; then
            # Maybe set as task-template env instead.
            local has_env
            has_env=$(sudo docker service inspect "$svc" \
                --format '{{range .Spec.TaskTemplate.ContainerSpec.Env}}{{println .}}{{end}}' 2>/dev/null \
                | grep -E '^BENTO_MANAGED=true$' || true)
            [[ -z "$has_env" ]] && continue
        fi

        local remove_args=()
        if [[ -n "$also_remove" ]]; then
            remove_args+=(--env-rm "$also_remove")
        fi
        sudo docker service update \
            "${remove_args[@]}" \
            "${add_args[@]}" \
            "$svc" >/dev/null 2>&1 || true
    done <<< "$services"
}

# -----------------------------------------------------------------------------
# Env-var injection for Hermes (single-stack — legacy entry, kept for
# back-compat with bento-auth callers that don't yet route through state)
# -----------------------------------------------------------------------------

# Wire CLAUDE_CODE_OAUTH_TOKEN into the paperclip service's runtime env so
# the Hermes provider `anthropic` picks it up.
#
# CRITICAL: we use CLAUDE_CODE_OAUTH_TOKEN, NOT ANTHROPIC_API_KEY. When set,
# the latter is also read by the Anthropic Python SDK's implicit env-var
# resolution and serialized as an `x-api-key` header in PARALLEL to the
# `Authorization: Bearer` header Hermes adds explicitly. Anthropic's API
# prioritises `x-api-key` and rejects OAuth tokens (sk-ant-oat*) on that
# code path with `401 invalid x-api-key` — leaving operators chasing a
# ghost "wrong API key" when the real cause is dual-header conflict.
#
# `docker service update --env-add` triggers a task replacement. The
# paperclip container restarts, but the `paperclip-data` volume keeps the
# CEO + chiefs intact, so the only cost is ~30s of agent cool-down.
auth_set_claude_oauth_env() {
    local token="$1"
    sudo docker service update \
        --env-add "CLAUDE_CODE_OAUTH_TOKEN=${token}" \
        --env-rm "ANTHROPIC_API_KEY" \
        "$AUTH_PAPERCLIP_SERVICE" >/dev/null
}

# Wire the Codex OAuth access token into Hermes's openai-codex provider.
#
# Two-step:
#   1. Update the service env so future restarts have the token (and so
#      doctor / introspection tools see it).
#   2. Call `hermes auth add openai-codex` inside the current task so the
#      live process picks it up without forcing a 30-second restart.
auth_set_codex_oauth_env() {
    local token="$1"
    local label="${2:-bento-auth}"
    local cid
    cid=$(auth_find_paperclip_container) || return 1
    # Persist for future restarts.
    sudo docker service update \
        --env-add "OPENAI_API_KEY=${token}" \
        "$AUTH_PAPERCLIP_SERVICE" >/dev/null
    # Live-update so existing tasks pick it up. The `hermes auth add` CLI
    # writes to ${HOME}/.hermes/auth.json — HOME is /paperclip for the
    # `node` user that runs inside the upstream image.
    sudo docker exec --user node -e HOME=/paperclip "$cid" \
        /opt/hermes/bin/hermes auth add openai-codex \
            --type api-key --api-key "$token" --label "$label" >/dev/null 2>&1 || true
}
