#!/bin/bash
# bento — helpers for AI-provider API-key auth
#
# Sourced by scripts/bento-auth and (lazily) by the auth menu hook in
# install.sh. Intentionally minimal — no `set -e`, no global state mutation —
# so they're safe to source from interactive menus and one-off scripts.
#
# Concerns covered:
#   * reading the data-driven provider catalog (lib/provider-catalog.json)
#   * validating an API key against the provider endpoint
#   * persisting keys to state.providers and propagating them to every
#     BENTO_MANAGED stack
#
# Subscription OAuth is intentionally NOT handled here — each app owns its
# native sign-in (which refreshes the token properly).

# -----------------------------------------------------------------------------
# Provider catalog — data-driven API-key providers
# -----------------------------------------------------------------------------
#
# Every provider in lib/provider-catalog.json is a plain API key: bento-auth
# prompts for it, optionally validates it, stores it in state.providers and
# propagates. Adding a provider is a JSON edit, not code.

# Absolute path to the catalog. Resolved at call time so it tracks
# BENTO_REPO_ROOT even when this file is sourced before it's set.
auth_catalog_path() {
    printf '%s/lib/provider-catalog.json' "${BENTO_REPO_ROOT:-/root/.local/share/bento}"
}

# True if <id> is a known catalog provider.
auth_catalog_has() {
    local id="$1" path
    path="$(auth_catalog_path)"
    [[ -f "$path" ]] || return 1
    jq -e --arg id "$id" '.providers[] | select(.id==$id)' "$path" >/dev/null 2>&1
}

# Echo one field of a catalog provider record (empty if absent).
auth_catalog_get() {
    local id="$1" field="$2" path
    path="$(auth_catalog_path)"
    [[ -f "$path" ]] || return 1
    jq -r --arg id "$id" --arg f "$field" \
        '.providers[] | select(.id==$id) | .[$f] // empty' "$path" 2>/dev/null
}

# Emit `id<TAB>label<TAB>format` for every catalog provider (pickers/help).
auth_catalog_list() {
    local path
    path="$(auth_catalog_path)"
    [[ -f "$path" ]] || return 1
    jq -r '.providers[] | "\(.id)\t\(.label)\t\(.format)"' "$path" 2>/dev/null
}

# Validate an API key by GETting <url> with a Bearer header.
#   0 = HTTP 2xx (accepted)
#   1 = non-2xx / unreachable (rejected)
#   2 = cannot validate (no url, or curl missing) — caller treats as skip
auth_validate_api_key() {
    local url="$1" key="$2"
    [[ -z "$url" ]] && return 2
    command -v curl >/dev/null 2>&1 || return 2
    local code
    code=$(curl -sS -o /dev/null -w '%{http_code}' \
        -H "Authorization: Bearer ${key}" \
        --max-time 15 "$url" 2>/dev/null) || true
    [[ "$code" =~ ^2[0-9][0-9]$ ]] && return 0
    return 1
}

# Emit `VAR<TAB>value` for every entry in state.providers (for `bento-auth
# list`). Sources state.sh lazily so BENTO_STATE_FILE is defined.
auth_state_providers_dump() {
    if ! declare -F state_set >/dev/null 2>&1; then
        # shellcheck source=state.sh
        source "${BENTO_REPO_ROOT}/lib/state.sh"
    fi
    [[ -f "$BENTO_STATE_FILE" ]] || return 0
    jq -r '.providers // {} | to_entries[] | "\(.key)\t\(.value)"' \
        "$BENTO_STATE_FILE" 2>/dev/null
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

# Remove a key from state.providers — used when vacating a provider slot
# (e.g. clearing the shared OpenAI slot before assigning a new occupant).
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
# Optional args: one or more env var names to --env-rm BEFORE the adds.
# Used when vacating a provider slot — e.g. clearing the shared OpenAI slot
# (OPENAI_API_KEY + OPENAI_BASE_URL together) before assigning a new occupant
# — so stale vars don't linger on the service alongside the new ones.
auth_propagate_state_providers() {
    local also_remove=("$@")
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

    # Build the --env-rm list once (same for every service).
    local remove_args=() rm_var
    for rm_var in "${also_remove[@]}"; do
        [[ -n "$rm_var" ]] && remove_args+=(--env-rm "$rm_var")
    done

    if [[ ${#add_args[@]} -eq 0 && ${#remove_args[@]} -eq 0 ]]; then
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

        sudo docker service update \
            "${remove_args[@]}" \
            "${add_args[@]}" \
            "$svc" >/dev/null 2>&1 || true
    done <<< "$services"
}

