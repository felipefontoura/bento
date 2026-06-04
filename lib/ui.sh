#!/bin/bash
# bento — UI helpers (gum wrappers + palette)
#
# All terminal styling routes through here so the look stays consistent.
# Requires gum (installed by lib/deps.sh).

# Idempotent source guard — this file is sourced multiple times in the same
# shell (install.sh + lib/banner.sh + lib/infra.sh all source it). Without
# the guard, the `readonly` declarations below abort on the second source.
[[ -n "${_BENTO_UI_LOADED:-}" ]] && return 0
_BENTO_UI_LOADED=1

# -----------------------------------------------------------------------------
# Palette — bento bento bento. Light on salmon, accents on wasabi.
# -----------------------------------------------------------------------------
readonly BENTO_COLOR_SALMON="#FF6B6B"     # primary accent (sushi salmon)
readonly BENTO_COLOR_WASABI="#06D6A0"     # info / progress
readonly BENTO_COLOR_RICE="#FAF3DD"       # neutral foreground on dark bg
readonly BENTO_COLOR_NORI="#293241"       # background for boxes
readonly BENTO_COLOR_SUCCESS="#06D6A0"
readonly BENTO_COLOR_WARNING="#FFD166"
readonly BENTO_COLOR_DANGER="#EF476F"
readonly BENTO_COLOR_MUTED="240"

# -----------------------------------------------------------------------------
# Status indicators (used in menu + status table)
# -----------------------------------------------------------------------------
ui_status_icon() {
    case "$1" in
        done)     printf '✓' ;;
        pending)  printf '⏵' ;;
        running)  printf '…' ;;
        failed)   printf '✗' ;;
        locked)   printf '🔒' ;;
        *)        printf '·' ;;
    esac
}

ui_status_color() {
    case "$1" in
        done)     printf '%s' "$BENTO_COLOR_SUCCESS" ;;
        pending)  printf '%s' "$BENTO_COLOR_SALMON" ;;
        running)  printf '%s' "$BENTO_COLOR_WASABI" ;;
        failed)   printf '%s' "$BENTO_COLOR_DANGER" ;;
        locked)   printf '%s' "$BENTO_COLOR_MUTED" ;;
        *)        printf '%s' "$BENTO_COLOR_MUTED" ;;
    esac
}

# -----------------------------------------------------------------------------
# Headers, sections, dividers
# -----------------------------------------------------------------------------
ui_section() {
    gum style \
        --foreground="$BENTO_COLOR_SALMON" \
        --bold \
        --margin="1 0 0 0" \
        "▸ $1"
}

ui_subtle() {
    gum style --foreground="$BENTO_COLOR_MUTED" --italic "$1"
}

ui_divider() {
    gum style --foreground="$BENTO_COLOR_MUTED" "$(printf '─%.0s' $(seq 1 60))"
}

# -----------------------------------------------------------------------------
# Status messages — wrap gum log + add icons
# -----------------------------------------------------------------------------
ui_info() {
    gum style --foreground="$BENTO_COLOR_WASABI" "ℹ $*"
}

ui_success() {
    gum style --foreground="$BENTO_COLOR_SUCCESS" --bold "✓ $*"
}

ui_warn() {
    gum style --foreground="$BENTO_COLOR_WARNING" "⚠ $*"
}

ui_error() {
    gum style --foreground="$BENTO_COLOR_DANGER" --bold "✗ $*" >&2
}

# Boxed success — for "you're done, here are the credentials" moments.
ui_boxed_success() {
    gum style \
        --border="rounded" \
        --border-foreground="$BENTO_COLOR_SUCCESS" \
        --padding="1 2" \
        --margin="1 0" \
        --foreground="$BENTO_COLOR_RICE" \
        "$@"
}

ui_boxed_warn() {
    gum style \
        --border="rounded" \
        --border-foreground="$BENTO_COLOR_WARNING" \
        --padding="1 2" \
        --margin="1 0" \
        --foreground="$BENTO_COLOR_RICE" \
        "$@"
}

# -----------------------------------------------------------------------------
# Prompts — thin wrappers around gum so callers don't repeat styling.
# -----------------------------------------------------------------------------
ui_input() {
    local prompt="$1"
    local placeholder="${2:-}"
    local default="${3:-}"
    gum input \
        --prompt="$prompt " \
        --prompt.foreground="$BENTO_COLOR_SALMON" \
        --placeholder="$placeholder" \
        --value="$default" \
        --width=60
}

ui_password() {
    local prompt="$1"
    gum input \
        --prompt="$prompt " \
        --prompt.foreground="$BENTO_COLOR_SALMON" \
        --password \
        --width=60
}

ui_confirm() {
    gum confirm \
        --selected.background="$BENTO_COLOR_SALMON" \
        --prompt.foreground="$BENTO_COLOR_RICE" \
        "$@"
}

ui_choose() {
    gum choose \
        --cursor.foreground="$BENTO_COLOR_SALMON" \
        --selected.foreground="$BENTO_COLOR_WASABI" \
        "$@"
}

ui_choose_multi() {
    gum choose --no-limit \
        --cursor.foreground="$BENTO_COLOR_SALMON" \
        --selected.foreground="$BENTO_COLOR_WASABI" \
        --cursor-prefix="◯ " \
        --selected-prefix="◉ " \
        --unselected-prefix="◯ " \
        "$@"
}

ui_spin() {
    local title="$1"
    shift
    gum spin \
        --spinner=dot \
        --title="$title" \
        --spinner.foreground="$BENTO_COLOR_WASABI" \
        --title.foreground="$BENTO_COLOR_RICE" \
        -- "$@"
}

ui_format_md() {
    gum format --type=markdown "$@"
}

ui_pause() {
    gum style --foreground="$BENTO_COLOR_MUTED" "Press enter to continue..."
    read -r _
}
