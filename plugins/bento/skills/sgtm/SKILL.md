---
name: sgtm
description: Operate a self-hosted server-side Google Tag Manager (sGTM) deployed by bento — check health, read tag logs, open Preview, wire a same-origin proxy (Cloudflare Worker or nginx) or switch on direct mode, rotate the proxy key, update Google's image, add Google Cloud credentials for BigQuery tags, and troubleshoot (404 on /g/collect, Tag Assistant waiting, wrong visitor IP, cookies not set). Use when the user says "my server GTM", "sGTM", "tagging server", "server container preview isn't opening", "hits return 404", "wrong IP in Meta CAPI", "rotate the sGTM key", "update sGTM", "BigQuery from server GTM", or asks how to point GTM at it. Does NOT deploy the stack — that is `/bento:deploy`.
---

You operate the `sgtm` stack on a bento VPS: Google's `gtm-cloud-image` as a
tagging service (`sgtm_sgtm_tagging`) and a preview service
(`sgtm_sgtm_preview`). Day-2 work only: redeploys go through `/bento:deploy`.
The full reference — modes, proxy recipes, GTM wiring, troubleshooting — is
`docs/reference/sgtm.md` in the bento repo (on the VPS:
`~/.local/share/bento/docs/reference/sgtm.md`). **When this skill and that doc
disagree, the doc wins.**

> **Never print secrets.** `SGTM_PROXY_KEY`, `SGTM_CONTAINER_CONFIG` and
> `SGTM_GCP_SA_JSON_B64` stay on the VPS: use them inside commands, never echo
> them into the chat, a file you show, or a screenshot.

# When to invoke

- "is my sGTM up / check the tagging server", "show sGTM logs"
- "Tag Assistant keeps waiting", "/g/collect returns 404", "Meta gets the wrong IP"
- "set up the proxy for sGTM", "use sGTM without a proxy (direct mode)"
- "rotate the sGTM key", "update sGTM", "let sGTM write to BigQuery"

# Discover the instance — don't hardcode

```bash
ssh "$user@$host" "jq -r '.envs.sgtm.SGTM_HOST'          \$HOME/.config/bento/state.json"
ssh "$user@$host" "jq -r '.envs.sgtm.SGTM_PREVIEW_HOST'  \$HOME/.config/bento/state.json"
ssh "$user@$host" "jq -r '.envs.sgtm.SGTM_DIRECT_MATCH // \"(proxy only)\"' \$HOME/.config/bento/state.json"
```

Know the mode before anything else:

- **Proxy mode** (always on): the site forwards `https://<site>/<path>` to
  `https://<SGTM_HOST>` with `X-Sgtm-Key` and the visitor in `Forwarded`.
  Without the key, Traefik answers 404.
- **Direct mode** (only if `SGTM_DIRECT_MATCH` is set): browsers call
  `https://<SGTM_HOST>` themselves; the visitor IP is Traefik's
  `X-Forwarded-For`.

# Health

```bash
ssh "$user@$host" "docker service ls --filter name=sgtm_ --format '{{.Name}} {{.Replicas}}'"   # both 1/1
curl -s "https://<SGTM_PREVIEW_HOST>/healthy"                                                  # ok
ssh "$user@$host" 'curl -s -H "X-Sgtm-Key: $(jq -r .envs.sgtm.SGTM_PROXY_KEY ~/.config/bento/state.json)" https://$(jq -r .envs.sgtm.SGTM_HOST ~/.config/bento/state.json)/healthy'   # ok
curl -s -o /dev/null -w '%{http_code}\n' "https://<site>/<path>/g/collect?v=2"                 # 400 = proxy → sGTM works
```

Logs: `docker service logs -f --tail 100 sgtm_sgtm_tagging` (tag errors,
`Listening on`). Restarts: `docker service ps --no-trunc sgtm_sgtm_tagging`.

# Common tasks

| Task | How |
|---|---|
| Wire GTM | Server container → Admin → Container Settings → **Server container URLs** = the site path (proxy) or `https://<SGTM_HOST>` (direct). Web container → Google tag → `server_container_url` = same URL. Server container needs a GA4 tag on a Custom "All events" trigger |
| Add the proxy | Cloudflare Worker or nginx recipe in the reference doc, section 2.3. The proxy must forward only `/g/collect` and `/gtm/…`, add `X-Sgtm-Key`, and set `Forwarded: for="<ip>";host=<site>;proto=https` (IPv6 in brackets) |
| Direct mode on | Set `envs.sgtm.SGTM_DIRECT_MATCH` to ``(Path(`/g/collect`) || PathPrefix(`/gtm/`))`` → `/bento:deploy` redeploy. Off: remove the key from state → redeploy |
| Rotate the key | `openssl rand -hex 32` → `envs.sgtm.SGTM_PROXY_KEY` → redeploy → update the proxy's secret. Warn the user: hits 404 between the two steps |
| Update the image | `/bento:update`, or `docker service update --force --image gcr.io/cloud-tagging-10302018/gtm-cloud-image:stable` on both services |
| BigQuery / Firestore | Service account key → `base64 -w0 key.json` → `envs.sgtm.SGTM_GCP_SA_JSON_B64` → redeploy → delete the file |
| Webhooks from n8n & co. | POST to `http://sgtm_sgtm_tagging:8080/<client path>` on `network_public` (no key, no Traefik). Real user IP goes in the payload |

Publishing in GTM needs nothing on the VPS: the tagging server polls for the
published version.

# Gotchas

- **404 on the site path** is almost always the key: compare the proxy's
  secret with `SGTM_PROXY_KEY` (inside a command, not by printing both).
- **Wrong visitor IP** (datacenter or `10.x`): in proxy mode the proxy isn't
  sending `Forwarded`; in direct mode something sits in front of Traefik
  (Cloudflare orange cloud). Check in the server container's Tag Assistant →
  request headers and event data `ip_override`.
- **Preview host must be HTTPS and reachable**, and the Server container URL
  in GTM must be the URL browsers use (the proxy path in proxy mode).
- **amd64 only**: no ARM image from Google.
- **One sGTM per VPS** (stack key `sgtm`).
- **Never test by pointing a copy of the production container at real
  vendors** (e.g. a local run with a production config): tags send real events
  to Meta/GA4. Test with Preview, or on a network where vendor hosts resolve to
  a mock.

# Report back

- Mode, both services' replicas, the `/healthy` and site-path checks.
- What you changed and that a hit went through (Tag Assistant or logs).

Upstream: [Manual setup guide](https://developers.google.com/tag-platform/tag-manager/server-side/manual-setup-guide),
[sGTM APIs](https://developers.google.com/tag-platform/tag-manager/server-side/api).
