---
name: evolution-api
description: Operate the Evolution API (WhatsApp gateway) on a bento VPS — create WhatsApp instances, get the QR code to connect a phone, check connection state, send WhatsApp messages (text and media), configure webhooks, list or delete instances, and manage the full lifecycle of a WhatsApp bot or integration. Use when the user says "send a WhatsApp message", "connect my WhatsApp", "get the QR code", "set up a WhatsApp bot", "configure a WhatsApp webhook", "create a WhatsApp instance", "disconnect WhatsApp", "check WhatsApp status", "link my phone number to the API", "scan the QR", "set up WhatsApp automation", or anything about getting WhatsApp to work on their server. Day-2 operation of the running app's HTTP API. Deploying the stack is `/bento:deploy`.
---

You operate the **Evolution API** on a bento VPS that is already deployed.
This skill carries the bento-specific wiring and the operational traps — for the
exact endpoint paths and request bodies, go to the official docs (linked at the
bottom); they are the source of truth and they move faster than this file. Your
job is to know *how to approach it*, not to memorize the reference.

> **Mutate via the HTTP API**, not the DB or container disk. Read-only
> inspection (logs, env) to recover a lost key is fine.

# When to invoke

- "connect my WhatsApp / get the QR / scan the code"
- "send a WhatsApp message (text or media)"
- "set up / check a webhook for incoming messages"
- "check connection state / list instances / disconnect / delete"

For *getting Evolution running* use `/bento:deploy`.

# Discover the instance — don't hardcode

```bash
# The stack name has a dash — confirm the exact state key first
ssh "$user@$host" "jq '.envs|keys' \$HOME/.config/bento/state.json"
ssh "$user@$host" "jq -r '.envs.\"evolution-api\".EVOLUTION_HOST'    \$HOME/.config/bento/state.json"  # base URL host
ssh "$user@$host" "jq -r '.envs.\"evolution-api\".EVOLUTION_API_KEY' \$HOME/.config/bento/state.json"  # global key (never echo)
```

Base URL = `https://<EVOLUTION_HOST>`. Swarm task: `evolution-api_evolution.1.*`
(stack `evolution-api`, service `evolution` — confirm with `docker ps`).

# Auth — the part that isn't obvious from the docs

Evolution uses a flat **`apikey: <key>`** header — **not** `Authorization: Bearer`.
There are **two keys**, and using the wrong one is the #1 source of 401s:

| Key | Scope | Source |
|---|---|---|
| **Global** | lifecycle: create / list / delete / logout instances | `EVOLUTION_API_KEY` (bento state) |
| **Instance** | messaging + per-instance config (send, webhooks, state) | `hash.apikey` in the `POST /instance/create` response; re-readable via `fetchInstances` |

Rule: global key for instance lifecycle, instance key for everything you do
*to* an instance.

# How to operate it

The flow is always: **create an instance → connect a phone (QR) → it goes
`open` → send/receive**. The endpoints you'll reach for, grouped by which key:

- **Lifecycle (global key):** create instance, connect/QR, connectionState, fetchInstances, logout, delete.
- **Messaging & config (instance key):** sendText, sendMedia, webhook set/find.

Look up exact paths, request bodies, and the full event list in the docs — don't
guess them from memory. Confirm the live shape against the running instance's
own Swagger if in doubt.

# Gotchas (the reason this skill exists)

- **QR expires in ~20–30s.** Don't call `connect` once and wait — register a
  webhook with `QRCODE_UPDATED` to receive fresh codes, and watch
  `CONNECTION_UPDATE` for `state: open`. Polling the endpoint races the expiry.
- **Two-token confusion** (see auth table) — a 401 almost always means a
  lifecycle call used the instance key, or a message call used the global key.
- **Phone format:** plain digits with country code, no `+`/spaces/dashes
  (`5511999990000`). Wrong format = silent non-delivery or 400.
- **Media base64 = raw bytes, no `data:...;base64,` prefix** (the prefix throws
  a "Maximum call stack" error). Files over ~3 MB → pass an HTTPS URL instead.
- **`logout` keeps the instance** (re-pair with a new QR); **`delete` is
  destructive, no undo.**
- **Global webhook:** Evolution supports a `WEBHOOK_GLOBAL_URL` env, but **bento
  does not wire one** — drive everything through per-instance webhooks set via
  the API (they live in the DB and survive restarts). Add the env + redeploy
  only if you specifically want a global one.
- **Long media uploads** can take 60–180s — bump your client timeout
  (`curl --max-time 180`).

# Report back

- Instances after the op (name + connection state); for create, the instance key
  captured and shown masked (last 4 only); for send, the returned message id.

**Docs (source of truth):** https://doc.evolution-api.com/v2 · live OpenAPI on
your instance at `https://<EVOLUTION_HOST>/docs`. When this skill and the docs
disagree, the docs win — tell the operator.
