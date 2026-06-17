---
name: hermes
description: Operate the Hermes agent gateway on a bento VPS — chat with the agent over its OpenAI-compatible API, run the CLI (sessions, tools, config), and wire MCP servers so the agent gains new tools. Use when the user says "talk to my hermes agent", "call my agent from a script/bot", "add an MCP server to hermes", "give my agent the youtube/search tools", "list hermes sessions", "change the hermes model", or otherwise wants to drive a running hermes stack. Two surfaces: the HTTP API (:8642, Bearer) and the CLI (`docker exec ... hermes`). Deploying hermes itself is the deploy skill.
---

You operate a **Hermes agent gateway** already deployed by bento. Hermes runs
`gateway run` and supervises, in parallel: an OpenAI-compatible **API server**
(:8642, for bots/scripts), a **dashboard** (:9119, Traefik basic-auth gate), and
a **CLI** reachable via `docker exec`. This is day-2 work — chat, configure, and
extend the agent. You do NOT redeploy the stack — that is `/bento:deploy`.
All artifacts stay in English.

> **Where config lives.** The daemon's mutable config is `/opt/data/config.yaml`
> inside the hermes container (the `.env` next to it holds secrets, mode 0600).
> Edit config and add MCP servers **in the hermes daemon container**
> (`hermes_hermes`), never in another stack that mounts the binary read-only.

# When to invoke

- "chat with / call my hermes agent" (from a script, bot, or by hand)
- "add an MCP server to hermes" / "give the agent the <youtube/search/...> tools"
- "list / inspect sessions", "list / enable / disable tools"
- "change the model or provider", "show the hermes config"

For *getting hermes running* use `/bento:deploy`. For *provider API keys*
(OpenAI/Anthropic/OpenRouter) use `/bento:auth` — hermes reads those propagated envs.

# Discover the instance — don't hardcode

```bash
ssh "$user@$host" "jq -r '.envs.hermes.HERMES_API_HOST' \$HOME/.config/bento/state.json"  # API gateway host
ssh "$user@$host" "jq -r '.envs.hermes.HERMES_HOST'     \$HOME/.config/bento/state.json"  # dashboard host
ssh "$user@$host" "jq -r '.envs.hermes.HERMES_API_KEY'  \$HOME/.config/bento/state.json"  # Bearer for the API (don't echo)
ssh "$user@$host" "jq -r '.envs.hermes.HERMES_MODEL_NAME' \$HOME/.config/bento/state.json" # advertised model name
```

API base URL = `https://<HERMES_API_HOST>`. Container (conventional in bento
swarm): `hermes_hermes.1.*`.

```bash
hermes_container() { ssh "$user@$host" "docker ps --filter name=hermes_hermes -q | head -1"; }
hx() { ssh "$user@$host" "docker exec \$(docker ps -qf name=hermes_hermes) hermes $*"; }  # run a hermes CLI subcommand
```

# Two surfaces

**A — OpenAI-compatible API (:8642, Bearer).** This is how external consumers
(bots, scripts, the paperclip `hermes_local` adapter) talk to the agent. Standard
`/v1/chat/completions` and `/v1/models`; auth is `Authorization: Bearer
<HERMES_API_KEY>`. The advertised model name is `HERMES_MODEL_NAME` (default
`hermes-agent`) — that string, not the underlying provider model:

```bash
curl -s "https://$HERMES_API_HOST/v1/chat/completions" \
  -H "authorization: Bearer $HERMES_API_KEY" -H "content-type: application/json" \
  -d '{"model":"'"$HERMES_MODEL_NAME"'","messages":[{"role":"user","content":"ping"}]}'
```

**B — CLI (`docker exec`).** Everything operational. Key subcommands:

| Goal | Command |
|---|---|
| One-shot chat (scope tools with `-t`) | `hermes chat -t web,memory "..."` |
| Sessions | `hermes sessions list` / `show <id>` |
| Tools (built-in + MCP) | `hermes tools list` / `enable <t>` / `disable <t>` |
| MCP servers | `hermes mcp list` / `add` / `test` / `catalog` / `install <name>` / `login` |
| Config | inspect / edit `/opt/data/config.yaml` |

Tools are addressable as `<server>:<tool>` for MCP (e.g. `youtube:YouTube_Analytics`)
and by simple name for built-ins (`web`, `memory`). Per-call scoping is
`hermes chat -t <comma-separated>`.

# Wire an MCP server (give the agent new tools)

Hermes is itself an MCP client. Add a server in the daemon container:

```bash
# HTTP / SSE server (with optional bearer header):
hx mcp add <name> --url <endpoint> --header "Authorization: Bearer <token>"
# stdio server:
hx mcp add <name> --command npx --args "-y,@scope/mcp-server@<pinned>"
# one-click from the Nous catalog:
hx mcp install <name>
```

Non-interactive add over SSH (the token getpass reads from stdin when there's no
TTY): `printf "Y\n<token>\nY\n" | hermes mcp add <name> --url <ep>`. Pin stdio
package versions — `latest` can break silently at boot.

⚠️ **CRITICAL — a newly-added MCP only surfaces to the model after a gateway
RESTART.** Add it after boot and you get `Unknown toolset`: the tools are
fetched but never enter the model's prompt (the model says "I don't have that
tool"). This is not a transport/count/schema problem — it's the boot-time
toolset registration. Servers that worked were present *before* boot.

Clean restart in swarm:
```bash
ssh "$user@$host" "docker service update --force hermes_hermes"
```
**Never** `docker restart` a swarm task — it orphans the container and (for a
Telegram-connected agent) double-binds the poller.

# Choosing the model / provider

The provider and model live in `/opt/data/config.yaml` (`model:` +
`custom_providers:` for any OpenAI-compatible endpoint like Z.ai/glm, OpenRouter,
etc.). Provider keys can come from `/bento:auth` propagation or be referenced as
`${ENV}` from the `.env`. After editing config, force-restart (above) for it to
take effect. Keep keys as `${ENV}` refs — never hardcode a key into the YAML on disk.

# Gotchas

- **Scoping is global by default** (`inherit_mcp_toolsets: true`) — every agent/
  session inherits all MCP tools (and their credentials). Hard-scope per use with
  `hermes chat -t <toolset>`; soft-scope by instruction until then.
- **Dashboard WebSocket auth** is layered: basic-auth gates the HTML, a
  `?token=<session>` gates the WS (Chrome won't forward basic-auth on a WS
  upgrade). Don't strip the basic-auth router expecting WS to "just work".
- **The API model field is the advertised name** (`HERMES_MODEL_NAME`), not the
  provider's model id — sending the wrong string 404s the model.

# Report back

- What changed (MCP added + that you force-restarted; config edited; tool toggled).
- Verify with `hermes mcp list` / `hermes tools list` and show it.
- Confirm any secret stayed out of the output.

Upstream: `nousresearch/hermes-agent`. `hermes --help` / `hermes <cmd> --help`
on the box is the source of truth for current flags.
