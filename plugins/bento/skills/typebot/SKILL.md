---
name: typebot
description: Operate the Typebot API on a bento VPS — start a chatbot conversation, run a bot flow, send messages and continue a chat session, list typebots in a workspace, publish a typebot (make it live), get chatbot results and responses (submissions, answers), embed a chatbot, and manage typebots via the management API. Use when the user says "start a chatbot conversation", "run my typebot", "continue a chat session", "send a message to my bot", "list my typebots", "publish my typebot", "get chatbot results", "get bot responses", "get form submissions", "embed my chatbot", or wants to drive a running Typebot stack's API. Does NOT deploy Typebot — deploying is `/bento:deploy`.
---

You operate the **HTTP API** of a Typebot stack that is already deployed by
bento. Day-2 work: run bot flows, manage typebots, pull results.
For the exact endpoint paths and request bodies go to the official docs (linked
at the bottom) — they are the source of truth. Your job is to know *how to
approach it*, not to memorize the reference.

> **When this skill and the docs disagree, the docs win.**

> **Critical — Typebot has two distinct API surfaces on two distinct hosts.**
> The **builder** (`TYPEBOT_BUILDER_HOST`) serves management and results APIs
> (list, publish, get results) — needs a Bearer token.
> The **viewer** (`TYPEBOT_VIEWER_HOST`) serves chat execution (startChat,
> continueChat) — public, no auth. Mixing the two hosts is the #1 source of
> mysterious 404s. Always resolve both before making any call.

# When to invoke

- "start / run / continue a typebot conversation"
- "list my typebots / publish a typebot / get results"
- "call the chat API / embed my chatbot"

For *getting Typebot running* use `/bento:deploy`.

# Discover the instance — don't hardcode

```bash
# Builder host (management + results)
ssh "$user@$host" \
  "jq -r '.envs.typebot.TYPEBOT_BUILDER_HOST' \$HOME/.config/bento/state.json"

# Viewer host (chat execution)
ssh "$user@$host" \
  "jq -r '.envs.typebot.TYPEBOT_VIEWER_HOST' \$HOME/.config/bento/state.json"
```

Swarm tasks (stack `typebot`): `typebot_typebot_builder.1.*` and
`typebot_typebot_viewer.1.*`. Confirm with `docker ps`.

# Auth — mint a token

Builder endpoints require `Authorization: Bearer <token>`. Viewer endpoints
are public — no token needed.

**Mint:** Typebot builder UI → top-right avatar → Settings → API tokens →
Create. Copy it once (shown only at creation). Store in an env var, never echo:

```bash
export TYPEBOT_TOKEN="<your-token>"
```

# Discover your workspaceId

Most management routes require `workspaceId`. Fetch it once:

```bash
curl -s -H "Authorization: Bearer $TYPEBOT_TOKEN" \
  "https://$TYPEBOT_BUILDER_HOST/api/v1/workspaces" | jq '.workspaces[] | {id, name}'
```

# How to operate it

Two surfaces — **builder** (management: list / get / publish / results, Bearer
token) and **viewer** (chat: startChat / continueChat, no auth). Look up exact
paths, query params, and request bodies in the docs; don't guess from memory.

Minimal chat anchor — start then continue:

```bash
VIEWER="https://$TYPEBOT_VIEWER_HOST/api"

# Start (uses publicId — the short slug from builder Share tab)
SESSION=$(curl -s -X POST "$VIEWER/v1/typebots/$PUBLIC_ID/startChat" \
  -H "Content-Type: application/json" -d '{}' | jq -r '.sessionId')

# Continue / send a message
curl -s -X POST "$VIEWER/v1/sessions/$SESSION/continueChat" \
  -H "Content-Type: application/json" \
  -d '{"message": {"type": "text", "text": "Hello"}}'
```

# Gotchas (the reason this skill exists)

- **Builder/viewer 404-vs-401 diagnosis:** a 404 on a chat endpoint means you
  hit the builder; a 401 (or missing management routes) means you hit the viewer
  without a token — or hit the viewer for a management call. Verify both hosts
  first.
- **`publicId` ≠ `typebotId`:** `startChat` takes the short public slug (builder
  Share tab). Management endpoints (`publish`, `results`, `get`) take the
  internal UUID. Never swap them.
- **Must publish before chat works:** `startChat` against an unpublished bot
  returns 404. Always `POST /typebots/{typebotId}/publish` (builder) first.
- **`workspaceId` mandatory for list:** `GET /v1/typebots` without
  `?workspaceId=` returns 400. Discover it first (see above).
- **Results pagination uses cursor, not page number:** pass `?cursor=<nextCursor>`
  from the previous response; stop when `nextCursor` is null.
- **`ENCRYPTION_SECRET` must match on builder and viewer:** bento propagates it
  from state — do not override it per-service, or the viewer will fail to
  decrypt session data written by the builder.

# Report back

- Which typebot(s) targeted (name + id).
- Publish: confirm `publishedTypebotId` is set.
- Chat: show session ID and returned messages.
- Results: count fetched and whether `nextCursor` is non-null.
- Never print the API token.

**Docs (source of truth):** https://docs.typebot.io/api-reference
When this skill and the docs disagree, the docs win — tell the operator.
