![bento](.assets/bento-banner.png)

_Your VPS, served on a tray._

![License MIT](https://img.shields.io/badge/license-MIT-blue.svg)
![Made with Bash](https://img.shields.io/badge/made%20with-bash-1f425f.svg)
![Docker Swarm](https://img.shields.io/badge/docker-swarm-2496ED.svg?logo=docker&logoColor=white)
[![Stars](https://img.shields.io/github/stars/felipefontoura/bento?style=flat)](https://github.com/felipefontoura/bento/stargazers)
[![Last commit](https://img.shields.io/github/last-commit/felipefontoura/bento)](https://github.com/felipefontoura/bento/commits/main)

[Quickstart](#quickstart) · [Maintainers](CLAUDE.md) · [Issues](https://github.com/felipefontoura/bento/issues)

---

## Quickstart

```bash
bash <(curl -sSL https://raw.githubusercontent.com/felipefontoura/bento/stable/boot.sh)
```

## TL;DR

Paste that on a fresh Ubuntu/Debian VPS, answer three questions (domain, admin email, public IP), and ~15 minutes later you have a hardened host, Traefik + Portainer with TLS, the apps you picked, and an HTML handoff report. Already know bento? Copy and go. Want context? Keep reading.

> **Prefer to drive it from Claude Code instead of the server console?** Install the `bento` plugin and Claude does the whole flow over SSH — you never SSH in by hand or touch the bento menu. See [Install with Claude Code](#install-with-claude-code-no-server-console). Ideal for beginners (works on Windows) and for consultants setting up a client's VPS: hand Claude an SSH-reachable host + a domain + an app list and pick up at the end with credentials + URLs.

<details>
<summary><strong>Table of contents</strong></summary>

- [Quickstart](#quickstart)
- [Install with Claude Code](#install-with-claude-code-no-server-console)
- [What is bento](#what-is-bento)
- [How it works](#how-it-works)
- [Stacks](#stacks)
- [Prerequisites](#prerequisites)
- [After install](#after-install)
- [Operations](#operations)
- [For maintainers and contributors](#for-maintainers-and-contributors)

</details>

---

## What is bento

**A guided installer that turns a fresh VPS into a hardened, TLS-fronted Docker Swarm with the apps you want — in under 15 minutes, with one terminal command.**

You answer three questions (domain, admin email, public IP), walk through three guided steps (harden, infra, apps), and finish with a single HTML report you can hand off to a client. Every secret is generated for you; nothing is hardcoded.

---

## How it works

A one-time bootstrap captures **`BASE_DOMAIN`**, **`ADMIN_EMAIL`**, and your **VPS public IP** (auto-detected). Then three idempotent, re-runnable steps:

### Step 1 — Harden the system

An embedded copy of the [ubinkaze](https://github.com/felipefontoura/ubinkaze) hardening script:
installs Docker, applies kernel sysctl + UFW (with `limit ssh`) + fail2ban + AppArmor + AIDE + auditd + chrony,
creates a `docker` user with your SSH keys, then initializes Docker Swarm and the `network_public` overlay. Requires one reboot.

### Step 2 — Install infrastructure

No prompts. Deploys Traefik (Let's Encrypt + HTTPS redirect) and Portainer at `portainer.<your-domain>`, generates a strong Portainer admin password, displays it once.

### Step 3 — Install applications

Pick from a checklist. For each stack, bento:

1. **Prompts only for env vars without sensible defaults.** Hostnames default to `<key>.<your-domain>`; secrets are auto-generated; DB passwords are reused from the postgres stack.
2. **Deploys via Portainer's API as a Git-backed stack** so Portainer becomes the canonical source of truth for the running spec.
3. **Runs an optional `install.sh`** for post-deploy bootstrap (DB creation, migrations).
4. **Prints the URL** — you open and log in.

When Paperclip is in the deploy set, Step 3 offers an optional **Authenticate AI providers** step right after a successful deploy so the agent runtime can immediately call out to Claude / OpenAI Codex. The same menu is available any time from the main menu, or directly as `bento-auth` on the host. Full details in [docs/reference/bento-auth.md](docs/reference/bento-auth.md).

---

## Install with Claude Code (no server console)

Everything above — Bootstrap, Step 1, Step 2, Step 3, the post-hardening reboot,
the unattended env vars, the recovery when something stalls — is **drudgery you
shouldn't have to do by hand** if you "just want to use it." The `bento` plugin
for Claude Code drives all of it over SSH. You never log into the server console
or touch bento's menu: you talk to Claude, it does the rest and hands you back
URLs + credentials.

**You need:** Claude Code, an SSH key on the VPS, and wildcard DNS (see
[Prerequisites](#prerequisites)). Nothing is installed locally except Claude
Code — Docker/Swarm/apt all run on the VPS.

**Install the plugin once** — type these **inside Claude Code** (not your shell),
**one at a time**. They are two separate slash commands; run the first, wait for
it to confirm, then run the second. Don't paste both lines together — that
concatenates them into one broken command.

1. Add the marketplace:

   ```
   /plugin marketplace add felipefontoura/bento
   ```

2. Then install the plugin:

   ```
   /plugin install bento@felipefontoura
   ```

**Then just ask.** The plugin adds these `/bento:*` skills.

**Lifecycle** — get the box and its apps running:

| Command | What Claude does over SSH |
|---|---|
| `/bento:install` | Fresh VPS → hardened host + Traefik/Portainer + your apps. Runs Step 1/2/3 unattended, rides through the reboot, recovers from known failures, reports URLs + Portainer login. |
| `/bento:deploy` | Add or redeploy apps on a server that already runs bento. |
| `/bento:update` | Pull the latest bento and redeploy your stacks. |
| `/bento:status` | Read-only health check (services, HTTPS, disk/memory). |
| `/bento:auth` | Register an AI-provider API key and propagate it to your stacks. |

**Operate** — day-2 work *inside* the deployed apps, through each one's API.
You don't invoke these by name: Claude auto-loads the right one when you describe
the task in plain language (*"send a WhatsApp"*, *"reply to a customer"*,
*"build a workflow"*). Each discovers the host/credentials from bento state — it
never hardcodes your instance.

| Command | Operate… | Talk to it like |
|---|---|---|
| `/bento:paperclip` | Paperclip agent orchestration — agents, instruction bundles, skills, board issues. | *"create an agent / import skills / clean up the board"* |
| `/bento:hermes` | Hermes agent gateway — chat over the OpenAI-compatible API, run the CLI, wire MCP servers. | *"talk to my agent / give it the youtube tools"* |
| `/bento:n8n` | n8n workflows, driven through the n8n-mcp tools (schemas + validation baked in). | *"build / fix / run a workflow"* |
| `/bento:evolution-api` | Evolution API — WhatsApp instances, QR pairing, send messages, webhooks. | *"connect my WhatsApp / send a message"* |
| `/bento:chatwoot` | Chatwoot support desk — conversations, replies, contacts, inboxes. | *"reply to a customer / list open chats"* |
| `/bento:typebot` | Typebot chatbots — start/continue chats, publish, read results (builder vs viewer). | *"start a bot chat / get results"* |
| `/bento:plunk` | Plunk transactional email — send, track events, manage contacts (AWS SES behind it). | *"send an email / track an event"* |
| `/bento:metamcp` | MetaMCP gateway — group MCP servers into namespaces + endpoints, mint keys. | *"add an MCP server / get my tools endpoint"* |

Example: *"`/bento:install` on root@198.51.100.42, domain example.com, apps n8n
and chatwoot"* → Claude takes it from there. Later: *"send a WhatsApp to +55…
saying the order shipped"* → Claude loads `/bento:evolution-api` on its own.

<details>
<summary><strong>Windows</strong> — the only local requirement is a working <code>ssh</code></summary>

Docker and everything else run on the VPS, so locally you just need Claude Code
+ `ssh`. The lowest-friction path is **WSL2**, where the commands are identical
to macOS/Linux:

```powershell
wsl --install        # PowerShell as admin, then reboot
```
```bash
# inside the Ubuntu/WSL terminal:
ssh-keygen -t ed25519                       # paste the .pub into Hetzner
curl -fsSL https://claude.ai/install.sh | bash
claude                                       # then: /plugin marketplace add … / /plugin install …
```

Native Windows works too (`irm https://claude.ai/install.ps1 | iex`, plus Git
for Windows for the Bash tool); if `ssh` complains about key permissions, run
`icacls "$env:USERPROFILE\.ssh\id_ed25519" /inheritance:r /grant:r "$env:USERNAME`:F"`.
</details>

---

## Stacks

Each stack is a directory at `stacks/<category>/<key>/` with `compose.yml`, `manifest.json`, and optionally `install.sh`. Adding a new stack is documented in [CLAUDE.md](CLAUDE.md).

| Category | Stack | What it is |
|---|---|---|
| infra | [Traefik](stacks/infra/traefik) | Reverse proxy + Let's Encrypt |
| infra | [Portainer](stacks/infra/portainer) | Stack manager UI |
| db | [PostgreSQL](stacks/db/postgres) | Each app creates its own database in `install.sh` |
| db | [Redis](stacks/db/redis) | In-memory cache |
| app | [Backup](stacks/app/backup) | Scheduled restic backups (postgres dumps + state + app volumes) to Backblaze B2 |
| app | [Chatwoot](stacks/app/chatwoot) | Customer support platform |
| app | [CLI Proxy API](stacks/app/cli-proxy-api) | OpenAI-compatible proxy in front of CLI providers |
| app | [Crawl4AI](stacks/app/crawl4ai) | Headless web crawler/extractor (internal-only). Optional outbound proxy to dodge datacenter-IP anti-bot blocks — see [docs/reference/crawl4ai-proxy.md](docs/reference/crawl4ai-proxy.md) |
| app | [Evolution API](stacks/app/evolution-api) | WhatsApp gateway |
| app | [Hermes](stacks/app/hermes) | Seeds a shared volume with Hermes Agent so Paperclip's hermes_local adapter can exec the CLI locally (overlay-only, idle sleep, no gateway) |
| app | [MetaMCP](stacks/app/metamcp) | MCP aggregator/gateway — unify multiple MCP servers (stdio + HTTP) behind one endpoint, with a web admin UI |
| app | [n8n](stacks/app/n8n) | Workflow automation |
| app | [n8n MCP](stacks/app/n8n-mcp) | MCP server for n8n |
| app | [Openclaw](stacks/app/openclaw) | Personal AI assistant with a web Control UI — sign in with your ChatGPT/Claude subscription, chat, connect a Telegram bot, no terminal. OpenAI-compatible API kept for overlay consumers |
| app | [Paperclip](stacks/app/paperclip) | AI agent orchestration (Claude Code, Codex, OpenCode, Hermes via hermes-bin volume) |
| app | [Plunk](stacks/app/plunk) | Open-source email platform |
| app | [RabbitMQ](stacks/app/rabbitmq) | Message broker |
| app | [Typebot](stacks/app/typebot) | Chatbot builder |

---

## Prerequisites

### VPS

<!-- TODO: replace YOUR_REF with the real Hetzner affiliate code before pushing. -->

| Partner | When | Plan | Link |
|---|---|---|---|
| **Hetzner** (primary) | EU/US users — bento is smoke-tested against it every release | CX22, latest Ubuntu LTS | [hetzner.cloud](https://hetzner.cloud/?ref=YOUR_REF) |
| Hostinger (secondary) | Brazil-based users — BRL billing, low BR latency | KVM 2+, latest Ubuntu LTS | [hostinger.com/br/smartdev](https://hostinger.com/br/smartdev) |

<details>
<summary>Affiliate disclosure (read once, applies to both)</summary>

Both links above are affiliate referrals. Signing up through them gives bento a small commission that funds new stacks and bug fixes — there is **no premium price** for you and **no functional difference** from a direct signup. If you'd rather not contribute, just visit [hetzner.com](https://hetzner.com) or [hostinger.com](https://hostinger.com) directly and the installer works identically. Same goes for any apt-based VPS (DigitalOcean, OVH, Vultr, your own metal).

</details>

### DNS

You need a wildcard A record before Step 2, or Let's Encrypt fails on first boot:

| Type | Name             | Value           |
|------|------------------|-----------------|
| A    | `*.mydomain.com` | `<your VPS IP>` |

(bento only uses subdomains. If you already have a website at the bare `mydomain.com`, leave its existing A/CNAME alone — the wildcard above won't touch it.)

[**Open the DNS records page on Cloudflare →**](https://dash.cloudflare.com/?to=/:account/:zone/dns) — Cloudflare prompts you to pick the account + zone, then drops you straight onto the records page. Cloudflare is the recommended DNS host (free tier, fast); any provider works.

Verify before Step 2:

```bash
dig +short A portainer.mydomain.com
# should print your VPS IP
```

### Firewall

| Layer | What it does | Setup |
|---|---|---|
| **Hetzner Cloud Firewall** | Edge filter; optional | Manual, in Hetzner panel |
| **UFW + fail2ban** | Default-deny inbound, `limit ssh`, allow 80/443/ICMP | Automatic during Step 1 |

<details>
<summary>Recommended Hetzner Cloud Firewall ruleset</summary>

In **Firewalls → Create Firewall → Apply to your server**:

| Direction | Source | Port | Protocol | Why |
|---|---|---|---|---|
| Inbound | Your home IP | 22 | TCP | SSH — or leave open and let `ufw limit` + fail2ban handle brute-force |
| Inbound | `0.0.0.0/0` | 80 | TCP | Let's Encrypt HTTP-01 + HTTPS redirect |
| Inbound | `0.0.0.0/0` | 443 | TCP | HTTPS |
| Inbound | `0.0.0.0/0` | any | ICMP | `ping` debugging |
| Outbound | `0.0.0.0/0` | all | all | Default |

If you lock SSH to your home IP and your IP changes (mobile, ISP renewal), use Hetzner's web console to recover. For starter setups, leaving SSH open with `ufw limit` + fail2ban is a reasonable trade-off.

</details>

---

## After install

### Handoff HTML

When Step 3 finishes — or any time, from the **Report** menu — bento writes a self-contained HTML file with the VPS overview, Traefik + Portainer access, and every deployed stack's URL and resolved env vars. Secrets are masked by default with click-to-reveal; print to PDF auto-reveals everything for offline handoff.

```
~/.local/share/bento/reports/handoff-<timestamp>.html       # chmod 600
```

Move it off the VPS:

```bash
scp user@vps:~/.local/share/bento/reports/handoff-*.html .
```

> The report carries live credentials. Treat it like a password vault: deliver over an encrypted channel (1Password, Bitwarden Send, encrypted email), rotate if it ever leaks.

### Backups

If you deployed the [`backup` stack](stacks/app/backup), restic snapshots run nightly to Backblaze B2 (default `0 3 * * *`). The handoff HTML surfaces:

- The Backblaze repository URL
- The schedule
- The last successful backup timestamp (refreshed on every `Report` run)
- `RESTIC_PASSWORD` — **save this in your password manager immediately**. Restic encrypts client-side; lose this password and every snapshot is unrecoverable.

Day-to-day ops live under `Backup` in the main menu (`bash ~/.local/share/bento/install.sh` → `Backup`): run on demand, list snapshots, check status, print the exact restore command, test B2 connectivity. Full restore procedure: [`docs/reference/backup.md`](docs/reference/backup.md).

### Ownership: bento vs Portainer

Same split as Helm + kubectl. bento owns the declarative state; Portainer owns day-to-day operations.

| Concern | bento | Portainer |
|---|---|---|
| Declarative state (what should run, with which envs) | owner | viewer |
| First deploy + git-backed updates | owner (via API) | executor |
| Logs, restart, scale, exec | redirect | owner |
| Stacks created outside bento (no `BENTO_MANAGED` label) | ignored | full owner |

Every bento-deployed stack carries `BENTO_MANAGED=true` + its source commit, so bento can spot drift and offer to reconcile during **Update**.

---

## Operations

### Update bento and stacks

Re-running the curl|bash command always re-clones the latest `boot.sh`. Or, from the menu, pick **Update** to:

- Pull the latest bento code locally (`git fetch + reset --hard`).
- Re-deploy any stack whose `compose.yml` or `manifest.json` changed since the last deploy (`POST /api/stacks/<id>/git/redeploy`).

### State and configuration

| Path | Mode | Purpose |
|---|---|---|
| `~/.config/bento/state.json` | 600 | Domain, email, IP, generated secrets, deployed-ref per stack |
| `~/.config/bento/portainer.json` | 600 | Portainer admin credentials |
| `~/.local/state/bento/logs/` | 700 | Hardening + install logs |
| `~/.local/share/bento/reports/` | 700 | Handoff HTML reports |

The state schema is versioned and migrated automatically across bento updates.

### Manual install (no curl|bash)

```bash
git clone --branch stable https://github.com/felipefontoura/bento ~/.local/share/bento
cd ~/.local/share/bento
bash install.sh
```

### Requirements

- Latest Ubuntu LTS, Debian, or any apt-based distro
- `root` or a non-root user with `sudo` — running directly as `root` on a fresh VPS is fine
- 1+ GB RAM, 5+ GB free disk
- Public IPv4
- Wildcard DNS pointing to that IPv4

---

## For maintainers and contributors

Adding a stack, changing conventions, or extending the installer? Read **[CLAUDE.md](CLAUDE.md)** — the canonical maintainer guide. It covers the Bento ↔ Portainer ownership model, the manifest schema, env resolution order, code style for shell + YAML + JSON, and a step-by-step recipe for adding new application stacks (with n8n called out as the gold-standard quality bar).

`.claude/skills/contribute-stack/` is a Claude Code skill (invoked `/contribute-stack`) that automates the new-stack scaffold for AI-assisted contributions. It guards on being inside a repo clone, so it never fires for end users who only installed the `bento` operator plugin.

PRs welcome. Open an issue first for anything beyond a small fix.

---

## License

Distributed under the MIT License.
