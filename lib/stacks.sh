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
# BENTO_REPO_REF tells Portainer which branch to clone when creating
# stacks. Default to the local bento clone's branch so Portainer stays
# in sync with whatever the installer is running from; fall back to main.
: "${BENTO_REPO_REF:=refs/heads/$(git -C "$BENTO_REPO_ROOT" symbolic-ref --short HEAD 2>/dev/null || echo main)}"

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
# Persist <value> at .envs[<stack>][<var>] in state, then echo it.
# Centralising the write means stacks_resolve_env only chooses where the
# value comes from — it doesn't repeat the same state_set+printf each
# time we land on a source.
_stacks_persist_env() {
    local stack_key="$1" var_name="$2" value="$3"
    state_set ".envs[\"$stack_key\"][\"$var_name\"]" "$value"
    printf '%s' "$value"
}

# Look up <from_state_key> in any other deployed stack's envs first,
# then in the bootstrap block. Echo the first non-empty match, or
# nothing on miss.
_stacks_lookup_from_state() {
    local from_state="$1"
    local sourced
    sourced=$(jq -r --arg fs "$from_state" \
        '[.envs // {} | .[]? | .[$fs] // empty] | map(select(. != null and . != "")) | first // ""' \
        "$BENTO_STATE_FILE" 2>/dev/null)
    [[ -z "$sourced" ]] && sourced="$(state_get ".bootstrap.$from_state")"
    printf '%s' "$sourced"
}

# Unattended-mode resolver: BENTO_ENV_<STACK>_<VAR> override → default →
# empty (fail if required). Echoes the resolved value (or nothing).
# Returns 1 only on "required + nothing".
_stacks_resolve_env_unattended() {
    local stack_key="$1" var_name="$2" default_value="$3" required="$4"
    local env_var env_val
    env_var="BENTO_ENV_$(printf '%s' "$stack_key" | tr 'a-z-' 'A-Z_')_${var_name}"
    env_val="${!env_var:-}"
    if [[ -n "$env_val" ]]; then
        _stacks_persist_env "$stack_key" "$var_name" "$env_val"
        return 0
    fi
    if [[ -n "$default_value" ]]; then
        _stacks_persist_env "$stack_key" "$var_name" "$default_value"
        return 0
    fi
    if [[ "$required" == "true" ]]; then
        ui_error "$var_name required for $stack_key (set $env_var)"
        return 1
    fi
    _stacks_persist_env "$stack_key" "$var_name" ""
}

# Interactive resolver: prompt the user, hide if it's a secret.
# Returns 1 on "required + empty answer".
_stacks_resolve_env_interactive() {
    local stack_key="$1" var_name="$2" prompt="$3" default_value="$4"
    local required="$5" hide="$6"
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
    _stacks_persist_env "$stack_key" "$var_name" "$answer"
}

stacks_resolve_env() {
    local stack_key="$1"
    local env_spec="$2"   # single JSON object from manifest.env array

    local var_name from_state default_tpl generate_cmd prompt required hide
    var_name=$(jq -r '.name' <<< "$env_spec")
    from_state=$(jq -r '.from_state // empty' <<< "$env_spec")
    default_tpl=$(jq -r '.default // empty' <<< "$env_spec")
    generate_cmd=$(jq -r '.generate // empty' <<< "$env_spec")
    prompt=$(jq -r '.prompt // empty' <<< "$env_spec")
    required=$(jq -r '.required // false' <<< "$env_spec")
    hide=$(jq -r '.hide // false' <<< "$env_spec")

    # 1. Existing state — reuse without touching anything.
    local existing
    existing="$(state_get ".envs[\"$stack_key\"][\"$var_name\"]")"
    if [[ -n "$existing" ]]; then
        printf '%s' "$existing"
        return 0
    fi

    # 2. from_state — pull another stack's env or a bootstrap field.
    if [[ -n "$from_state" ]]; then
        local sourced
        sourced=$(_stacks_lookup_from_state "$from_state")
        if [[ -n "$sourced" ]]; then
            _stacks_persist_env "$stack_key" "$var_name" "$sourced"
            return 0
        fi
    fi

    # 3. generate — run the shell snippet once, persist the output.
    if [[ -n "$generate_cmd" ]]; then
        local generated
        generated=$(bash -c "$generate_cmd")
        _stacks_persist_env "$stack_key" "$var_name" "$generated"
        return 0
    fi

    # 4. Compute the default (template-substituted) for use by prompts.
    local default_value=""
    [[ -n "$default_tpl" ]] && default_value="$(stacks_substitute_template "$default_tpl")"

    # 5/6. Prompt the user (env-driven in unattended mode).
    if [[ -n "$prompt" ]]; then
        if [[ "${BENTO_UNATTENDED:-0}" == "1" ]]; then
            _stacks_resolve_env_unattended "$stack_key" "$var_name" "$default_value" "$required"
        else
            _stacks_resolve_env_interactive "$stack_key" "$var_name" "$prompt" "$default_value" "$required" "$hide"
        fi
        return $?
    fi

    # 7. No prompt — silent default if there is one.
    [[ -n "$default_value" ]] && _stacks_persist_env "$stack_key" "$var_name" "$default_value"
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

    # `jq -s '.'` slurps the stream of JSON objects into a single array
    # — safer than concatenating with printf when values can contain
    # commas, quotes, or newlines.
    printf '%s\n' "${env_entries[@]}" | jq -cs '.'
}

# -----------------------------------------------------------------------------
# Memory budget — sums every `memory: NNNm` / `NNNM` / `NNg` line in the
# selected stacks' compose files and compares against `free -m` available.
# Heuristic only: limits aren't reservations, so a single OOM-mark doesn't
# kill the deploy, but a 4 GB VPS asked for 6 GB worth of limits is
# something the user should know before tickets get cut.
# -----------------------------------------------------------------------------
stacks_memory_budget_check() {
    local apps_csv="$1"
    local sum_mb=0 stack_mb free_mb manifest compose app

    IFS=',' read -ra apps <<< "$apps_csv"
    for app in "${apps[@]}"; do
        app="${app// /}"
        [[ -z "$app" ]] && continue
        manifest=$(stacks_manifest_for_key "$app")
        [[ -z "$manifest" ]] && continue
        compose="${BENTO_REPO_ROOT}/$(stacks_compose_path_for_manifest "$manifest")"
        [[ -f "$compose" ]] || continue
        # Sum every `memory:` value. Convert `Ng`/`Gg` → MB.
        stack_mb=$(awk '
            /^[[:space:]]*memory:[[:space:]]*[0-9]+[MmGg]?/ {
                v = $2
                if (v ~ /[Gg]/) { sub(/[Gg]/, "", v); v = v * 1024 }
                else            { sub(/[Mm]/, "", v) }
                sum += v + 0
            }
            END { print int(sum) }
        ' "$compose" 2>/dev/null || echo 0)
        sum_mb=$((sum_mb + stack_mb))
    done

    free_mb=$(free -m 2>/dev/null | awk '/^Mem:/{print $7}')
    [[ -z "$free_mb" || "$free_mb" == "0" ]] && free_mb=$(free -m | awk '/^Mem:/{print $4}')

    if (( sum_mb == 0 || free_mb == 0 )); then
        return 0
    fi

    if (( sum_mb > free_mb * 12 / 10 )); then
        ui_warn "Memory budget tight: stacks declare ~${sum_mb} MB of limits, only ${free_mb} MB available."
        ui_warn "Either upgrade the VPS or deploy in smaller waves (lighter apps first)."
    else
        ui_info "Memory budget OK: stacks declare ~${sum_mb} MB of limits, ${free_mb} MB available."
    fi
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

    # If the compose declares a `build:` directive (paperclip is the only
    # stack like this today), Swarm's `docker stack deploy` will ignore it
    # and try to pull the image. Build it locally first so the resulting
    # image is in the host daemon when Portainer's stack create runs.
    local full_compose="${BENTO_REPO_ROOT}/${compose_path}"
    if grep -qE '^[[:space:]]+build:' "$full_compose" 2>/dev/null; then
        ui_info "Compose declares a build target — building image locally first"
        local build_log=/tmp/bento-build-${stack_key}.log
        : > "$build_log"
        if (cd "$(dirname "$full_compose")" \
            && sudo docker compose -f "$(basename "$full_compose")" build --pull \
                >>"$build_log" 2>&1); then
            ui_success "Local image built (log: $build_log)"
        else
            ui_error "Image build failed — see $build_log"
            tail -8 "$build_log" >&2
            return 1
        fi
    fi

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

        # Export every env resolved for THIS stack so install.sh can read
        # CHATWOOT_HOST, *_SECRET_KEY_BASE, etc. without cracking open
        # state.json itself. POSTGRES_PASSWORD is always available.
        local stack_env_assigns=()
        while IFS= read -r kv; do
            [[ -n "$kv" ]] && stack_env_assigns+=("$kv")
        done < <(jq -r ".envs[\"$stack_key\"] // {} | to_entries[] | \"\(.key)=\(.value)\"" "$BENTO_STATE_FILE")

        env \
            BENTO_REPO_ROOT="$BENTO_REPO_ROOT" \
            BENTO_STACK_KEY="$stack_key" \
            BENTO_STATE_FILE="$BENTO_STATE_FILE" \
            POSTGRES_PASSWORD="$pg_pass" \
            "${stack_env_assigns[@]}" \
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

    # Surface a memory budget for the chosen apps before the first deploy.
    local picks_csv=""
    while IFS= read -r picked; do
        local pn="${picked%% — *}"
        picks_csv+="${pn},"
    done <<< "$picks"
    stacks_memory_budget_check "${picks_csv%,}"

    local failures=()
    while IFS= read -r picked; do
        local picked_name
        picked_name="${picked%% — *}"
        local m
        m=$(stacks_manifest_for_key "$picked_name")
        if [[ -n "$m" ]]; then
            if ! stacks_deploy "$m"; then
                ui_error "Deploy of $picked_name failed; continuing."
                failures+=("$picked_name")
            fi
        fi
    done <<< "$picks"

    if (( ${#failures[@]} > 0 )); then
        printf '%s\n' "${failures[@]}" > "${BENTO_STATE_DIR}/last-run-failures"
        ui_warn "Step 3 finished with failures: ${failures[*]}"
        return 1
    fi

    rm -f "${BENTO_STATE_DIR}/last-run-failures"
    state_set '.steps.apps' "done"
}

stacks_is_apps_done() {
    [[ "$(state_get '.steps.apps')" == "done" ]]
}
