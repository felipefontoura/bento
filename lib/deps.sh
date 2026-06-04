#!/bin/bash
# bento — dependency installation
#
# Installs (idempotently): gum, jq, envsubst (gettext-base), curl.
# Validates apt-get is available — single distro requirement.

readonly BENTO_CHARM_KEY_URL="https://repo.charm.sh/apt/gpg.key"
readonly BENTO_CHARM_REPO="deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *"

deps_check_apt() {
    if ! command -v apt-get >/dev/null 2>&1; then
        local distro="unknown"
        if [[ -r /etc/os-release ]]; then
            # shellcheck disable=SC1091
            distro=$(. /etc/os-release && printf '%s' "$PRETTY_NAME")
        fi
        cat >&2 <<EOF

bento needs a distro with apt-get (Ubuntu, Debian, Mint, Pop!_OS, etc.).
Detected: ${distro}

If you're on Fedora/Arch/RHEL, bento doesn't support you yet.

EOF
        return 1
    fi
}

deps_install_base() {
    # Quiet apt-get upgrade noise on subsequent runs.
    sudo apt-get update -qq
    sudo apt-get install -y -qq \
        curl \
        ca-certificates \
        gettext-base \
        jq \
        git
}

deps_install_gum() {
    if command -v gum >/dev/null 2>&1; then
        return 0
    fi

    sudo mkdir -p /etc/apt/keyrings
    if ! curl -fsSL "$BENTO_CHARM_KEY_URL" \
        | sudo gpg --dearmor --batch --yes -o /etc/apt/keyrings/charm.gpg; then
        echo "Failed to fetch Charm signing key, falling back to release binary." >&2
        deps_install_gum_binary
        return $?
    fi

    echo "$BENTO_CHARM_REPO" | sudo tee /etc/apt/sources.list.d/charm.list >/dev/null
    sudo apt-get update -qq
    if ! sudo apt-get install -y -qq gum; then
        deps_install_gum_binary
    fi
}

# Fallback: download the gum binary directly from a GitHub release.
deps_install_gum_binary() {
    local arch tmpdir url
    case "$(uname -m)" in
        x86_64)  arch="x86_64" ;;
        aarch64) arch="arm64" ;;
        *) echo "Unsupported arch $(uname -m) for gum binary fallback." >&2; return 1 ;;
    esac
    tmpdir=$(mktemp -d)
    url="https://github.com/charmbracelet/gum/releases/latest/download/gum_Linux_${arch}.tar.gz"
    curl -fsSL "$url" -o "$tmpdir/gum.tar.gz" || return 1
    tar -xzf "$tmpdir/gum.tar.gz" -C "$tmpdir" || return 1
    sudo install -m 0755 "$tmpdir"/gum_*/gum /usr/local/bin/gum
    rm -rf "$tmpdir"
}

deps_ensure_all() {
    deps_check_apt || return 1
    deps_install_base || return 1
    deps_install_gum || return 1
}
