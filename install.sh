#!/bin/bash
# bento — main interactive menu
#
# Sourced by boot.sh. Can also be run standalone after cloning.

set -uo pipefail

BENTO_REPO_ROOT="${BENTO_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
export BENTO_REPO_ROOT

# Validation patterns reused by both interactive bootstrap and the
# BENTO_UNATTENDED env-driven path. Living here (not inside a function)
# means unattended_main can reject garbage BENTO_ADVERTISE_ADDR / etc.
# before any state mutation, instead of discovering the typo at deploy
# time.
readonly BENTO_DOMAIN_REGEX='^([a-z0-9]+(-[a-z0-9]+)*\.)+[a-z]{2,}$'
readonly BENTO_EMAIL_REGEX='^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'
readonly BENTO_IPV4_REGEX='^([0-9]{1,3}\.){3}[0-9]{1,3}$'

# Detect the host's public IPv4. `curl -4` forces v4 — without it,
# dual-stack hosts (most Hetzner / DigitalOcean VPS) often return v6,
# which the user can't paste into a Swarm advertise-addr field. Echoes
# nothing on failure so the caller can decide what to do (prompt, error,
# default placeholder).
bento_detect_public_ipv4() {
    local ip
    # Two providers; the second is a fallback when the first is rate-
    # limited or down. Both are documented IPv4-only when forced with -4.
    for endpoint in https://api.ipify.org https://ifconfig.me; do
        ip=$(curl -4 -fsSL --max-time 5 "$endpoint" 2>/dev/null || true)
        if [[ "$ip" =~ $BENTO_IPV4_REGEX ]]; then
            printf '%s' "$ip"
            return 0
        fi
    done
    return 1
}

# -----------------------------------------------------------------------------
# Load libraries
# -----------------------------------------------------------------------------
# shellcheck source=lib/deps.sh
source "${BENTO_REPO_ROOT}/lib/deps.sh"

# Ensure gum + jq + envsubst are installed before sourcing UI modules.
if ! deps_ensure_all; then
    echo "Failed to install bento dependencies." >&2
    exit 1
fi

# shellcheck source=lib/ui.sh
source "${BENTO_REPO_ROOT}/lib/ui.sh"
# shellcheck source=lib/banner.sh
source "${BENTO_REPO_ROOT}/lib/banner.sh"
# shellcheck source=lib/state.sh
source "${BENTO_REPO_ROOT}/lib/state.sh"
# shellcheck source=lib/portainer.sh
source "${BENTO_REPO_ROOT}/lib/portainer.sh"
# shellcheck source=lib/infra.sh
source "${BENTO_REPO_ROOT}/lib/infra.sh"
# shellcheck source=lib/stacks.sh
source "${BENTO_REPO_ROOT}/lib/stacks.sh"
# shellcheck source=lib/report.sh
source "${BENTO_REPO_ROOT}/lib/report.sh"

state_init

# Unattended mode — set BENTO_UNATTENDED=1 + BENTO_BASE_DOMAIN +
# BENTO_ADMIN_EMAIL (+ optionally BENTO_ADVERTISE_ADDR + BENTO_APPS) to
# drive bento end-to-end without prompts. See unattended_main below.
BENTO_UNATTENDED="${BENTO_UNATTENDED:-0}"

# -----------------------------------------------------------------------------
# Bootstrap inicial (single prompt screen with BASE_DOMAIN + ADMIN_EMAIL + IP)
# -----------------------------------------------------------------------------

bootstrap_from_env() {
    local d="${BENTO_BASE_DOMAIN:-}"
    local e="${BENTO_ADMIN_EMAIL:-}"
    local a="${BENTO_ADVERTISE_ADDR:-}"

    if [[ -z "$d" ]]; then
        ui_error "BENTO_UNATTENDED requires BENTO_BASE_DOMAIN"
        exit 1
    fi
    if [[ ! "$d" =~ $BENTO_DOMAIN_REGEX ]]; then
        ui_error "BENTO_BASE_DOMAIN='$d' is not a valid domain."
        exit 1
    fi
    if [[ -z "$e" ]]; then
        e="admin@${d}"
    fi
    if [[ ! "$e" =~ $BENTO_EMAIL_REGEX ]]; then
        ui_error "BENTO_ADMIN_EMAIL='$e' is not a valid email."
        exit 1
    fi
    if [[ -z "$a" ]]; then
        a=$(bento_detect_public_ipv4 || true)
    fi
    if [[ -z "$a" ]]; then
        ui_error "Could not detect a public IPv4 — set BENTO_ADVERTISE_ADDR explicitly."
        exit 1
    fi
    # Reject IPv6 / garbage in unattended mode. Interactive mode loops
    # the prompt; unattended has no human to re-ask, so bail.
    if [[ ! "$a" =~ $BENTO_IPV4_REGEX ]]; then
        ui_error "BENTO_ADVERTISE_ADDR='$a' is not a valid IPv4 address."
        exit 1
    fi

    state_set '.bootstrap.base_domain' "$d"
    state_set '.bootstrap.admin_email' "$e"
    state_set '.bootstrap.advertise_addr' "$a"
    ui_info "Unattended bootstrap: domain=$d  email=$e  ip=$a"
}

bootstrap_prompt_once() {
    if state_has '.bootstrap.base_domain' \
       && state_has '.bootstrap.admin_email' \
       && state_has '.bootstrap.advertise_addr'; then
        return 0
    fi

    if [[ "$BENTO_UNATTENDED" == "1" ]]; then
        bootstrap_from_env
        return 0
    fi

    ui_section "First-time setup"
    ui_subtle "These values seed every stack you'll deploy. They're written to ~/.config/bento/state.json."

    # Placeholders for domain + email; the IP is the exception — we
    # auto-detect it (IPv4-forced) and pre-fill the field so the
    # operator only confirms with enter when the detection is right.
    # Domain and email stay placeholder-only because their "obvious"
    # guess (derived email, hand-typed domain) is too easy to accept by
    # mistake. If detection fails we leave the field empty rather than
    # suggest an IPv6 (the rejected form before this fix).
    local base_domain admin_email advertise_addr detected_ip=""
    base_domain=$(ui_input_validated \
        "Base domain" "mydomain.com" "" \
        "$BENTO_DOMAIN_REGEX" "That doesn't look like a domain. Try again.")

    admin_email=$(ui_input_validated \
        "Admin email (Let's Encrypt + alerts)" "admin@yourdomain.com" "" \
        "$BENTO_EMAIL_REGEX" "That doesn't look like an email. Try again.")

    detected_ip="$(bento_detect_public_ipv4 || true)"
    advertise_addr=$(ui_input_validated \
        "VPS public IPv4" "${detected_ip:-198.51.100.42}" "$detected_ip" \
        "$BENTO_IPV4_REGEX" "That doesn't look like an IPv4 address. Try again.")

    ui_format_md <<EOF
**About to use:**

- Portainer at \`portainer.${base_domain}\`
- Subdomains derive from \`${base_domain}\` per stack
- Let's Encrypt via \`${admin_email}\`
- Docker Swarm advertising \`${advertise_addr}\`
EOF

    if ! ui_confirm "Looks right?"; then
        ui_warn "Aborting bootstrap. Re-run to try again."
        exit 1
    fi

    state_set '.bootstrap.base_domain' "$base_domain"
    state_set '.bootstrap.admin_email' "$admin_email"
    state_set '.bootstrap.advertise_addr' "$advertise_addr"
}

# -----------------------------------------------------------------------------
# Step 1 — Hardening (+ Docker foundation as tail)
# -----------------------------------------------------------------------------
step1_status() {
    if [[ "$(state_get '.steps.hardening')" == "done" ]]; then echo "done"
    elif [[ -f /var/lib/bento/reboot-required ]]; then echo pending
    else echo pending
    fi
}

step1_run() {
    ui_section "Step 1 — Harden the system"

    # Auto-detect: hardening already ran (Docker present + reboot sentinel
    # exists from a previous run that didn't go through bento's wrapper).
    if command -v docker >/dev/null 2>&1 \
       && systemctl is-active --quiet docker 2>/dev/null \
       && [[ -f /var/lib/bento/reboot-required ]]; then
        ui_info "Hardening artifacts detected — skipping re-run."
        state_set '.steps.hardening' "done"
        infra_run_step1_tail || return 1
        return 0
    fi

    if [[ "$BENTO_UNATTENDED" != "1" ]]; then
        ui_format_md <<EOF
**This will:**
- Update + upgrade all packages
- Install Docker, UFW, fail2ban, AppArmor, AIDE, auditd, chrony
- Apply kernel sysctl hardening
- Enable firewall (ssh/http/https)
- Initialize Docker Swarm + create overlay network \`network_public\`

This takes ~5-10 minutes and will require a reboot afterward.
EOF
        ui_confirm "Proceed?" || return 0
    fi

    local log_file
    log_file="${BENTO_LOG_DIR}/hardening-$(date +%Y%m%d-%H%M%S).log"
    ui_info "Streaming output to $log_file"

    # `</dev/null` is load-bearing — without it, apt-get reproducibly enters
    # the T (stopped) state at "Processing triggers for install-info" on
    # Ubuntu 26.04. Something in the post-trigger phase (likely needrestart
    # or a snapd postinst hook) probes the controlling tty and trips the
    # kernel into sending SIGTTIN/SIGTSTP to apt-get, which has no handler
    # and just stops. Disconnecting stdin from the tty closes that path:
    # any process that tries to read sees EOF instead of receiving a
    # job-control signal.
    if sudo NEEDRESTART_MODE=a DEBIAN_FRONTEND=noninteractive \
            bash "${BENTO_REPO_ROOT}/lib/hardening.sh" </dev/null 2>&1 \
            | tee "$log_file"; then
        state_set '.steps.hardening' "done"
    else
        state_set '.steps.hardening' "failed"
        ui_error "Hardening failed — see $log_file"
        return 1
    fi

    # Foundation tail: swarm + network.
    infra_run_step1_tail || return 1

    if [[ -f /var/lib/bento/reboot-required ]]; then
        if [[ "$BENTO_UNATTENDED" == "1" ]]; then
            ui_info "Reboot required — installing bento-resume.service and rebooting"
            unattended_install_resume_hook
            sudo reboot
            exit 0
        fi
        ui_boxed_warn "$(cat <<EOF
Reboot required to apply security settings.

After the reboot, re-run:
  bash <(curl -sSL https://raw.githubusercontent.com/felipefontoura/bento/stable/boot.sh)

bento will pick up where it left off.
EOF
        )"
        if ui_confirm "Reboot now?"; then
            sudo reboot
        fi
    fi
}

# -----------------------------------------------------------------------------
# Step 2 — Infra (Traefik + Portainer)
# -----------------------------------------------------------------------------
step2_status() {
    if infra_is_done; then echo "done"
    elif [[ "$(state_get '.steps.hardening')" != "done" ]]; then echo locked
    else echo pending
    fi
}

step2_run() {
    if [[ "$(step2_status)" == "locked" ]]; then
        ui_warn "Run Step 1 first."
        return 0
    fi
    # Step 2 is already 'done' in state — skip by default. Re-running
    # silently re-prompts DNS, kicks a rolling-update on Traefik +
    # Portainer (brief downtime), and prints 'admin already initialized'
    # instead of the credentials box the operator was probably hoping
    # for. Offer the re-run explicitly so it stays available for the
    # legitimate case (compose file edited locally, image bumped).
    if infra_is_done; then
        ui_info "Step 2 is already complete (Traefik + Portainer deployed)."
        ui_format_md <<EOF
**Re-running** will:
- re-prompt the DNS confirmation
- redeploy \`stacks/infra/{traefik,portainer}/compose.yml\` via Swarm rolling-update (brief Portainer downtime)
- skip the Portainer admin init (credentials are persisted at \`${BENTO_PORTAINER_CREDS}\`)

**For Portainer credentials**, run "Report" from the main menu instead —
it prints the same box without touching the deploy.
EOF
        if ! ui_confirm "Re-run Step 2 anyway?"; then
            return 0
        fi
    fi
    infra_run_step2
}

# -----------------------------------------------------------------------------
# Step 3 — Apps
# -----------------------------------------------------------------------------
step3_status() {
    if stacks_is_apps_done; then echo "done"
    elif ! infra_is_done; then echo locked
    else echo pending
    fi
}

step3_run() {
    if [[ "$(step3_status)" == "locked" ]]; then
        ui_warn "Run Step 2 first."
        return 0
    fi
    local rc=0
    stacks_step3_menu || rc=$?
    case "$rc" in
        0)
            # Offer AI-provider auth right after a successful Step 3 — most
            # operators land here ready to wire their LLM keys, and the
            # paperclip container is guaranteed up at this point. Skipped
            # under unattended (no interactive stdin) and skipped silently
            # when paperclip was not in the deploy set (the prompt would
            # just confuse those operators).
            if [[ "${BENTO_UNATTENDED:-0}" != "1" ]] \
               && [[ -x "${BENTO_REPO_ROOT}/scripts/bento-auth" ]] \
               && sudo docker service inspect paperclip_paperclip >/dev/null 2>&1
            then
                if ui_confirm "Authenticate AI providers now?"; then
                    auth_run
                fi
            fi
            report_run "auto"
            ;;
        1) ui_warn "Re-run Step 3 to retry the failed stacks." ;; # at least one failure
        2) : ;;                                                  # cancelled / nothing to do
    esac
}

# -----------------------------------------------------------------------------
# Settings + Status + Update — minimal stubs for Phase 1
# -----------------------------------------------------------------------------
settings_run() {
    local choice
    choice="$(ui_choose \
        "Edit base domain" \
        "Edit admin email" \
        "Show state file path" \
        "Back")"
    case "$choice" in
        "Edit base domain")
            local d
            d="$(ui_input "Base domain" "$(state_get '.bootstrap.base_domain')")"
            state_set '.bootstrap.base_domain' "$d"
            ;;
        "Edit admin email")
            local e
            e="$(ui_input "Admin email" "$(state_get '.bootstrap.admin_email')")"
            state_set '.bootstrap.admin_email' "$e"
            ;;
        "Show state file path")
            ui_info "$BENTO_STATE_FILE"
            ui_pause
            ;;
    esac
}

status_run() {
    ui_section "Installed services"
    local stacks_json
    if stacks_json="$(portainer_list_stacks 2>/dev/null)"; then
        local rows
        rows=$(jq -r '.[] | select(.Env[]?.name == "BENTO_MANAGED" and .Env[].value == "true") | "\(.Name)\t\(.Status)"' <<< "$stacks_json")
        if [[ -n "$rows" ]]; then
            printf '%s\n' "$rows" | gum table --columns "Name,Status" --separator $'\t' || printf '%s\n' "$rows"
        else
            ui_subtle "No bento-managed stacks yet."
        fi
    else
        ui_warn "Portainer not reachable."
    fi
    ui_pause
}

report_run() {
    local trigger="${1:-manual}"
    ui_section "Handoff report"
    if [[ "$trigger" == "auto" ]]; then
        ui_info "Generating a handoff HTML for $(state_get '.bootstrap.base_domain')…"
    fi
    local path
    path=$(report_generate) || {
        ui_error "Failed to generate the report."
        return 1
    }
    ui_boxed_success "$(cat <<EOF
Report saved to:
  $path

Copy it to your machine with, for example:
  scp $(whoami)@$(state_get '.bootstrap.advertise_addr'):$path .

Open it in any browser. Sensitive values are masked by default; click
"show" to reveal individual entries. Print to PDF for offline delivery.
EOF
    )"

    # Hold the screen until the operator acknowledges. Without this,
    # 'auto' callers (step3_run after a successful Step 3) drop back
    # to main_menu, which immediately redraws and wipes the path the
    # operator needs for the `scp` command above. Unattended runs
    # skip the pause — no human in the loop, and the handoff HTML
    # path is already in the resume log.
    if [[ "${BENTO_UNATTENDED:-0}" != "1" ]]; then
        ui_pause
    fi
}

# -----------------------------------------------------------------------------
# Authenticate AI providers
# -----------------------------------------------------------------------------
# Thin gum-styled wrapper around scripts/bento-auth so the operator never
# has to remember the path. The script itself works fine from a bare
# shell — this menu just makes it discoverable from the main bento flow.
#
# Skipped under BENTO_UNATTENDED: device-flow OAuth is, by design, an
# interactive step (the user has to paste a code from their browser).
# We still print a hint so unattended runs surface the suggestion in
# their resume log.
auth_run() {
    if [[ "${BENTO_UNATTENDED:-0}" == "1" ]]; then
        ui_info "Skipping AI provider auth — run 'bento-auth' on the host post-install."
        return 0
    fi
    local script="${BENTO_REPO_ROOT}/scripts/bento-auth"
    if [[ ! -x "$script" ]]; then
        ui_error "bento-auth script not found at ${script}. Run 'Update' first."
        ui_pause
        return 1
    fi
    ui_section "Authenticate AI providers"
    local choice
    choice="$(ui_choose \
        "Claude  (Anthropic, Pro/Max)" \
        "OpenAI Codex  (ChatGPT Plus)" \
        "List authenticated providers" \
        "Back")"
    case "$choice" in
        "Claude"*)        "$script" claude ;;
        "OpenAI Codex"*)  "$script" openai-codex ;;
        "List"*)          "$script" list ;;
        "Back"|*)         return 0 ;;
    esac
    ui_pause
}

update_run() {
    ui_section "Updates"
    local choice
    choice="$(ui_choose \
        "Update bento (pull latest from git)" \
        "Re-deploy stacks from latest git ref" \
        "Back")"
    case "$choice" in
        "Update bento (pull latest from git)")
            local ref="${BENTO_REF:-stable}"
            # Fetch first so origin/<ref> is current. Then prove the ref
            # actually exists on the remote before doing a hard reset —
            # the previous form silently no-op'd when the branch was
            # missing (forked repos without 'stable'), so operators
            # thought they were updated when they weren't.
            if ! (cd "$BENTO_REPO_ROOT" && git fetch --quiet origin); then
                ui_error "git fetch failed — check network / remote access."
                return 1
            fi
            if ! (cd "$BENTO_REPO_ROOT" && git rev-parse --verify --quiet "origin/${ref}" >/dev/null); then
                ui_error "Branch 'origin/${ref}' does not exist on the remote."
                ui_warn  "Set BENTO_REF to a valid branch (e.g. 'main' or 'stable')."
                return 1
            fi
            (cd "$BENTO_REPO_ROOT" && git reset --hard "origin/${ref}") || {
                ui_error "git reset --hard failed."
                return 1
            }
            ui_success "Bento updated to origin/${ref}. Reloading menu…"
            # Re-exec the freshly-pulled install.sh in-place so the
            # operator stays in the menu without retyping anything. The
            # current bash process is replaced entirely; every sourced
            # lib/* is re-read from the new git ref. `$0` would be
            # unreliable here (could be boot.sh or a path with `bash -c`
            # in front) — go through the canonical repo path.
            exec bash "${BENTO_REPO_ROOT}/install.sh"
            ;;
        "Re-deploy stacks from latest git ref")
            update_redeploy_stacks
            ;;
    esac
}

# Lets the user pick bento-managed stacks to redeploy from the latest
# commit on the branch Portainer is tracking. Each call is a single
# Portainer API request — Portainer pulls the new commit, re-renders
# the compose, and applies a rolling update honouring the stack's
# update_config.
update_redeploy_stacks() {
    # Same staleness trap as Step 3 — operators who deleted stacks via
    # Portainer would otherwise see the orphans listed here and pick a
    # redeploy that targets a non-existent stack id. Reconcile first.
    stacks_reconcile_state_with_portainer

    local stacks_json
    if ! stacks_json="$(portainer_list_stacks 2>/dev/null)"; then
        ui_error "Portainer not reachable — cannot list stacks."
        ui_pause
        return 1
    fi

    # Bento-managed only — we never touch stacks the user created
    # directly in Portainer.
    local managed
    managed=$(jq -r '
        [ .[] | select(any(.Env[]?; .name == "BENTO_MANAGED" and .value == "true")) | "\(.Id)\t\(.Name)" ]
        | .[]
    ' <<< "$stacks_json")

    if [[ -z "$managed" ]]; then
        ui_subtle "No bento-managed stacks deployed yet."
        ui_pause
        return 0
    fi

    local labels=()
    while IFS=$'\t' read -r _id name; do
        labels+=("$name")
    done <<< "$managed"

    local picks
    picks="$(printf '%s\n' "${labels[@]}" | ui_choose_multi)"
    [[ -z "$picks" ]] && return 0

    local failures=()
    while IFS= read -r pick; do
        local stack_id
        stack_id=$(jq -r --arg n "$pick" '.[] | select(.Name == $n) | .Id' <<< "$stacks_json" | head -1)
        if [[ -z "$stack_id" ]]; then
            ui_warn "Could not resolve stack id for '$pick' — skipping."
            failures+=("$pick")
            continue
        fi
        ui_info "Redeploying $pick (Portainer stack #$stack_id)…"
        if portainer_redeploy_stack "$stack_id"; then
            ui_success "$pick redeployed."
        else
            ui_error "Redeploy of $pick failed."
            failures+=("$pick")
        fi
    done <<< "$picks"

    if (( ${#failures[@]} > 0 )); then
        ui_warn "Some redeploys failed: ${failures[*]}"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Menu loop
# -----------------------------------------------------------------------------
render_menu_line() {
    local label="$1" status="$2"
    local icon color
    icon=$(ui_status_icon "$status")
    color=$(ui_status_color "$status")
    gum style --foreground="$color" "  $icon  $label"
}

main_menu() {
    while true; do
        banner_render

        render_menu_line "Step 1 — Harden the system"      "$(step1_status)"
        render_menu_line "Step 2 — Install infrastructure" "$(step2_status)"
        render_menu_line "Step 3 — Install applications"   "$(step3_status)"
        ui_divider

        # Pre-select the next actionable step so a single enter advances
        # the operator through the flow without arrow keys. Once Step 1
        # and Step 2 are both done, stay on Step 3 indefinitely — the most
        # common reason to re-open the menu after a successful install is
        # to add more applications, which Step 3 covers (it's a per-app
        # checklist, re-runnable without ever 'completing' in a final sense).
        local next_step
        if [[ "$(step1_status)" != "done" ]]; then
            next_step="Step 1 — Harden the system"
        elif [[ "$(step2_status)" != "done" ]]; then
            next_step="Step 2 — Install infrastructure"
        else
            next_step="Step 3 — Install applications"
        fi

        local choice
        choice="$(ui_choose --selected="$next_step" \
            "Step 1 — Harden the system" \
            "Step 2 — Install infrastructure" \
            "Step 3 — Install applications" \
            "Authenticate AI providers" \
            "Settings" \
            "Status" \
            "Report — handoff HTML" \
            "Update" \
            "Exit")"

        case "$choice" in
            "Step 1"*)              step1_run ;;
            "Step 2"*)              step2_run ;;
            "Step 3"*)              step3_run ;;
            "Authenticate AI"*)     auth_run ;;
            "Settings")             settings_run ;;
            "Status")               status_run ;;
            "Report"*)              report_run "manual" ;;
            "Update")               update_run ;;
            "Exit")                 exit 0 ;;
        esac
    done
}

# -----------------------------------------------------------------------------
# Unattended end-to-end flow
# -----------------------------------------------------------------------------
unattended_main() {
    ui_info "Unattended mode — Step 1 → Step 2 → Step 3 in sequence"

    if [[ "$(step1_status)" != "done" ]]; then
        step1_run || { ui_error "Step 1 failed"; exit 1; }
    fi

    if ! infra_is_done; then
        step2_run || { ui_error "Step 2 failed"; exit 1; }
    fi

    local step3_rc=0
    if [[ -n "${BENTO_APPS:-}" ]]; then
        unattended_step3 || step3_rc=$?
    else
        ui_warn "BENTO_APPS not set — skipping Step 3"
    fi

    report_run "auto"
    if (( step3_rc != 0 )); then
        ui_error "Unattended install finished with failures — see report and /var/log/bento-resume.log"
        exit 2
    fi
    ui_success "Unattended install complete"
}

# Depth-first deploy. <seen_arr> and <failed_arr> are nameref array
# names so the recursion can accumulate state without globals. Lifted
# out of unattended_step3 so it shows up in `grep` and `declare -f`.
_deploy_with_deps() {
    local -n _seen=$1
    local -n _failed=$2
    local key="$3"

    local s
    for s in "${_seen[@]}"; do
        [[ "$s" == "$key" ]] && return 0
    done

    local manifest_path
    manifest_path=$(stacks_manifest_for_key "$key")
    if [[ -z "$manifest_path" ]]; then
        ui_warn "Unknown stack key: $key — skipping"
        _failed+=("$key (unknown)")
        return 0
    fi

    local dep
    while IFS= read -r dep; do
        [[ -z "$dep" ]] && continue
        _deploy_with_deps "$1" "$2" "$dep"
    done < <(jq -r '.depends_on[]?' "$manifest_path")

    # The section header lives inside stacks_deploy. Printing it here
    # too was the source of the doubled 'Deploying X' lines.
    if stacks_deploy "$manifest_path"; then
        _seen+=("$key")
    else
        ui_error "Deploy of $key failed; continuing"
        _failed+=("$key")
    fi
}

unattended_step3() {
    local apps_csv="${BENTO_APPS}"
    stacks_memory_budget_check "$apps_csv"
    IFS=',' read -ra apps <<< "$apps_csv"

    # Same reconcile as the interactive path — unattended re-runs after
    # the operator has done Portainer-side cleanup would otherwise hit
    # the same orphan trap and silently skip deploys.
    stacks_reconcile_state_with_portainer

    # Pre-populate "seen" with stacks bento has already successfully
    # deployed (state.stacks.<key>.stack_id present), so re-running with
    # a wider BENTO_APPS list only deploys the new ones.
    local seen=()
    local failed=()
    while IFS= read -r _existing; do
        [[ -n "$_existing" ]] && seen+=("$_existing")
    done < <(jq -r '.stacks // {} | to_entries[] | select(.value.stack_id) | .key' \
        "$BENTO_STATE_FILE" 2>/dev/null)

    local app
    for app in "${apps[@]}"; do
        app="${app// /}"
        [[ -z "$app" ]] && continue
        _deploy_with_deps seen failed "$app"
    done

    # Surface failures upstream so unattended_main can fail loudly and
    # the handoff report carries the news.
    if (( ${#failed[@]} > 0 )); then
        printf '%s\n' "${failed[@]}" > "${BENTO_STATE_DIR}/last-run-failures"
        ui_error "Some stacks failed to deploy: ${failed[*]}"
        return 1
    fi
    rm -f "${BENTO_STATE_DIR}/last-run-failures"
    state_set '.steps.apps' "done"
    return 0
}

# Installs a systemd one-shot that re-runs install.sh in unattended mode
# after the post-hardening reboot. Picks up the same env vars from a file
# so the resume happens identically.
unattended_install_resume_hook() {
    local env_file=/var/lib/bento/unattended.env
    sudo mkdir -p /var/lib/bento
    sudo tee "$env_file" > /dev/null <<EOF
BENTO_UNATTENDED=1
BENTO_BASE_DOMAIN=$(state_get '.bootstrap.base_domain')
BENTO_ADMIN_EMAIL=$(state_get '.bootstrap.admin_email')
BENTO_ADVERTISE_ADDR=$(state_get '.bootstrap.advertise_addr')
BENTO_APPS=${BENTO_APPS:-}
HOME=${HOME}
TERM=xterm-256color
EOF
    sudo chmod 600 "$env_file"

    sudo tee /etc/systemd/system/bento-resume.service > /dev/null <<EOF
[Unit]
Description=Bento — resume install after hardening reboot
After=network-online.target docker.service
Wants=network-online.target docker.service

[Service]
Type=oneshot
EnvironmentFile=/var/lib/bento/unattended.env
WorkingDirectory=${BENTO_REPO_ROOT}
ExecStart=/bin/bash ${BENTO_REPO_ROOT}/install.sh
ExecStartPost=-/bin/rm -f /var/lib/bento/reboot-required
ExecStartPost=-/bin/systemctl disable bento-resume.service
StandardOutput=append:/var/log/bento-resume.log
StandardError=append:/var/log/bento-resume.log

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable bento-resume.service
}

# -----------------------------------------------------------------------------
# Entry
# -----------------------------------------------------------------------------
if [[ "$BENTO_UNATTENDED" != "1" ]]; then
    banner_render
fi
bootstrap_prompt_once

if [[ "$BENTO_UNATTENDED" == "1" ]]; then
    unattended_main
    exit 0
fi

main_menu
