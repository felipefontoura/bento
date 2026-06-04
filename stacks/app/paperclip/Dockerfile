# =============================================================================
# paperclip-custom — Paperclip + bundled coding-agent CLIs
# =============================================================================
#
# Extends the official ghcr.io/paperclipai/paperclip image with the coding
# agents that appear in Paperclip's "New Agent → Adapter type" dropdown but
# are NOT shipped in the base image:
#
#   - Hermes Agent (NousResearch)  → `hermes`
#   - Google Gemini CLI            → `gemini`
#   - Pi coding agent              → `pi`
#   - xAI Grok Build               → `grok`
#
# Already bundled by the base image:
#   - @anthropic-ai/claude-code  → `claude`
#   - @openai/codex              → `codex`
#   - opencode-ai                → `opencode`
#
# Build:
#   docker compose -f stacks/app/paperclip.yml build
# =============================================================================

ARG PAPERCLIP_VERSION=latest
ARG HERMES_VERSION=latest
ARG GEMINI_CLI_VERSION=latest
ARG PI_CLI_VERSION=latest
ARG GROK_INSTALL_URL=https://x.ai/cli/install.sh

FROM nousresearch/hermes-agent:${HERMES_VERSION} AS hermes

FROM ghcr.io/paperclipai/paperclip:${PAPERCLIP_VERSION}

ARG PAPERCLIP_VERSION
ARG HERMES_VERSION
ARG GEMINI_CLI_VERSION
ARG PI_CLI_VERSION
ARG GROK_INSTALL_URL

LABEL org.opencontainers.image.source="https://github.com/felipefontoura/bento" \
      org.opencontainers.image.title="paperclip-custom" \
      org.opencontainers.image.description="Paperclip + Hermes + Gemini + Pi + Grok bundled agent runtime" \
      org.opencontainers.image.licenses="MIT" \
      org.bento.paperclip-version="${PAPERCLIP_VERSION}" \
      org.bento.hermes-version="${HERMES_VERSION}" \
      org.bento.gemini-cli-version="${GEMINI_CLI_VERSION}" \
      org.bento.pi-cli-version="${PI_CLI_VERSION}"

USER root

# -----------------------------------------------------------------------------
# Hermes Agent — copy the full runtime tree (CLI, Python venv, web_dist,
# ui-tui, playwright cache) from the official image.
# -----------------------------------------------------------------------------
COPY --from=hermes /opt/hermes /opt/hermes

# -----------------------------------------------------------------------------
# Runtime defaults. Single source of truth — the compose file does NOT
# override these unless a deployment needs to differ.
# -----------------------------------------------------------------------------
ENV PATH="/opt/hermes/bin:/opt/hermes/venv/bin:${PATH}" \
    PYTHONUNBUFFERED=1 \
    PLAYWRIGHT_BROWSERS_PATH=/opt/hermes/.playwright \
    HERMES_WEB_DIST=/opt/hermes/hermes_cli/web_dist \
    HERMES_TUI_DIR=/opt/hermes/ui-tui \
    HERMES_HOME=/paperclip/.hermes \
    HERMES_DASHBOARD=0 \
    API_SERVER_ENABLED=false

RUN mkdir -p /paperclip/.hermes && chmod 755 /paperclip/.hermes

# -----------------------------------------------------------------------------
# Node-based agents.
# -----------------------------------------------------------------------------
RUN npm install --global --omit=dev \
        @google/gemini-cli@${GEMINI_CLI_VERSION} \
        @earendil-works/pi-coding-agent@${PI_CLI_VERSION} \
    && npm cache clean --force

# -----------------------------------------------------------------------------
# xAI Grok Build — runtime auth requires a SuperGrok or X Premium+ plan,
# but the binary install itself does not. No silent fallback — if the
# upstream script changes shape, the build fails loudly.
# -----------------------------------------------------------------------------
RUN curl -fsSL "$GROK_INSTALL_URL" | bash

# -----------------------------------------------------------------------------
# Healthcheck baked into the image so `docker run` works standalone.
# Compose may still override.
# -----------------------------------------------------------------------------
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=5 \
    CMD wget -qO- http://127.0.0.1:3100/ >/dev/null 2>&1 || exit 1

# -----------------------------------------------------------------------------
# Final gate: every advertised CLI must resolve, or the build fails.
# -----------------------------------------------------------------------------
RUN set -e; \
    for bin in hermes gemini pi grok claude codex opencode; do \
        command -v "$bin" >/dev/null 2>&1 \
            || { echo "ERROR: $bin not on PATH"; exit 1; }; \
    done; \
    echo "All bundled agent CLIs present."
