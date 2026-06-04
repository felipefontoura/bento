#!/bin/bash
# bento — app stacks (manifest + deploy via Portainer API)
#
# Reads per-stack manifests (stacks/*/<name>.manifest.json), resolves envs in
# the documented order (state → from_state → default → generate → prompt),
# deploys via Portainer's "create stack from Git repository" endpoint, then
# runs the optional per-stack install.sh post-deploy hook.

[[ -n "${_BENTO_STACKS_LOADED:-}" ]] && return 0
_BENTO_STACKS_LOADED=1

# shellcheck source=lib/ui.sh
source "$(dirname "${BASH_SOURCE[0]}")/ui.sh"
# shellcheck source=lib/state.sh
source "$(dirname "${BASH_SOURCE[0]}")/state.sh"
# shellcheck source=lib/portainer.sh
source "$(dirname "${BASH_SOURCE[0]}")/portainer.sh"

# BENTO_REPO_ROOT is exported by install.sh. Fall back to deriving it
# from this file's own location when sourced standalone (smoke tests).
: "${BENTO_REPO_ROOT:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
: "${BENTO_REPO_URL:=https://github.com/felipefontoura/bento}"
: "${BENTO_REPO_REF:=refs/heads/main}"

# -----------------------------------------------------------------------------
# Manifest discovery
#
# Layout: stacks/<category>/<key>/{compose.yml, manifest.json, install.sh}
# Stack key == directory name.
# -----------------------------------------------------------------------------
stacks_list_manifests() {
    find "${BENTO_REPO_ROOT}/stacks" -mindepth 3 -maxdepth 3 -type f -name 'manifest.json' | sort
}

stacks_list_app_manifests() {
    find "${BENTO_REPO_ROOT}/stacks/app" -mindepth 2 -maxdepth 2 -type f -name 'manifest.json' 2>/dev/null | sort
}

stacks_manifest_for_key() {
    local key="$1"
    local hit
    hit=$(find "${BENTO_REPO_ROOT}/stacks" -mindepth 3 -maxdepth 3 -type f -name 'manifest.json' -path "*/${key}/manifest.json" | head -1)
    [[ -n "$hit" ]] && printf '%s' "$hit"
}

# Convention: compose lives next to manifest as compose.yml.
stacks_compose_path_for_manifest() {
    local manifest_path="$1"
    local override
    override=$(jq -r '.compose_path // empty' "$manifest_path")
    if [[ -n "$override" ]]; then
        printf '%s' "$override"
    else
        # Path relative to repo root.
        local dir="$(dirname "$manifest_path")"
        printf '%s' "${dir#${BENTO_REPO_ROOT}/}/compose.yml"
    fi
}

# Convention: install.sh lives next to manifest. Optional.
stacks_install_script_for_manifest() {
    local manifest_path="$1"
    local override
    override=$(jq -r '.install_script // empty' "$manifest_path")
    if [[ -n "$override" ]]; then
        printf '%s' "$override"
        return 0
    fi
    local dir="$(dirname "$manifest_path")"
    if [[ -x "$dir/install.sh" ]]; then
        printf '%s' "${dir#${BENTO_REPO_ROOT}/}/install.sh"
    fi
}

# -----------------------------------------------------------------------------
# Template substitution — replaces ${VAR} from state.bootstrap.* + envs already
# resolved for this stack.
# -----------------------------------------------------------------------------
stacks_substitute_template() {
    local template="$1"
    local base_domain admin_email
    base_domain="$(state_get '.bootstrap.base_domain')"
    admin_email="$(state_get '.bootstrap.admin_email')"

    BASE_DOMAIN="$base_domain" \
    ADMIN_EMAIL="$admin_email" \
        envsubst <<< "$template"
}

# -----------------------------------------------------------------------------
# Env resolution: implements the documented order from the plan.
#   1. state.envs[<key>][<var>]  → reuse
#   2. manifest.from_state        → pull another state var
#   3. manifest.default           → use as default in prompt
#   4. manifest.generate          → run command, mark hide
#   5. manifest.prompt (required) → must ask
#   6. manifest.prompt (optional) → ask, skippable
# -----------------------------------------------------------------------------
stacks_resolve_env() {
    local stack_key="$1"
    local env_spec="$2"   # single JSON object from manifest.env array

    local var_name from_state default_tpl generate_cmd prompt required hide existing
    var_name=$(jq -r '.name' <<< "$env_spec")
    from_state=$(jq -r '.from_state // empty' <<< "$env_spec")
    default_tpl=$(jq -r '.default // empty' <<< "$env_spec")
    generate_cmd=$(jq -r '.generate // empty' <<< "$env_spec")
    prompt=$(jq -r '.prompt // empty' <<< "$env_spec")
    required=$(jq -r '.required // false' <<< "$env_spec")
    hide=$(jq -r '.hide // false' <<< "$env_spec")

    # 1. Existing state.
    existing="$(state_get ".envs[\"$stack_key\"][\"$var_name\"]")"
    if [[ -n "$existing" ]]; then
        printf '%s' "$existing"
        return 0
    fi

    # 2. from_state.
    if [[ -n "$from_state" ]]; then
        local sourced
        sourced="$(state_get ".envs[\"global\"][\"$from_state\"]")"
        if [[ -z "$sourced" ]]; then
            sourced="$(state_get ".bootstrap.$from_state")"
        fi
        if [[ -n "$sourced" ]]; then
            state_set ".envs[\"$stack_key\"][\"$var_name\"]" "$sourced"
            printf '%s' "$sourced"
            return 0
        fi
    fi

    # 4. generate (handled before prompt so we don't ask for things we make).
    if [[ -n "$generate_cmd" ]]; then
        local generated
        generated=$(bash -c "$generate_cmd")
        state_set ".envs[\"$stack_key\"][\"$var_name\"]" "$generated"
        printf '%s' "$generated"
        return 0
    fi

    # 3. default template (substituted).
    local default_value=""
    if [[ -n "$default_tpl" ]]; then
        default_value="$(stacks_substitute_template "$default_tpl")"
    fi

    # 5/6. prompt the user.
    if [[ -n "$prompt" ]]; then
        local answer prompt_label
        prompt_label="$var_name — $prompt"
        if [[ "$hide" == "true" ]]; then
            answer="$(ui_password "$prompt_label")"
        else
            answer="$(ui_input "$prompt_label" "$default_value" "$default_value")"
        fi
        if [[ -z "$answer" && "$required" == "true" ]]; then
            ui_error "$var_name is required."
            return 1
        fi
        state_set ".envs[\"$stack_key\"][\"$var_name\"]" "$answer"
        printf '%s' "$answer"
        return 0
    fi

    # No prompt — just use the default if there is one.
    if [[ -n "$default_value" ]]; then
        state_set ".envs[\"$stack_key\"][\"$var_name\"]" "$default_value"
        printf '%s' "$default_value"
    fi
}

# Build the env array Portainer expects ([{name, value}, …]).
stacks_build_env_payload() {
    local stack_key="$1"
    local manifest_path="$2"

    local env_entries=()
    local env_spec value var_name

    while IFS= read -r env_spec; do
        var_name=$(jq -r '.name' <<< "$env_spec")
        value="$(stacks_resolve_env "$stack_key" "$env_spec")" || return 1
        env_entries+=("$(jq -n --arg n "$var_name" --arg v "$value" '{name: $n, value: $v}')")
    done < <(jq -c '.env[]?' "$manifest_path")

    # Always add the tracking labels so bento knows which stacks it owns.
    local git_sha
    git_sha=$(git -C "$BENTO_REPO_ROOT" rev-parse HEAD 2>/dev/null || echo "unknown")

    env_entries+=("$(jq -n '{name: "BENTO_MANAGED",      value: "true"}')")
    env_entries+=("$(jq -n --arg v "$git_sha"        '{name: "BENTO_DEPLOYED_REF", value: $v}')")
    env_entries+=("$(jq -n --arg v "$stack_key"      '{name: "BENTO_STACK_KEY",    value: $v}')")

    printf '['
    local first=1
    for e in "${env_entries[@]}"; do
        if (( first )); then first=0; else printf ','; fi
        printf '%s' "$e"
    done
    printf ']'
}

# -----------------------------------------------------------------------------
# Deploy
# -----------------------------------------------------------------------------
stacks_deploy() {
    local manifest_path="$1"
    local stack_key compose_path stack_name
    stack_key=$(jq -r '.name' "$manifest_path")
    compose_path="$(stacks_compose_path_for_manifest "$manifest_path")"
    stack_name="$stack_key"

    ui_section "Deploying $stack_key"

    local env_payload stack_id
    env_payload="$(stacks_build_env_payload "$stack_key" "$manifest_path")" || return 1

    stack_id=$(portainer_create_stack_from_git \
        "$stack_name" \
        "$compose_path" \
        "$env_payload" \
        "$BENTO_REPO_URL" \
        "$BENTO_REPO_REF") || return 1

    state_set ".stacks[\"$stack_key\"].stack_id" "$stack_id"
    state_set ".stacks[\"$stack_key\"].deployed_ref" "$(git -C "$BENTO_REPO_ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"

    ui_success "$stack_key deployed (Portainer stack #$stack_id)."

    # Run optional post-deploy hook. Install scripts get a known set of env
    # vars so they can call helpers from lib/install-helpers.sh.
    local install_script
    install_script="$(stacks_install_script_for_manifest "$manifest_path")"
    if [[ -n "$install_script" && -x "${BENTO_REPO_ROOT}/${install_script}" ]]; then
        ui_info "Running post-deploy script: $install_script"
        local pg_pass
        pg_pass="$(state_get '.envs["postgres"]["POSTGRES_PASSWORD"]')"
        BENTO_REPO_ROOT="$BENTO_REPO_ROOT" \
        BENTO_STACK_KEY="$stack_key" \
        BENTO_STATE_FILE="$BENTO_STATE_FILE" \
        POSTGRES_PASSWORD="$pg_pass" \
            "${BENTO_REPO_ROOT}/${install_script}"
    fi

    # Print URL if manifest declares post_deploy_url.
    local url_tpl resolved_url
    url_tpl=$(jq -r '.post_deploy_url // empty' "$manifest_path")
    if [[ -n "$url_tpl" ]]; then
        resolved_url="$(stacks_substitute_template_with_stack_envs "$stack_key" "$url_tpl")"
        ui_boxed_success "$stack_key is ready at: $resolved_url"
    fi
}

# Substitute template using both bootstrap envs AND the stack's resolved envs.
stacks_substitute_template_with_stack_envs() {
    local stack_key="$1"
    local template="$2"

    local env_kv envs_args=()
    while IFS= read -r env_kv; do
        envs_args+=("$env_kv")
    done < <(jq -r ".envs[\"$stack_key\"] // {} | to_entries[] | \"\(.key)=\(.value)\"" "$BENTO_STATE_FILE")

    local base_domain admin_email
    base_domain="$(state_get '.bootstrap.base_domain')"
    admin_email="$(state_get '.bootstrap.admin_email')"

    env -i \
        BASE_DOMAIN="$base_domain" \
        ADMIN_EMAIL="$admin_email" \
        "${envs_args[@]}" \
        envsubst <<< "$template"
}

# -----------------------------------------------------------------------------
# Menu — Step 3
# -----------------------------------------------------------------------------
stacks_step3_menu() {
    local manifests=()
    while IFS= read -r m; do manifests+=("$m"); done < <(stacks_list_app_manifests)

    if (( ${#manifests[@]} == 0 )); then
        ui_warn "No app stack manifests found yet."
        return 0
    fi

    # Build "name — description" labels for gum choose.
    local labels=() label name desc
    for m in "${manifests[@]}"; do
        name=$(jq -r '.name' "$m")
        desc=$(jq -r '.description // ""' "$m")
        labels+=("${name} — ${desc}")
    done

    local picks
    picks="$(printf '%s\n' "${labels[@]}" | ui_choose_multi)"
    [[ -z "$picks" ]] && return 0

    while IFS= read -r picked; do
        local picked_name
        picked_name="${picked%% — *}"
        local m
        m=$(stacks_manifest_for_key "$picked_name")
        if [[ -n "$m" ]]; then
            stacks_deploy "$m" || ui_error "Deploy of $picked_name failed; continuing."
        fi
    done <<< "$picks"

    state_set '.steps.apps' "done"
}

stacks_is_apps_done() {
    [[ "$(state_get '.steps.apps')" == "done" ]]
}
