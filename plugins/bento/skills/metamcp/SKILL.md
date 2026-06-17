---
name: metamcp
description: Operate MetaMCP on a bento VPS — add MCP servers to the gateway, group them into namespaces, create unified public endpoints, manage API keys, and get the URL to plug your tools into Claude/Cursor/an agent. Use when the user says "add an MCP server to my gateway", "group my MCP tools", "create an MCP endpoint", "create a namespace", "get the URL to plug my MCP tools into Claude or Cursor or an agent", "give my agent a bundle of MCP tools", "create an API key for my MCP endpoint", "set up MetaMCP", or otherwise wants to drive a running MetaMCP stack. Two surfaces: the web admin UI (primary, all CRUD) and tRPC procedures callable from the box (automation). Deploying MetaMCP itself is /bento:deploy.
---

You operate a **MetaMCP gateway** already deployed by bento. MetaMCP aggregates
multiple MCP servers (stdio or HTTP/SSE) into unified public endpoints, each
protected by API-key or OAuth auth. Day-2 work only — you configure servers,
namespaces, endpoints, and API keys. For deploying the stack use `/bento:deploy`.

**Docs (source of truth):** https://github.com/metatool-ai/metamcp · https://docs.metamcp.com
The **web UI** is the authoritative management surface — use it for all CRUD.

> **Management surface reality.** MetaMCP's backend is a **tRPC API** (`/trpc`),
> consumed by the Next.js web UI. There is no documented public REST API with
> stable versioned routes. For interactive configuration, use the web UI (always
> safe). For automation, tRPC procedures are callable but internal and
> unversioned — verify schemas against the running container before scripting.

# When to invoke

- "add / list MCP servers" · "create a namespace / endpoint" · "create / rotate an API key"
- "get the URL to plug into Claude / Cursor / my agent"
- "wire MetaMCP into hermes"

For *getting MetaMCP running* use `/bento:deploy`. For *AI provider keys* use `/bento:auth`.

# Discover the instance — don't hardcode

```bash
ssh "$user@$host" "jq -r '.envs.metamcp.METAMCP_HOST' \$HOME/.config/bento/state.json"
```

Base URL = `https://<METAMCP_HOST>`. The backend listens on internal port **12008**.
Container name (conventional in bento swarm): `metamcp_*.1.*`

```bash
metamcp_container() { ssh "$user@$host" "docker ps --filter name=metamcp_ -q | head -1"; }
```

Health probe (resolves only after DB migrations + session pool init):

```bash
curl -s "https://$METAMCP_HOST/health"   # → 200 OK when ready
```

# Auth model

**Admin UI** — Better Auth sessions. First visitor self-registers as admin via
`https://<METAMCP_HOST>` → "Create account". Session-cookie based; no seeded credentials.

**MCP endpoint access** — API keys (`sk_mt_...`). Create in the UI: Settings → API Keys.
The key is shown **only once** — copy immediately. Use as `Authorization: Bearer sk_mt_<key>`.

**SSE quirk:** query-param auth (`?api_key=`) does **not** work for SSE transport —
use `Authorization: Bearer` header regardless of transport.

**tRPC automation** — requires a valid session cookie from `POST /api/auth/sign-in/email`.
Cleanest automation path: drive from inside the container against the loopback (`127.0.0.1:12008`).

> **Honesty gap.** tRPC routes (`/trpc/mcpServers.create`, etc.) exist and are callable
> but are internal and not versioned as a public API. For bulk config, prefer the UI's
> "Bulk Import" over raw tRPC scripting. Inspect before automating:
> ```bash
> ssh "$user@$host" "docker exec \$(docker ps -qf name=metamcp_) \
>   find /app/apps/backend/src/trpc -name '*.impl.ts' | head -20"
> ```

# Concept hierarchy

```
MCP Servers  →  added to  →  Namespaces  →  exposed via  →  Endpoints
                                                              (public URL + API key)
```

All CRUD for each layer lives in the **web UI**. Non-obvious fields to watch:
- **Servers:** pin STDIO package versions (not `@latest`); for HTTP types set `url` + `bearerToken`.
- **Namespaces:** you can enable/disable individual servers and tools post-creation; use "Refresh tools" after upstream changes.
- **Endpoints:** `name` is a globally unique slug that becomes the URL path — **immutable after creation**, choose carefully.
- **API keys:** no scope field; any valid key grants access to any API-key-protected endpoint.

For full field reference, see the web UI and https://docs.metamcp.com.

# Endpoint URL shapes

```
https://<METAMCP_HOST>/metamcp/<endpoint-name>/mcp     # Streamable HTTP (recommended)
https://<METAMCP_HOST>/metamcp/<endpoint-name>/sse     # SSE (for clients requiring it)
https://<METAMCP_HOST>/metamcp/<endpoint-name>/api     # OpenAPI / REST-style

# Loopback test (inside VPS, no TLS):
http://127.0.0.1:12008/metamcp/<endpoint-name>/mcp
```

# Wire the endpoint into a client

**Claude Desktop** (`claude_desktop_config.json`) — requires SSE or stdio, bridge with `mcp-proxy`:
```json
{
  "mcpServers": {
    "my-gateway": {
      "command": "mcp-proxy",
      "args": ["https://<METAMCP_HOST>/metamcp/<endpoint-name>/sse"],
      "env": { "API_KEY": "sk_mt_<YOUR_KEY>" }
    }
  }
}
```

**Cursor** (`mcp.json`):
```json
{
  "mcpServers": {
    "my-gateway": {
      "url": "https://<METAMCP_HOST>/metamcp/<endpoint-name>/mcp",
      "headers": { "Authorization": "Bearer sk_mt_<YOUR_KEY>" }
    }
  }
}
```

**Hermes agent** (from inside the hermes container):
```bash
hermes mcp add metamcp-gateway \
  --url "https://<METAMCP_HOST>/metamcp/<endpoint-name>/mcp" \
  --header "Authorization: Bearer sk_mt_<YOUR_KEY>"
# Force-restart so the toolset enters the model's prompt:
ssh "$user@$host" "docker service update --force hermes_hermes"
```

See `/bento:hermes` for the full MCP-wiring flow and the critical restart requirement.

# Gotchas

- **SSE + `?api_key=`** don't mix — only Bearer header works on SSE (see Auth above).
- **Endpoint `name` is immutable** — changing it breaks all client configs; duplicates fail validation.
- **Shared Postgres** — MetaMCP uses a DB named `metamcp` on the bento-managed `postgres` stack. Don't drop it; check `docker service ls --filter name=postgres_postgres` on connection errors.
- **STDIO runtimes run inside the MetaMCP container** — if a stdio server fails, `exec` into the container and run the command manually to see the real error.
- **Health after boot** — `/health` returns 200 only after DB migrations + session pool init (~3s delay by design). Wait before sending traffic after a restart.

# Report back

- What was created/modified (servers, namespaces, endpoints with their public URLs).
- Confirm endpoint reachable: `curl -s https://<host>/metamcp/<name>/mcp -H "Authorization: Bearer <key>"`.
- If an API key was created: confirm the user copied it (unretrievable after creation).
