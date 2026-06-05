#!/bin/bash
# bento — pre-gum ANSI palette
#
# Single source of truth for the salmon / wasabi / muted colours used
# by boot.sh and lib/deps.sh BEFORE gum is installed. lib/ui.sh defines
# the same palette in hex form for gum once it's available.
#
# Keep names short — these are typed a lot in printf format strings.

[[ -n "${_BENTO_PALETTE_LOADED:-}" ]] && return 0
_BENTO_PALETTE_LOADED=1

BENTO_ANSI_SALMON=$'\033[38;2;255;107;107m'
BENTO_ANSI_WASABI=$'\033[38;2;6;214;160m'
BENTO_ANSI_MUTED=$'\033[38;2;120;120;120m'
BENTO_ANSI_BOLD=$'\033[1m'
BENTO_ANSI_RESET=$'\033[0m'
