#!/bin/bash
# Smoke test for portainer_redeploy_stack endpoint routing (issue #29).
#
# Bento has no real test framework yet, so this stays self-contained: it
# sources lib/portainer.sh against a throwaway HOME, overrides the HTTP
# helpers with bash function shadows, and asserts which endpoint +
# request body portainer_redeploy_stack produces in each branch.
#
# Run from the repo root:
#   bash tests/portainer_redeploy_test.sh
#
# Exit code 0 means every assertion passed.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export HOME
HOME="$(mktemp -d)"
trap 'rm -rf "$HOME"' EXIT

# Minimal state.json so state.sh's reads don't error.
mkdir -p "$HOME/.config/bento"
printf '{"schema_version": 1}\n' > "$HOME/.config/bento/state.json"

# shellcheck source=../lib/portainer.sh
source "$REPO_ROOT/lib/portainer.sh"

# -----------------------------------------------------------------------------
# Mocks
# -----------------------------------------------------------------------------

# portainer_curl runs inside command substitution `$(...)` in the
# production code, so any vars it sets in a subshell die there. Persist
# every capture to a file the parent test process can read back.
MOCK_REQ_FILE="$HOME/.mock_last_request"
MOCK_NEXT_HTTP_CODE="200"

mock_reset_request() {
    : > "$MOCK_REQ_FILE"
}

mock_field() {
    local field="$1"
    grep -m1 "^${field}=" "$MOCK_REQ_FILE" 2>/dev/null | cut -d= -f2-
}

portainer_auth_header() { printf 'Authorization: Bearer testjwt'; }
portainer_endpoint_id()  { printf '1'; }
portainer_local_url()    { printf 'http://127.0.0.1:9000'; }
portainer_invalidate_token() { :; }

# Per-test stack metadata stubs. Tests set MOCK_STACK_META + MOCK_STACK_FILE
# before calling portainer_redeploy_stack.
MOCK_STACK_META=""
MOCK_STACK_FILE=""
export MOCK_STACK_META MOCK_STACK_FILE MOCK_REQ_FILE MOCK_NEXT_HTTP_CODE

portainer_get_stack() { printf '%s' "$MOCK_STACK_META"; }
portainer_get_stack_file() { printf '%s' "$MOCK_STACK_FILE"; }

# Capturing portainer_curl. Only matters for the PUT call inside
# portainer_redeploy_stack; the GETs are short-circuited by the two
# stubs above. We walk the curl-style argv to recover method, url,
# body, and the path the production code asked us to write the
# response into, then persist them to MOCK_REQ_FILE because the
# production caller wraps us in `$(...)`.
portainer_curl() {
    local method="" url="" body="" outfile=""
    while (( $# > 0 )); do
        case "$1" in
            -X)
                method="$2"; shift 2 ;;
            -o)
                outfile="$2"; shift 2 ;;
            -d)
                body="$2"; shift 2 ;;
            -w|-H)
                shift 2 ;;
            -fsS|--silent|--show-error)
                shift ;;
            http*://*)
                url="$1"; shift ;;
            *)
                shift ;;
        esac
    done

    {
        printf 'METHOD=%s\n' "$method"
        printf 'URL=%s\n'    "$url"
        # body may contain newlines/JSON; base64-encode for a single line.
        printf 'BODY_B64=%s\n' "$(printf '%s' "$body" | base64 -w0)"
    } > "$MOCK_REQ_FILE"

    if [[ -n "$outfile" ]]; then
        : > "$outfile"
    fi
    printf '%s' "$MOCK_NEXT_HTTP_CODE"
}

mock_last_method()   { mock_field METHOD; }
mock_last_url()      { mock_field URL; }
mock_last_body()     {
    local b64
    b64=$(mock_field BODY_B64)
    [[ -z "$b64" ]] && return 0
    base64 -d <<< "$b64"
}

# -----------------------------------------------------------------------------
# Assertions
# -----------------------------------------------------------------------------

FAILS=0
PASSES=0

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        printf '  ok    %s\n' "$label"
        PASSES=$((PASSES + 1))
    else
        printf '  FAIL  %s\n        expected: %s\n        actual:   %s\n' \
            "$label" "$expected" "$actual"
        FAILS=$((FAILS + 1))
    fi
}

assert_jq_eq() {
    local label="$1" filter="$2" expected="$3" json="$4"
    local actual
    actual=$(jq -r "$filter" <<< "$json" 2>/dev/null || echo "<jq-error>")
    assert_eq "$label" "$expected" "$actual"
}

# -----------------------------------------------------------------------------
# Scenario 1 — git-backed stack: must hit /git/redeploy with lowercase body
# -----------------------------------------------------------------------------
echo "Scenario 1: git-backed stack uses /git/redeploy"

MOCK_STACK_META='{"Id": 7, "Name": "demo", "Type": 2, "GitConfig": {"URL": "https://github.com/foo/bar", "ReferenceName": "refs/heads/main"}}'
MOCK_STACK_FILE=""  # not consulted on git branch
MOCK_NEXT_HTTP_CODE="200"

portainer_redeploy_stack 7 '[{"name":"FOO","value":"bar"}]' >/dev/null

assert_eq "method"   "PUT" "$(mock_last_method)"
assert_eq "endpoint" "http://127.0.0.1:9000/api/stacks/7/git/redeploy?endpointId=1" "$(mock_last_url)"
assert_jq_eq "body uses lowercase 'env' key"     ".env[0].name"   "FOO"  "$(mock_last_body)"
assert_jq_eq "body has lowercase prune"          ".prune"         "false" "$(mock_last_body)"
assert_jq_eq "body has lowercase pullImage"      ".pullImage"     "true"  "$(mock_last_body)"
assert_jq_eq "no PascalCase StackFileContent"    "has(\"StackFileContent\")" "false" "$(mock_last_body)"

# -----------------------------------------------------------------------------
# Scenario 2 — standalone stack: must hit /api/stacks/{id} with PascalCase body
# -----------------------------------------------------------------------------
echo "Scenario 2: standalone stack uses /api/stacks/{id}"

MOCK_STACK_META='{"Id": 16, "Name": "paperclip", "Type": 1, "GitConfig": null, "FromAppTemplate": true}'
MOCK_STACK_FILE='services:
  paperclip:
    image: ghcr.io/paperclipai/paperclip:v2026.1.0
'
MOCK_NEXT_HTTP_CODE="200"

portainer_redeploy_stack 16 '[{"name":"OPENROUTER_API_KEY","value":"sk-or-v1-test"},{"name":"BENTO_MANAGED","value":"true"}]' >/dev/null

assert_eq "method"   "PUT" "$(mock_last_method)"
assert_eq "endpoint" "http://127.0.0.1:9000/api/stacks/16?endpointId=1" "$(mock_last_url)"
assert_jq_eq "body uses PascalCase Env"          ".Env[0].name"            "OPENROUTER_API_KEY"  "$(mock_last_body)"
assert_jq_eq "body roundtrips StackFileContent"  ".StackFileContent | contains(\"paperclip\")"  "true"  "$(mock_last_body)"
assert_jq_eq "body has PascalCase Prune"         ".Prune"                  "false"               "$(mock_last_body)"
assert_jq_eq "body has PascalCase PullImage"     ".PullImage"              "true"                "$(mock_last_body)"
assert_jq_eq "no lowercase env leakage"          "has(\"env\")"            "false"               "$(mock_last_body)"
assert_jq_eq "no lowercase prune leakage"        "has(\"prune\")"          "false"               "$(mock_last_body)"

# -----------------------------------------------------------------------------
# Scenario 3 — standalone stack with empty Env: must refuse
# -----------------------------------------------------------------------------
echo "Scenario 3: standalone stack refuses empty Env"

MOCK_STACK_META='{"Id": 16, "Name": "paperclip", "Type": 1, "GitConfig": null}'
MOCK_STACK_FILE='services:
  paperclip:
    image: ghcr.io/paperclipai/paperclip:v2026.1.0
'
mock_reset_request

set +e
portainer_redeploy_stack 16 '[]' 2>/dev/null
rc=$?
set -e

assert_eq "refuses empty Env (return code)" "1" "$rc"
assert_eq "no HTTP request issued"          ""  "$(mock_last_url)"

# -----------------------------------------------------------------------------
# Scenario 4 — stack metadata unreachable: must abort
# -----------------------------------------------------------------------------
echo "Scenario 4: missing metadata aborts cleanly"

MOCK_STACK_META=""
mock_reset_request
portainer_get_stack() { printf ''; }   # simulate empty body

set +e
portainer_redeploy_stack 99 '[{"name":"FOO","value":"bar"}]' 2>/dev/null
rc=$?
set -e

assert_eq "aborts on empty metadata (return code)" "1" "$rc"
assert_eq "no HTTP request issued"                  ""  "$(mock_last_url)"

# Restore for any downstream additions.
portainer_get_stack() { printf '%s' "$MOCK_STACK_META"; }

# -----------------------------------------------------------------------------
# Scenario 5 — git-backed stack: empty env is allowed (current behavior)
# -----------------------------------------------------------------------------
echo "Scenario 5: git-backed stack allows empty env (backward compat)"

MOCK_STACK_META='{"Id": 4, "Name": "infra_traefik", "Type": 1, "GitConfig": {"URL": "https://github.com/foo/bar"}}'
MOCK_NEXT_HTTP_CODE="200"

portainer_redeploy_stack 4 '[]' >/dev/null

assert_eq "method"   "PUT" "$(mock_last_method)"
assert_eq "endpoint" "http://127.0.0.1:9000/api/stacks/4/git/redeploy?endpointId=1" "$(mock_last_url)"
assert_jq_eq "env is empty array" ".env | length" "0" "$(mock_last_body)"

# -----------------------------------------------------------------------------
# Report
# -----------------------------------------------------------------------------
echo
if (( FAILS > 0 )); then
    printf 'FAIL: %d passed, %d failed\n' "$PASSES" "$FAILS" >&2
    exit 1
fi
printf 'PASS: %d assertions\n' "$PASSES"
