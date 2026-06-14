# `bento-auth` — AI provider API keys

`bento-auth` is the one-stop CLI for registering **AI-provider API keys** into
a deployed bento and propagating them to every running stack. You paste a key,
it validates it (where possible), stores it in `~/.config/bento/state.json`
under `providers.<ENV_VAR>`, and pushes it to every `BENTO_MANAGED` service
(plus all future deploys, via `lib/stacks.sh::stacks_build_env_payload`).

The script lives at `scripts/bento-auth` and is also reachable from the main
`bento` menu under **Authenticate AI providers** (`install.sh` hosts a small
`auth_run` wrapper).

> **Scope: classic API keys only.** Subscriptions (Claude Pro/Max, ChatGPT
> Plus) are **out of scope** — they are OAuth, and each app's *native* sign-in
> handles them far better (it refreshes the token; bento-auth's old
> env-snapshot went stale in ~10 days). Use the app's own flow:
> - **openclaw** → `openclaw models auth login --provider openai` (and friends)
> - **paperclip** → the bundled CLIs (`claude /login`, `opencode auth login`)

---

## Provider catalog

Providers are declared as data in `lib/provider-catalog.json` — **adding one is
a JSON edit, not a code change.** Two formats:

- **`native`** — the apps recognise a dedicated key env var built-in (no base
  URL). Set the key, done. These all **coexist**.
- **`compat`** — OpenAI-compatible but NOT built-in, so it gets a dedicated key
  env **plus** a dedicated base-URL env (e.g. `ZAI_API_KEY` + `ZAI_BASE_URL`).
  Wire it in your app as a custom provider whose `apiKey`/`baseUrl` reference
  those vars. It lives in its OWN slot — never the shared OpenAI slot — so
  z.ai/Kimi/Qwen/MiniMax coexist with each other and with the real OpenAI.

| ID | Provider | Format | Env var(s) |
|---|---|---|---|
| `anthropic` | Anthropic (Claude API key) | native | `ANTHROPIC_API_KEY` |
| `openai` | OpenAI (Platform API key) | native | `OPENAI_API_KEY` |
| `openrouter` | OpenRouter | native | `OPENROUTER_API_KEY` |
| `opencode` | OpenCode (Zen + Go) | native | `OPENCODE_API_KEY` (one key, both catalogs) |
| `gemini` | Google Gemini (API key) | native | `GEMINI_API_KEY` |
| `deepseek` | DeepSeek | native | `DEEPSEEK_API_KEY` |
| `groq` | Groq | native | `GROQ_API_KEY` |
| `xai` | xAI Grok | native | `XAI_API_KEY` |
| `mistral` | Mistral | native | `MISTRAL_API_KEY` |
| `zai` | z.ai GLM Coding Plan | compat | `ZAI_API_KEY` + `ZAI_BASE_URL` |
| `kimi` | Kimi (Moonshot) | compat | `KIMI_API_KEY` + `KIMI_BASE_URL` |
| `qwen` | Qwen (DashScope) | compat | `QWEN_API_KEY` + `QWEN_BASE_URL` |
| `minimax` | MiniMax | compat | `MINIMAX_API_KEY` + `MINIMAX_BASE_URL` |

The **shared `OPENAI_API_KEY` + `OPENAI_BASE_URL` slot** is used only by the
real OpenAI (`openai`) and by the ad-hoc `bento-auth openai-compat` command
(below) — a `compat` catalog entry never touches it.

> The `anthropic`/`openai` entries are **classic console/platform API keys**
> (pay-as-you-go), NOT the Pro/Max/Plus subscriptions. For a subscription use
> the app's native sign-in (see the scope note above).

---

## Usage

```bash
# Interactive picker
bento-auth

# Register a catalog provider (prompts for the key, hidden)
bento-auth zai
bento-auth openrouter
bento-auth openai

# Any OpenAI-compatible endpoint not in the catalog (uses the shared slot)
bento-auth openai-compat my-llm https://api.example.com/v1

# Show registered keys (masked)
bento-auth list

bento-auth --help
```

When run from a fresh shell on the VPS, `bento-auth` finds itself relative to
`${BENTO_REPO_ROOT}` (default `/root/.local/share/bento`). If you cloned bento
elsewhere, set `BENTO_REPO_ROOT` before invoking.

---

## What the script does

For each catalog provider, `bento-auth <id>`:

1. Prints where to get the key (`signup_url`) and, for `compat` providers, the
   env vars to reference in your app's custom-provider config.
2. Prompts for the key (hidden input).
3. **Validates** it — `GET <validate_url>` with `Authorization: Bearer <key>`,
   expecting 2xx. Non-fatal: if it fails you're asked whether to store anyway
   (skip the prompt with `BENTO_AUTH_ASSUME_YES=1`); some providers have no
   validate endpoint and are stored without a check.
4. **Persists** to `state.providers.<ENV>` (and `<BASE_URL_ENV>` for `compat`).
5. **Propagates** to every running `BENTO_MANAGED` stack via
   `auth_propagate_state_providers` (`docker service update --env-add`), and to
   future deploys via `stacks_build_env_payload`.

---

## Ambient propagation — `state.providers`

`bento-auth` writes every key to `~/.config/bento/state.json` under
`providers.<ENV_VAR_NAME>` and propagates it to every running stack labeled
`BENTO_MANAGED=true`. The key is the env var name itself — downstream stacks
just read the env var they expect, no provider abstraction in the middle.

```json
{
  "providers": {
    "OPENROUTER_API_KEY": "sk-or-v1-…",
    "ZAI_API_KEY":        "…",
    "ZAI_BASE_URL":       "https://api.z.ai/api/coding/paas/v4"
  }
}
```

`auth_propagate_state_providers` accepts one or more env names to `--env-rm`
before the adds, so a slot can be vacated cleanly when switching providers.

### Who actually consumes the propagated env

Propagation reaches every `BENTO_MANAGED` container, but only stacks that
**read the env var** benefit:

- **hermes**, **paperclip**, generic OpenAI-compatible apps, n8n (via `$env`
  expressions) — consume standard provider env vars. bento-auth's "set once,
  propagate everywhere" is a real win here.
- **openclaw** — does **not** consume these. It manages providers in its own
  config (`models.providers` in `openclaw.json`) and its own OAuth auth-profiles.
  For openclaw, configure providers in its Control UI / config; bento-auth's
  propagated env vars are ignored. (You *can* reference a propagated key like
  `${ZAI_API_KEY}` inside an openclaw custom-provider definition.)

---

## Adding a provider

Append one object to `lib/provider-catalog.json`:

```json5
{
  "id": "groq",
  "label": "Groq",
  "format": "native",           // 'native' (dedicated env) or 'compat' (env + base_url)
  "env": "GROQ_API_KEY",
  "base_url": "",               // compat only
  "base_url_env": "",           // compat only, e.g. GROQ_BASE_URL
  "signup_url": "https://console.groq.com/keys",
  "validate_url": "https://api.groq.com/openai/v1/models",  // empty to skip
  "note": ""
}
```

No code change — `bento-auth <id>`, the interactive picker, and `--help` pick
it up automatically.

---

## Troubleshooting

**Validation FAILED but the key is good** — the endpoint may not expose
`/models`, may not accept Bearer (e.g. Anthropic uses `x-api-key`), or egress
is blocked. Validation is non-fatal: answer `y` to store anyway, or set the
catalog entry's `validate_url` to `""`.

**A stack doesn't pick up the key** — confirm the stack actually reads that env
var (see "Who actually consumes" above). openclaw, in particular, does not.

**Switching a `compat`/shared-slot provider** — registering a new one
overwrites the previous occupant of that slot. `native` providers each have
their own env and coexist.

---

## Related

- Provider catalog: `lib/provider-catalog.json`
- Engine: `lib/auth-helpers.sh` (catalog read, validation, state + propagation)
- Env injection at deploy: `lib/stacks.sh::stacks_build_env_payload`
