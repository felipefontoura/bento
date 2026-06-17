---
name: chatwoot
description: Operate the Chatwoot customer support platform via HTTP API on an already-deployed bento VPS — reply to a customer, send a support message, create a new conversation, list open conversations, assign a conversation to an agent, resolve or reopen a ticket, create or search a contact, list help desk inboxes, add a private note, filter conversations by status/inbox/team/label. Use when the user says "reply to a customer", "send a message to a contact", "create a support ticket", "list open chats", "assign this conversation", "resolve a ticket", "create a contact in chatwoot", "set up a help desk inbox", "check unassigned conversations", "list my inboxes", "add a note to a conversation", "search for a contact", "get chatwoot conversations", or any other day-2 support desk operation. Deploying Chatwoot itself is `/bento:deploy`.
---

You operate the **Application API** of a Chatwoot stack already deployed by
bento. This is day-2 work: you query and manage conversations, contacts,
inboxes, and agents. For the exact endpoint paths, parameters, and request
bodies, go to the official docs (linked at the bottom) — they are the source
of truth. Your job is to know *how to approach it*, not to memorize the
reference.

> **Golden rule — mutate via the API, never the DB.** Raw `INSERT`/`UPDATE` on
> Postgres bypasses Chatwoot's event pipeline (ActionCable, webhooks, Sidekiq)
> and leaves the UI in a broken state.

# When to invoke

- "reply to / message a customer"
- "list open / unassigned / snoozed conversations"
- "create a new conversation / ticket"
- "assign this conversation to an agent or team"
- "resolve / reopen / snooze a conversation"
- "create / search / list contacts"
- "list inboxes"
- "add a private note to a conversation"

For *getting Chatwoot running* use `/bento:deploy`.

# Discover the instance — don't hardcode

```bash
ssh "$user@$host" "jq -r '.envs.chatwoot.CHATWOOT_HOST' \$HOME/.config/bento/state.json"
```

Base URL is `https://<CHATWOOT_HOST>`. The two containers follow bento's swarm
naming convention: `chatwoot_chatwoot_web.1.*` (Rails) and
`chatwoot_chatwoot_sidekiq.1.*` (background worker).

## Finding account_id

Every Application API route is account-scoped: `/api/v1/accounts/{account_id}/...`

Read it from the browser URL after login (`/app/accounts/**1**/dashboard`), or
confirm via Rails runner:

```bash
ssh "$user@$host" "docker exec \$(docker ps -qf name=chatwoot_chatwoot_web) \
  bundle exec rails runner 'puts Account.pluck(:id, :name).inspect'"
```

# Auth model — the non-obvious parts

All three API surfaces use an **`api_access_token`** header — **not**
`Authorization: Bearer`.

- **Application API** (`/api/v1/accounts/...`) — day-to-day inbox work. Two
  token flavors: **user token** (Profile → Access Token; carries that agent's
  permissions) and **agent bot token** (Settings → Integrations → Agent Bots;
  system identity, broader scope — use for automation).
- **Platform API** (`/api/v1/platform/...`) — super-admin provisioning
  (create accounts, users). Token from Super Admin console →
  `https://<CHATWOOT_HOST>/super_admin/platform_apps`.
- **Client API** (`/public/api/v1/inboxes/...`) — in-widget visitor flows.
  Out of scope here.

Never echo a token. Store it in a shell variable: `-H "api_access_token: $TOK"`.

# How to operate it

The operation groups you'll reach for most:

- **Conversations** — list (filter by status/inbox/team/assignee), get, create, toggle status (open/resolved/snoozed).
- **Messages / replies** — send outgoing reply or private note to a conversation.
- **Contacts** — list, search, get, create.
- **Inboxes** — list (to resolve `inbox_id` before creating a conversation).
- **Assignment / status** — assign agent or team, update priority.

Look up exact paths, query params, and request bodies in the docs — don't guess
from memory. Confirm the live schema against the instance's own Swagger before
mutating.

# Gotchas (the reason this skill exists)

**account_id = 1 on bento, but verify.** If a second account is ever created
via the UI or Platform API, route IDs shift. Always read it from the URL or
Rails runner; never hardcode `1`.

**agent bot token vs user token — different identity.** A bot token can send
`message_type: outgoing` and toggle statuses without inbox-membership checks
that apply to regular agents. Use a bot token for automation, a user token when
acting on behalf of a human agent.

**`source_id` on conversation create.** The OpenAPI spec lists it as the only
required field, but in practice `inbox_id` drives the channel — supply both.
Omitting `inbox_id` returns a 422 on most inbox types.

**Private notes vs outgoing messages.** `"private": true` on a messages POST
creates an internal agent note invisible to the customer. Omitting it (or
`false`) sends to the customer. Double-check before posting.

**Sidekiq must be running for deliveries.** Outgoing messages are queued via
Sidekiq. If `chatwoot_chatwoot_sidekiq` is down, messages persist in the DB
but are never dispatched. Check `docker service ps chatwoot_chatwoot_sidekiq`
before diagnosing delivery failures.

**`toggle_status` fires events every call.** Calling it in a retry loop
re-triggers webhooks and ActionCable broadcasts each time. Confirm current
status from `GET .../conversations/{cid}` before toggling.

# Report back

- Which conversations / contacts were read or mutated (IDs + statuses).
- Confirm mutations with a follow-up `GET` and show the changed fields.
- If you minted any tokens interactively, remind the user to treat them as
  secrets and not commit them.

**Docs (source of truth):** https://developers.chatwoot.com/api-reference · live
OpenAPI on your instance at `https://<CHATWOOT_HOST>/swagger`. When this skill
and the docs disagree, the docs win — tell the operator.
