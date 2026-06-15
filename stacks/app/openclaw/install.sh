#!/bin/bash
# Drop the JSON5 config that enables the two Openclaw surfaces bento relies on:
# the public web Control UI (beginner management) and the OpenAI-compatible
# /v1/chat/completions shim (a plain inference endpoint for generic OpenAI-API
# consumers). Neither flag has an env-var equivalent upstream (verified against
# src/config/types.gateway.ts), so this hook is the canonical way to set them
# at install time.
#
# Note: paperclip's openclaw_gateway adapter does NOT use /v1 — it speaks the
# Gateway WS protocol (ws://openclaw:18789) and drives openclaw's full agent
# runtime. That protocol is served by the gateway itself (mode + token below),
# not by the chatCompletions flag.
#
# We write through a throwaway alpine container with the named volume
# mounted, instead of `docker exec` against the openclaw container — that
# way the file is in place even if the gateway is in a crash loop, and we
# don't depend on openclaw being healthy yet.
#
# `gateway.auth.mode` defaults to `"token"`, so OPENCLAW_GATEWAY_TOKEN
# becomes the bearer for /v1 AND the secret that gates the Control UI's WS
# handshake automatically. controlUi.allowedOrigins MUST list the public
# origin (https://$OPENCLAW_HOST) or non-loopback browsers are rejected on
# the WS upgrade.

set -euo pipefail
source "${BENTO_REPO_ROOT}/lib/install-helpers.sh"

# Swarm prefixes volume names with the stack name. The compose declares
# `openclaw-config:` and the stack is `openclaw`, so the actual volume is:
volume_name="openclaw_openclaw-config"

# Telegram has no in-UI login button — the bot token comes from the
# TELEGRAM_BOT_TOKEN env (default-account fallback), but the channel must also
# be enabled in config. Only emit the channels block when a token is actually
# present, so an empty deploy doesn't ship a dangling, disabled-but-declared
# channel. lib/stacks.sh exports TELEGRAM_BOT_TOKEN into this script's env.
telegram_channels=""
if [[ -n "${TELEGRAM_BOT_TOKEN:-}" ]]; then
    telegram_channels='
  channels: {
    // botToken resolves from the TELEGRAM_BOT_TOKEN env (default account).
    telegram: { enabled: true },
  },'
fi

echo "Writing Openclaw config to volume $volume_name…"
# Five things happen in this one-shot container:
#   1. Drop the JSON5 that enables /v1/chat/completions AND the public
#      Control UI, and sets gateway.mode=local (openclaw refuses to boot
#      when mode is absent).
#   2. Pin controlUi.allowedOrigins to the public host so the browser WS
#      upgrade from https://$OPENCLAW_HOST is accepted. OPENCLAW_HOST and
#      TELEGRAM_CHANNELS are exported into this script's env by lib/stacks.sh /
#      computed above and forwarded to the alpine container via `-e`; the
#      unquoted heredoc expands them there.
#   3. Enable the Telegram channel when a bot token was supplied.
#   4. Create the logs/ subdir openclaw writes to on boot — otherwise the
#      gateway logs EACCES on every start.
#   5. chown the whole tree to uid/gid 1000 (the upstream `node` user),
#      because Swarm's default mount is root-owned and openclaw drops
#      privileges before writing.
sudo docker run --rm \
    -e OPENCLAW_HOST="$OPENCLAW_HOST" \
    -e TELEGRAM_CHANNELS="$telegram_channels" \
    -v "$volume_name:/cfg" alpine sh -c 'cat > /cfg/openclaw.json <<EOF
{
  gateway: {
    mode: "local",
    http: {
      endpoints: {
        chatCompletions: { enabled: true },
      },
    },
    controlUi: {
      // Public web Control UI: the terminal-free way a beginner manages
      // openclaw — sign in with a ChatGPT/Claude subscription, chat, and
      // connect a Telegram bot, all in the browser. Traefik fronts port
      // 18789 on OPENCLAW_HOST; the gateway token gates the WS handshake.
      enabled: true,
      // Required for non-loopback browsers: openclaw rejects the WS upgrade
      // unless the page origin is listed here.
      allowedOrigins: ["https://$OPENCLAW_HOST"],
    },
  },$TELEGRAM_CHANNELS
}
EOF
mkdir -p /cfg/logs
chown -R 1000:1000 /cfg'

# Recreate the running task so the gateway picks up the new config.
# `--force` re-runs the service-update lifecycle even when nothing in the
# spec changed (the file we just wrote is on a volume, not in the spec).
sudo docker service update --force openclaw_openclaw >/dev/null

echo "Openclaw Control UI live at https://${OPENCLAW_HOST} (token login link is in the bento report)"
echo "Openclaw OpenAI-compatible endpoint enabled at http://openclaw:18789/v1/chat/completions"
