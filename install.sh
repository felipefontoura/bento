#!/bin/bash
# bento — main interactive menu
#
# Sourced by boot.sh. Can also be run standalone after cloning.

set -uo pipefail

BENTO_REPO_ROOT="${BENTO_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
export BENTO_REPO_ROOT

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
DOMAIN_REGEX='^([a-z0-9]+(-[a-z0-9]+)*\.)+[a-z]{2,}$'
EMAIL_REGEX='^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'
IP_REGEX='^([0-9]{1,3}\.){3}[0-9]{1,3}$'

bootstrap_from_env() {
    local d="${BENTO_BASE_DOMAIN:-}"
    local e="${BENTO_ADMIN_EMAIL:-}"
    local a="${BENTO_ADVERTISE_ADDR:-}"

    # Optional: when set, Traefik uses Cloudflare DNS-01 instead of HTTP-01.
    # Lets users keep the Cloudflare orange-cloud proxy on, and works on
    # VPS where port 80 is closed by a cloud firewall.
    if [[ -n "${BENTO_CF_DNS_API_TOKEN:-}" ]]; then
        export CF_DNS_API_TOKEN="$BENTO_CF_DNS_API_TOKEN"
    fi

    if [[ -z "$d" ]]; then
        ui_error "BENTO_UNATTENDED requires BENTO_BASE_DOMAIN"
        exit 1
    fi
    if [[ -z "$e" ]]; then
        e="admin@${d}"
    fi
    if [[ -z "$a" ]]; then
        a=$(curl -fsSL --max-time 5 https://ifconfig.me 2>/dev/null || true)
    fi
    if [[ -z "$a" ]]; then
        ui_error "Could not detect ADVERTISE_ADDR — set BENTO_ADVERTISE_ADDR"
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

    local base_domain admin_email advertise_addr detected
    base_domain=$(ui_input_validated \
        "Base domain (e.g. mydomain.com)" "mydomain.com" \
        "$DOMAIN_REGEX" "That doesn't look like a domain. Try again.")

    admin_email=$(ui_input_validated \
        "Admin email (Let's Encrypt + alerts)" "admin@${base_domain}" \
        "$EMAIL_REGEX" "That doesn't look like an email. Try again.")

    detected="$(curl -fsSL --max-time 5 https://ifconfig.me 2>/dev/null || true)"
    advertise_addr=$(ui_input_validated \
        "VPS public IP" "$detected" \
        "$IP_REGEX" "That doesn't look like an IPv4 address. Try again.")

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
    if [[ "$(state_get '.steps.hardening')" == "done" ]]; then echo done
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
- Create a \`docker\` user, copy your SSH keys
- Enable firewall (ssh/http/https)
- Initialize Docker Swarm + create overlay network \`network_public\`

This takes ~5-10 minutes and will require a reboot afterward.
EOF
        ui_confirm "Proceed?" || return 0
    fi

    local log_file
    log_file="${BENTO_LOG_DIR}/hardening-$(date +%Y%m%d-%H%M%S).log"
    ui_info "Streaming output to $log_file"

    if sudo NEEDRESTART_MODE=a DEBIAN_FRONTEND=noninteractive \
            bash "${BENTO_REPO_ROOT}/lib/hardening.sh" 2>&1 | tee "$log_file"; then
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
    if infra_is_done; then echo done
    elif [[ "$(state_get '.steps.hardening')" != "done" ]]; then echo locked
    else echo pending
    fi
}

step2_run() {
    if [[ "$(step2_status)" == "locked" ]]; then
        ui_warn "Run Step 1 first."
        return 0
    fi
    infra_run_step2
}

# -----------------------------------------------------------------------------
# Step 3 — Apps
# -----------------------------------------------------------------------------
step3_status() {
    if stacks_is_apps_done; then echo done
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
    if stacks_is_apps_done; then
        report_run "auto"
    elif (( rc != 0 )); then
        ui_warn "Re-run Step 3 to retry the failed stacks."
    fi
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
            ui_info "$(state_path)"
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
            (cd "$BENTO_REPO_ROOT" && git fetch --quiet origin && git reset --hard "origin/${BENTO_REF:-stable}")
            ui_success "Bento updated. Restart the menu to load fresh code."
            exit 0
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

        local choice
        choice="$(ui_choose \
            "Step 1 — Harden the system" \
            "Step 2 — Install infrastructure" \
            "Step 3 — Install applications" \
            "Settings" \
            "Status" \
            "Report — handoff HTML" \
            "Update" \
            "Exit")"

        case "$choice" in
            "Step 1"*) step1_run ;;
            "Step 2"*) step2_run ;;
            "Step 3"*) step3_run ;;
            "Settings") settings_run ;;
            "Status")   status_run ;;
            "Report"*)  report_run "manual" ;;
            "Update")   update_run ;;
            "Exit")     exit 0 ;;
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

unattended_step3() {
    local apps_csv="${BENTO_APPS}"
    stacks_memory_budget_check "$apps_csv"
    IFS=',' read -ra apps <<< "$apps_csv"

    # Pre-populate "seen" with stacks bento has already successfully
    # deployed (state.stacks.<key>.stack_id present), so re-running with
    # a wider BENTO_APPS list only deploys the new ones.
    local seen=()
    local failed=()
    while IFS= read -r _existing; do
        [[ -n "$_existing" ]] && seen+=("$_existing")
    done < <(jq -r '.stacks // {} | to_entries[] | select(.value.stack_id) | .key' \
        "$BENTO_STATE_FILE" 2>/dev/null)
    deploy_with_deps() {
        local key="$1"
        # Skip if already in seen
        local s
        for s in "${seen[@]}"; do
            [[ "$s" == "$key" ]] && return 0
        done
        local manifest_path
        manifest_path=$(stacks_manifest_for_key "$key")
        if [[ -z "$manifest_path" ]]; then
            ui_warn "Unknown stack key: $key — skipping"
            failed+=("$key (unknown)")
            return 0
        fi
        # Resolve declared deps first
        local dep
        while IFS= read -r dep; do
            [[ -z "$dep" ]] && continue
            deploy_with_deps "$dep"
        done < <(jq -r '.depends_on[]?' "$manifest_path")
        ui_section "Deploying $key"
        if stacks_deploy "$manifest_path"; then
            seen+=("$key")
        else
            ui_error "Deploy of $key failed; continuing"
            failed+=("$key")
        fi
    }

    local app
    for app in "${apps[@]}"; do
        app="${app// /}"
        [[ -z "$app" ]] && continue
        deploy_with_deps "$app"
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
