---
name: paperclip
description: Operate the Paperclip API on a bento VPS — create and configure agents, write their instruction bundles, import and sync skills, manage issues/projects/goals, and wire the official MCP server as a control plane. Use when the user says "create a paperclip agent", "configure my chiefs", "import skills into paperclip", "delete paperclip issues", "set up the paperclip MCP server", or otherwise wants to drive a running paperclip stack's API (not deploy it). Mutations go through the HTTP API with a Bearer board key — never raw DB writes. Deploying paperclip itself is the deploy skill.
---

You operate the **application API** of a paperclip stack that is already
deployed by bento. This is day-2 work: you configure agents and skills, manage
the board, and wire integrations. You do NOT install or redeploy the stack —
that is `/bento:deploy`. All artifacts stay in English.

> **Golden rule — mutate via the API, never the DB or disk.** Creating agents,
> editing instruction bundles, syncing skills, and changing config must go
> through the HTTP API. The API validates schemas, applies defaults, fires the
> runtime side-effects the app expects (instruction-folder scaffold, config
> revisions, audit log, skill-content sync), and never leaves an agent
> half-built. Raw `INSERT`/`UPDATE` on Postgres or `cat > file` into the
> container can diverge from what the app expects. The **only** tolerated DB
> exception is minting a bootstrap board key (below) — and you delete it after.
> Read-only DB/code inspection to *understand* the API is always fine.

# When to invoke

- "create / configure a paperclip agent (CEO, chiefs, ICs)"
- "write the instruction bundle (SOUL / AGENTS / HEARTBEAT / TOOLS)"
- "import skills into paperclip" / "sync an agent's skills"
- "delete issues / clean up the board / reset failed runs"
- "wire the paperclip MCP server into hermes (control plane)"

For *getting paperclip running* use `/bento:deploy`. For *provider API keys*
(OpenAI/Anthropic) use `/bento:auth` — paperclip reads those propagated envs.

# Discover the instance — don't hardcode

Read the host from bento state on the VPS (same source the other skills use):

```bash
ssh "$user@$host" "jq -r '.envs.paperclip.PAPERCLIP_HOST' \$HOME/.config/bento/state.json"
```

Base URL is `https://<PAPERCLIP_HOST>`. Find the company id (you almost always
need it — most routes are `/api/companies/:companyId/...`):

```bash
# from inside the box, against the loopback API (see headless mode below)
docker exec "$(paperclip_container)" node -e \
  'fetch("http://127.0.0.1:3100/api/companies",{headers:{authorization:"Bearer "+process.env.TOK}}).then(r=>r.json()).then(d=>console.log(JSON.stringify(d,null,2)))'
```

Bento swarm container names are conventional across deploys:
- paperclip: `paperclip_paperclip.1.*`
- postgres:  `postgres_postgres.1.*`

```bash
paperclip_container() { ssh "$user@$host" "docker ps --filter name=paperclip_paperclip -q | head -1"; }
```

# Auth — Bearer board key

The API's `actorMiddleware` accepts `Authorization: Bearer <token>`. If the
token hashes (`sha256(token)`, hex) to a row in `board_api_keys`, the request
becomes a **board actor** carrying that key owner's memberships. A key owned by
an `instance_admin` short-circuits every `assertCanMutate*` check. Token format:
`pcp_board_<48hex>`. Bearer auth bypasses CSRF / Origin / cookie entirely — this
is why it's the right path for automation (no browser session needed).

**Get a key** the clean way: the Paperclip web UI → company → Settings → API
keys. Hand that key to the skill via an env var; never echo it.

**Bootstrap a temporary key** (the one tolerated DB write) when no UI key exists
yet — mint, use, delete:

```bash
# 1. mint (TOKEN generated locally; store its sha256 only)
#    user_id must be an instance_admin for full mutate rights
ssh "$user@$host" "docker exec \$(docker ps -qf name=postgres_postgres) \
  psql -U postgres -d paperclip -c \
  \"INSERT INTO board_api_keys (user_id,name,key_hash,expires_at) \
    VALUES ('<ADMIN_USER_ID>','tmp-cc','<SHA256_OF_TOKEN>',now()+interval '1 hour')\""
# 2. ... use TOKEN as Bearer (see below) ...
# 3. delete when done
ssh "$user@$host" "docker exec \$(docker ps -qf name=postgres_postgres) \
  psql -U postgres -d paperclip -c \"DELETE FROM board_api_keys WHERE name='tmp-cc'\""
```

# Two ways to call the API

**A — over HTTPS** (from anywhere, with a real board key). Plain REST:

```bash
curl -s -H "authorization: Bearer $TOK" "https://$PAPERCLIP_HOST/api/companies/$COMPANY/agents"
```

**B — headless on the box** (no public exposure, no TLS, no CSRF). Run `fetch`
inside the container against `http://127.0.0.1:3100` — useful for bootstrap and
for routes that are picky about Origin/Referer when hit cross-site:

```bash
ssh "$user@$host" "docker exec -e TOK -e COMP \$(docker ps -qf name=paperclip_paperclip) \
  node -e 'fetch(\"http://127.0.0.1:3100/api/companies/\"+process.env.COMP+\"/agents\",\
  {headers:{authorization:\"Bearer \"+process.env.TOK}}).then(r=>r.json()).then(d=>console.log(JSON.stringify(d)))'"
```

# Core operations

All under `/api`. Company-scoped routes take `:companyId`.

| Goal | Endpoint | Schema / note |
|---|---|---|
| List / get agents | `GET /companies/:cid/agents` | |
| Create agent | `POST /companies/:cid/agents` | `createAgentSchema` — never `INSERT` into `agents` |
| Update agent (title, config, manager) | `PATCH /companies/:cid/agents/:id` | `updateAgentSchema` |
| Update permissions (e.g. `canCreateAgents`) | dedicated permissions route | `updateAgentPermissions` — hiring is gated here |
| Instruction bundle (whole) | `PATCH …/agents/:id/instructions` | `updateAgentInstructionsBundle` |
| Single instruction file | `PUT …/agents/:id/instructions/<file>` | `upsertAgentInstructionsFile` — never write SOUL/AGENTS/etc to disk |
| Sync an agent's skills | `POST /agents/:agentId/skills/sync` | `agentSkillSyncSchema`, body `{desiredSkills:[...]}` |
| Import skills (company) | `POST /companies/:cid/skills/import` | `{source:<path>}` — see gotcha below |
| Delete a company skill | `DELETE /companies/:cid/skills/:skillId` | 422 if still assigned to an agent (sync it off first) |
| Issues | `GET/POST /companies/:cid/issues`, `POST …/issues/:id/comments` | create / list / comment |
| Projects & goals | project routes + `project_goals` (PATCH project `goalIds`) | goals have `level` = company/team/agent/task |

**Instruction bundles are pure execution code.** The 4 files (SOUL / AGENTS /
HEARTBEAT / TOOLS) describe *work only*. Two things do NOT belong in them:
(1) **human life-vision** — an agent has no family, sleep, or weekend; don't
encode "don't run after 17h" as an execution gate. Model the async human board
instead: "produce, queue the decision, keep going on what you can." (2)
**runtime/substrate meta** — the agent needn't know which model/adapter/gateway
runs it; `TOOLS.md` is just the Paperclip API surface + its skill list. Keep
infra notes in a folder README for the human, not in the bundle.

# Known gotchas (these cost real debugging hours)

**`skills/import` wants the PARENT dir, not a skill dir.** The server walks
`source` for nested `<slug>/SKILL.md` and builds each skill's file inventory by
filtering `entry.startsWith(skillDir + "/")`. Point `source` at the directory
that *contains* many skill subdirs:
- ✅ `source = "/paperclip/skill-sources"` → discovers every subdir, full inventory each.
- ❌ `source = ".../skill-sources/alex-hormozi"` → `skillDir="."`, filter never matches → inventory is just `[SKILL.md]`.
Re-import upserts by key (only delete first if renaming/cleaning). The path
lives **inside** the container; ship skills with
`tar czf - <slugs> | ssh "$user@$host" "docker exec -i \$(docker ps -qf name=paperclip_paperclip) sh -c 'cd /paperclip/skill-sources && tar xzf -'"`.

**`DELETE /api/issues/:id` returns a blind 500 on dependents.** Seven FK tables
are `ON DELETE NO ACTION` (`cost_events`, `feedback_votes`, `finance_events`,
`issue_comments`, `issue_inbox_archives`, `issue_read_states`,
`issue_thread_interactions`) plus `issues.parent_id`. The handler doesn't
pre-clean. For bulk cleanup, do it in one DB transaction instead of looping the
endpoint:

```sql
BEGIN;
CREATE TEMP TABLE _t AS SELECT id FROM issues WHERE <filter>;
DELETE FROM cost_events            WHERE issue_id IN (SELECT id FROM _t);
DELETE FROM feedback_votes         WHERE issue_id IN (SELECT id FROM _t);
DELETE FROM finance_events         WHERE issue_id IN (SELECT id FROM _t);
DELETE FROM issue_comments         WHERE issue_id IN (SELECT id FROM _t);
DELETE FROM issue_inbox_archives   WHERE issue_id IN (SELECT id FROM _t);
DELETE FROM issue_read_states      WHERE issue_id IN (SELECT id FROM _t);
DELETE FROM issue_thread_interactions WHERE issue_id IN (SELECT id FROM _t);
UPDATE issues SET parent_id = NULL WHERE parent_id IN (SELECT id FROM _t);
DELETE FROM issues WHERE id IN (SELECT id FROM _t);
COMMIT;
```

`heartbeat_runs` has the same orphan-FK pattern (`activity_log`,
`agent_task_sessions.last_run_id`, `cost_events`, `finance_events`,
`heartbeat_run_events`) — cascade-clean those before deleting failed runs.

**Skill `DELETE` is 422 while a skill is still assigned.** First
`POST /agents/:id/skills/sync` with `desiredSkills` excluding that slug, then delete.

# Control plane via the official MCP server

To let a hermes agent (or any MCP client) drive the board, use the official
`@paperclipai/mcp-server` (stdio, thin wrapper over this REST API). In hermes'
`config.yaml`:

```yaml
paperclip:
  command: npx
  args: [-y, '@paperclipai/mcp-server@<PINNED_VERSION>']   # PIN — "latest" can break silently at boot
  env:
    PAPERCLIP_API_URL: http://paperclip:3100               # internal overlay
    PAPERCLIP_API_KEY: ${PAPERCLIP_BOARD_KEY}              # ref the .env, don't hardcode
    PAPERCLIP_COMPANY_ID: <COMPANY_ID>
  enabled: true
  tools: {include: [paperclipListAgents, paperclipListIssues, paperclipCreateIssue, paperclipAddComment, paperclipApiRequest]}
```

⚠️ **A newly-added MCP only surfaces to the model after a gateway RESTART.**
Added after boot → "Unknown toolset" → tools are fetched but never enter the
model's prompt. Clean restart in swarm: `docker service update --force hermes_hermes`
(never `docker restart` a swarm task — it orphans the container). See `/bento:hermes`.

# Report back

- What changed (agents created/updated, skills imported with per-skill file counts, issues touched).
- Confirm via a read (`GET …/agents`) and show the result.
- If you minted a bootstrap board key, confirm you deleted it.

Upstream API/source: `paperclipai/paperclip`. Inspect the running server's
`/app/server/dist` (read-only) to confirm a schema before mutating.
