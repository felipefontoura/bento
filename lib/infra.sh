#!/bin/bash
# bento — infra (Swarm + network + Traefik + Portainer)
#
# Step 1 tail: swarm + network (right after Docker is installed).
# Step 2: Deploy Traefik + Portainer, init Portainer admin.

# shellcheck source=lib/ui.sh
source "$(dirname "${BASH_SOURCE[0]}")/ui.sh"
# shellcheck source=lib/state.sh
source "$(dirname "${BASH_SOURCE[0]}")/state.sh"
# shellcheck source=lib/portainer.sh
source "$(dirname "${BASH_SOURCE[0]}")/portainer.sh"

readonly BENTO_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly BENTO_INFRA_STACK_NAME="infra"

# -----------------------------------------------------------------------------
# Docker foundation (called as tail of Step 1).
# -----------------------------------------------------------------------------
infra_is_swarm_active() {
    docker info 2>/dev/null | grep -q "Swarm: active"
}

infra_ensure_swarm() {
    local advertise_addr
    advertise_addr="$(state_get '.bootstrap.advertise_addr')"

    if infra_is_swarm_active; then
        ui_info "Docker Swarm already active."
        state_set '.foundation.swarm' "active"
        return 0
    fi

    if [[ -z "$advertise_addr" ]]; then
        ui_error "advertise_addr missing from state — re-run bootstrap."
        return 1
    fi

    ui_spin "Initializing Docker Swarm…" \
        sudo docker swarm init --advertise-addr="$advertise_addr"

    state_set '.foundation.swarm' "active"
    ui_success "Swarm active (advertising $advertise_addr)."
}

infra_ensure_network() {
    if sudo docker network inspect network_public >/dev/null 2>&1; then
        ui_info "Network 'network_public' already exists."
        state_set '.foundation.network_public' "ready"
        return 0
    fi

    ui_spin "Creating overlay network 'network_public'…" \
        sudo docker network create --driver=overlay --attachable network_public
    state_set '.foundation.network_public' "ready"
    ui_success "Overlay network ready."
}

# -----------------------------------------------------------------------------
# Step 2 — deploy Traefik + Portainer.
# -----------------------------------------------------------------------------
infra_deploy_stack_file() {
    # Substitute env vars in a YAML and pipe to docker stack deploy as a single
    # multi-service stack named 'infra'.
    local yml="$1"
    local stack_name="$2"
    envsubst < "$yml" | sudo docker stack deploy \
        --with-registry-auth \
        --resolve-image always \
        -c - "$stack_name"
}

infra_deploy_traefik_and_portainer() {
    # Export everything envsubst needs.
    export TRAEFIK_ACME_EMAIL
    export PORTAINER_HOST
    TRAEFIK_ACME_EMAIL="$(state_get '.bootstrap.admin_email')"
    PORTAINER_HOST="portainer.$(state_get '.bootstrap.base_domain')"

    state_set '.bootstrap.portainer_host' "$PORTAINER_HOST"
    state_set '.bootstrap.portainer_url' "http://127.0.0.1:9000"

    ui_section "Deploying Traefik"
    infra_deploy_stack_file \
        "${BENTO_REPO_ROOT}/stacks/infra/traefik/compose.yml" \
        "$BENTO_INFRA_STACK_NAME"

    ui_section "Deploying Portainer"
    infra_deploy_stack_file \
        "${BENTO_REPO_ROOT}/stacks/infra/portainer/compose.yml" \
        "$BENTO_INFRA_STACK_NAME"
}

# Wait for Portainer to be reachable, then initialize the admin user.
infra_init_portainer_admin() {
    ui_spin "Waiting for Portainer to come up…" \
        bash -c 'source "$1" && portainer_wait_ready "" 240' _ \
            "${BENTO_REPO_ROOT}/lib/portainer.sh"

    if ! portainer_wait_ready "" 30; then
        ui_error "Portainer did not become ready in time."
        return 1
    fi

    if [[ -f "${BENTO_STATE_DIR}/portainer.json" ]]; then
        ui_info "Portainer admin already initialized."
        return 0
    fi

    local password
    password=$(openssl rand -base64 24 | tr -d '\n=' | head -c 32)
    if ! portainer_init_admin "admin" "$password"; then
        ui_error "Portainer admin init failed."
        return 1
    fi

    state_set '.bootstrap.portainer_admin_user' "admin"
    state_set '.foundation.portainer' "ready"

    local public_url
    public_url="https://$(state_get '.bootstrap.portainer_host')"

    ui_boxed_success "$(cat <<EOF
Portainer is ready.

  URL:       $public_url
  Username:  admin
  Password:  $password

This password is shown only once. Store it now.
EOF
    )"
}

infra_run_step1_tail() {
    infra_ensure_swarm || return 1
    infra_ensure_network || return 1
    ui_success "Docker foundation ready (Swarm + network_public)."
}

infra_run_step2() {
    infra_ensure_dns || return 1
    infra_deploy_traefik_and_portainer || return 1
    infra_init_portainer_admin || return 1
    state_set '.steps.infra' "done"
    ui_success "Step 2 complete — infra is up."
}

# Ensures wildcard + root A records exist before Traefik tries to obtain
# Let's Encrypt certs. If Cloudflare is configured we sync via API;
# otherwise we print manual instructions and require explicit confirmation.
infra_ensure_dns() {
    local base advertise
    base="$(state_get '.bootstrap.base_domain')"
    advertise="$(state_get '.bootstrap.advertise_addr')"

    if state_has '.bootstrap.cloudflare_api_token'; then
        ui_section "Cloudflare — syncing DNS records"
        if ui_spin "Creating *.${base} and ${base} → ${advertise}…" bash -c \
            'source "$1" && source "$2" && cloudflare_sync_required_records' _ \
            "${BENTO_REPO_ROOT}/lib/state.sh" \
            "${BENTO_REPO_ROOT}/lib/cloudflare.sh"; then
            ui_success "Cloudflare DNS in sync."
            return 0
        fi
        ui_error "Cloudflare sync failed. Falling back to manual check."
    fi

    ui_section "DNS check"
    ui_format_md <<EOF
Step 2 will request HTTPS certificates from Let's Encrypt. For that to
work, these records must already resolve to **${advertise}**:

- \`*.${base}\` (wildcard A record)
- \`${base}\` (root A record)

If you're using Cloudflare, you can re-run bootstrap from **Settings** to
provide an API token and let bento manage these automatically.

Otherwise create both records manually now and verify with:
\`\`\`
dig +short A portainer.${base}
\`\`\`
EOF
    if ! ui_confirm "DNS records are in place and resolving?"; then
        ui_warn "Aborting Step 2. Re-run after DNS is ready."
        return 1
    fi
}

infra_is_done() {
    [[ "$(state_get '.steps.infra')" == "done" ]]
}
