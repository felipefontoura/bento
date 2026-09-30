# `sgtm` — server-side Google Tag Manager

Self-hosted replacement for a managed sGTM host (Stape, Cloud Run). Two
services from Google's image `gtm-cloud-image:stable`:

| Service        | Host                  | Role                                         |
| -------------- | --------------------- | -------------------------------------------- |
| `sgtm_tagging` | `SGTM_HOST`           | Runs the container: clients, tags, variables |
| `sgtm_preview` | `SGTM_PREVIEW_HOST`   | Tag Assistant debug sessions                 |

No per-request billing, so scanners and bots cost nothing — but they still
pollute data, which is why the tagging host is locked down (below).

## Designed for a same-origin proxy

The browser never talks to `SGTM_HOST`. The site serves a path on its own
origin (e.g. `https://example.com/io`) through an edge proxy (a Cloudflare
Worker, nginx…), and the proxy forwards to `https://SGTM_HOST`. That keeps
cookies first-party, dodges blockers keyed on tagging hostnames and lets the
proxy filter what goes through.

The tagging router only matches requests that carry the proxy key:

```
Host(`SGTM_HOST`) && Headers(`X-Sgtm-Key`, `SGTM_PROXY_KEY`)
```

Anything else gets Traefik's 404. The key is stripped before the request
reaches the container (the preview UI lists every request header).

### What the proxy must send

| Header       | Value                                              | Why |
| ------------ | -------------------------------------------------- | --- |
| `X-Sgtm-Key` | `SGTM_PROXY_KEY`                                   | Router match |
| `Forwarded`  | `for="<visitor IP>";host=<site host>;proto=https`  | sGTM reads the visitor IP (`getRemoteAddress`, `ip_override`) from `Forwarded`/`X-Forwarded-For` and the cookie domain (`setCookie` with `domain: 'auto'`) from `Forwarded` first. IPv6 goes in brackets: `for="[2001:db8::1]"` |

Why `Forwarded` and not `X-Forwarded-For`: bento's Traefik trusts no
upstream, so it **replaces** `X-Forwarded-For` / `X-Forwarded-Host` with the
proxy's own address, but passes `Forwarded` through untouched (tested on
`traefik:v2.11`). The router's middleware then deletes those rewritten
`X-Forwarded-*` and `X-Real-Ip`, leaving `Forwarded` as the only source.
Trusting the proxy's IP ranges globally in Traefik would let anyone behind
those ranges forge the header for every stack; the key check keeps the trust
scoped to this router.

### Server to server (webhooks)

Other stacks on `network_public` (n8n posting a purchase to a Data Client,
say) skip Traefik and the key: `http://sgtm_sgtm_tagging:8080/<client path>`
(stack `sgtm`, service `sgtm_tagging`). Those requests carry no `Forwarded`,
so the container sees the caller's overlay IP as the visitor: send the real
buyer's IP and user agent in the payload if the tags need them.

Read the key on the VPS:

```bash
jq -r '.envs.sgtm.SGTM_PROXY_KEY' ~/.config/bento/state.json
```

## Values

| Env                     | Where it comes from |
| ----------------------- | ------------------- |
| `SGTM_CONTAINER_CONFIG` | GTM → server container → Admin → Container settings → "Manually provision tagging server". Same string for both services |
| `SGTM_PROXY_KEY`        | Generated. Copy it into the proxy's secret store |
| `SGTM_GCP_SA_JSON_B64`  | Optional. `base64 -w0 key.json` of a service account key, for tags that call BigQuery/Firestore. The image is distroless (no shell), so a `node --import data:` preload writes it to `/tmp/gcp-sa.json` and sets `GOOGLE_APPLICATION_CREDENTIALS` before the server starts |

In GTM → Admin → Container settings, set **Server container URL** to the
same-origin URL (`https://example.com/io`), not `SGTM_HOST`.

## DNS

Both hosts point at the VPS. On Cloudflare keep them **DNS only** (grey
cloud): Traefik's Let's Encrypt uses HTTP-01.

## Checks

```bash
curl -s https://SGTM_PREVIEW_HOST/healthy                 # ok
curl -s -o /dev/null -w '%{http_code}\n' https://SGTM_HOST/healthy   # 404 (no key)
curl -s -H "X-Sgtm-Key: $KEY" https://SGTM_HOST/healthy   # ok
```

Then open Preview in the server container and send a hit through the proxy:
the GA4 client's event data must show `ip_override` = your real IP.
