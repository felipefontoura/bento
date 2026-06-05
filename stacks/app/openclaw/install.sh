#!/bin/bash
# Drop the 5-line JSON5 config that enables Openclaw's OpenAI-compatible
# /v1/chat/completions endpoint. No env-var equivalent exists upstream
# (verified against src/config/types.gateway.ts), so this hook is the
# canonical way to flip the flag at install time.
#
# We write through a throwaway alpine container with the named volume
# mounted, instead of `docker exec` against the openclaw container — that
# way the file is in place even if the gateway is in a crash loop, and we
# don't depend on openclaw being healthy yet.
#
# `gateway.auth.mode` defaults to `"token"`, so OPENCLAW_GATEWAY_TOKEN
# becomes the bearer for /v1/chat/completions automatically.

set -euo pipefail
source "${BENTO_REPO_ROOT}/lib/install-helpers.sh"

# Swarm prefixes volume names with the stack name. The compose declares
# `openclaw-config:` and the stack is `openclaw`, so the actual volume is:
volume_name="openclaw_openclaw-config"

echo "Writing OpenAI-compat config to volume $volume_name…"
sudo docker run --rm -v "$volume_name:/cfg" alpine sh -c 'cat > /cfg/openclaw.json <<EOF
{
  gateway: {
    http: {
      endpoints: {
        chatCompletions: { enabled: true },
      },
    },
  },
}
EOF'

# Recreate the running task so the gateway picks up the new config.
# `--force` re-runs the service-update lifecycle even when nothing in the
# spec changed (the file we just wrote is on a volume, not in the spec).
sudo docker service update --force openclaw_openclaw >/dev/null

echo "Openclaw OpenAI-compatible endpoint enabled at http://openclaw:18789/v1/chat/completions"
