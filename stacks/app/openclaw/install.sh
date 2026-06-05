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
# Three things happen in this one-shot container:
#   1. Drop the 5-line JSON5 that enables /v1/chat/completions AND sets
#      gateway.mode=local (openclaw refuses to boot when mode is absent).
#   2. Create the logs/ subdir openclaw writes to on boot — otherwise the
#      gateway logs EACCES on every start.
#   3. chown the whole tree to uid/gid 1000 (the upstream `node` user),
#      because Swarm's default mount is root-owned and openclaw drops
#      privileges before writing.
sudo docker run --rm -v "$volume_name:/cfg" alpine sh -c 'cat > /cfg/openclaw.json <<EOF
{
  gateway: {
    mode: "local",
    http: {
      endpoints: {
        chatCompletions: { enabled: true },
      },
    },
  },
}
EOF
mkdir -p /cfg/logs
chown -R 1000:1000 /cfg'

# Recreate the running task so the gateway picks up the new config.
# `--force` re-runs the service-update lifecycle even when nothing in the
# spec changed (the file we just wrote is on a volume, not in the spec).
sudo docker service update --force openclaw_openclaw >/dev/null

echo "Openclaw OpenAI-compatible endpoint enabled at http://openclaw:18789/v1/chat/completions"
