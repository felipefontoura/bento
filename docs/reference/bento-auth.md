# `bento-auth` — AI provider authentication

`bento-auth` is the one-stop CLI for logging your AI-provider OAuth
subscriptions (and one-shot API keys) into a deployed bento. It runs
on the VPS host, drives the device-flow login that the paperclip image's
bundled CLIs already implement (`claude`, `opencode`), then wires the
resulting token into the paperclip swarm service so the Hermes runtime
picks it up.

The script lives at `scripts/bento-auth` and is also reachable from the
main `bento` menu under **Authenticate AI providers** (`install.sh` line
hosts a small `auth_run` wrapper).

---

## Supported providers (MVP)

| ID | Provider | Subscription used | Notes |
|---|---|---|---|
| `claude` | Anthropic (Claude) | Pro / Max | **Anthropic charges third-party apps to "extra usage"** — see [Commercial reality](#commercial-reality-anthropic) below. |
| `openai-codex` | OpenAI Codex via ChatGPT | Plus ($20/mo) | Only `gpt-5.4` model accepted on Plus. |

Other OAuth providers (Gemini, Qwen, etc.) are easy to add — open an
issue with a one-line "I want X" and we'll wire it.

---

## Usage

```bash
# Interactive picker (default)
bento-auth

# Direct subcommands
bento-auth claude
bento-auth openai-codex
bento-auth list                # tabular view of authenticated providers
bento-auth status claude       # exit 0 if valid, non-zero if expired
bento-auth status openai-codex

bento-auth --help              # full reference
```

When run from a fresh shell on the VPS, `bento-auth` finds itself
relative to `${BENTO_REPO_ROOT}` (default `/root/.local/share/bento`).
If you cloned bento elsewhere, set `BENTO_REPO_ROOT` before invoking.

### Re-running after token expiry

OAuth access tokens for both Anthropic and OpenAI Codex expire in
~10 days. `bento-auth status <provider>` returns non-zero when a token
is expired or absent; pipe it into a healthcheck or just re-run
`bento-auth <provider>` and complete the device flow again. The MVP
does **not** auto-refresh — see issue [#19](https://github.com/felipefontoura/bento/issues/19)
for the planned enhancement.

---

## Anthropic third-party policy (as of 2026-06-08)

Anthropic currently splits requests against `api.anthropic.com/v1/messages` into two billing buckets based on the **caller fingerprint**, not on the token. The OAuth token is the same in both cases, but the regime applied to the request is different:

| Caller | Fingerprint Anthropic sees | Billing |
|---|---|---|
| `claude` CLI itself (interactive or `claude -p ...`) | Native Claude Code | **On-plan** (Pro/Max covers) |
| Paperclip's `claude_local` adapter | Native Claude Code (spawns `claude` as a subprocess) | **On-plan** |
| Hermes Agent `--provider anthropic` | Third-party HTTP client (Hermes spoofs the `user-agent` and `anthropic-beta` headers, but Anthropic still distinguishes it) | **Extra usage** (pay-as-you-go, public per-token rate) |
| Any other third-party client (Continue, Aider, Cursor extensions, …) | Third-party HTTP client | **Extra usage** |

Off-plan requests fail with `HTTP 400` and the literal text:

> Third-party apps now draw from your extra usage, not your plan limits. Add more at claude.ai/settings/usage and keep going.

Auth succeeded — the request just got routed off-plan. Load credits at https://claude.ai/settings/usage to unblock the third-party path, or drive your agents through paperclip's `claude_local` adapter to stay on-plan.

### Why bento-auth still wires the token unconditionally

The token is useful regardless of which path you choose:

- **On-plan paths** (the `claude` CLI itself, `claude_local` adapter): the token in `~/.claude/.credentials.json` is what those subprocess invocations consume directly. `bento-auth claude` writes it there.
- **Off-plan paths** (Hermes `anthropic` provider, etc.): the token in `state.providers.CLAUDE_CODE_OAUTH_TOKEN` is what bento propagates as an env var so those callers can use it the moment you load credits.

`bento-auth claude` prints the warning verbatim before launching the device flow and asks for explicit y/N confirmation. Set `BENTO_AUTH_ASSUME_YES=1` to skip the prompt — the warning still prints, because the rule is "no surprise bills," not "no friction."

### Practical guidance for Base25-style agent fleets

- **Default driver**: OpenAI Codex via ChatGPT Plus subscription (`--provider openai-codex --model gpt-5.4`). Plus covers third-party callers uniformly; no off-plan trap. Recommended primary path for agents until/unless this changes.
- **When you specifically need Claude**: either load some "extra usage" credit at https://claude.ai/settings/usage and use Hermes `--provider anthropic`, OR route that single agent through paperclip's `claude_local` adapter (stays on-plan but bypasses Hermes — no MCP, no sub-agent delegation, etc., for that agent).

### This is an Anthropic policy, not a bento bug

This document tracks the policy as of 2026-06-08. If Anthropic changes it (e.g. opens Pro/Max to all OAuth callers, or differentiates by app registration), the warning in `bento-auth claude` and this section will be updated to match. Open an issue with a fresh `HTTP 400` body if you observe a change.

OpenAI Codex via ChatGPT Plus does **not** have an analogous regime as of 2026-06-08: Plus rate limits apply uniformly to native and third-party callers.

---

## What the script actually does

### `bento-auth claude`

1. Print the commercial-policy warning and prompt for confirmation
   (skipped when `BENTO_AUTH_ASSUME_YES=1`).
2. Find the running `paperclip_paperclip` container.
3. Run `docker exec -it ... claude /login` — the bundled Claude CLI
   walks the user through the device flow (URL in stdout, code from
   user, persists `~/.claude/.credentials.json` on success).
4. Read `claudeAiOauth.accessToken` from that JSON.
5. **Persist to bento state** at `~/.config/bento/state.json` under
   `providers.CLAUDE_CODE_OAUTH_TOKEN` and **drop the mutually exclusive
   `ANTHROPIC_API_KEY`** from state (see the dual-header invariant
   below).
6. **Propagate to every running stack** with label `BENTO_MANAGED=true`
   via `docker service update --env-rm ANTHROPIC_API_KEY --env-add
   CLAUDE_CODE_OAUTH_TOKEN=<token>`. Future deploys of any stack
   automatically inherit the token via `stacks_build_env_payload`.

The choice of `CLAUDE_CODE_OAUTH_TOKEN` instead of `ANTHROPIC_API_KEY`
is load-bearing — see [Why `CLAUDE_CODE_OAUTH_TOKEN` and not `ANTHROPIC_API_KEY`](#why-claude_code_oauth_token-and-not-anthropic_api_key)
below.

### `bento-auth openai-codex`

1. Print a no-cost-surprise info block (Plus subscription continues to
   cover Codex calls).
2. Find the running `paperclip_paperclip` container.
3. Run `docker exec -it ... opencode auth login openai` — the bundled
   `opencode` CLI walks the user through the OAuth device flow and
   persists `~/.local/share/opencode/auth.json`.
4. Read `openai.access` from that JSON.
5. **Persist to bento state** under `providers.OPENAI_API_KEY` and
   propagate to every `BENTO_MANAGED=true` stack.
6. Live-register with Hermes by running
   `hermes auth add openai-codex --type api-key --api-key <token> --label chatgpt-plus`
   inside the current paperclip task — no restart needed for the
   immediate live registration.

### `bento-auth list` and `status <provider>`

Read the same credential files inside the container, decode JWT `exp`
claims where present (Codex tokens), and print a relative-expiry table:

```
provider         source       expires                        subject
--------         ------       -------                        -------
claude           claude-cli   in 8d 17h                      (Anthropic OAuth)
openai-codex     opencode     in 5d 2h                       (ChatGPT Plus OAuth)
```

`status <provider>` returns:

| Exit code | Meaning |
|---|---|
| 0 | token present and valid |
| 2 | bad usage |
| 3 | paperclip container not running |
| 4 | no credentials for that provider |
| 5 | token expired |

---

## Why `CLAUDE_CODE_OAUTH_TOKEN` and not `ANTHROPIC_API_KEY`

Tutorials online (and the bento README itself, before this script) tell
you to `export ANTHROPIC_API_KEY=...` and call it a day. With a
console-issued API key (`sk-ant-api...`) that works. With a Claude OAuth
token (`sk-ant-oat...`) it triggers a subtle dual-header bug:

The Anthropic Python SDK implicitly reads `ANTHROPIC_API_KEY` from the
environment and emits an `x-api-key: <token>` header on every request.
Independently, Hermes's `anthropic_messages` adapter detects the
`sk-ant-oat` prefix, recognises an OAuth token, and emits an
`Authorization: Bearer <token>` header. The result: the request goes
out with **both** headers set to the same OAuth token.

Anthropic's API prioritises `x-api-key`, tries to validate it as a
console API key, sees the wrong prefix, and rejects with
`401 invalid x-api-key`. The OAuth Bearer header is never consulted.

Setting `CLAUDE_CODE_OAUTH_TOKEN` instead means the Anthropic SDK never
auto-injects `x-api-key` (the SDK doesn't know about that env var) —
Hermes is the only writer of an auth header, and the Bearer path
succeeds.

This is encapsulated inside `bento-auth claude` so the operator never
has to think about it. The `--env-rm ANTHROPIC_API_KEY` in the service
update guards against a pre-existing leftover.

---

## Ambient propagation — state.providers

`bento-auth` writes every token to `~/.config/bento/state.json` under
`providers.<ENV_VAR_NAME>` and propagates it to every running stack
labeled `BENTO_MANAGED=true`. The key is the env var name itself
(`CLAUDE_CODE_OAUTH_TOKEN`, `OPENAI_API_KEY`, …) — encapsulating the
auth-mode invariant at the state layer means downstream stacks just
read the env var they expect, no provider abstraction in the middle.

```json
// ~/.config/bento/state.json
{
  "providers": {
    "CLAUDE_CODE_OAUTH_TOKEN": "sk-ant-oat01-...",
    "OPENAI_API_KEY":          "eyJhbGc...",
    "OPENROUTER_API_KEY":      "sk-or-v1-..."
  }
}
```

When `lib/stacks.sh::stacks_build_env_payload` constructs the env array
for a new (or re-)deployed stack, it injects every entry in
`state.providers` that the stack's own manifest didn't already declare.
Stacks that don't use them simply ignore them.

### Override semantics

- **Manifest envs win on collision.** A stack that declares
  `OPENAI_API_KEY` in its own `manifest.json` env list (with an operator
  prompt) gets that value, not the ambient one. The per-stack
  `BENTO_ENV_<STACK>_<VAR>` override knob already works because
  manifest envs are resolved AFTER `state.providers` are injected (but
  the dedup logic keeps the manifest value).
- **Cosmetic pollution.** Stacks like postgres, redis, traefik will
  show provider env vars in their `docker service inspect` output. No
  technical impact — they ignore env vars they don't read.

### Switching OAuth ↔ API key for the same provider

For Anthropic specifically, OAuth (`CLAUDE_CODE_OAUTH_TOKEN`) and API
key (`ANTHROPIC_API_KEY`) cannot coexist — the dual-header trap below
makes them mutually exclusive. `bento-auth claude` always drops the
other variant from state AND removes it from every BENTO_MANAGED stack
before propagating the new one.

## Limits of the MVP

Deliberately out of scope, all tracked separately:

- **Auto-refresh cron** — manual re-run every ~10 days. See issue
  [#19](https://github.com/felipefontoura/bento/issues/19).
- **Web UI** — CLI first. Web only if there's real demand.
- **Multi-tenant** (per-agent OAuth tokens vs one service-wide token) —
  current model is one token per provider, swarm-wide.
- **Other OAuth providers** (Gemini, Qwen, MiniMax, Z.ai) — add when
  asked.

---

## Troubleshooting

**`bento-auth claude` says "paperclip container not running"**
Step 3 of the bento installer didn't deploy paperclip (or it crashed).
Run `bento` → Step 3 → re-deploy paperclip; retry.

**`claude /login` exits without writing credentials**
The most common cause is a stale Anthropic session in the user's
browser. Open the login URL in a private window and re-run.

**`HTTP 400 — Third-party apps now draw from your extra usage`**
This is exactly what the commercial warning told you would happen. Load
credits at https://claude.ai/settings/usage. The OAuth wiring is fine.

**`HTTP 401 invalid x-api-key` after `bento-auth claude`**
A leftover `ANTHROPIC_API_KEY` env on the service. Run
`docker service inspect paperclip_paperclip --format '{{json .Spec.TaskTemplate.ContainerSpec.Env}}' | jq`
and confirm `ANTHROPIC_API_KEY` is absent. If present, remove with
`sudo docker service update --env-rm ANTHROPIC_API_KEY paperclip_paperclip`.

**`bento-auth status <prov>` reports EXPIRED but `claude` CLI still works**
The `claude` CLI auto-refreshes its own credentials JSON on demand, but
the env var we injected into the swarm service is a snapshot. Re-run
`bento-auth claude` to push the refreshed token through.

---

## Related

- Operational journal: `40-journal/operational/2026-06-08.md` in the
  `my-second-brain` vault — full discovery / debugging trail behind the
  design.
- Enhancement: issue [#19](https://github.com/felipefontoura/bento/issues/19)
  — auto-refresh cron.
