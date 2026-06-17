---
name: n8n
description: Operate n8n (workflow automation) on a bento VPS THROUGH the n8n-mcp server — build, validate, deploy, and manage automation workflows by driving the n8n-mcp tools, not the raw REST API. Use when the user says "build an n8n workflow", "automate this with n8n", "add a node to my workflow", "fix my n8n workflow", "list/run my workflows", "connect a webhook", or describes an automation to wire up. Work via the n8n-mcp MCP tools (node schemas + validation baked in) — never hand-roll the n8n REST API. Deploying n8n/n8n-mcp themselves is the deploy skill.
---

You operate an **n8n** instance already deployed by bento — but you drive it
**through the `n8n-mcp` server**, never through n8n's raw REST API. bento
deploys both stacks together: `n8n` (editor + worker + webhook) and `n8n-mcp`
(an MCP server that wraps n8n with full node schemas and validation). This is
day-2 work: building and operating workflows. You do NOT redeploy the stacks —
that is `/bento:deploy`. All artifacts stay in English.

> **Golden rule — operate via `n8n-mcp`, not the raw API.** The n8n-mcp tools
> carry every node's property schema, run validation before deploy, and encode
> the tedious API rules (connection shapes, expression syntax, credential
> wiring). Hand-rolling `POST /api/v1/workflows` skips all of that and produces
> workflows that import but don't run. Use the MCP tools.

# When to invoke

- "build / automate <X> in n8n", "wire a workflow", "add/configure a node"
- "validate / fix / autofix my workflow", "why doesn't my workflow run"
- "list / run / inspect my workflows and executions"

For *getting n8n running* use `/bento:deploy`.

# Discover the instance — don't hardcode

```bash
ssh "$user@$host" "jq -r '.envs.\"n8n-mcp\".N8N_MCP_HOST'       \$HOME/.config/bento/state.json"  # MCP endpoint host
ssh "$user@$host" "jq -r '.envs.\"n8n-mcp\".N8N_MCP_AUTH_TOKEN' \$HOME/.config/bento/state.json"  # Bearer (don't echo)
ssh "$user@$host" "jq -r '.envs.n8n.N8N_HOST'                   \$HOME/.config/bento/state.json"  # editor (UI)
ssh "$user@$host" "jq -r '.envs.n8n.N8N_WEBHOOK_HOST'           \$HOME/.config/bento/state.json"  # webhook host
```

- MCP endpoint: `https://<N8N_MCP_HOST>/mcp` (Streamable HTTP) or `/sse`. Auth:
  `Authorization: Bearer <N8N_MCP_AUTH_TOKEN>`.
- The n8n-mcp talks to n8n internally with an **n8n API key** (a JWT minted in
  n8n → Settings → n8n API), wired at deploy as `N8N_MCP_N8N_API_KEY`. Without
  it the `n8n_*` API tools are disabled and only the read-only node/template
  tools work.
- Editor UI = `https://<N8N_HOST>`. Webhooks/MCP-trigger workflows are served
  from `https://<N8N_WEBHOOK_HOST>` — **a different host than the editor**.

# Connect the MCP server to your client

The tools become available once the n8n-mcp endpoint is wired into your MCP
client. In Claude Code: `claude mcp add n8n-mcp --transport http
https://<N8N_MCP_HOST>/mcp --header "Authorization: Bearer <token>"`. In hermes:
`hermes mcp add n8n --url https://<N8N_MCP_HOST>/mcp --header "Authorization:
Bearer <token>"` then force-restart the gateway (see `/bento:hermes`).

# The standard workflow pattern (always this order)

The n8n-mcp surface is ~21 tools. To build or change a workflow:

1. **Find** the node — `search_nodes({query})` (keyword / category / "AI langchain").
2. **Configure** — `get_node({nodeType, detail:'standard'})` **FIRST** (~1-2KB,
   required fields). Escalate to `detail:'full'` only if standard is
   insufficient; `mode:'docs'` for prose; `mode:'search_properties'` to find a
   property.
3. **Validate** — `validate_node({nodeType, config})` per node, then
   `validate_workflow({workflow})` for the whole graph (nodes + connections +
   expressions). Validate BEFORE deploying.
4. **Deploy** — `n8n_create_workflow` (new) or `n8n_update_partial_workflow`
   (incremental diff — prefer it over full replacement for edits).

The ~21 tools group into: **discovery** (`search_nodes`), **config**
(`get_node`), **validation** (`validate_node`, `validate_workflow`),
**templates** (`search_templates`/`get_template`/`n8n_deploy_template`), and the
**`n8n_*` API tools** (create / update-full / update-partial / get / list /
delete / validate / autofix / test / executions / versions / health). Don't
memorize the surface — call `tools_documentation` (no args for the quick
reference, or `{topic:'<tool>', depth:'full'}` for one tool); it's the live
source of truth and updates with the server. For Code nodes, read
`tools_documentation({topic:'javascript_code_node_guide'})` (or
`python_code_node_guide`) before writing logic.

# Gotchas

- **`n8n_health_check` first** when API tools misbehave — confirms the n8n-mcp →
  n8n link (API key valid, n8n reachable) before you blame your workflow.
- **MCP-Server-Trigger workflows only accept `*Tool` nodes (or HTTP Request
  Tool) as tools.** Base nodes without a `*Tool` variant (e.g. `googleAnalytics`,
  `googleSheets`) error with "cannot output ai_tool" when connected to an
  MCP Server Trigger. Route those through `httpRequestTool` hitting the API with
  `$fromAI(...)` params instead.
- **Editor host ≠ webhook host.** A webhook/MCP-trigger URL is on
  `<N8N_WEBHOOK_HOST>`, not `<N8N_HOST>`. Using the editor host for a webhook
  URL silently fails to trigger.
- **Google OAuth credentials die every ~7 days** if the Google Cloud OAuth app
  is in `Testing` — publish the app to `In production` and reconnect once.
  (Recurring infra gotcha; the n8n-mcp side has nothing to do with it.)
- **`get_node` standard before full.** Full schemas are ~100KB+; pulling full
  for every node burns context. Standard shows required fields.

# Report back

- What you built/changed (workflow name + id), that you validated it, and the
  `n8n_health_check` / execution result proving it runs.
- Editor link (`https://<N8N_HOST>/workflow/<id>`) so the user can inspect.

Upstream: n8n (`n8n-io/n8n`) + n8n-mcp (`czlonkowski/n8n-mcp`). The MCP server's
own `tools_documentation` tool is the live source of truth for the tool surface.
