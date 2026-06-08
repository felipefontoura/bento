#!/bin/bash
# shellcheck shell=bash disable=SC2034
# bento — pre-gum ANSI palette
#
# Single source of truth for the salmon / wasabi / muted colours used
# by boot.sh and lib/deps.sh BEFORE gum is installed. lib/ui.sh defines
# the same palette in hex form for gum once it's available.
#
# Keep names short — these are typed a lot in printf format strings.
#
# SC2034 is disabled file-wide here: every variable is consumed by
# callers that source this file (boot.sh, lib/deps.sh). shellcheck
# only sees palette.sh in isolation so it flags them all as unused.

[[ -n "${_BENTO_PALETTE_LOADED:-}" ]] && return 0
_BENTO_PALETTE_LOADED=1

BENTO_ANSI_SALMON=$'\033[38;2;255;107;107m'
BENTO_ANSI_WASABI=$'\033[38;2;6;214;160m'
BENTO_ANSI_MUTED=$'\033[38;2;120;120;120m'
BENTO_ANSI_BOLD=$'\033[1m'
BENTO_ANSI_RESET=$'\033[0m'
