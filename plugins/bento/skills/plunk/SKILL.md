---
name: plunk
description: Operate the Plunk email platform API on a bento VPS — send a transactional email, send an email to a user, track an email event, add a contact to my email list, trigger an email automation, create or update a contact, unsubscribe a contact, list contacts. Use when the user wants to drive a running Plunk stack's HTTP API for day-2 work: sending emails, managing contacts, or firing event-based automations. Plunk exposes two key types (secret sk_* for server-side operations, public pk_* for client-side event tracking) and sends through AWS SES. Deploying Plunk itself is `/bento:deploy`.
---

You operate the **HTTP API** of a Plunk stack that is already deployed by bento.
This is day-2 work: send transactional emails, track events, manage contacts.
This skill carries the bento-specific wiring and operational traps — for exact
endpoint paths and request bodies, go to the official docs (linked at the bottom);
they are the source of truth and move faster than this file.

> **Golden rule — use the HTTP API, never the DB.** All contact, event, and
> email operations must go through the REST endpoints. Read-only DB inspection
> to understand state is always fine.

# When to invoke

- "send a transactional email" / "send an email to a user"
- "track an event" / "trigger an email automation"
- "add / create / update / delete / list a contact"
- "subscribe or unsubscribe a contact"

For *getting Plunk running* use `/bento:deploy`. For *AWS SES credentials* use
`/bento:auth` or set them directly in the stack envs.

# Discover the instance — don't hardcode

```bash
ssh "$user@$host" "jq -r '.envs.plunk.PLUNK_HOST' \$HOME/.config/bento/state.json"
```

Base URL: `https://<PLUNK_HOST>`. Traefik routes directly to the container's
port 3000 — there is no nginx layer. Container name convention in the Swarm:

```bash
plunk_container() { ssh "$user@$host" "docker ps --filter name=plunk_plunk -q | head -1"; }
```

For loopback calls (inside the container): `http://127.0.0.1:3000`.
From outside: always use `https://<PLUNK_HOST>`.

# Auth — two key types, both Bearer

`Authorization: Bearer <key>` on every authenticated call. Keys are minted in
the Plunk dashboard → Project → API Keys; there is no DB bootstrap path.

| Key type | Prefix | Scope |
|---|---|---|
| Secret key | `sk_...` | Server-side: send, contacts CRUD, event tracking (`/events/track`) |
| Public key | `pk_...` | Client-side only: `POST /v1/track` (browser/app tracking) |

**Never echo either key.** Store in env vars and reference by name.

# Operation groups

Four groups — look up exact paths and bodies in the docs:

- **Send email** — `POST /v1/send` (secret key)
- **Track event** — `POST /v1/track` (public key, upserts contact + fires automations); `POST /events/track` (secret key, authenticated variant)
- **Contacts CRUD** — create/upsert/list/get/update/delete (secret key); public subscribe/unsubscribe endpoints require no key
- **Verify email address** — `POST /v1/verify` (secret key)

Minimal anchor — a transactional send:

```bash
curl -s -X POST "https://$PLUNK_HOST/v1/send" \
  -H "Authorization: Bearer $PLUNK_SECRET_KEY" \
  -H "Content-Type: application/json" \
  -d '{"to":"user@example.com","subject":"Hi","body":"<p>Hello</p>","from":"noreply@yourdomain.com"}'
```

# Gotchas (the reason this skill exists)

**SES sandbox / unverified domain is the #1 non-delivery cause.** AWS SES starts
in sandbox — only verified recipients, low send limits. Request production access
in the AWS console and verify your sending domain in Plunk (Project → Domains)
so DKIM/SPF are in place; Plunk enforces domain ownership before allowing a
`from` address.

**`EMAIL_RATE_LIMIT_PER_SECOND` has a silent fallback.** If `ses:GetSendQuota`
is denied at worker startup, the worker silently falls back to 14 msg/s. In SES
sandbox that immediately triggers throttling. Set `EMAIL_RATE_LIMIT_PER_SECOND=1`
for sandbox accounts.

**`/v1/track` uses the public key; `/v1/send` uses the secret key.** Mixing them
returns a 401. `/contacts` and `/events/track` also require the secret key.

**Transactional emails do NOT subscribe new contacts by default.** `POST /v1/send`
creates the contact as unsubscribed unless `"subscribed": true` is explicitly
passed. `POST /v1/track` does subscribe new contacts by default.

**Template variable syntax is `{{fieldName}}`.** Unmatched placeholders are
replaced with empty string, not left as-is. Use `{{field ?? default}}` for
fallbacks. System vars (`email`, `unsubscribeUrl`, `subscribeUrl`, `manageUrl`,
`id`) are always available in transactional bodies without passing them in `data`.

# Report back

- What changed: emails sent (recipient + subject), contacts created/updated
  (email + subscribed status), events tracked (event name + contact).
- Read-back to confirm: for contacts, `GET /contacts/:id`; for emails, the
  `data.emails` array from the `/v1/send` response.
- If delivery fails: check `/health` first, then SES sandbox / domain verification.

**Docs (source of truth):** https://docs.useplunk.com — API reference for all
paths, bodies, and response shapes. When this skill and the docs disagree, the
docs win — tell the operator.
