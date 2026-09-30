# `sgtm` — server-side Google Tag Manager

Self-hosted server-side GTM (sGTM): Google's own `gtm-cloud-image`, the same
software Stape or Cloud Run run for you, on your bento VPS. Flat cost, no
per-request billing, your data stays on your box.

| Service        | Host                | Role                                          |
| -------------- | ------------------- | --------------------------------------------- |
| `sgtm_tagging` | `SGTM_HOST`         | Runs your server container: clients, tags     |
| `sgtm_preview` | `SGTM_PREVIEW_HOST` | Tag Assistant debug sessions (Preview)        |

Operating it day to day with Claude: `/bento:sgtm`.

---

## 1. Pick a mode

| | **Proxy mode** (default, recommended) | **Direct mode** (opt-in) |
|---|---|---|
| Browsers send hits to | a path on **your site**: `https://example.com/metrics` | `https://sgtm.example.com` |
| Needs | a small reverse proxy on your site's origin (Cloudflare Worker, nginx — recipes below) | nothing else |
| Cookies | first-party on your site's host, set by server responses (Safari keeps them past 7 days) | first-party on `example.com` via the `sgtm.` subdomain |
| Ad blockers | miss it: same host as the site | blocklists that match tagging subdomains can catch it |
| Scanners/bots hitting sGTM | never reach it: only requests with the proxy key are routed | reach it, unless you limit paths (recommended value below) |
| Visitor IP | proxy sends it in `Forwarded` | Traefik's `X-Forwarded-For` (the browser's own IP) |

Both can be on at once: the proxy key always works.

### How requests are routed

- **Proxy mode:** the router matches `Host(SGTM_HOST) && Headers(X-Sgtm-Key, SGTM_PROXY_KEY)`. Anything without the key gets Traefik's 404. The key and the `X-Forwarded-*` Traefik rewrote are stripped before the container sees the request, leaving the proxy's `Forwarded` as the only source for the visitor IP and cookie domain.
- **Direct mode:** a second router matches `Host(SGTM_HOST) && SGTM_DIRECT_MATCH`. It is off by default: the default matcher never matches. Any `Forwarded` header the browser sends is dropped, so nobody can claim another IP.

Why `Forwarded` and not `X-Forwarded-For` in proxy mode: bento's Traefik trusts no upstream, so it **replaces** `X-Forwarded-For`/`X-Forwarded-Host` with the proxy's own address but passes `Forwarded` through untouched (verified on `traefik:v2.11`). sGTM reads the visitor IP (`getRemoteAddress`) and the `auto` cookie domain (`setCookie`) from `Forwarded`. Trusting the proxy's IP ranges globally in Traefik would let anything behind those ranges forge headers for every stack; the key keeps the trust scoped to this router.

---

## 2. Quickstart

### 2.1 GTM: create the server container

1. [tagmanager.google.com](https://tagmanager.google.com) → your account → **Create Container** → target platform **Server** → **Manually provision tagging server**.
2. Copy the **Container Config** string. It is also at **Admin → Container Settings** later.

The server container ships with a **GA4** client; keep it.

### 2.2 bento: deploy

Deploy `sgtm` (`/bento:deploy`, or the bento menu). Prompts:

| Prompt | Answer |
|---|---|
| Tagging server hostname | Enter (`sgtm.<base domain>`) or your own |
| Preview server hostname | Enter (`sgtm-preview.<base domain>`) |
| Container config string | the string from 2.1 |
| Direct browser access (optional) | **empty** for proxy mode; for direct mode: ``(Path(`/g/collect`) || PathPrefix(`/gtm/`))`` |
| Google service account (optional) | empty unless tags write to BigQuery/Firestore (section 5) |

DNS: both hostnames point at the VPS. On Cloudflare keep them **DNS only** (grey cloud): Traefik's Let's Encrypt uses HTTP-01.

Check:

```bash
curl -s https://sgtm-preview.example.com/healthy                        # ok
curl -s -o /dev/null -w '%{http_code}\n' https://sgtm.example.com/healthy  # 404 in proxy-only mode (no key)
KEY=$(jq -r '.envs.sgtm.SGTM_PROXY_KEY' ~/.config/bento/state.json)      # on the VPS; don't paste it anywhere
curl -s -H "X-Sgtm-Key: $KEY" https://sgtm.example.com/healthy          # ok
```

### 2.3 Proxy mode: add the proxy on your site

Pick the path your site will use (`/metrics` below; any neutral name). The proxy forwards **only** GA4 hits (`/g/collect`) and the preview (`/gtm/…`), adds the key and the visitor in `Forwarded`, and answers 404 to everything else.

**Cloudflare Worker** (site on Cloudflare). Route `example.com/metrics/*` to this Worker and add the secret `SGTM_KEY` (Workers → Settings → Variables and Secrets) with the value of `SGTM_PROXY_KEY`:

```js
const PATH = "/metrics";                // same-origin path your site uses
const UPSTREAM = "sgtm.example.com";    // SGTM_HOST
const ALLOWED = [/^\/g\/collect$/, /^\/gtm\//];

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname.slice(PATH.length);
    if (!ALLOWED.some((re) => re.test(path))) return new Response(null, { status: 404 });

    const upstream = new Request(`https://${UPSTREAM}${path}${url.search}`, request);
    upstream.headers.set("X-Sgtm-Key", env.SGTM_KEY);
    const ip = request.headers.get("CF-Connecting-IP");
    const node = ip ? (ip.includes(":") ? `for="[${ip}]";` : `for="${ip}";`) : "";
    upstream.headers.set("Forwarded", `${node}host=${url.hostname};proto=https`);
    return fetch(upstream);
  },
};
```

If your site is served by Workers static assets, list the path in `run_worker_first` (`["/metrics/*"]`) so the script runs before the assets.

**nginx** (site on your own server). In the site's `server {}`:

```nginx
# http {} level: visitor IP for Forwarded, IPv6 in brackets.
map $remote_addr $sgtm_for {
  ~:      "\"[$remote_addr]\"";
  default "\"$remote_addr\"";
}

# server {} level
location = /metrics/g/collect {
  proxy_pass https://sgtm.example.com/g/collect;
  include snippets/sgtm_proxy.conf;
}
location ^~ /metrics/gtm/ {
  proxy_pass https://sgtm.example.com/gtm/;
  include snippets/sgtm_proxy.conf;
}
location ^~ /metrics/ { return 404; }
```

`snippets/sgtm_proxy.conf`:

```nginx
proxy_set_header Host sgtm.example.com;
proxy_ssl_server_name on;
proxy_set_header X-Sgtm-Key "<SGTM_PROXY_KEY>";
proxy_set_header Forwarded "for=$sgtm_for;host=$host;proto=https";
proxy_set_header X-Forwarded-For "";
```

If nginx itself sits behind Cloudflare, use `$http_cf_connecting_ip` instead of `$remote_addr` in the `map`.

Check (proxy mode): `curl -s -o /dev/null -w '%{http_code}\n' "https://example.com/metrics/g/collect?v=2"` → **400** (that's sGTM rejecting an empty hit: the path works). `https://example.com/metrics/.env` → **404**.

### 2.4 GTM: point both containers at it

The URL below is `https://example.com/metrics` in proxy mode, `https://sgtm.example.com` in direct mode.

1. **Server container** → **Admin** → **Container Settings** → **Server container URLs**: the URL.
2. **Web container** → your **Google tag** (GA4) → **Configuration settings** → add `server_container_url` = the URL. Every GA4 hit now goes to your sGTM, which forwards it to GA4 through its GA4 tag.
3. **Server container** → **Tags** → **New** → **Google Analytics: GA4** (defaults inherit everything from the incoming hit) → **Triggering** → **New** → **Custom** → **All events** → **Save**. Without a tag, hits reach sGTM and stop there.

### 2.5 Preview, then publish

1. Server container → **Preview**. Tag Assistant opens `<URL>/gtm/debug…` through your proxy (or directly) and waits.
2. Web container → **Preview** on your site. Browse: requests show up in the server Tag Assistant with the GA4 client and your tags.
3. **Publish the server container first, then the web container.**

---

## 3. Values

| Env | Where it comes from |
|---|---|
| `SGTM_HOST`, `SGTM_PREVIEW_HOST` | Prompted; default `sgtm.` / `sgtm-preview.` + your base domain |
| `SGTM_CONTAINER_CONFIG` | GTM → server container → **Admin** → **Container Settings**. Same string for both services |
| `SGTM_PROXY_KEY` | Generated. Put it in your proxy's secret store. Never in a repo or a screenshot |
| `SGTM_DIRECT_MATCH` | Optional Traefik matcher that turns on direct mode. Empty = proxy only |
| `SGTM_GCP_SA_JSON_B64` | Optional. `base64 -w0 key.json` of a Google service account key (section 5) |
| `SGTM_TAGGING_CPU_LIMIT` / `_MEM_LIMIT`, `SGTM_PREVIEW_…` | Defaults 1 CPU / 512M and 0.5 / 256M. Google: "at most 1 vCPU" per tagging server |

Values live in `~/.config/bento/state.json` under `envs.sgtm`. Change one: edit it there (or the stack's env in Portainer) and redeploy with `/bento:deploy` (or Portainer → stack → **Update the stack**).

---

## 4. Operations

```bash
docker service ls --filter name=sgtm_                  # both services 1/1
docker service logs -f --tail 100 sgtm_sgtm_tagging    # tag errors, "Listening on"
docker service logs -f --tail 100 sgtm_sgtm_preview
```

| Task | How |
|---|---|
| Update to Google's latest image | `/bento:update`, or `docker service update --force --image gcr.io/cloud-tagging-10302018/gtm-cloud-image:stable sgtm_sgtm_tagging` (same for `sgtm_sgtm_preview`). `stable` is a moving tag: nothing updates until a redeploy pulls it. Google retires old builds, so update every few months |
| Publish changes | Nothing on the VPS: the tagging server polls GTM for the published version |
| Rotate the proxy key | New value (`openssl rand -hex 32`) → `envs.sgtm.SGTM_PROXY_KEY` in state → redeploy → same value in the proxy's secret. Between the two steps, hits 404 |
| Turn direct mode on/off | Set/clear `envs.sgtm.SGTM_DIRECT_MATCH` → redeploy |
| Webhooks from other stacks | Stacks on `network_public` (e.g. n8n posting purchases to a Data Client) call `http://sgtm_sgtm_tagging:8080/<path>`: no Traefik, no key. They carry no `Forwarded`, so the container sees the caller's overlay IP: send the real user's IP in the payload if a tag needs it |

---

## 5. Google Cloud credentials (BigQuery, Firestore)

Tags that call Google APIs (e.g. a "Write to BigQuery" tag) need a service account:

1. Google Cloud → IAM → Service Accounts → create one, and grant it only what the tag needs (e.g. **BigQuery Data Editor** on one dataset).
2. **Keys** → Add key → JSON. On the VPS: `base64 -w0 key.json`.
3. Put the output in `SGTM_GCP_SA_JSON_B64` and redeploy. Delete `key.json`.

The image is distroless (no shell), so a `node --import data:` preload writes the key to `/tmp/gcp-sa.json` and sets `GOOGLE_APPLICATION_CREDENTIALS` before the server starts.

---

## 6. Troubleshooting

| Symptom | Likely cause | Check |
|---|---|---|
| `…/metrics/g/collect` answers 404 | Proxy key differs from `SGTM_PROXY_KEY`, or stack down | `curl -H "X-Sgtm-Key: $KEY" https://sgtm.example.com/healthy` → `ok` means the proxy's key is wrong |
| Tag Assistant (server) keeps waiting | Server container URL in GTM ≠ your proxy URL; preview host not reachable | `curl -s https://sgtm-preview.example.com/healthy` → `ok`; recheck 2.4 |
| Meta/GA4 get a datacenter or Docker IP | Proxy mode: proxy not sending `Forwarded`. Direct mode: something in front of Traefik (e.g. Cloudflare orange cloud) | In the server Tag Assistant, request headers: `Forwarded: for="<your IP>"`; event data `ip_override` = your IP |
| Cookies not set on the site | Cookie domain comes from `Forwarded`'s `host=` (proxy) or `SGTM_HOST` (direct) | `host=` must be your site's host; `SGTM_HOST` must be a subdomain of the site |
| Container restarts | Out of memory, or a bad config string | `docker service ps --no-trunc sgtm_sgtm_tagging`; raise `SGTM_TAGGING_MEM_LIMIT` |
| BigQuery tag fails | No/invalid service account | Section 5; tag logs in `docker service logs sgtm_sgtm_tagging` |

---

## 7. Limitations

- **amd64 only.** Google publishes no ARM image: an ARM VPS (e.g. Hetzner CAX) can't run it.
- **One sGTM per VPS.** The stack key is `sgtm`; a second site needs a second server container **and** a copy of the stack under another key (or another VPS).
- **The preview host is public.** A debug session still needs GTM's auth token, but anyone can reach `/healthy`.
- **No per-request filtering beyond paths.** Direct mode with the recommended matcher keeps scanners off other paths, but anything can post to `/g/collect`; filter bots inside the container (e.g. a trigger condition on user agent).
