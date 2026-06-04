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
# shellcheck source=lib/cloudflare.sh
source "${BENTO_REPO_ROOT}/lib/cloudflare.sh"
# shellcheck source=lib/infra.sh
source "${BENTO_REPO_ROOT}/lib/infra.sh"
# shellcheck source=lib/stacks.sh
source "${BENTO_REPO_ROOT}/lib/stacks.sh"

state_init

# -----------------------------------------------------------------------------
# Bootstrap inicial (single prompt screen with BASE_DOMAIN + ADMIN_EMAIL + IP)
# -----------------------------------------------------------------------------
DOMAIN_REGEX='^([a-z0-9]+(-[a-z0-9]+)*\.)+[a-z]{2,}$'
EMAIL_REGEX='^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'
IP_REGEX='^([0-9]{1,3}\.){3}[0-9]{1,3}$'

bootstrap_prompt_once() {
    if state_has '.bootstrap.base_domain' \
       && state_has '.bootstrap.admin_email' \
       && state_has '.bootstrap.advertise_addr'; then
        return 0
    fi

    ui_section "First-time setup"
    ui_subtle "These values seed every stack you'll deploy. They're written to ~/.config/bento/state.json."

    local base_domain admin_email advertise_addr detected
    while true; do
        base_domain="$(ui_input "Base domain (e.g. mydomain.com)" "mydomain.com")"
        if [[ "$base_domain" =~ $DOMAIN_REGEX ]]; then
            break
        fi
        ui_warn "That doesn't look like a domain. Try again."
    done

    while true; do
        admin_email="$(ui_input "Admin email (Let's Encrypt + alerts)" "admin@${base_domain}")"
        if [[ "$admin_email" =~ $EMAIL_REGEX ]]; then
            break
        fi
        ui_warn "That doesn't look like an email. Try again."
    done

    detected="$(curl -fsSL --max-time 5 https://ifconfig.me 2>/dev/null || true)"
    while true; do
        advertise_addr="$(ui_input "VPS public IP" "$detected" "$detected")"
        if [[ "$advertise_addr" =~ $IP_REGEX ]]; then
            break
        fi
        ui_warn "That doesn't look like an IPv4 address. Try again."
    done

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

    bootstrap_prompt_cloudflare
}

# Optional Cloudflare DNS integration. Skippable. If the user provides a
# token with Zone:DNS:Edit on $BASE_DOMAIN, bento will keep the wildcard +
# root A records in sync automatically. Otherwise we print manual steps in
# Step 2.
bootstrap_prompt_cloudflare() {
    if state_has '.bootstrap.cloudflare_api_token' \
       || state_has '.bootstrap.cloudflare_skipped'; then
        return 0
    fi

    ui_section "Cloudflare DNS (optional)"
    ui_format_md <<EOF
If your domain is on Cloudflare, bento can auto-create the wildcard + root
**A** records that Traefik needs for Let's Encrypt — no DNS clicking
required.

**One-click token creation** (open on the machine where you're logged into
Cloudflare):

<${BENTO_CF_TOKEN_TEMPLATE_URL}>

That link drops you directly on Cloudflare's token review screen with
**DNS → Edit** permission already selected. Just:

1. (Optional) narrow **Zone Resources** to your domain only.
2. Click **Continue to summary**, then **Create Token**.
3. Copy the token Cloudflare displays once and paste it below.

Otherwise you'll create the DNS records by hand before Step 2.
EOF

    if ! ui_confirm "Configure Cloudflare DNS automatically?"; then
        state_set '.bootstrap.cloudflare_skipped' "true"
        return 0
    fi

    local token
    token="$(ui_password "Cloudflare API token (Zone:DNS:Edit)")"
    if [[ -z "$token" ]]; then
        ui_warn "Empty token — skipping Cloudflare integration."
        state_set '.bootstrap.cloudflare_skipped' "true"
        return 0
    fi

    state_set '.bootstrap.cloudflare_api_token' "$token"
    chmod 600 "$(state_path)"

    if ui_spin "Verifying Cloudflare token…" bash -c \
        'source "$1" && source "$2" && cloudflare_verify_token' _ \
        "${BENTO_REPO_ROOT}/lib/state.sh" \
        "${BENTO_REPO_ROOT}/lib/cloudflare.sh"; then
        ui_success "Cloudflare token verified."
    else
        ui_error "Token verification failed. Token cleared; you can re-run bootstrap via Settings."
        state_set '.bootstrap.cloudflare_api_token' ""
        state_set '.bootstrap.cloudflare_skipped' "true"
    fi
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

    local log_file
    log_file="${BENTO_LOG_DIR}/hardening-$(date +%Y%m%d-%H%M%S).log"
    ui_info "Streaming output to $log_file"

    if sudo bash "${BENTO_REPO_ROOT}/lib/hardening.sh" 2>&1 | tee "$log_file"; then
        state_set '.steps.hardening' "done"
    else
        state_set '.steps.hardening' "failed"
        ui_error "Hardening failed — see $log_file"
        return 1
    fi

    # Foundation tail: swarm + network.
    infra_run_step1_tail || return 1

    if [[ -f /var/lib/bento/reboot-required ]]; then
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
    stacks_step3_menu
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
            ui_warn "Stack redeploy via API arrives in Phase 2 — for now, redeploy via the Portainer UI."
            ui_pause
            ;;
    esac
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
            "Update" \
            "Exit")"

        case "$choice" in
            "Step 1"*) step1_run ;;
            "Step 2"*) step2_run ;;
            "Step 3"*) step3_run ;;
            "Settings") settings_run ;;
            "Status")   status_run ;;
            "Update")   update_run ;;
            "Exit")     exit 0 ;;
        esac
    done
}

# -----------------------------------------------------------------------------
# Entry
# -----------------------------------------------------------------------------
banner_render
bootstrap_prompt_once
main_menu
