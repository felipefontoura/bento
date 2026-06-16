---
name: auth
description: Register an AI-provider API key on a VPS running bento, via SSH, and propagate it to every BENTO_MANAGED stack. Drives bento-auth (Anthropic, OpenAI, OpenRouter, z.ai, Gemini, and any OpenAI-compatible endpoint). Use when the user says "add my OpenAI key", "register an Anthropic key", "set up provider auth on my bento server". NOTE: subscriptions (Claude Pro/Max, ChatGPT Plus) are OUT OF SCOPE — those use each app's native sign-in.
---

You are handling a secret (an API key) on the user's behalf. **Never echo the
key** into any output, log line, or command you display — keep it out of
narration and out of `BENTO_VERBOSE` traces. All artifacts stay in English.

# When to invoke

- "register my OpenAI / Anthropic / OpenRouter / z.ai / Gemini key on `<host>`"
- "add a provider key to my bento server"
- "wire an OpenAI-compatible endpoint into bento"

This is API KEYS only. If the user wants to use a **subscription**
(Claude Pro/Max, ChatGPT Plus), do NOT use bento-auth — point them at the app's
native sign-in (e.g. `openclaw models auth login --provider openai`, or
paperclip's bundled `claude /login`). bento-auth's old subscription snapshots
went stale in days and were removed.

# Inputs

| Input | Source | Notes |
|---|---|---|
| VPS host + SSH user | user message; default user `root` | reachable via SSH |
| provider | user message | must be a bento-auth catalog id (see below) |
| API key | user message — collect privately, NEVER display it back | |

Discover the valid provider ids from the host itself (don't hardcode):
```bash
ssh "$user@$host" "bash /root/.local/share/bento/scripts/bento-auth --help"
```

# Register — non-interactive over SSH

bento-auth reads the key from stdin (`read -rs`) and honours
`BENTO_AUTH_ASSUME_YES=1` to skip the "store anyway?" prompt on a failed
validation. So you can pipe the key in without a TTY. Read the key into a shell
variable WITHOUT printing it, then:

```bash
# Collect the key into $KEY by whatever private means; do not echo it.
printf '%s\n' "$KEY" | ssh "$user@$host" \
  "BENTO_AUTH_ASSUME_YES=1 bash /root/.local/share/bento/scripts/bento-auth <provider>"
unset KEY
```

For an exotic OpenAI-compatible endpoint not in the catalog:
```bash
printf '%s\n' "$KEY" | ssh "$user@$host" \
  "BENTO_AUTH_ASSUME_YES=1 bash /root/.local/share/bento/scripts/bento-auth openai-compat <label> <base_url>"
```

bento-auth validates the key (where the catalog defines a validate URL),
persists it to `state.providers.<ENV>`, and runs `auth_propagate_state_providers`
to `docker service update --env-add` it onto every running BENTO_MANAGED stack.
Future deploys inherit it automatically.

If validation fails, bento-auth (with ASSUME_YES) still stores it and prints a
warning — surface that warning to the user so they can re-check the key.

# Verify

```bash
ssh "$user@$host" "bash /root/.local/share/bento/scripts/bento-auth list"
```
This prints registered keys MASKED — safe to show the user. Confirm the
provider's env var appears.

# Report back

- Which provider env var is now set (masked), and that it propagated to managed stacks.
- Which apps consume it: hermes, paperclip, and generic OpenAI-compatible apps
  read these env vars. **openclaw does NOT** — it owns its provider config; tell
  the user to reference the propagated `${ENV}` in an openclaw custom-provider
  definition if they want it there.
- If the user actually needs a subscription, redirect to the app's native sign-in.

Full reference: `docs/reference/bento-auth.md` on the host (and in the repo).
