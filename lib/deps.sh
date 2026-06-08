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

# Palette comes from lib/palette.sh — single source of truth shared
# with boot.sh. The guard inside palette.sh makes the second source a
# no-op so we can re-source freely.
# shellcheck source=lib/palette.sh
source "$(dirname "${BASH_SOURCE[0]}")/palette.sh"

_d_step()  { printf '  %s⏵%s %s' "$BENTO_ANSI_MUTED"  "$BENTO_ANSI_RESET" "$1"; }
_d_ok()    { printf '\r\033[K  %s✓%s %s\n' "$BENTO_ANSI_WASABI" "$BENTO_ANSI_RESET" "$1"; }
_d_fail()  { printf '\r\033[K  %s✗%s %s\n' "$BENTO_ANSI_SALMON" "$BENTO_ANSI_RESET" "$1" >&2; }

deps_check_apt() {
    # boot.sh already validated this, but keep as a cheap safety net.
    if ! command -v apt-get >/dev/null 2>&1; then
        _d_fail "apt-get not found"
        return 1
    fi
}

deps_install_base() {
    # Idempotent skip — every Step 1 already pulled these in (curl + git
    # are required for boot.sh to even reach us), and re-running
    # `apt-get update` on every install.sh source costs a noticeable
    # round-trip to the mirror. If every binary is on $PATH we skip the
    # whole apt block.
    if command -v curl     >/dev/null 2>&1 \
       && command -v jq       >/dev/null 2>&1 \
       && command -v envsubst >/dev/null 2>&1 \
       && command -v gpg      >/dev/null 2>&1 \
       && command -v git      >/dev/null 2>&1; then
        return 0
    fi

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
    # Split fetch + dearmor instead of 'curl | gpg'. Under pipefail a
    # mid-stream curl failure used to leave gpg processing a truncated
    # key, occasionally producing a malformed keyring that apt-get
    # update accepted at first and rejected on the next run. Fetch to
    # a tmp file we can checksum / inspect, then dearmor.
    local tmpkey
    tmpkey=$(mktemp)
    if ! curl -fsSL "$BENTO_CHARM_KEY_URL" -o "$tmpkey" 2>>"$BENTO_DEPS_LOG"; then
        rm -f "$tmpkey"
        _d_fail "Charm key fetch failed — trying release binary"
        if deps_install_gum_binary; then
            _d_ok "gum installed (binary fallback)"
            return 0
        fi
        return 1
    fi
    if ! sudo gpg --dearmor --batch --yes \
              -o /etc/apt/keyrings/charm.gpg < "$tmpkey" 2>>"$BENTO_DEPS_LOG"; then
        rm -f "$tmpkey"
        _d_fail "gpg --dearmor on Charm key failed — trying release binary"
        if deps_install_gum_binary; then
            _d_ok "gum installed (binary fallback)"
            return 0
        fi
        return 1
    fi
    rm -f "$tmpkey"

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

# Fallback: download the gum binary directly from a GitHub release and
# verify it against the SHA256SUMS file the release publishes alongside.
# Without that check we'd be `sudo install`-ing whatever a transparent
# proxy or compromised CDN handed us.
deps_install_gum_binary() {
    local arch tmpdir tar_url sums_url tar_name
    case "$(uname -m)" in
        x86_64)  arch="x86_64" ;;
        aarch64) arch="arm64" ;;
        *)
            _d_fail "Unsupported arch $(uname -m) for gum binary fallback"
            return 1 ;;
    esac
    tmpdir=$(mktemp -d)
    tar_name="gum_Linux_${arch}.tar.gz"
    tar_url="https://github.com/charmbracelet/gum/releases/latest/download/${tar_name}"
    sums_url="https://github.com/charmbracelet/gum/releases/latest/download/checksums.txt"

    if ! curl -fsSL "$tar_url" -o "$tmpdir/$tar_name" 2>>"$BENTO_DEPS_LOG"; then
        _d_fail "Could not download gum tarball"
        rm -rf "$tmpdir"
        return 1
    fi

    if curl -fsSL "$sums_url" -o "$tmpdir/SHA256SUMS" 2>>"$BENTO_DEPS_LOG"; then
        local expected actual
        expected=$(awk -v n="$tar_name" '$2 ~ n {print $1; exit}' "$tmpdir/SHA256SUMS")
        actual=$(sha256sum "$tmpdir/$tar_name" | awk '{print $1}')
        if [[ -z "$expected" ]]; then
            _d_fail "checksums.txt did not list $tar_name"
            rm -rf "$tmpdir"
            return 1
        fi
        if [[ "$expected" != "$actual" ]]; then
            _d_fail "SHA-256 mismatch on $tar_name (expected $expected, got $actual)"
            rm -rf "$tmpdir"
            return 1
        fi
    else
        # No checksums file — refuse to silently install untrusted bytes.
        _d_fail "Could not fetch checksums.txt; refusing to install unverified gum"
        rm -rf "$tmpdir"
        return 1
    fi

    tar -xzf "$tmpdir/$tar_name" -C "$tmpdir" 2>>"$BENTO_DEPS_LOG" || {
        rm -rf "$tmpdir"
        return 1
    }
    sudo install -m 0755 "$tmpdir"/gum_*/gum /usr/local/bin/gum
    rm -rf "$tmpdir"
}

deps_ensure_all() {
    deps_check_apt || return 1
    deps_install_base || return 1
    deps_install_gum || return 1
}
