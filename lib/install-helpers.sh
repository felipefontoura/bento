#!/bin/bash
# bento — helpers for per-app install scripts
#
# Each stacks/app/<name>.install.sh sources this file and uses the helpers
# below to (re-)create databases, users, or whatever else needs bootstrapping
# AFTER `docker stack deploy` returns successfully.
#
# Available env vars (exported by lib/stacks.sh before invoking the script):
#   BENTO_REPO_ROOT      — absolute path to the bento clone
#   BENTO_STACK_KEY      — the manifest's "name" field (e.g. "plunk")
#   BENTO_STATE_FILE     — ~/.config/bento/state.json
#   POSTGRES_PASSWORD    — superuser password if postgres stack is deployed

set -euo pipefail

# -----------------------------------------------------------------------------
# Container discovery
# -----------------------------------------------------------------------------
_find_container() {
    # Echo the first container ID matching <pattern>, or fail loudly.
    #
    # `set -e` doesn't help callers when this runs inside $(...) — the
    # captured stdout would just be empty and any downstream `docker
    # exec ""` would error with a misleading message. So we explicitly
    # check the captured value and abort the script if it's empty.
    local pattern="$1"
    local cid
    cid=$(sudo docker ps --filter "name=$pattern" --format '{{.ID}}' | head -1)
    if [[ -z "$cid" ]]; then
        printf 'No running container matches pattern: %s\n' "$pattern" >&2
        printf 'Run `sudo docker ps` to confirm the service is up.\n' >&2
        return 1
    fi
    printf '%s' "$cid"
}

# Wrapper that abort()s the script with context when the container is
# missing. Use this when "no container" is fatal — which is almost
# always the case in post-deploy install scripts.
require_container() {
    local pattern="$1"
    local cid
    if ! cid=$(_find_container "$pattern"); then
        printf 'install.sh aborted: cannot continue without a %s container.\n' "$pattern" >&2
        exit 1
    fi
    printf '%s' "$cid"
}

postgres_container() {
    # Swarm names containers <stack>_<service>.<task-id>. The postgres stack
    # has both stack-key and service-name = "postgres", so the prefix is
    # "postgres_postgres".
    _find_container 'postgres_postgres'
}

# -----------------------------------------------------------------------------
# Postgres helpers
# -----------------------------------------------------------------------------

# Block until postgres is reachable on the docker network. Used internally
# so each helper doesn't have to retry separately.
_wait_for_postgres() {
    local elapsed=0 cid
    while (( elapsed < 120 )); do
        cid=$(postgres_container 2>/dev/null) || cid=""
        if [[ -n "$cid" ]] \
           && sudo docker exec "$cid" pg_isready -U postgres -h 127.0.0.1 -p 5432 \
                >/dev/null 2>&1; then
            return 0
        fi
        sleep 3
        elapsed=$((elapsed + 3))
    done
    echo "Postgres did not become ready within 120s." >&2
    return 1
}

psql_exec() {
    local sql="$1"
    _wait_for_postgres || return 1
    local cid
    cid=$(postgres_container) || return 1
    sudo docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$cid" \
        psql -U postgres -tA -c "$sql"
}

ensure_database() {
    local db_name="$1"
    # Split the existence check from the grep so a psql failure
    # (postgres not ready, bad password, network blip) is detected
    # explicitly. The old 'psql_exec … | grep -q 1' masked psql's
    # exit code: an empty/error response collapsed to "false" and the
    # script then attempted CREATE DATABASE against a broken
    # connection, producing two confusing errors instead of one
    # informative one.
    local exists
    exists=$(psql_exec "SELECT 1 FROM pg_database WHERE datname='${db_name}'") || {
        echo "psql_exec failed while checking for database '${db_name}'." >&2
        return 1
    }
    if [[ "$exists" == "1" ]]; then
        echo "Database '${db_name}' already exists."
        return 0
    fi
    psql_exec "CREATE DATABASE \"${db_name}\"" || return 1
    echo "Created database '${db_name}'."
}

ensure_db_user() {
    # ensure_db_user <username> <password>
    local user="$1"
    local password="$2"
    local exists
    exists=$(psql_exec "SELECT 1 FROM pg_roles WHERE rolname='${user}'") || {
        echo "psql_exec failed while checking for role '${user}'." >&2
        return 1
    }
    if [[ "$exists" == "1" ]]; then
        psql_exec "ALTER ROLE \"${user}\" WITH LOGIN PASSWORD '${password}'" || return 1
        echo "Updated password for role '${user}'."
    else
        psql_exec "CREATE ROLE \"${user}\" WITH LOGIN PASSWORD '${password}'" || return 1
        echo "Created role '${user}'."
    fi
}

grant_db_ownership() {
    # grant_db_ownership <database> <user>
    local db="$1"
    local user="$2"
    psql_exec "ALTER DATABASE \"${db}\" OWNER TO \"${user}\"" || return 1
    echo "Database '${db}' is now owned by '${user}'."
}

# -----------------------------------------------------------------------------
# Health waiters
# -----------------------------------------------------------------------------
wait_for_service() {
    # wait_for_service <docker-service-name> [timeout-seconds]
    local svc="$1"
    local timeout="${2:-120}"
    local elapsed=0 desired actual
    while (( elapsed < timeout )); do
        desired=$(sudo docker service inspect "$svc" \
            --format '{{.Spec.Mode.Replicated.Replicas}}' 2>/dev/null || echo 0)
        actual=$(sudo docker service ls --filter "name=$svc" \
            --format '{{.Replicas}}' | awk -F/ '{print $1}')
        if [[ "$desired" != "0" && "$actual" == "$desired" ]]; then
            return 0
        fi
        sleep 3
        elapsed=$((elapsed + 3))
    done
    echo "Service $svc not healthy within ${timeout}s." >&2
    return 1
}

