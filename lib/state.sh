#!/bin/bash
# bento — state management
#
# State lives in ~/.config/bento/state.json. Schema is versioned; on read,
# state_migrate runs migrations to the current schema version.
#
# Functions:
#   state_init              — create dir + empty state if missing
#   state_get <jq-path>     — read a value with jq
#   state_set <jq-path> <v> — write a value (atomic via tmpfile + mv)
#   state_has <jq-path>     — exit 0 if path exists with non-null value
#   state_migrate           — bump schema_version if needed
#
# Convention: jq paths use jq syntax, e.g. ".bootstrap.base_domain"

[[ -n "${_BENTO_STATE_LOADED:-}" ]] && return 0
_BENTO_STATE_LOADED=1

readonly BENTO_STATE_DIR="${HOME}/.config/bento"
readonly BENTO_STATE_FILE="${BENTO_STATE_DIR}/state.json"
readonly BENTO_STATE_HISTORY_DIR="${BENTO_STATE_DIR}/history"
readonly BENTO_LOG_DIR="${HOME}/.local/state/bento/logs"
readonly BENTO_STATE_SCHEMA=1

state_init() {
    mkdir -p "$BENTO_STATE_DIR" "$BENTO_STATE_HISTORY_DIR" "$BENTO_LOG_DIR"
    chmod 700 "$BENTO_STATE_DIR"
    if [[ ! -f "$BENTO_STATE_FILE" ]]; then
        printf '{"schema_version": %d}\n' "$BENTO_STATE_SCHEMA" > "$BENTO_STATE_FILE"
        chmod 600 "$BENTO_STATE_FILE"
    fi
    state_migrate
}

state_migrate() {
    local current
    current=$(jq -r '.schema_version // 0' "$BENTO_STATE_FILE" 2>/dev/null || echo 0)
    if (( current < BENTO_STATE_SCHEMA )); then
        # Future migrations: case statement per version.
        state_set '.schema_version' "$BENTO_STATE_SCHEMA"
    fi
}

state_get() {
    local path="$1"
    local default="${2:-}"
    local result
    result=$(jq -r "${path} // empty" "$BENTO_STATE_FILE" 2>/dev/null)
    if [[ -z "$result" || "$result" == "null" ]]; then
        printf '%s' "$default"
    else
        printf '%s' "$result"
    fi
}

state_set() {
    local path="$1"
    local value="$2"
    local tmp
    tmp=$(mktemp "${BENTO_STATE_FILE}.XXXXXX")

    if [[ "$value" =~ ^(true|false|null)$ || "$value" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
        # numeric or boolean — pass raw
        jq "${path} = ${value}" "$BENTO_STATE_FILE" > "$tmp"
    else
        # string — quote
        jq --arg v "$value" "${path} = \$v" "$BENTO_STATE_FILE" > "$tmp"
    fi
    mv "$tmp" "$BENTO_STATE_FILE"
    chmod 600 "$BENTO_STATE_FILE"
}

# Set a raw JSON value (object, array, complex). Caller must provide valid JSON.
state_set_json() {
    local path="$1"
    local json="$2"
    local tmp
    tmp=$(mktemp "${BENTO_STATE_FILE}.XXXXXX")
    jq --argjson v "$json" "${path} = \$v" "$BENTO_STATE_FILE" > "$tmp"
    mv "$tmp" "$BENTO_STATE_FILE"
    chmod 600 "$BENTO_STATE_FILE"
}

state_has() {
    local path="$1"
    local result
    result=$(jq -r "${path} // empty" "$BENTO_STATE_FILE" 2>/dev/null)
    [[ -n "$result" && "$result" != "null" ]]
}

# Snapshot the current state to history before destructive operations.
state_snapshot() {
    local ts
    ts=$(date +%Y%m%d-%H%M%S)
    cp "$BENTO_STATE_FILE" "${BENTO_STATE_HISTORY_DIR}/state-${ts}.json"
    chmod 600 "${BENTO_STATE_HISTORY_DIR}/state-${ts}.json"
}

state_path() {
    printf '%s' "$BENTO_STATE_FILE"
}
