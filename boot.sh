#!/bin/bash
# bento — curl|bash entry point
#
# Usage:
#   bash <(curl -sSL https://raw.githubusercontent.com/felipefontoura/bento/stable/boot.sh)
#
# Optional env vars:
#   BENTO_REF       — git ref to check out (default: stable)
#   BENTO_HOME      — clone destination (default: ~/.local/share/bento)

set -euo pipefail

# Some apt postinst hooks (and `clear`/tput later) explode when TERM is
# unset, which happens whenever boot.sh runs via `ssh host 'bash …'`
# without a PTY. Export a safe default so the chain stays alive.
export TERM="${TERM:-xterm-256color}"

BENTO_REF="${BENTO_REF:-stable}"
BENTO_HOME="${BENTO_HOME:-$HOME/.local/share/bento}"
BENTO_REPO_URL="${BENTO_REPO_URL:-https://github.com/felipefontoura/bento.git}"
BENTO_DEPS_LOG=/tmp/bento-deps.log
: > "$BENTO_DEPS_LOG" || true

# -----------------------------------------------------------------------------
# Palette — sourced from a single file so deps.sh, banner.sh, and boot.sh
# all use the exact same hex values. The library is loaded directly from
# the repo we are about to clone if it doesn't exist yet in $BENTO_HOME
# (first ever run); when boot.sh re-runs after the clone, it sources
# from there.
# -----------------------------------------------------------------------------
if [[ -f "$BENTO_HOME/lib/palette.sh" ]]; then
    # shellcheck source=lib/palette.sh
    source "$BENTO_HOME/lib/palette.sh"
else
    # First run — palette.sh isn't on disk yet. Inline the values.
    BENTO_ANSI_SALMON=$'\033[38;2;255;107;107m'
    BENTO_ANSI_WASABI=$'\033[38;2;6;214;160m'
    BENTO_ANSI_MUTED=$'\033[38;2;120;120;120m'
    BENTO_ANSI_BOLD=$'\033[1m'
    BENTO_ANSI_RESET=$'\033[0m'
fi
_S=$BENTO_ANSI_SALMON _W=$BENTO_ANSI_WASABI _M=$BENTO_ANSI_MUTED
_B=$BENTO_ANSI_BOLD _N=$BENTO_ANSI_RESET

# Confirms the right command landed before any apt-get noise.
prebanner() {
    printf '\n  %s%s▸%s bento bootstrap  %sref: %s%s\n\n' \
        "$_S" "$_B" "$_N" "$_M" "$BENTO_REF" "$_N"
}

# Progressive step lines: "  ⏵ doing thing…" → "  ✓ thing done"
# The \r\033[K overwrites the same line so the terminal stays tidy.
_step() { printf '  %s⏵%s %s' "$_M" "$_N" "$1"; }
_ok()   { printf '\r\033[K  %s✓%s %s\n' "$_W" "$_N" "$1"; }
_fail() { printf '\r\033[K  %s✗%s %s\n' "$_S" "$_N" "$1" >&2; exit 1; }

prebanner

# -----------------------------------------------------------------------------
# Pre-flight — visible checks. Each step prints ⏵ then becomes ✓ on success
# so the user knows the command landed and the process is alive.
# -----------------------------------------------------------------------------

_step "Checking distro…"
distro="unknown"
if [[ -r /etc/os-release ]]; then
    distro=$(. /etc/os-release && printf '%s' "$PRETTY_NAME")
fi
if command -v apt-get >/dev/null 2>&1; then
    _ok "Distro: $distro"
else
    _fail "bento needs apt-get (Ubuntu/Debian). Found: $distro"
fi

_step "Checking privileges…"
if (( EUID == 0 )); then
    _ok "Running as root"
elif command -v sudo >/dev/null 2>&1; then
    _ok "Non-root user with sudo available"
else
    _fail "bento needs root, or a non-root user with sudo installed"
fi

_step "Checking network…"
if ping -c1 -W2 github.com >/dev/null 2>&1 \
   || curl -fsSL --max-time 5 -o /dev/null https://github.com 2>/dev/null; then
    _ok "github.com reachable"
else
    _fail "Cannot reach github.com — check VPS networking before continuing"
fi

_step "Checking disk space…"
disk_free_gb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
if (( disk_free_gb >= 5 )); then
    _ok "Disk: ${disk_free_gb}GB free"
elif (( disk_free_gb >= 1 )); then
    _ok "Disk: ${disk_free_gb}GB free (5+ GB recommended)"
else
    _fail "Only ${disk_free_gb}GB free — bento needs at least 1 GB"
fi

# -----------------------------------------------------------------------------
# Ensure git so we can clone the repo. Everything else (jq, gum, envsubst)
# is handled by lib/deps.sh once we're inside install.sh.
# -----------------------------------------------------------------------------
if ! command -v git >/dev/null 2>&1; then
    _step "Installing git…"
    if sudo NEEDRESTART_MODE=a DEBIAN_FRONTEND=noninteractive apt-get update -qq \
            >>"$BENTO_DEPS_LOG" 2>&1 \
       && sudo NEEDRESTART_MODE=a DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git \
            >>"$BENTO_DEPS_LOG" 2>&1; then
        _ok "git installed"
    else
        _fail "git install failed — see $BENTO_DEPS_LOG"
    fi
fi

# -----------------------------------------------------------------------------
# Clone (or re-clone) the bento repo.
# -----------------------------------------------------------------------------
_step "Fetching bento ($BENTO_REF)…"
# Hop out of $BENTO_HOME before we delete it. `bash <(curl …)` inherits
# the launching shell's CWD; if the operator was sitting inside the
# previous clone, the rm -rf below unlinks the directory the running
# process is anchored to. git's getcwd() then returns ENOENT and the
# clone aborts — historically mis-reported as "branch may not exist".
cd / >/dev/null 2>&1 || true
if [[ -d "$BENTO_HOME" ]]; then
    rm -rf "$BENTO_HOME"
fi
mkdir -p "$(dirname "$BENTO_HOME")"
if git clone --quiet --depth 1 --branch "$BENTO_REF" \
       "$BENTO_REPO_URL" "$BENTO_HOME" 2>>"$BENTO_DEPS_LOG"; then
    _ok "Cloned to $BENTO_HOME"
else
    _fail "git clone failed for '$BENTO_REF' on $BENTO_REPO_URL"
    # Surface git's actual stderr — "branch may not exist" was wrong as
    # often as it was right (CWD gone, network blip, disk full, …).
    if [[ -s "$BENTO_DEPS_LOG" ]]; then
        printf '\n  git said:\n' >&2
        tail -5 "$BENTO_DEPS_LOG" | sed 's/^/    /' >&2
    fi
fi

printf '\n'

# -----------------------------------------------------------------------------
# Hand off to install.sh (which handles deps + UI + the menu).
# -----------------------------------------------------------------------------
# shellcheck disable=SC1091
source "$BENTO_HOME/install.sh"
