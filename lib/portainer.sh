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

# Internal-loopback URL the bento process uses to drive Portainer. Even
# when bootstrap.portainer_url tracks the public HTTPS URL (for the
# report), the install pipeline should hit Portainer via the localhost
# port published in stacks/infra/portainer/compose.yml.
portainer_local_url() {
    printf 'http://127.0.0.1:9000'
}

# Curl wrapper — adds verbose logging when BENTO_VERBOSE=1.
portainer_curl() {
    if [[ "${BENTO_VERBOSE:-0}" == "1" ]]; then
        printf '→ curl %s\n' "$*" >&2
    fi
    curl --silent --show-error "$@"
}

# Poll /api/system/status until Portainer responds (or timeout). Always
# probes the host-loopback URL — the public HTTPS URL might not be
# certificate-ready yet, and bento talks to Portainer locally anyway.
portainer_wait_ready() {
    local base="${1:-$(portainer_local_url)}"
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
    base="$(portainer_local_url)"

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
    base="$(portainer_local_url)"
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
        cat /tmp/bento-portainer-auth.json >&2 2>/dev/null || true
        return 1
    fi

    local jwt
    jwt=$(jq -r '.jwt // empty' /tmp/bento-portainer-auth.json)
    if [[ -z "$jwt" || "$jwt" == "null" ]]; then
        echo "Portainer auth returned no JWT — response was:" >&2
        cat /tmp/bento-portainer-auth.json >&2 2>/dev/null || true
        return 1
    fi
    printf '%s' "$jwt"
}

# Auth header builder — caches the JWT in BENTO_PORTAINER_JWT for the
# session. Stale tokens (after a Portainer restart, after server-side
# session timeout, after rate-limit recovery) are cleared by callers via
# `unset BENTO_PORTAINER_JWT` so the next request re-logs in.
portainer_auth_header() {
    if [[ -z "${BENTO_PORTAINER_JWT:-}" ]]; then
        BENTO_PORTAINER_JWT=$(portainer_login)
        export BENTO_PORTAINER_JWT
    fi
    printf 'Authorization: Bearer %s' "$BENTO_PORTAINER_JWT"
}

# Helper used by api wrappers that get a 401 mid-operation: drop the
# cached token and try again from the beginning.
portainer_invalidate_token() {
    unset BENTO_PORTAINER_JWT
}

# Run a Portainer API call and, if it returns 401/403, drop the cached
# JWT and retry exactly once. Avoids a class of "rate-limit recovery"
# bugs where the JWT survives in memory but Portainer no longer accepts
# it. Echoes whatever the inner callback echoes; returns its exit code.
#
# Usage:
#   portainer_with_token_retry _portainer_do_get /api/endpoints
portainer_with_token_retry() {
    local fn="$1"; shift
    local out rc
    out=$("$fn" "$@")
    rc=$?
    if (( rc != 0 )) && [[ "${BENTO_LAST_PORTAINER_HTTP_CODE:-}" =~ ^(401|403)$ ]]; then
        portainer_invalidate_token
        out=$("$fn" "$@")
        rc=$?
    fi
    printf '%s' "$out"
    return $rc
}

# Get the default endpoint ID (usually 1 in a single-node Swarm).
# Memoised — survives multiple calls in the same install run.
portainer_endpoint_id() {
    if [[ -n "${BENTO_PORTAINER_ENDPOINT_ID:-}" ]]; then
        printf '%s' "$BENTO_PORTAINER_ENDPOINT_ID"
        return 0
    fi
    local base auth raw id
    base="$(portainer_local_url)"
    auth="$(portainer_auth_header)" || return 1

    # Split the curl + jq pair so a failure in either surfaces. The
    # previous form `curl | jq -r '.[0].Id'` swallowed both: curl errors
    # produced nothing, jq returned the string "null" on empty arrays,
    # and downstream calls hit cryptic 404s with id="null" in the path.
    raw=$(portainer_curl -fsS "${base}/api/endpoints" -H "$auth") || {
        echo "Portainer /api/endpoints request failed." >&2
        return 1
    }
    id=$(jq -r '.[0].Id // empty' <<< "$raw")
    if [[ -z "$id" ]]; then
        echo "Portainer returned no endpoints (response: $raw)" >&2
        return 1
    fi
    BENTO_PORTAINER_ENDPOINT_ID="$id"
    export BENTO_PORTAINER_ENDPOINT_ID
    printf '%s' "$BENTO_PORTAINER_ENDPOINT_ID"
}

# Get the Swarm ID for the default endpoint. Memoised.
portainer_swarm_id() {
    if [[ -n "${BENTO_PORTAINER_SWARM_ID:-}" ]]; then
        printf '%s' "$BENTO_PORTAINER_SWARM_ID"
        return 0
    fi
    local base auth endpoint_id raw id
    base="$(portainer_local_url)"
    auth="$(portainer_auth_header)" || return 1
    endpoint_id="$(portainer_endpoint_id)" || return 1

    raw=$(portainer_curl -fsS "${base}/api/endpoints/${endpoint_id}/docker/swarm" \
        -H "$auth") || {
        echo "Portainer /docker/swarm request failed (endpoint ${endpoint_id})." >&2
        return 1
    }
    id=$(jq -r '.ID // empty' <<< "$raw")
    if [[ -z "$id" ]]; then
        echo "Portainer returned no Swarm ID (response: $raw)" >&2
        return 1
    fi
    BENTO_PORTAINER_SWARM_ID="$id"
    export BENTO_PORTAINER_SWARM_ID
    printf '%s' "$BENTO_PORTAINER_SWARM_ID"
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
    base="$(portainer_local_url)"
    auth="$(portainer_auth_header)" || return 1
    endpoint_id="$(portainer_endpoint_id)" || return 1
    swarm_id="$(portainer_swarm_id)" || return 1

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

    local resp
    resp=$(mktemp)
    # shellcheck disable=SC2064
    trap "rm -f '$resp'" RETURN

    http_code=$(portainer_curl -o "$resp" -w '%{http_code}' \
        -X POST "${base}/api/stacks/create/swarm/repository?endpointId=${endpoint_id}" \
        -H "$auth" \
        -H 'Content-Type: application/json' \
        -d "$body")
    export BENTO_LAST_PORTAINER_HTTP_CODE="$http_code"

    # Stale JWT after rate-limit recovery: drop the token and retry once.
    if [[ "$http_code" =~ ^(401|403)$ ]]; then
        portainer_invalidate_token
        auth="$(portainer_auth_header)"
        http_code=$(portainer_curl -o "$resp" -w '%{http_code}' \
            -X POST "${base}/api/stacks/create/swarm/repository?endpointId=${endpoint_id}" \
            -H "$auth" \
            -H 'Content-Type: application/json' \
            -d "$body")
        export BENTO_LAST_PORTAINER_HTTP_CODE="$http_code"
    fi

    if [[ "$http_code" != "200" ]]; then
        echo "Portainer stack create failed (HTTP $http_code):" >&2
        cat "$resp" >&2 || true
        return 1
    fi

    # Insist on a non-empty numeric Id. Portainer can return 200 with an
    # error body on edge cases (auth race + repo unreachable); jq then
    # produces "null", and the caller would persist a bogus stack_id.
    local new_id
    new_id=$(jq -r '.Id // empty' "$resp")
    if [[ -z "$new_id" ]]; then
        echo "Portainer create returned 200 but no .Id field. Body:" >&2
        cat "$resp" >&2 || true
        return 1
    fi
    printf '%s' "$new_id"
}

# List all stacks.
portainer_list_stacks() {
    local base auth
    base="$(portainer_local_url)"
    auth="$(portainer_auth_header)"
    portainer_curl -fsS "${base}/api/stacks" -H "$auth"
}

# Get details for one stack.
portainer_get_stack() {
    local stack_id="$1"
    local base auth
    base="$(portainer_local_url)"
    auth="$(portainer_auth_header)"
    portainer_curl -fsS "${base}/api/stacks/${stack_id}" -H "$auth"
}

# Get the current StackFileContent (compose YAML) for one stack. The
# standalone redeploy endpoint requires the body to round-trip the
# existing compose file — omitting it makes Portainer wipe the stack
# definition instead of just refreshing envs.
portainer_get_stack_file() {
    local stack_id="$1"
    local base auth raw
    base="$(portainer_local_url)"
    auth="$(portainer_auth_header)" || return 1
    raw=$(portainer_curl -fsS "${base}/api/stacks/${stack_id}/file" -H "$auth") || return 1
    jq -r '.StackFileContent // empty' <<< "$raw"
}

# Redeploy a stack. Handles both git-backed (Type=2 / Swarm-from-git)
# and standalone (Type=1) Portainer stacks transparently. The
# discriminator is the live .GitConfig field, not .Type — stacks created
# via /api/stacks/create/swarm/repository sometimes land with Type=1 and
# GitConfig=null (issue #29 repro on Hetzner), so .Type alone misroutes
# them to /git/redeploy, which silently no-ops the env update.
portainer_redeploy_stack() {
    local stack_id="$1"
    # Default `[]` is preserved for the git-backed branch (which ignores
    # env on /git/redeploy anyway). The standalone branch refuses to
    # proceed with an empty Env array — see below — because the PUT
    # endpoint replaces, rather than merges, envs.
    local env_json="${2:-[]}"
    local base auth endpoint_id body http_code meta git_backed
    base="$(portainer_local_url)"
    auth="$(portainer_auth_header)" || return 1
    endpoint_id="$(portainer_endpoint_id)" || return 1

    meta=$(portainer_get_stack "$stack_id") || {
        echo "Portainer redeploy: stack #${stack_id} not reachable." >&2
        return 1
    }
    if [[ -z "$meta" || "$(jq -r 'type' <<< "$meta" 2>/dev/null)" != "object" ]]; then
        echo "Portainer redeploy: stack #${stack_id} returned no metadata." >&2
        return 1
    fi
    git_backed=$(jq -r '(.GitConfig // null) != null' <<< "$meta")

    local resp
    resp=$(mktemp)
    # shellcheck disable=SC2064
    trap "rm -f '$resp'" RETURN

    if [[ "$git_backed" == "true" ]]; then
        # Portainer is case-sensitive — env, not Env, on /git/redeploy. Do not normalize.
        body=$(jq -n --argjson env "$env_json" \
            '{env: $env, prune: false, pullImage: true}')

        http_code=$(portainer_curl -o "$resp" -w '%{http_code}' \
            -X PUT "${base}/api/stacks/${stack_id}/git/redeploy?endpointId=${endpoint_id}" \
            -H "$auth" \
            -H 'Content-Type: application/json' \
            -d "$body")
        export BENTO_LAST_PORTAINER_HTTP_CODE="$http_code"

        if [[ "$http_code" =~ ^(401|403)$ ]]; then
            portainer_invalidate_token
            auth="$(portainer_auth_header)"
            http_code=$(portainer_curl -o "$resp" -w '%{http_code}' \
                -X PUT "${base}/api/stacks/${stack_id}/git/redeploy?endpointId=${endpoint_id}" \
                -H "$auth" \
                -H 'Content-Type: application/json' \
                -d "$body")
            export BENTO_LAST_PORTAINER_HTTP_CODE="$http_code"
        fi
    else
        # Standalone path. Refuse to PUT with an empty Env — the endpoint
        # replaces (not merges) the stack env, so [] would wipe every
        # value. Callers that genuinely want a redeploy without env
        # changes should pass back the stack's current .Env array.
        if [[ "$(jq -r 'length' <<< "$env_json" 2>/dev/null)" == "0" ]]; then
            echo "Portainer redeploy: refusing to PUT standalone stack #${stack_id} with empty Env (would clear all values)." >&2
            return 1
        fi

        local stack_file
        stack_file=$(portainer_get_stack_file "$stack_id") || {
            echo "Portainer redeploy: failed to fetch StackFileContent for stack #${stack_id}." >&2
            return 1
        }
        if [[ -z "$stack_file" ]]; then
            echo "Portainer redeploy: empty StackFileContent for stack #${stack_id} — refusing to PUT." >&2
            return 1
        fi

        # Portainer is case-sensitive — Env/StackFileContent/Prune/PullImage on the standalone PUT. Do not normalize.
        body=$(jq -n \
            --arg content "$stack_file" \
            --argjson env "$env_json" \
            '{StackFileContent: $content, Env: $env, Prune: false, PullImage: true}')

        http_code=$(portainer_curl -o "$resp" -w '%{http_code}' \
            -X PUT "${base}/api/stacks/${stack_id}?endpointId=${endpoint_id}" \
            -H "$auth" \
            -H 'Content-Type: application/json' \
            -d "$body")
        export BENTO_LAST_PORTAINER_HTTP_CODE="$http_code"

        if [[ "$http_code" =~ ^(401|403)$ ]]; then
            portainer_invalidate_token
            auth="$(portainer_auth_header)"
            http_code=$(portainer_curl -o "$resp" -w '%{http_code}' \
                -X PUT "${base}/api/stacks/${stack_id}?endpointId=${endpoint_id}" \
                -H "$auth" \
                -H 'Content-Type: application/json' \
                -d "$body")
            export BENTO_LAST_PORTAINER_HTTP_CODE="$http_code"
        fi
    fi

    if [[ "$http_code" != "200" ]]; then
        echo "Portainer redeploy failed (HTTP $http_code):" >&2
        cat "$resp" >&2 || true
        return 1
    fi
}
