# `crawl4ai` — optional outbound proxy

bento's self-hosted Crawl4AI (`stacks/app/crawl4ai/`) runs headless Chromium on
your VPS and crawls whatever URL it's handed. On a datacenter host (Hetzner,
OVH, DigitalOcean…) many targets — Reddit, Cloudflare-protected sites, social
networks — block the **IP range itself** at the reputation layer and return
`HTTP 403 "Blocked by anti-bot protection"` no matter how good the browser
fingerprint is. The fix is to route the crawler's egress through a
**residential or mobile proxy** so the target sees a real consumer IP.

bento exposes this as a single **optional** value, `CRAWL4AI_PROXY`. Set it and
the crawler routes through your proxy; leave it blank (the default) and the
crawler egresses directly, exactly as before. It is stored in
`~/.config/bento/state.json` under `envs.crawl4ai.CRAWL4AI_PROXY` and injected
into the container as `HTTP_PROXY` / `HTTPS_PROXY` on every deploy via
`lib/stacks.sh::stacks_build_env_payload`.

> **Scope: pragmatic global lever, not an upstream contract.** Crawl4AI
> officially configures proxies **per request** (`CrawlerRunConfig.proxy_config`);
> the self-hosted Docker server has **no documented global-proxy setting**. The
> `HTTP_PROXY` / `HTTPS_PROXY` env vars bento sets are the community pattern that
> Linux Chromium honors when launched without an explicit `--proxy-server`. It
> works on the current image, but it is **not** an upstream-guaranteed contract.
> If a future image build ignores it, the fully-supported fallback is a
> per-request `proxy_config` set in **MetaMCP's tool definition** (the
> `Crawl4AI_Extract` tool), which lives in MetaMCP's database, not in any compose
> file. Verify with the IP-echo check below.

---

## What to buy

The proxy **type** matters more than the vendor. Residential rotating is the
right default for almost every case.

| Type | IP origin | Block rate | Price (order) | Use when |
|---|---|---|---|---|
| Datacenter | Servers (same class as your VPS) | High | ~$1/IP or $0.5–1/GB | Targets with no anti-bot. Won't fix a 403 — it's what you already have. |
| ISP / static residential | Residential IP, fixed | Medium-low | ~$2–5/IP/mo | You need a **stable** IP for logins/sessions. |
| **Residential (rotating)** | Real consumer devices | **Low** | ~$1.75–8/GB | **Default.** Medium/strong anti-bot. Best cost/benefit. |
| Mobile (4G/5G) | Carrier IPs | Minimal | ~$10/GB or $50+/mo | Brutal targets (Instagram, TikTok, hard Cloudflare). |
| Web unblocker | Vendor solves the challenge | Minimal | ~$1/1000 req | Zero tuning; pay per request; no fingerprint control. |

**Billing.** Per-GB suits a crawler (HTML is KB, not GB) and is the common
choice; per-port/IP suits long-lived same-IP sessions. A typical HTML page is
0.3–1 MB, so ~$1.75/GB buys roughly 1.000–3.000 pages.

**Recommendation.** Start with a **residential rotating pay-as-you-go** plan
(IPRoyal, Decodo, Oxylabs, Bright Data — all comparable) to validate success
rate, then escalate only the domains that still resist to **mobile** or a
**web unblocker**.

---

## Configuring it in bento

The proxy URL is a full URL with optional credentials:

```
http://user:pass@gateway.provider.io:7777
```

Most providers hand you `host:port:user:pass` plus username **suffixes** that
control rotation/geo (e.g. `user-xxxx-country-br`, `user-xxxx-session-abc` to
pin one IP). Assemble those into the URL above. A single rotating-gateway URL
already gives you a different IP per request.

Two ways to set it:

1. **During deploy** — `/bento:deploy` (or interactive Step 3) prompts
   `Optional: outbound proxy URL for the crawler …`. Paste the URL, or press
   Enter to skip (direct egress). The value is hidden and persisted.

2. **Directly in state, then redeploy** —

   ```bash
   state_set '.envs.crawl4ai.CRAWL4AI_PROXY' "http://user:pass@host:port"
   # then redeploy crawl4ai (Update → Re-deploy stacks, or /bento:deploy crawl4ai)
   ```

The value is reused on every subsequent deploy (env-resolution step 1), so you
set it once. To go back to direct egress, set it to `""` and redeploy.

---

## Self-hosting the proxy from a home connection

A home residential IP (e.g. a Vivo fibra line) is a *real* residential IP and
works as a proxy egress. It can be a zero-marginal-cost option for low volume —
but read the caveats first.

- **One IP, no rotation.** A paid pool gives you millions; home gives you one.
  High volume against a per-IP rate limiter burns it — and then your *home*
  starts getting captchas on normal browsing.
- **CGNAT.** Residential fibre (Vivo included) is usually behind CGNAT, so you
  can't open an inbound port. Work around it with a **WireGuard reverse tunnel**:
  a box at home *dials out* to the VPS, and the crawler container egresses back
  through the tunnel (or to a small `3proxy`/`dante` listening only inside the
  tunnel — point `CRAWL4AI_PROXY` at that internal address).
- **Dynamic IP / reliability.** The home IP changes; the link or power can drop
  and stop the crawler. Home upload is lower (fine for HTML).
- **ToS.** Residential plans often forbid running servers.

**Recommendation.** Use a paid residential pool as the default; treat the
home-tunnel as a niche cost optimization for low-volume, non-sensitive targets —
not a starting point.

---

## Verifying

After setting `CRAWL4AI_PROXY` and redeploying, confirm the proxy actually
routes the headless browser (not just curl):

1. Crawl an IP-echo page — `https://api.ipify.org` or `https://ifconfig.me`.
2. The returned IP must be the **proxy's**, not your VPS's. If it's the VPS IP,
   the env-var lever was ignored by this image — use the per-request
   `proxy_config` path in MetaMCP's tool definition instead (see scope note).
3. Re-crawl the originally-blocked URL — expect `200` instead of `403`.
4. Set `CRAWL4AI_PROXY=""`, redeploy, and confirm direct crawling still works —
   proving the feature stays optional.

---

## Troubleshooting

**Still getting 403 with a proxy set** — the proxy IP itself may be flagged
(cheap datacenter proxy) or the target needs a cleaner pool. Move from
datacenter → residential, or residential → mobile / web unblocker for that
domain.

**Egress still shows the VPS IP** — Chromium didn't pick up the env var (image
build difference). Use MetaMCP's per-request `proxy_config` instead; bento's env
var only covers the global-lever case.

**Auth fails / `407 Proxy Authentication Required`** — check the `user:pass` in
the URL and any provider-required username suffix (geo/session). URL-encode
special characters in the password.

**Internal calls slow or failing after enabling the proxy** — make sure the
overlay service names stay in `NO_PROXY` (they are by default in
`compose.yml`); otherwise internal traffic is forced through the proxy too.

---

## Related

- Stack compose: `stacks/app/crawl4ai/compose.yml` (the `HTTP(S)_PROXY` block)
- Manifest env entry: `stacks/app/crawl4ai/manifest.json` (`CRAWL4AI_PROXY`)
- Env injection at deploy: `lib/stacks.sh::stacks_build_env_payload`
- Per-request alternative: MetaMCP `Crawl4AI_Extract` tool definition
