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

## Commercial reality (Anthropic)

`bento-auth claude` prints this warning before launching the OAuth flow.
The intent is honesty up front, not paternalism — you read, you decide,
the script wires the token either way:

> Anthropic moved third-party apps OFF the Pro/Max quota. When Hermes
> (or any non-Claude-Code app) calls `/v1/messages` with this OAuth
> token, it consumes "extra usage" credits, NOT your monthly Pro/Max
> allowance.
>
> Inference will fail with HTTP 400 until you load credits:
> https://claude.ai/settings/usage
>
> Cost is the same per-token rate as the public API. Your Pro/Max plan
> still covers the `claude` CLI itself when invoked directly — only
> third-party callers like Hermes are routed to extra usage.

If you've already accepted this in writing for your deployment, set
`BENTO_AUTH_ASSUME_YES=1` to skip the confirm prompt. The warning still
prints — telemetry visibility matters more than friction.

OpenAI Codex via ChatGPT Plus does **not** have an analogous regime as
of 2026-06-08: Plus subscription rate limits apply uniformly to native
and third-party callers.

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
5. Update the paperclip swarm service with
   `--env-add CLAUDE_CODE_OAUTH_TOKEN=<token> --env-rm ANTHROPIC_API_KEY`.
   The replacement task picks up the new env on next restart (~30s).

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
5. Update the service env (`--env-add OPENAI_API_KEY=<token>`).
6. Live-register with Hermes by running
   `hermes auth add openai-codex --type api-key --api-key <token> --label chatgpt-plus`
   inside the current task — no restart needed.

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
