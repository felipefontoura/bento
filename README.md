<a name="readme-top"></a>

<!-- PROJECT LOGO -->
<br />
<div align="center">
  <a href="https://github.com/felipefontoura/bento">
    <img src=".assets/bento-banner.png" alt="bento" width="720">
  </a>

  <p align="center">
    Your VPS, served on a tray.
    <br />
    <br />
    <a href="#quickstart"><strong>Quickstart »</strong></a>
    ·
    <a href="CLAUDE.md">For maintainers</a>
    ·
    <a href="https://github.com/felipefontoura/bento/issues">Report a bug</a>
  </p>

  <p align="center">
    <img alt="License: MIT" src="https://img.shields.io/badge/License-MIT-blue.svg">
    <img alt="Made with Bash" src="https://img.shields.io/badge/Made%20with-Bash-1f425f.svg">
    <img alt="Docker Swarm" src="https://img.shields.io/badge/Docker-Swarm-2496ED.svg?logo=docker&logoColor=white">
    <img alt="Apt-based" src="https://img.shields.io/badge/distro-Ubuntu%20%7C%20Debian-orange">
  </p>
</div>

<br />

Bento takes a freshly-installed Ubuntu (or any Debian-family) VPS and walks
you through a guided terminal menu until you have a hardened host, Docker
Swarm bootstrapped, Traefik + Portainer running with TLS, and your chosen
applications deployed and ready to log into.

---

## Table of Contents

- [Get a VPS (recommended: Hetzner)](#get-a-vps-recommended-hetzner)
- [DNS (recommended: Cloudflare)](#dns-recommended-cloudflare)
- [Network firewall (Hetzner Cloud Firewall)](#network-firewall-hetzner-cloud-firewall)
- [Quickstart](#quickstart)
- [What bento does](#what-bento-does)
  - [Step 1 — Harden the system](#step-1--harden-the-system)
  - [Step 2 — Install infrastructure](#step-2--install-infrastructure)
  - [Step 3 — Install applications](#step-3--install-applications)
- [Ownership: bento vs Portainer](#ownership-bento-vs-portainer)
- [Updating later](#updating-later)
- [Stacks available](#stacks-available)
- [Manual install](#manual-install-if-curlbash-is-not-your-thing)
- [Requirements](#requirements)
- [State and configuration](#state-and-configuration)
- [For maintainers](#for-maintainers)
- [Contributing](#contributing)
- [License](#license)

---

<!-- TODO: replace YOUR_REF with the real Hetzner affiliate code before pushing. -->

## Get a VPS (recommended: Hetzner)

> **Don't have a server yet?** Bento is built and tested on **[Hetzner Cloud](https://hetzner.cloud/?ref=YOUR_REF)** — affordable, fast, and Ubuntu-default. A **CX22** (~€4/month) comfortably runs hardening + Traefik + Portainer + a couple of apps.
>
> **[Sign up here](https://hetzner.cloud/?ref=YOUR_REF)** — gets you free
> Hetzner credit on signup to test bento for free.

**Why we recommend Hetzner specifically**

- We've run every release of bento on it; it is the only provider we
  actively validate against.
- The current Ubuntu LTS is the default image at Hetzner — exactly what
  `boot.sh` expects.
- The CX22 SKU has enough RAM/disk for the full stack list.

**Full disclosure — this is an affiliate link**

The link above is an affiliate referral. If you sign up through it and
use paid resources, Hetzner pays us a small commission. That revenue is
**the main thing that funds new stacks, bug fixes, and keeping bento free
and open source**. There is zero pressure to use it — bento works
identically on any Ubuntu/Debian VPS (DigitalOcean, OVH, Vultr, your own
hardware…). If you'd rather pay no referral, just sign up directly at
[hetzner.com](https://hetzner.com) and the installer works the same way.

After signing up: create a **CX22** (or larger) with the **latest Ubuntu
LTS**, add your SSH key, and continue with the next section.

---

## DNS (recommended: Cloudflare)

> **Bento expects a wildcard A record.** Every stack gets its own
> subdomain (`portainer.mydomain.com`, `n8n.mydomain.com`, etc.), and
> Traefik asks Let's Encrypt for certs on each one. Without DNS in place
> Step 2 will fail.
>
> **[Cloudflare](https://www.cloudflare.com/)** is our recommended DNS
> provider for two reasons: the free tier is genuinely free (no credit
> card), and it ships a clean API that lets bento configure the records
> for you in one click.

**Not an affiliate.** Cloudflare doesn't run a public referral program
for individuals, so this is a pure technical recommendation.

### Records you need to create

Anywhere you host DNS — Cloudflare's dashboard, your registrar, Route 53,
whatever — create these two records pointing at your VPS IP:

| Type | Name             | Content         | TTL  |
| ---- | ---------------- | --------------- | ---- |
| A    | `*.mydomain.com` | `<your VPS IP>` | Auto |
| A    | `mydomain.com`   | `<your VPS IP>` | Auto |

**Using Cloudflare?** This deep link skips the navigation and lands you
directly on your zone's DNS records page — Cloudflare will prompt you to
pick the account and zone first:

[**Open the Cloudflare DNS records page →**](https://dash.cloudflare.com/?to=/:account/:zone/dns)

Cloudflare does not expose a public "click and create the record" flow
for third parties, so the values still come from the table above. The
deep link just saves a few clicks of navigation.

Verify before running Step 2:

```bash
dig +short A portainer.mydomain.com
# should print your VPS IP
```

Bento will print these same records (and the deep link) during Step 2
and wait for you to confirm they resolve — there is no API integration
to set up, no token to manage. Pick whatever DNS host you prefer; we
just recommend Cloudflare for the speed and zero-cost free tier.

---

## Network firewall (Hetzner Cloud Firewall)

You get **two layers of firewall** when you run bento on Hetzner:

1. **Hetzner Cloud Firewall** — runs at Hetzner's network edge, *before*
   packets reach your VPS. Configured in the Hetzner panel.
2. **OS-level UFW** — runs on the VPS itself. Configured automatically by
   `lib/hardening.sh` during Step 1.

You don't need both, but layered defense is cheap and Hetzner's edge firewall
is free.

### What bento's UFW already does

`lib/hardening.sh` resets and re-enables UFW with this policy:

- `default deny incoming`, `default allow outgoing`
- `limit ssh` — drops brute-force attempts at 6 connections/30s
- `allow http`, `allow https` — ports 80/443 for Traefik
- `allow proto icmp` — keeps `ping` working for debugging

Combined with `fail2ban` (also installed during hardening), SSH brute-force
is shut down within seconds.

### Recommended Hetzner Cloud Firewall ruleset

In the Hetzner Cloud console: **Firewalls → Create Firewall → Apply to your server**.

| Direction | Source         | Port    | Protocol | Why                              |
| --------- | -------------- | ------- | -------- | -------------------------------- |
| Inbound   | Your home IPv4 | 22      | TCP      | SSH (lock down further later)    |
| Inbound   | `0.0.0.0/0`    | 80      | TCP      | Let's Encrypt HTTP-01 + redirect |
| Inbound   | `0.0.0.0/0`    | 443     | TCP      | HTTPS                            |
| Inbound   | `0.0.0.0/0`    | (any)   | ICMP     | `ping` debugging (optional)      |
| Outbound  | `0.0.0.0/0`    | all     | all      | Default — keep open              |

**Important:** if you set the SSH rule to your home IP only and that IP
changes (mobile, ISP renewal, etc.), you'll lose access and have to use
Hetzner's web console to fix it. For a starter setup, leaving SSH open to
the world but enforcing `ufw limit` + `fail2ban` (both already on) is a
reasonable trade-off.

> **Future**: bento may add a Hetzner Cloud Firewall sync via the
> `hcloud` API token, similar to the Cloudflare flow. For now it's a
> one-time manual configuration in the panel.

---

## Quickstart

One command, anywhere on a fresh Ubuntu/Debian VPS:

```bash
bash <(curl -sSL https://raw.githubusercontent.com/felipefontoura/bento/stable/boot.sh)
```

You will be asked once for:

- **Base domain** (e.g. `mydomain.com`) — every subsequent service gets a
  subdomain (`portainer.mydomain.com`, `n8n.mydomain.com`, etc.).
- **Admin email** — for Let's Encrypt + service-level admin contact.
- **VPS public IP** — auto-detected, confirm or override.

Then bento drops you into an interactive menu with three steps to follow in
order. Each step is idempotent and can be re-run safely.

---

## What bento does

### Step 1 — Harden the system

Runs the [ubinkaze](https://github.com/felipefontoura/ubinkaze) hardening
script (copied in as `lib/hardening.sh`):

- Installs Docker via the official installer
- Applies kernel sysctl hardening (BPF, IP forwarding, source-route protections)
- Enables UFW (ssh/http/https only), fail2ban, AppArmor, AIDE, auditd, chrony
- Creates a `docker` user with your SSH keys
- Configures unattended security upgrades, log rotation, daily cleanup cron

When hardening finishes, Step 1 immediately initializes the Docker Swarm
using the IP you confirmed and creates the shared overlay network
`network_public`. A reboot is required before continuing.

### Step 2 — Install infrastructure

No prompts. Bento takes the values from the bootstrap and:

- Deploys **Traefik** with HTTPS redirects + Let's Encrypt via your email
- Deploys **Portainer** at `portainer.<your-domain>`
- Generates a strong admin password and initializes Portainer's admin via API
- Shows the URL, username, and password once on screen

After Step 2 you have a working production-grade router and a UI to inspect
everything bento later deploys.

### Step 3 — Install applications

Pick from the menu what you want. For each selected stack bento:

1. Prompts for missing required env vars (defaults derived from your base domain).
2. Generates strong secrets where the manifest declares `generate`.
3. Calls Portainer's API to create the stack from this Git repo (so Portainer
   becomes the source of truth for the running spec).
4. Runs the optional per-stack `install.sh` to bootstrap the app (e.g. create
   its Postgres database, run Rails migrations, etc.).
5. Prints the URL — you open it and log in.

---

## Ownership: bento vs Portainer

Bento and Portainer split responsibilities cleanly. This is the same model as
Helm + kubectl or Terraform + the cloud console.

| Concern                                              | bento    | Portainer  |
| ---------------------------------------------------- | -------- | ---------- |
| Declarative state (what should run)                  | owner    | viewer     |
| First deploy + bulk updates                          | owner    | executor   |
| Day-to-day ops (logs, restart, scale, exec)          | redirect | owner      |
| Stacks created directly in Portainer (outside bento) | ignored  | full owner |

Every bento-deployed stack carries the env var `BENTO_MANAGED=true` plus the
deployed Git commit, so bento can spot drift and offer to reconcile during
**Update**.

---

## Updating later

Just re-run the same one-liner — `boot.sh` re-clones the repo. Or, from the
menu, pick **Update** to:

- Pull the latest bento code (`git fetch + reset --hard`).
- Re-deploy any stacks where the YAML or manifest changed since the deployed
  Git commit (via `POST /api/stacks/<id>/git/redeploy`).

---

## Stacks available

Layout: each stack is a directory with `compose.yml`, `manifest.json`, and
optionally `install.sh`.

### Infrastructure (deployed by Step 2)

- **[Traefik](stacks/infra/traefik):** reverse proxy with Let's Encrypt.
- **[Portainer](stacks/infra/portainer):** stack manager UI.

### Databases (deployed on demand by Step 3 when an app depends on them)

- **[PostgreSQL](stacks/db/postgres):** every app creates its own database
  via its `install.sh`.
- **[Redis](stacks/db/redis):** in-memory cache.

### Applications (Step 3)

- **[Chatwoot](stacks/app/chatwoot):** customer support platform.
- **[CLI Proxy API](stacks/app/cli-proxy-api):** OpenAI-compatible proxy.
- **[Evolution API](stacks/app/evolution-api):** WhatsApp gateway.
- **[N8n](stacks/app/n8n):** workflow automation.
- **[N8n MCP](stacks/app/n8n-mcp):** MCP server for n8n.
- **[Paperclip](stacks/app/paperclip):** AI agent orchestration (custom
  image bundling Hermes, Gemini, Pi, Grok alongside Claude Code, Codex,
  OpenCode).
- **[Plunk](stacks/app/plunk):** open-source email platform.
- **[RabbitMQ](stacks/app/rabbitmq):** message broker.
- **[Typebot](stacks/app/typebot):** chatbot builder.

---

## Manual install (if curl|bash is not your thing)

```bash
git clone --branch stable https://github.com/felipefontoura/bento ~/.local/share/bento
cd ~/.local/share/bento
bash install.sh
```

Same menu, no curl required.

---

## Requirements

- Latest Ubuntu LTS (or any apt-based distro: Debian, Mint, Pop!_OS, etc.)
- Non-root user with `sudo` access
- 1+ GB RAM
- 20+ GB free disk
- Public IPv4
- Domain with A records pointing to the VPS (`*.mydomain.com` → VPS IP)

---

## State and configuration

- Bento state: `~/.config/bento/state.json` (chmod 600)
- Portainer admin credentials: `~/.config/bento/portainer.json` (chmod 600)
- Hardening logs: `~/.local/state/bento/logs/`

These survive `bento update`. Schema is versioned and migrated automatically.

---

## For maintainers

Adding a new stack, debugging the installer, or changing conventions?
Read **[CLAUDE.md](CLAUDE.md)** first. It is the canonical guide to:

- The Bento ↔ Portainer ownership model.
- Stack directory layout and manifest schema.
- The env resolution order.
- Step-by-step recipe for adding a new application stack.
- Code style for shell, YAML, and JSON.
- Helpers available to per-stack `install.sh` scripts.

CLAUDE.md is loaded automatically by Claude Code (or other coding agents
like OpenCode) when working in this repo; it is also a complete
human-readable maintainer guide.

There is also a `add-app-stack` skill in `.claude/skills/` that automates
the new-stack scaffold for AI-assisted contributions.

---

## Contributing

Pull requests welcome. Open an issue first for anything beyond a small fix.

---

## License

Distributed under the MIT License.

<p align="right">(<a href="#readme-top">back to top</a>)</p>
