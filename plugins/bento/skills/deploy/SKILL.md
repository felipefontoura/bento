---
name: deploy
description: Add or redeploy application stacks on a VPS that ALREADY runs bento, via SSH. Drives bento's unattended Step 3 (BENTO_APPS) for the chosen apps, reconciles state against Portainer, verifies each app, and reports URLs + bootstrap artifacts. Use when the user says "add n8n to my server", "deploy chatwoot on my bento box", "install another app". For a brand-new server use the install skill instead.
---

You are operating bento on a remote machine the user trusts you with. Narrate
before every state-changing step and stop on anything that smells off. Every
artifact and message you produce stays in English.

# When to invoke

The user has a server that ALREADY has bento installed and wants more apps:
- "add n8n and typebot to my VPS"
- "deploy chatwoot on `<host>`"
- "install paperclip on my bento server"

If bento is NOT yet installed on the host, this is the wrong skill — use
`/bento:install` (fresh-VPS bootstrap). If the user wants logs/restart/scale of
an already-running app, point them at Portainer (`https://portainer.<domain>`).

# Inputs to gather

| Input | Source | Validation |
|---|---|---|
| VPS host | user message; ask if missing | reachable via SSH |
| SSH user | default `root`; ask if otherwise | has sudo or is root |
| apps to deploy | user message (CSV) | each must be a directory under `stacks/app/` on the host clone |
| per-app overrides | only if the user wants a non-default hostname/secret | passed as `BENTO_ENV_<STACK>_<VAR>` |

Use `AskUserQuestion` for anything missing. Don't guess an app name.

# Pre-flight (mandatory)

1. SSH reachable: `ssh -o ConnectTimeout=5 "$user@$host" "echo SSH_OK"`.
2. Confirm bento is installed: `ssh "$user@$host" "test -f ~/.config/bento/state.json && echo BENTO_OK"`. If absent, stop — tell the user to run `/bento:install` first.
3. List deployable apps so you validate the requested set against reality:
   ```bash
   ssh "$user@$host" "ls /root/.local/share/bento/stacks/app"
   ```
   Reject any requested app not in that list and show the valid options.
4. DNS for any NEW public hostname: `dig +short A "<app>.<base_domain>" @1.1.1.1`. The wildcard `*.<base_domain>` from the original install normally already covers it; warn only if it doesn't resolve to the VPS IP.

# Deploy — unattended only

Never drive bento's interactive TUI over SSH (gum prompts hang without a real
terminal). Re-run bento's installer in unattended mode with `BENTO_APPS` set to
ONLY the new apps. bento reconciles `state.stacks` against Portainer on entry to
`unattended_step3`, so orphaned state from a Portainer-side deletion won't
short-circuit the deploy.

```bash
ssh "$user@$host" "\
  BENTO_UNATTENDED=1 \
  BENTO_APPS=<comma,separated,apps> \
  ${BENTO_ENV_OVERRIDES:+$BENTO_ENV_OVERRIDES} \
  bash /root/.local/share/bento/install.sh"
```

Per-app override example (non-default hostname):
`BENTO_ENV_N8N_N8N_HOST=automation.example.com`.

Stream stdout. Watch for the failure patterns in the `install` skill's
"Failure-mode library" (409 stack-already-exists, ENOTFOUND postgres, directory
nonexistent, post-deploy ran too early) — the recoveries there apply verbatim.
Identify the pattern before running any recovery.

# Verify before reporting (per app)

1. **Swarm**: `docker service ls --filter name=<stack>_ --format '{{.Name}} {{.Replicas}}'` shows the expected replicas (n8n has 3 services).
2. **HTTPS**: `curl -sI --max-time 15 https://<app>.<base_domain>/` returns a sane status (2xx/3xx or the app's expected code).
3. **DB** (if the stack uses shared postgres): `psql -lt | grep -w <stack>` finds the DB on the postgres container.
4. **Stack-specific artifact**: read `stacks/app/<stack>/install.sh` to know what it bootstrapped (e.g. paperclip's `~/.config/bento/paperclip-invite-url.txt`).

Don't trust an install.sh "is ready" line — verify against Swarm + HTTPS + the
marker file, always.

# Report back

- Per-app URL (from `state_get .bootstrap.base_domain` + each manifest's `post_deploy_url`).
- Any bootstrap invite URLs (paperclip marker file is the canonical one).
- If any deployed app is an AI runtime (paperclip, openclaw, cli-proxy-api) and
  no provider key is registered yet, point at `/bento:auth`.
- Warnings (DNS still propagating, memory tight).

Format URLs as clickable links and quote credentials verbatim.
