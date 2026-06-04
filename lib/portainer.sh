#!/bin/bash
# bento — Portainer REST API wrappers
#
# Every call here is logged when BENTO_VERBOSE=1.
# Auth state (credentials + JWT) lives in ~/.config/bento/portainer.json.

[[ -n "${_BENTO_PORTAINER_LOADED:-}" ]] && return 0
_BENTO_PORTAINER_LOADED=1

# shellcheck source=lib/state.sh
source "$(dirname "${BASH_SOURCE[0]}")/state.sh"

readonly BENTO_PORTAINER_CREDS="${BENTO_STATE_DIR}/portainer.json"

portainer_base_url() {
    state_get '.bootstrap.portainer_url' "http://127.0.0.1:9000"
}

# Curl wrapper — adds verbose logging when BENTO_VERBOSE=1.
portainer_curl() {
    if [[ "${BENTO_VERBOSE:-0}" == "1" ]]; then
        printf '→ curl %s\n' "$*" >&2
    fi
    curl --silent --show-error "$@"
}

# Poll /api/system/status until Portainer responds (or timeout).
portainer_wait_ready() {
    local base="${1:-$(portainer_base_url)}"
    local max_seconds="${2:-180}"
    local elapsed=0

    while (( elapsed < max_seconds )); do
        if portainer_curl -fsS "${base}/api/system/status" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    return 1
}

# Initialize the very first admin. Body: { Username, Password }.
# Returns 0 on success (admin created or already exists).
portainer_init_admin() {
    local username="$1"
    local password="$2"
    local base
    base="$(portainer_base_url)"

    local body http_code
    body=$(jq -n --arg u "$username" --arg p "$password" \
        '{Username: $u, Password: $p}')

    http_code=$(portainer_curl -o /tmp/bento-portainer-init.json -w '%{http_code}' \
        -X POST "${base}/api/users/admin/init" \
        -H 'Content-Type: application/json' \
        -d "$body")

    case "$http_code" in
        200|204)
            portainer_persist_creds "$username" "$password"
            return 0 ;;
        409)
            # Admin already exists — that's fine if we already have creds.
            [[ -f "$BENTO_PORTAINER_CREDS" ]]
            return $? ;;
        *)
            echo "Portainer admin init failed (HTTP $http_code):" >&2
            cat /tmp/bento-portainer-init.json >&2 || true
            return 1 ;;
    esac
}

portainer_persist_creds() {
    local username="$1"
    local password="$2"
    jq -n --arg u "$username" --arg p "$password" \
        '{username: $u, password: $p}' > "$BENTO_PORTAINER_CREDS"
    chmod 600 "$BENTO_PORTAINER_CREDS"
}

# POST /api/auth — returns a fresh JWT.
portainer_login() {
    local base body http_code username password
    base="$(portainer_base_url)"
    username=$(jq -r '.username' "$BENTO_PORTAINER_CREDS")
    password=$(jq -r '.password' "$BENTO_PORTAINER_CREDS")

    body=$(jq -n --arg u "$username" --arg p "$password" \
        '{username: $u, password: $p}')

    http_code=$(portainer_curl -o /tmp/bento-portainer-auth.json -w '%{http_code}' \
        -X POST "${base}/api/auth" \
        -H 'Content-Type: application/json' \
        -d "$body")

    if [[ "$http_code" != "200" ]]; then
        echo "Portainer auth failed (HTTP $http_code)." >&2
        return 1
    fi

    jq -r '.jwt' /tmp/bento-portainer-auth.json
}

# Auth header builder — caches the JWT in BENTO_PORTAINER_JWT for the session.
portainer_auth_header() {
    if [[ -z "${BENTO_PORTAINER_JWT:-}" ]]; then
        BENTO_PORTAINER_JWT=$(portainer_login)
        export BENTO_PORTAINER_JWT
    fi
    printf 'Authorization: Bearer %s' "$BENTO_PORTAINER_JWT"
}

# Get the default endpoint ID (usually 1 in a single-node Swarm).
portainer_endpoint_id() {
    local base auth
    base="$(portainer_base_url)"
    auth="$(portainer_auth_header)"

    portainer_curl -fsS "${base}/api/endpoints" \
        -H "$auth" \
        | jq -r '.[0].Id'
}

# Get the Swarm ID for the default endpoint.
portainer_swarm_id() {
    local base auth endpoint_id
    base="$(portainer_base_url)"
    auth="$(portainer_auth_header)"
    endpoint_id="$(portainer_endpoint_id)"

    portainer_curl -fsS "${base}/api/endpoints/${endpoint_id}/docker/swarm" \
        -H "$auth" \
        | jq -r '.ID'
}

# Create a Swarm stack from a Git repository.
# Args:
#   $1 — stack name
#   $2 — compose file path inside the repo
#   $3 — JSON array of {name, value} env vars
#   $4 — repo URL (default felipefontoura/bento)
#   $5 — git ref (default refs/heads/main)
portainer_create_stack_from_git() {
    local stack_name="$1"
    local compose_path="$2"
    local env_json="$3"
    local repo_url="${4:-https://github.com/felipefontoura/bento}"
    local ref="${5:-refs/heads/main}"

    local base auth endpoint_id swarm_id body http_code
    base="$(portainer_base_url)"
    auth="$(portainer_auth_header)"
    endpoint_id="$(portainer_endpoint_id)"
    swarm_id="$(portainer_swarm_id)"

    body=$(jq -n \
        --arg name "$stack_name" \
        --arg swarm "$swarm_id" \
        --arg url "$repo_url" \
        --arg ref "$ref" \
        --arg compose "$compose_path" \
        --argjson env "$env_json" \
        '{
            name: $name,
            swarmID: $swarm,
            repositoryURL: $url,
            repositoryReferenceName: $ref,
            composeFile: $compose,
            env: $env
        }')

    http_code=$(portainer_curl -o /tmp/bento-portainer-stack.json -w '%{http_code}' \
        -X POST "${base}/api/stacks/create/swarm/repository?endpointId=${endpoint_id}" \
        -H "$auth" \
        -H 'Content-Type: application/json' \
        -d "$body")

    if [[ "$http_code" != "200" ]]; then
        echo "Portainer stack create failed (HTTP $http_code):" >&2
        cat /tmp/bento-portainer-stack.json >&2 || true
        return 1
    fi

    jq -r '.Id' /tmp/bento-portainer-stack.json
}

# List all stacks.
portainer_list_stacks() {
    local base auth
    base="$(portainer_base_url)"
    auth="$(portainer_auth_header)"
    portainer_curl -fsS "${base}/api/stacks" -H "$auth"
}

# Get details for one stack.
portainer_get_stack() {
    local stack_id="$1"
    local base auth
    base="$(portainer_base_url)"
    auth="$(portainer_auth_header)"
    portainer_curl -fsS "${base}/api/stacks/${stack_id}" -H "$auth"
}

# Redeploy a Git-backed stack — pulls latest commit + new images.
portainer_redeploy_stack() {
    local stack_id="$1"
    local env_json="${2:-[]}"
    local base auth endpoint_id body http_code
    base="$(portainer_base_url)"
    auth="$(portainer_auth_header)"
    endpoint_id="$(portainer_endpoint_id)"

    body=$(jq -n --argjson env "$env_json" \
        '{env: $env, prune: false, pullImage: true}')

    http_code=$(portainer_curl -o /tmp/bento-portainer-redeploy.json -w '%{http_code}' \
        -X PUT "${base}/api/stacks/${stack_id}/git/redeploy?endpointId=${endpoint_id}" \
        -H "$auth" \
        -H 'Content-Type: application/json' \
        -d "$body")

    if [[ "$http_code" != "200" ]]; then
        echo "Portainer redeploy failed (HTTP $http_code):" >&2
        cat /tmp/bento-portainer-redeploy.json >&2 || true
        return 1
    fi
}
