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

BENTO_REF="${BENTO_REF:-stable}"
BENTO_HOME="${BENTO_HOME:-$HOME/.local/share/bento}"
BENTO_REPO_URL="${BENTO_REPO_URL:-https://github.com/felipefontoura/bento.git}"

readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly GREEN='\033[0;32m'
readonly NC='\033[0m'

say()  { printf '%b\n' "${GREEN}▸${NC} $*"; }
warn() { printf '%b\n' "${YELLOW}⚠${NC} $*" >&2; }
die()  { printf '%b\n' "${RED}✗${NC} $*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# Pre-flight (mínimo viável)
# -----------------------------------------------------------------------------
if (( EUID == 0 )); then
    die "bento espera ser executado como um usuário regular com sudo. Não rode como root."
fi

if ! command -v apt-get >/dev/null 2>&1; then
    distro="desconhecida"
    if [[ -r /etc/os-release ]]; then
        distro=$(. /etc/os-release && printf '%s' "$PRETTY_NAME")
    fi
    die "bento precisa de uma distro com apt-get (Ubuntu, Debian e derivados). Detectei: $distro"
fi

if ! command -v sudo >/dev/null 2>&1; then
    die "bento precisa de sudo instalado."
fi

if ! ping -c1 -W2 github.com >/dev/null 2>&1; then
    warn "github.com inalcançável — bento precisa de internet."
fi

# Espaço em disco mínimo (~5 GB para Docker images + paperclip-custom).
disk_free_gb=$(df -BG --output=avail / | tail -1 | tr -d 'G ')
if (( disk_free_gb < 5 )); then
    warn "Apenas ${disk_free_gb}GB livres em /. Recomendado: 20+GB."
fi

# -----------------------------------------------------------------------------
# Garantir git
# -----------------------------------------------------------------------------
if ! command -v git >/dev/null 2>&1; then
    say "Instalando git…"
    sudo apt-get update -qq
    sudo apt-get install -y -qq git
fi

# -----------------------------------------------------------------------------
# Clone (ou re-clone) do repo
# -----------------------------------------------------------------------------
if [[ -d "$BENTO_HOME" ]]; then
    say "Atualizando bento em $BENTO_HOME …"
    rm -rf "$BENTO_HOME"
fi
mkdir -p "$(dirname "$BENTO_HOME")"
git clone --quiet --depth 1 --branch "$BENTO_REF" "$BENTO_REPO_URL" "$BENTO_HOME"

# -----------------------------------------------------------------------------
# Source install.sh
# -----------------------------------------------------------------------------
# shellcheck disable=SC1091
source "$BENTO_HOME/install.sh"
