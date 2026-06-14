---
name: install-bento
description: Drive an end-to-end bento install on a fresh Ubuntu/Debian VPS via SSH — pre-flight checks, unattended one-liner, post-hardening reboot, app deploys, recovery from the failure modes that historically required manual operator intervention, and a final report with URLs + invite links.
---

You are operating an installer the user has trusted you with on a remote machine. **Confirm scope before destructive actions.** This skill chooses to be loud about what it is doing — narrate before every state-changing step, dump enough output to be auditable, and stop on anything that smells off rather than guess.

# When to invoke

The user says something like:
- "install bento on `<host>` with `<apps>`"
- "set up paperclip + n8n + chatwoot on my new VPS"
- "bootstrap a bento deployment on `<ip>`"

Or names this skill explicitly: `/install-bento`.

If the user asks a question *about* bento without asking you to install (e.g. "what does Step 1 do?"), this is the wrong skill — answer from `CLAUDE.md` instead.

# Inputs to gather

Before you touch the VPS, you need:

| Input | Source | Validation |
|---|---|---|
| VPS host | user message; ask if missing | reachable via SSH |
| SSH user | default `root`; ask if otherwise | has sudo or is root |
| `BENTO_BASE_DOMAIN` | user message; ask if missing | matches `^([a-z0-9]+(-[a-z0-9]+)*\.)+[a-z]{2,}$` |
| `BENTO_ADMIN_EMAIL` | user message; default `admin@<base_domain>` | matches email regex |
| `BENTO_APPS` | user message (CSV) | each value matches a directory under `stacks/app/` on `BENTO_REF` |
| `BENTO_REF` | default `stable`; ask only if user wants `main` or a feature branch | branch exists on `felipefontoura/bento` |
| `BENTO_ADVERTISE_ADDR` | default: probed via `bento_detect_public_ipv4` on the VPS | matches IPv4 regex |

Use `AskUserQuestion` for anything missing. Don't guess a domain or email.

# Pre-flight on the VPS

Before the first `boot.sh` invocation:

1. `ssh-keygen -R "$host"` (idempotent, kills any stale host key from a reinstall).
2. `ssh -o StrictHostKeyChecking=accept-new "$user@$host" "echo SSH_OK; uname -a; uptime"` — verify reachable + capture distro/kernel.
3. Confirm apt-based: `command -v apt-get` → must exist.
4. Resources: `free -m`, `df -h /`, `nproc`. Warn (don't block) if RAM < 2 GB or free disk < 10 GB.
5. DNS: `dig +short A "portainer.$BENTO_BASE_DOMAIN" @1.1.1.1`. If empty or mismatched, tell the user the exact A record they need (`*.<base_domain>` → VPS IP) and stop. Bento's Step 2 will fail Let's Encrypt HTTP-01 without this.

# Install command — unattended mode only

**Never invoke bento's interactive TUI from this skill.** Gum prompts (`ui_input`, `ui_choose`, `ui_confirm`) expect a real terminal and they DO NOT work when driven from `ssh "$user@$host" "bash …"`. You'll get half-rendered output, hung deploys, and no way to send input.

The contract this skill operates under is `BENTO_UNATTENDED=1`. Bento's `install.sh` checks for that env var and routes around every prompt, every confirm, every checklist. The env vars below are what drive the bootstrap:

| Env var | Purpose |
|---|---|
| `BENTO_UNATTENDED=1` | mandatory — bypasses every interactive UI element |
| `BENTO_BASE_DOMAIN` | drives every default hostname and Traefik routing |
| `BENTO_ADMIN_EMAIL` | Let's Encrypt + alert routing |
| `BENTO_ADVERTISE_ADDR` | optional — auto-detected via `bento_detect_public_ipv4` if absent |
| `BENTO_APPS` | comma-separated list of apps for Step 3 |
| `BENTO_REF` | git branch — default `stable` |
| `BENTO_ENV_<STACK>_<VAR>` | override any per-stack manifest env (e.g. `BENTO_ENV_PAPERCLIP_PAPERCLIP_HOST=…`) |

If the operator's request can't be answered with those env vars alone, **stop and ask via `AskUserQuestion` before going to the VPS**. Don't try to drive the menu interactively over SSH — that path leads to silent hangs.

Run it via SSH:

```bash
ssh "$user@$host" "\
  BENTO_UNATTENDED=1 \
  BENTO_REF=${BENTO_REF:-stable} \
  BENTO_BASE_DOMAIN=$BENTO_BASE_DOMAIN \
  BENTO_ADMIN_EMAIL=$BENTO_ADMIN_EMAIL \
  ${BENTO_ADVERTISE_ADDR:+BENTO_ADVERTISE_ADDR=$BENTO_ADVERTISE_ADDR} \
  ${BENTO_APPS:+BENTO_APPS=$BENTO_APPS} \
  bash <(curl -sSL https://raw.githubusercontent.com/felipefontoura/bento/${BENTO_REF:-stable}/boot.sh)"
```

Stream stdout. Watch for the `BENTO_REBOOT_SENTINEL` line ("Kernel or core lib was upgraded — reboot will be needed") — that's the hand-off into the post-Step-1 reboot.

# Post-hardening reboot

When Step 1 finishes, the VPS reboots automatically (sudo reboot from `lib/hardening.sh`) and a `bento-resume.service` unit fires on next boot to continue Step 2 + Step 3. Your job here:

1. SSH session drops. Note the time.
2. Poll: `until ssh -o ConnectTimeout=5 "$user@$host" exit 2>/dev/null; do sleep 5; done`. Cap at 5 minutes — VPS reboots almost always finish under 2 minutes.
3. After SSH is back, watch the resume service:
   ```bash
   ssh "$user@$host" "sudo journalctl -u bento-resume.service -f --since '5 minutes ago'"
   ```
4. Wait for one of: `Unattended install complete`, `Step 2 failed`, or `Step 3 finished with failures`.

If the resume service didn't fire (e.g., systemd unit was removed by something), manually re-trigger:
```bash
ssh "$user@$host" "BENTO_UNATTENDED=1 BENTO_APPS=$BENTO_APPS bash /root/.local/share/bento/install.sh"
```

# Failure-mode library

These are the failure modes we've seen and the recovery for each. **Always identify the failure pattern first** — don't run a recovery without matching evidence in the output.

## 409 — "stack already exists" (Portainer create rejected)

Symptom in output:
```
Portainer stack create failed (HTTP 409):
{"message":"A stack with the normalized name 'X' already exists"}
```

Cause: bento's state was wiped but the Portainer stack record survived (orphan).

Recovery:
```bash
ssh "$user@$host" '
creds=$(cat ~/.config/bento/portainer.json)
user=$(echo "$creds" | jq -r .username)
pass=$(echo "$creds" | jq -r .password)
jwt=$(curl -s -X POST http://127.0.0.1:9000/api/auth \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"$user\",\"password\":\"$pass\"}" | jq -r .jwt)

# Find the stack ID by name and DELETE it
STACK_NAME=<the stack name from the error>
stacks=$(curl -s -H "Authorization: Bearer $jwt" http://127.0.0.1:9000/api/stacks)
id=$(echo "$stacks" | jq -r ".[] | select(.Name == \"$STACK_NAME\") | .Id" | head -1)
curl -s -X DELETE "http://127.0.0.1:9000/api/stacks/$id?endpointId=1" -H "Authorization: Bearer $jwt"
'
```
Then re-run Step 3 for that stack.

## "ENOTFOUND postgres" (Swarm DNS not propagated)

Symptom: app fails first boot with `getaddrinfo ENOTFOUND postgres`.

Cause: app started before postgres' DNS alias propagated on the overlay.

Status: handled by the bash `/dev/tcp/postgres/5432` wait wrapper added to each affected stack's compose. If you see this and the wrapper isn't present, the stack needs the same treatment paperclip got in commit `f4243ca`. Otherwise wait — Swarm's restart_policy recovers within ~30s.

## "Directory nonexistent" inside container post-deploy

Symptom in install.sh output:
```
sh: 1: cannot create /<path>: Directory nonexistent
```

Cause: install.sh tried to write before the app initialised that directory.

Recovery for THIS deploy: re-run install.sh manually:
```bash
ssh "$user@$host" "BENTO_REPO_ROOT=/root/.local/share/bento \
  BENTO_STACK_KEY=<stack> \
  BENTO_STATE_FILE=/root/.config/bento/state.json \
  PAPERCLIP_HOST=... POSTGRES_PASSWORD=$(jq -r .envs.postgres.POSTGRES_PASSWORD /root/.config/bento/state.json) \
  bash /root/.local/share/bento/stacks/app/<stack>/install.sh"
```

Permanent fix: the install.sh should `mkdir -p` before writing (commit `f1a380b` pattern).

## "Failed query: select … from instance_user_roles" (post-deploy ran too early)

Symptom from CLI tools that need the app's DB schema:
```
Could not create … Failed query: select … from "<table>" …
```

Cause: install.sh ran before the app finished migrating the shared postgres schema.

Recovery for the running deploy: wait 60s and re-run install.sh manually. Permanent fix: retry loop pattern from commit `56e8174` (paperclip's bootstrap-ceo).

## "Invalid config at …" with `$meta` complaints

Cause: install.sh wrote a config the app's schema validator rejected.

Common gotchas:
- `$meta` field is missing because bash interpolated `$meta` instead of writing it literal. Escape: `"\$meta"` inside a `<<EOF` (unquoted) heredoc, or use `<<'EOF'` (quoted) to disable interpolation.
- `$meta.source` only accepts specific enum values. Inspect the running container's CLI: `node cli/.../paperclipai onboard --help` (or equivalent) to see the schema, then mirror.

# Hard-reset recipe (when you need a clean slate for ONE stack)

Tonight's wipe ritual, codified:

```bash
ssh "$user@$host" '
S=<stack-name>
sudo docker stack rm "$S" 2>&1 || true
sleep 10
sudo docker volume rm "${S}_${S}-data" 2>&1 || true

# Drop the database if the stack uses bento's shared postgres
if jq -e ".envs[\"$S\"].POSTGRES_PASSWORD" ~/.config/bento/state.json > /dev/null; then
  pw=$(jq -r .envs.postgres.POSTGRES_PASSWORD ~/.config/bento/state.json)
  sudo docker exec -e PGPASSWORD="$pw" \
    $(sudo docker ps -q -f name=postgres_postgres) \
    psql -U postgres -c "DROP DATABASE IF EXISTS \"$S\";"
fi

# Delete Portainer record by ID
pid=$(jq -r ".stacks[\"$S\"].stack_id // empty" ~/.config/bento/state.json)
if [ -n "$pid" ]; then
  creds=$(cat ~/.config/bento/portainer.json)
  u=$(echo "$creds" | jq -r .username); p=$(echo "$creds" | jq -r .password)
  jwt=$(curl -s -X POST http://127.0.0.1:9000/api/auth \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"$u\",\"password\":\"$p\"}" | jq -r .jwt)
  curl -s -X DELETE "http://127.0.0.1:9000/api/stacks/$pid?endpointId=1" \
    -H "Authorization: Bearer $jwt"
fi

# Drop bento state for the stack + any marker files
jq "del(.stacks[\"$S\"], .envs[\"$S\"])" ~/.config/bento/state.json > /tmp/s && mv /tmp/s ~/.config/bento/state.json
rm -f ~/.config/bento/"$S"-*.txt
'
```

Use this **only** when the user has agreed the data on that stack can go away.

# Success criteria (verify before reporting back)

For every chosen app, confirm in this order:

1. **Swarm**: `docker service ls --filter name=<stack>_ --format '{{.Replicas}}'` shows `1/1` for every service in that stack (some stacks like n8n have 3 services: editor + worker + webhook).
2. **HTTPS endpoint**: `curl -sI --max-time 15 https://<app>.<base_domain>/` returns a 2xx, 3xx, or app-specific expected status (paperclip serves 200 on `/`, n8n serves 200 on the editor).
3. **Database**: if the stack uses shared postgres, `psql -lt | grep -w <stack>` finds the DB on the postgres container.
4. **Stack-specific post-install artifact**:
   - paperclip: marker file at `~/.config/bento/paperclip-invite-url.txt` exists and contains a valid `pcp_bootstrap_…` URL. The first signup against that URL becomes `instance_admin`.
   - chatwoot: the install.sh ran `rails db:chatwoot_prepare`; UI returns a login form.
   - n8n: editor URL returns the n8n login.
   - Other stacks: refer to `stacks/app/<stack>/install.sh` for what it bootstrapped.

# Post-install: AI provider authentication

If the operator's `BENTO_APPS` includes any AI-runtime stack (`paperclip`, `openclaw`, `cli-proxy-api`), the install does **not** wire provider keys for them automatically. API keys go in via `scripts/bento-auth` after Step 3; subscriptions go in via each app's native sign-in.

## What `bento-auth` does

Registers **API keys only**, catalog-driven (`lib/provider-catalog.json`): you paste a provider API key, it validates it (where possible), stores it in `state.providers.<ENV>`, and propagates to every `BENTO_MANAGED` stack (and future deploys, via `stacks_build_env_payload`).

```
bento-auth                     interactive picker (lists catalog providers)
bento-auth <provider>          register a key (anthropic, openai, openrouter, zai, gemini, …)
bento-auth openai-compat <label> <base_url>   ad-hoc OpenAI-compatible endpoint
bento-auth list                registered keys (masked)
```

Full reference: `docs/reference/bento-auth.md`.

## Subscriptions are NOT bento-auth

Claude Pro/Max and ChatGPT Plus are OAuth **subscriptions** — bento-auth does not handle them (the old env-snapshot approach went stale in ~10 days). Register them via the app's own native sign-in, which refreshes the token properly:

- **openclaw** → `openclaw models auth login --provider openai` (interactive, TTY required; prints an `auth.openai.com` URL → operator authorizes in their browser → pastes the redirect URL back). The token auto-refreshes via the `offline_access` refresh token.
- **paperclip** → the bundled CLIs (`claude /login`, `opencode auth login`).

Caveat to surface if Claude-via-Hermes is the plan: Hermes calling `api.anthropic.com` is off-plan ("extra usage") even with a subscription; paperclip's `claude_local` adapter stays on-plan. (This is an app-native concern now, not a bento-auth one.)

## Triggering after unattended install

`bento` Step 3 interactive offers `bento-auth` when an AI stack is in the deploy set. Under `BENTO_UNATTENDED=1` it's **skipped** (registering a key is interactive). After a successful unattended install, end the report-back with:

> To register AI provider API keys, SSH in and run:
>
> ```
> ssh root@<host> 'bash /root/.local/share/bento/scripts/bento-auth'
> ```
>
> Pick a provider and paste the key. For **subscriptions** (ChatGPT Plus / Claude Pro/Max), use the app's native sign-in instead — e.g. `openclaw models auth login --provider openai` (it opens a URL; authorize in your browser and paste the redirect URL back).

## Ambient state.providers — bento propagates automatically

`bento-auth` writes every key to `~/.config/bento/state.json` under `providers.<ENV_VAR_NAME>` and propagates it via `docker service update --env-add` to every running BENTO_MANAGED stack; future deploys inherit it.

Operator implications to surface:

- **Set once, every env-consumer stack benefits.** No per-stack login.
- **Who consumes it.** hermes, paperclip, and generic OpenAI-compatible apps read these env vars. **openclaw does NOT** — it owns its provider config (`models.providers`) and OAuth auth-profiles; configure its providers in its Control UI / config (it can reference a propagated `${ZAI_API_KEY}` in a custom-provider definition).
- **Cosmetic.** Stacks like postgres / redis will show provider env vars in `docker service inspect`. Expected, no impact.
- **Manifest envs still win.** A stack that declares its own `OPENAI_API_KEY` in its manifest gets that value, not the ambient one. `BENTO_ENV_<STACK>_<VAR>` overrides continue to work.

# Report back to the operator

Final message (always include):

- **Portainer URL + username + password** (read `~/.config/bento/portainer.json`).
- **Per-app URL** (read `state_get .bootstrap.base_domain` and the manifest's `post_deploy_url`).
- **Bootstrap invite URLs** if any (the paperclip marker file is the canonical one).
- **Handoff HTML path** — and the `scp` line to fetch it.
- **Next step: provider auth** when any AI-runtime stack (paperclip, openclaw, cli-proxy-api) is in the deploy set. For **API keys**, include the `bento-auth` SSH oneliner. For **subscriptions** (ChatGPT Plus / Claude Pro/Max), point to the app's native sign-in (e.g. `openclaw models auth login --provider openai`) — bento-auth doesn't do subscriptions.
- **Any warnings** (DNS still propagating, memory tight, etc.).

Format the URLs as actual clickable links the user can copy. Don't paraphrase the values — the operator will paste them verbatim.

# What NOT to do

- **Never auto-flip `PAPERCLIP_AUTH_DISABLE_SIGN_UP`**, write to other apps' admin APIs without operator consent, or destroy data on a stack that has running customer traffic. Confirm before any wipe.
- **Never fabricate a recovery step.** If you hit a failure mode that doesn't match the pattern library above, stop, dump the relevant output, and ask the operator before guessing.
- **Don't skip the verification steps** because the install.sh said "is ready". Tonight's debug session showed install.sh repeatedly printed "is ready" while critical post-deploy bootstrap had silently aborted. Verify against Swarm + HTTPS + marker files, always.

# Why this skill exists

A bento install on a fresh VPS goes through many independent surfaces — cloud-init, apt, Docker, Swarm, Portainer's REST API, Let's Encrypt HTTP-01, per-app migrations, and per-app post-deploy CLIs. Most of the operator's wall-clock time is spent waiting for one of those to settle, watching for known-bad messages, and intervening with a small set of recovery recipes that look identical across runs. This skill is the loop, so the operator can drop in once at the start with a domain + app list and pick up at the end with credentials + URLs.
