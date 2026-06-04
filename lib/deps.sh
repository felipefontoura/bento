#!/bin/bash
# bento — dependency installation
#
# Runs before gum is available, so it uses the same minimal ANSI helpers as
# boot.sh. apt-get output is captured to /tmp/bento-deps.log; the terminal
# only shows step lines, one per operation, so the user sees progress
# without scroll-spam.

[[ -n "${_BENTO_DEPS_LOADED:-}" ]] && return 0
_BENTO_DEPS_LOADED=1

readonly BENTO_CHARM_KEY_URL="https://repo.charm.sh/apt/gpg.key"
readonly BENTO_CHARM_REPO="deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *"
BENTO_DEPS_LOG="${BENTO_DEPS_LOG:-/tmp/bento-deps.log}"
: > "$BENTO_DEPS_LOG" || true

# Local palette in case boot.sh's readonly globals were not exported.
_dS=$'\033[38;2;255;107;107m'   # salmon
_dW=$'\033[38;2;6;214;160m'     # wasabi
_dM=$'\033[38;2;120;120;120m'   # muted
_dN=$'\033[0m'

_d_step()  { printf '  %s⏵%s %s' "$_dM" "$_dN" "$1"; }
_d_ok()    { printf '\r\033[K  %s✓%s %s\n' "$_dW" "$_dN" "$1"; }
_d_fail()  { printf '\r\033[K  %s✗%s %s\n' "$_dS" "$_dN" "$1" >&2; }

deps_check_apt() {
    # boot.sh already validated this, but keep as a cheap safety net.
    if ! command -v apt-get >/dev/null 2>&1; then
        _d_fail "apt-get not found"
        return 1
    fi
}

deps_install_base() {
    _d_step "Installing core packages (curl, jq, envsubst, gpg)…"
    if sudo NEEDRESTART_MODE=a DEBIAN_FRONTEND=noninteractive apt-get update -qq \
            >>"$BENTO_DEPS_LOG" 2>&1 \
       && sudo NEEDRESTART_MODE=a DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
            curl ca-certificates gettext-base jq git gnupg \
            >>"$BENTO_DEPS_LOG" 2>&1; then
        _d_ok "Core packages ready"
    else
        _d_fail "apt-get install failed — see $BENTO_DEPS_LOG"
        return 1
    fi
}

deps_install_gum() {
    if command -v gum >/dev/null 2>&1; then
        return 0
    fi

    _d_step "Installing gum (Charm TUI)…"
    sudo mkdir -p /etc/apt/keyrings
    if ! curl -fsSL "$BENTO_CHARM_KEY_URL" \
        | sudo gpg --dearmor --batch --yes \
              -o /etc/apt/keyrings/charm.gpg 2>>"$BENTO_DEPS_LOG"; then
        _d_fail "Charm key fetch failed — trying release binary"
        if deps_install_gum_binary; then
            _d_ok "gum installed (binary fallback)"
            return 0
        fi
        return 1
    fi

    echo "$BENTO_CHARM_REPO" | sudo tee /etc/apt/sources.list.d/charm.list >/dev/null
    if sudo NEEDRESTART_MODE=a DEBIAN_FRONTEND=noninteractive apt-get update -qq \
            >>"$BENTO_DEPS_LOG" 2>&1 \
       && sudo NEEDRESTART_MODE=a DEBIAN_FRONTEND=noninteractive apt-get install -y -qq gum \
            >>"$BENTO_DEPS_LOG" 2>&1; then
        _d_ok "gum installed"
    else
        _d_fail "apt install of gum failed — trying release binary"
        if deps_install_gum_binary; then
            _d_ok "gum installed (binary fallback)"
        else
            return 1
        fi
    fi
}

# Fallback: download the gum binary directly from a GitHub release.
deps_install_gum_binary() {
    local arch tmpdir url
    case "$(uname -m)" in
        x86_64)  arch="x86_64" ;;
        aarch64) arch="arm64" ;;
        *)
            _d_fail "Unsupported arch $(uname -m) for gum binary fallback"
            return 1 ;;
    esac
    tmpdir=$(mktemp -d)
    url="https://github.com/charmbracelet/gum/releases/latest/download/gum_Linux_${arch}.tar.gz"
    curl -fsSL "$url" -o "$tmpdir/gum.tar.gz" 2>>"$BENTO_DEPS_LOG" || return 1
    tar -xzf "$tmpdir/gum.tar.gz" -C "$tmpdir" 2>>"$BENTO_DEPS_LOG" || return 1
    sudo install -m 0755 "$tmpdir"/gum_*/gum /usr/local/bin/gum
    rm -rf "$tmpdir"
}

deps_ensure_all() {
    deps_check_apt || return 1
    deps_install_base || return 1
    deps_install_gum || return 1
}
