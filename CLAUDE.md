# CLAUDE.md

Maintainer guide for the `bento` repository. Read this before touching
anything. It is loaded automatically by Claude Code when you work in this
repo and is meant to be equally useful for any human contributor.

---

> **English only.** Every user-facing message (prompts, log lines, error
> output, README, CLAUDE.md, code comments) must be in English. We have
> users outside Brazil; mixed-language strings break documentation tools
> and look unprofessional. If you catch a `pt-BR` leak, fix it on sight.

> **Docs stay in sync with code.** Any change deeper than a one-line bug
> fix — a new stack, a behaviour change, a convention reversal, a path
> rename, a removed file — must be reflected in the docs in the same PR.
> Specifically:
>
> - **New / removed stack** → update the table in `README.md` *and* the
>   `stacks/` ASCII tree in this file.
> - **Convention change** (healthchecks, logging, secrets, deploy block,
>   etc.) → update the "Quality bar" table and the "How to add a new
>   application stack" section here, **and** the relevant guidance in
>   `.claude/skills/add-app-stack/SKILL.md`.
> - **New library file under `lib/`** → add it to the architecture box
>   *and* the `lib/` ASCII tree below.
> - **External-facing behaviour** (env vars, flags, prompts, report
>   contents) → update `README.md`.
>
> If a maintainer notices doc drift before code drift, fix it the same
> way. The rule is "no PR leaves the docs misleading."

## What this repo is

`bento` is an all-in-one installer that takes a fresh Ubuntu/Debian VPS to
"production-ready apps running" through a guided interactive menu. It is
**not** a generic Docker Swarm stack collection — it is an opinionated
platform where every stack is parametrized, generated, and deployed through
a single tool.

A user runs **one** `curl | bash` command, then a guided 3-step menu
(`Harden → Infra → Apps`) leaves them with a hardened host, Traefik +
Portainer with TLS, and the apps they picked, each ready for first login.

## Why it exists

Beginners with a brand-new VPS shouldn't need to:

- Read five docs to understand Docker Swarm bootstrap.
- Manually substitute env vars in YAMLs and SSH into Portainer to edit them.
- Wire TLS, networks, and ownership themselves.
- Track which secrets they generated and which they copied from examples.

`bento` collapses all of that into a guided flow that is also idempotent and
restartable.

## Repo meta

The governance is tiny on purpose. Two lines and four templates.

- License: @LICENSE — MIT.
- Contribution rule: @CONTRIBUTING.md — one sentence, taken at face value.
- Issue templates live under `.github/ISSUE_TEMPLATE/`:
  - `bug.yml` — broken installs, stacks that won't deploy, etc.
  - `feature.yml` — changes to bento behavior.
  - `stack-request.yml` — asks for a new application stack.
  - `config.yml` — disables blank issues, routes questions to Discussions.
- PR template: `.github/PULL_REQUEST_TEMPLATE.md` — description, type, test plan, conventions checklist.

When you change one of those files, this section stays in sync because the `@` references load them into context whenever Claude Code reads this file.

---

## Architecture in 60 seconds

```
curl | bash
    │
    ▼
boot.sh ─ validates apt-get exists, installs git, clones repo, sources install.sh
    │
    ▼
install.sh
    │
    ├── lib/palette.sh ANSI palette shared with boot.sh / banner / deps
    ├── lib/deps.sh    ensures gum + jq + envsubst + curl (idempotent)
    ├── lib/banner.sh  themed ASCII bento banner
    ├── lib/state.sh   reads/writes ~/.config/bento/state.json (schema versioned)
    ├── lib/ui.sh      gum wrappers + bento color palette + ui_input_validated
    ├── lib/hardening.sh  copied from felipefontoura/ubinkaze
    ├── lib/infra.sh   swarm init, network, deploy Traefik + Portainer, init admin
    ├── lib/portainer.sh  REST client (auth + stacks CRUD + git redeploy + JWT retry)
    ├── lib/stacks.sh  manifest discovery + env resolution + memory budget + deploy via API
    ├── lib/report.sh  generates handoff HTML at end of Step 3 / on demand
    ├── lib/install-helpers.sh  helpers used by per-stack install.sh scripts
    └── lib/auth-helpers.sh     helpers for scripts/bento-auth (OAuth wiring)
    │
    ▼
Bootstrap (one-time): asks BASE_DOMAIN + ADMIN_EMAIL + ADVERTISE_ADDR, persists to state
    │
    ▼
Main menu loop: Step 1 → Step 2 → Step 3, with Settings / Status / Update
```

- **State**: `~/.config/bento/state.json` (`chmod 600`, schema versioned, migrate-on-read).
- **Portainer creds**: `~/.config/bento/portainer.json` (`chmod 600`).
- **Logs**: `~/.local/state/bento/logs/`.
- **Repo clone**: `~/.local/share/bento/`.

## Bento ↔ Portainer ownership

This is the most important mental model in the repo. Same split as
Helm + kubectl or Terraform + the cloud console.

| Concern | bento | Portainer |
|---|---|---|
| Declarative state (what should run, with which envs) | owner | viewer |
| First deploy + bulk updates | owner (via API) | executor |
| Day-to-day ops (logs, restart, scale, exec) | redirect | owner |
| Stacks added directly in Portainer (no `BENTO_MANAGED` label) | ignored | full owner |

The discriminator is **`BENTO_MANAGED=true`**, set in two places:

1. As a **stack-level env var** on every `create_stack_from_git` call (Portainer keeps it on the stack record — that's what `update_redeploy_stacks` and Portainer's stack filter use).
2. As a **Docker service label** declared in every shipped `compose.yml` under `services.<name>.deploy.labels` (Swarm carries it on the running service spec — that's what `docker service ls --filter label=BENTO_MANAGED=true` and `auth_propagate_state_providers` use).

Both surfaces stay aligned because the CI job `BENTO_MANAGED labels` (`.github/workflows/lint.yml`) fails the PR if any stack `compose.yml` is missing the three labels (`BENTO_MANAGED`, `BENTO_STACK_KEY=<key>`, `BENTO_DEPLOYED_REF`). Anything without those is invisible to bento — Portainer/Swarm own it directly.

---

## Repo layout

```
bento/
├── boot.sh                       # curl|bash entry point
├── install.sh                    # main menu loop
├── README.md                     # user-facing quickstart
├── CLAUDE.md                     # this file
├── .claude/
│   └── skills/                   # task-specific playbooks for AI agents
│       ├── add-app-stack/
│       │   └── SKILL.md
│       └── install-bento/
│           └── SKILL.md
├── docs/
│   ├── architecture/
│   │   └── cross-stack-volume-graft.md  # pattern: producer→consumer via shared volume
│   └── reference/
│       └── bento-auth.md         # AI provider OAuth login (bento-auth script)
├── lib/
│   ├── auth-helpers.sh           # helpers for scripts/bento-auth
│   ├── banner.sh
│   ├── deps.sh
│   ├── hardening.sh              # copied from ubinkaze
│   ├── infra.sh
│   ├── install-helpers.sh        # helpers for per-stack install.sh scripts
│   ├── palette.sh                # pre-gum ANSI palette
│   ├── portainer.sh
│   ├── report.sh                 # handoff HTML generator
│   ├── stacks.sh
│   ├── state.sh
│   └── ui.sh
├── scripts/
│   └── bento-auth                # AI provider OAuth + API-key login wrapper
└── stacks/
    ├── infra/
    │   ├── traefik/compose.yml
    │   └── portainer/compose.yml
    ├── db/
    │   ├── postgres/{compose.yml, manifest.json}
    │   └── redis/{compose.yml, manifest.json}
    └── app/
        ├── chatwoot/{compose.yml, manifest.json, install.sh}
        ├── hermes/{compose.yml, manifest.json}
        ├── n8n/{compose.yml, manifest.json, install.sh}
        ├── openclaw/{compose.yml, manifest.json, install.sh}
        ├── paperclip/{compose.yml, manifest.json, install.sh}
        └── …
```

## Stack layout (the convention)

**Every stack lives under `stacks/<category>/<key>/`** where `<key>` is the
stack name. The directory name **is** the stack identity — it appears in
Portainer, in env labels, in URLs.

Files inside:

| File | Required? | Purpose |
|---|---|---|
| `compose.yml` | yes | Docker Compose YAML, parametrized with `${VAR}` |
| `manifest.json` | yes | env spec + metadata |
| `install.sh` | optional | post-deploy bootstrap (DB create, migrations, seed) |
| `Dockerfile` | almost never | only when an upstream image genuinely cannot be reused. bento's build-first path in `lib/stacks.sh` picks it up automatically, but the operational cost (slow first boot, big images, disk pressure on small VPS) is steep — prefer extending the running container via `docker exec`. |

Discovery in `lib/stacks.sh` globs `stacks/*/*/manifest.json` so adding a new
stack means just creating its directory — no central registry to edit.

---

## Manifest schema

`stacks/<category>/<key>/manifest.json` declares everything bento needs to
know about the stack at deploy time.

```json
{
  "name": "n8n",
  "category": "app",
  "description": "Workflow automation (editor + worker + webhook)",
  "depends_on": ["postgres", "redis"],
  "env": [
    {
      "name": "N8N_HOST",
      "default": "n8n.${BASE_DOMAIN}",
      "prompt": "n8n editor hostname"
    },
    {
      "name": "N8N_ENCRYPTION_KEY",
      "generate": "openssl rand -hex 32",
      "hide": true
    },
    {
      "name": "POSTGRES_PASSWORD",
      "from_state": "POSTGRES_PASSWORD"
    }
  ],
  "post_deploy_url": "https://${N8N_HOST}"
}
```

| Field | Required | Meaning |
|---|---|---|
| `name` | yes | Stack key (must match directory name). |
| `category` | yes | One of `infra`, `db`, `app`. |
| `description` | yes | One-line description shown in the menu. |
| `depends_on` | no | Array of stack keys to ensure are deployed first. |
| `env[]` | yes | List of env vars; see resolution rules below. |
| `post_deploy_url` | no | URL printed at the end (template-substituted). |
| `compose_path` | no | Override the auto-derived `compose.yml`. Rarely needed. |
| `install_script` | no | Override the auto-derived `install.sh`. Rarely needed. |

### Env entry fields

| Field | Effect |
|---|---|
| `name` | Variable name. Must match `${NAME}` in compose.yml. |
| `default` | Template string used as the prompt default (`${BASE_DOMAIN}`, `${ADMIN_EMAIL}` expanded). |
| `prompt` | Human label shown above the input field. If absent and no other source provides a value, the var is skipped. |
| `required` | If `true`, an empty answer is rejected. |
| `generate` | Shell command whose stdout becomes the value. Implies the var is auto-generated, no prompt. |
| `from_state` | Pull the value from another state path (e.g. `POSTGRES_PASSWORD` reads `state.envs.postgres.POSTGRES_PASSWORD`). |
| `hide` | Set to `true` for secrets — the prompt masks input and the value is never echoed in summaries. |

### Resolution order

`lib/stacks.sh:stacks_resolve_env` walks this list in order. The first match
wins:

1. **Existing state** — if `state.envs.<stack>.<var>` already has a value, reuse it (no prompt).
2. **`from_state`** — pull from another state path.
3. **`generate`** — run the command, persist the result.
4. **`default`** + `prompt` — show the prompt with the substituted default.
5. **`required`** — empty answer rejected.

This means: **the user only sees prompts for the values they actually have
to type.** Hostnames default to `<key>.${BASE_DOMAIN}` and just need an
Enter; secrets are generated; DB passwords are reused from the postgres
stack.

---

## Quality bar — what "production-ready" means here

Before any stack gets merged, it should clear the same bar that `n8n/`
already clears. Look at `stacks/app/n8n/compose.yml` and use it as the
benchmark. Concretely:

| Aspect | Minimum | Gold-standard (n8n level) |
|---|---|---|
| Image tag | `:latest` accepted only if upstream is stable | Pin to a real release (`v1.x.y`) and document bump cadence |
| Env vars | All deployment-variable values use `${VAR}` | Grouped into commented categories with a one-line WHY per variable, mirroring upstream's docs |
| Hostnames | At least the primary hostname is parametrized | All public surfaces (editor + webhook + builder + viewer if applicable) |
| Healthcheck | DBs only (`pg_isready`, `redis-cli ping`, `rabbitmq-diagnostics ping`) — cheap, meaningful, never wedge boot | Same |
| Deploy block | `replicas`, `placement`, `update_config`, `restart_policy` (start-first stateless / stop-first stateful) | Same + `resources.limits` |
| BENTO labels | **Mandatory.** `deploy.labels` includes `BENTO_MANAGED=true`, `BENTO_STACK_KEY=<key>`, `BENTO_DEPLOYED_REF=${BENTO_DEPLOYED_REF:-unknown}`. Enforced by the `BENTO_MANAGED labels` CI job. | Same |
| Logging | `json-file` + `max-size: 10m` + `max-file: 3` | Same |
| Resources | None acceptable only for genuinely tiny services. **Avoid `reservations` — Swarm guarantees them at placement time and they bin-pack worse than limits-only on small VPS.** | `limits` only for CPU and memory; calibrate from `docker stats` of a warm instance |
| Network | `network_public` only | Same — apps connect via service name |
| Volumes | `driver: local` for anything app-private | Same; no `external: true` outside `network_public` |
| Secrets | Generated via manifest, never literal `secret` | Same |
| Comments | Section dividers (`# ====`) | Section dividers + per-var WHY comments + examples for commented-out alternatives (SMTP, OAuth, S3) |

A stack that only ticks "Minimum" is acceptable for genuinely simple
services (e.g. `cli-proxy-api`). Anything with non-trivial configuration
must aim for "Gold-standard" — copy n8n's env block layout literally.

## How to add a new application stack

This is the most common contribution. Follow it step by step.

### 1. Pick a key

Lowercase, kebab-case, matches what you want the user to see in menus and
URLs. Examples: `n8n`, `cli-proxy-api`, `paperclip`.

### 2. Create the directory

```bash
mkdir stacks/app/<your-key>
```

### 3. Fetch the upstream reference first

**Do not write `compose.yml` from memory.** Every serious open-source
project publishes a reference `docker-compose.yml` and an env example.
Pull them and use them as the source of truth:

```bash
# Replace <owner>/<repo> with the upstream project.
gh api repos/<owner>/<repo>/contents/docker-compose.yml --jq '.content' | base64 -d
gh api repos/<owner>/<repo>/contents/.env.example     --jq '.content' | base64 -d
gh api repos/<owner>/<repo>/releases/latest           --jq '.tag_name'
```

If the project uses different paths (`docker/compose.yaml`, `docs/`,
multi-file setups), search:

```bash
gh api search/code -X GET -f q="repo:<owner>/<repo> filename:docker-compose"
```

For things gh can't reach (deployment docs, third-party guides), use
`WebFetch` against the project's README or docs page.

From the upstream artifacts you extract:

- Every required env var with its purpose, default, and whether it's secret.
- The recommended image and the **latest stable** release tag (pin it, do
  not use `latest`).
- Required ports and healthcheck patterns.
- Service dependencies (Postgres, Redis, MinIO, etc.).

### 4. Write `compose.yml` — n8n is the gold standard

Once you have the upstream reference, model the file on the closest
existing stack:

- **Gold-standard reference**: `stacks/app/n8n/compose.yml`. Its env block
  is grouped into commented categories (Core, Observability, Database,
  Public URLs, Queue Mode, Execution Control, UI, Persistence, Code Node,
  Workers, Security, Binary Data, Email), every var has a one-line WHY
  comment, and the deploy block has `update_config` + `restart_policy`.
  **Always aim for this depth** unless the app is genuinely simpler.
- **Multi-service** (editor + worker + webhook pattern): same n8n.
- **Rails-style with DB migrations**: `stacks/app/chatwoot/`.
- **Genuinely tiny**: `stacks/app/cli-proxy-api/` — only when there are no
  meaningful knobs to document.

Replace any string that varies between deployments with `${VAR}`:

- Hostnames in Traefik labels: `` Host(`${YOUR_HOST}`) ``
- Public URL envs: `APP_URI=https://${YOUR_HOST}`
- Secrets / API keys / JWT signing: `JWT_SECRET=${YOUR_JWT_SECRET}`
- Database connection strings: `postgresql://postgres:${POSTGRES_PASSWORD}@postgres:5432/<dbname>`

**Volumes**: prefer `driver: local`. Only `network_public` should be
`external` (it's created during Step 1).

**Logging**: every long-running service must declare the standard
rotation block so a chatty debug-level app cannot fill the disk:

```yaml
logging:
  driver: json-file
  options:
    max-size: "10m"
    max-file: "3"
```

**Healthchecks**: do NOT add a Swarm healthcheck to an app service.
Earlier iterations had `wget -qO- http://127.0.0.1:<port>/` on every
app — they SIGKILLed perfectly healthy containers on small VPS,
either because the image lacked `wget` (typebot, paperclip) or
because Rails/Next.js bootstrap exceeded `start_period` (chatwoot,
typebot). Traefik's backend HTTP probe handles user-facing readiness
externally. The only healthchecks bento keeps are on databases
(`pg_isready`, `redis-cli ping`, `rabbitmq-diagnostics ping`) — they
are cheap, instantaneous, and meaningful.

**Traefik labels** (paste & adapt):

```yaml
- traefik.enable=true
- traefik.http.routers.<key>.rule=Host(`${YOUR_HOST}`)
- traefik.http.routers.<key>.entrypoints=websecure
- traefik.http.routers.<key>.tls.certresolver=letsencryptresolver
- traefik.http.routers.<key>.priority=2
- traefik.http.routers.<key>.service=<key>
- traefik.http.services.<key>.loadbalancer.server.port=<container-port>
- traefik.http.services.<key>.loadbalancer.passHostHeader=true
```

**`BENTO_MANAGED` labels** (mandatory — paste at the end of every `deploy.labels` block):

```yaml
- BENTO_MANAGED=true
- BENTO_STACK_KEY=<key>
- BENTO_DEPLOYED_REF=${BENTO_DEPLOYED_REF:-unknown}
```

These three surfaces are how everything bento-aware finds your stack at runtime: `docker service ls --filter label=BENTO_MANAGED=true` lists them, `auth_propagate_state_providers` propagates ambient AI-provider tokens to them, future reconciliation tooling matches `BENTO_STACK_KEY` against `state.stacks.<key>` to detect orphans. The CI job `BENTO_MANAGED labels` fails the PR if any of the three is missing. `${BENTO_DEPLOYED_REF:-unknown}` is a stack-level env that `lib/stacks.sh::stacks_build_env_payload` injects with the current git SHA on deploy; the fallback `:-unknown` keeps `docker compose config` quiet during local lint runs.

### 5. Write `manifest.json`

Template:

```json
{
  "name": "<your-key>",
  "category": "app",
  "description": "<one line>",
  "depends_on": [],
  "env": [
    {
      "name": "<YOUR_KEY_UPPER>_HOST",
      "default": "<your-key>.${BASE_DOMAIN}",
      "prompt": "<Your App> hostname"
    }
  ],
  "post_deploy_url": "https://${<YOUR_KEY_UPPER>_HOST}"
}
```

Add entries to `env[]` for:

- **Hostnames** — `default: "<sub>.${BASE_DOMAIN}"`, with `prompt`.
- **Secrets** — `generate: "openssl rand -hex 32"`, `hide: true`. Pick a
  length that matches the app's expectation (32 chars for hex, 24 base64,
  64 hex for Rails secret key base).
- **DB password reuse** — `from_state: "POSTGRES_PASSWORD"`.
- **External API keys (optional)** — `prompt: "Optional: <X> API key"`,
  `hide: true` if secret.

Add `"depends_on": ["postgres"]` if the app needs Postgres,
`["postgres", "redis"]` for both.

Validate: `jq -e . stacks/app/<your-key>/manifest.json`.

### 6. Write `install.sh` (only when needed)

**Write one if** your app needs anything between `docker stack deploy` and
first login: DB creation, migrations, seed data, admin user via API.

**Skip it if** the app self-bootstraps on first browser visit (n8n, plunk,
typebot).

Template (Postgres database + done):

```bash
#!/bin/bash
set -euo pipefail
source "${BENTO_REPO_ROOT}/lib/install-helpers.sh"

ensure_database <dbname>
```

Template (DB + migration via Rails-style exec):

```bash
#!/bin/bash
set -euo pipefail
source "${BENTO_REPO_ROOT}/lib/install-helpers.sh"

ensure_database <dbname>

wait_for_service <stack-key>_<service-name> 240 || {
    echo "<service> did not become healthy; skipping bootstrap." >&2
    exit 1
}

cid=$(_find_container '<stack-key>_<service-name>')
sudo docker exec "$cid" <your-bootstrap-command>
```

Always `chmod +x stacks/app/<your-key>/install.sh`.

Env vars exported when `lib/stacks.sh` calls your script:

- `BENTO_REPO_ROOT` — absolute path to the bento clone.
- `BENTO_STACK_KEY` — your stack's key.
- `BENTO_STATE_FILE` — path to `state.json`.
- `POSTGRES_PASSWORD` — postgres superuser password (if postgres is deployed).

Helpers in `lib/install-helpers.sh`:

| Helper | Use |
|---|---|
| `ensure_database <name>` | Creates the DB if missing (idempotent). |
| `ensure_db_user <user> <pass>` | Creates/updates a Postgres role with LOGIN. |
| `grant_db_ownership <db> <user>` | Reassigns DB owner. |
| `psql_exec '<SQL>'` | Run arbitrary SQL as the postgres superuser. |
| `_find_container <pattern>` | First running container matching the name pattern. |
| `wait_for_service <docker-service-name> [timeout]` | Block until replicas match desired. |

### 7. Add to `README.md`

Under `### Applications`, alphabetically:

```markdown
- **[<App Name>](stacks/app/<your-key>):** <one-line description>.
```

### 8. Smoke verify

From the repo root:

```bash
# Syntax of every shell script
find . -name '*.sh' -not -path './.git/*' -exec bash -n {} \;

# Validate every manifest
find stacks -name manifest.json -exec jq -e . {} \; >/dev/null

# Validate compose
docker compose -f stacks/app/<your-key>/compose.yml config >/dev/null

# Check there are no residual website.com or =secret literals
grep -rn 'website\.com\|=secret$' stacks/<your-key>/ || echo "clean"
```

### 9. Commit and push

Atomic commit per logical unit:

```
feat(<your-key>): add <App Name> stack
```

If you also added a DB dependency: separate commit `feat(<your-key>): add post-deploy DB init`.

---

## Code style

### Shell scripts (`*.sh`)

- `set -euo pipefail` at the top, `IFS=$'\n\t'` where it matters.
- Source dependencies via `$(dirname "${BASH_SOURCE[0]}")` for portability.
- Function names: `snake_case` with a module prefix (`portainer_login`,
  `stacks_deploy`).
- Use `local` for every function-scoped variable.
- Errors go to stderr (`>&2`). Exit codes matter — don't swallow them with
  `|| true` unless you mean it.
- `bash -n` must pass. Aim for `shellcheck` clean too.
- No comments restating what the code does; comment only the WHY when
  non-obvious.

### Compose YAML (`compose.yml`)

- 2-space indent.
- `${VAR}` for anything that varies per deployment.
- `${VAR:-default}` for optional with sensible defaults.
- `${VAR:?Missing X}` only when there is genuinely no useful default and the
  value must come from the user.
- Group envs into commented sections (see existing stacks for the
  established pattern).

### Manifests (`manifest.json`)

- Pretty-printed, 2-space indent.
- Lowercase field names. No trailing whitespace.
- `jq -e .` must succeed.
- Required fields: `name`, `category`, `description`, `env[]`.

---

## Common operations

### Reset all bento state on a VPS (clean re-test)

```bash
rm -rf ~/.config/bento ~/.local/state/bento ~/.local/share/bento
# Then in Portainer or via docker: remove stacks tagged BENTO_MANAGED=true,
# and the infra stack:
sudo docker stack rm infra
sudo docker stack ls
sudo docker volume prune -f
# Re-run boot.sh from scratch.
```

### Run the install menu locally without re-cloning

```bash
cd ~/.local/share/bento
bash install.sh
```

### Verbose Portainer API calls (for debugging deploys)

```bash
BENTO_VERBOSE=1 bash install.sh
```

Every `curl` issued by `lib/portainer.sh` is logged to stderr.

### Pin paperclip to a specific upstream tag

```bash
# edit stacks/app/paperclip/compose.yml:
#   image: ghcr.io/paperclipai/paperclip:v2026.X.Y
```

---

## State file shape

`~/.config/bento/state.json`:

```json
{
  "schema_version": 1,
  "bootstrap": {
    "base_domain": "mydomain.com",
    "admin_email": "admin@mydomain.com",
    "advertise_addr": "198.51.100.42",
    "portainer_host": "portainer.mydomain.com",
    "portainer_url": "http://127.0.0.1:9000",
    "portainer_admin_user": "deployer"
  },
  "foundation": {
    "swarm": "active",
    "network_public": "ready",
    "portainer": "ready"
  },
  "steps": {
    "hardening": "done",
    "infra": "done",
    "apps": "done"
  },
  "envs": {
    "postgres": { "POSTGRES_PASSWORD": "…" },
    "n8n":      { "N8N_HOST": "n8n.mydomain.com", "N8N_ENCRYPTION_KEY": "…", … }
  },
  "stacks": {
    "n8n": { "stack_id": 4, "deployed_ref": "abc1234" }
  }
}
```

Read with `state_get '.bootstrap.base_domain'`, write with
`state_set '.foundation.swarm' "active"`. Always go through `lib/state.sh`
so the schema migration runs.

---

## What lives in `.claude/`

- `.claude/skills/<name>/SKILL.md` — task-specific playbooks Claude Code
  loads as slash commands when working in this repo. Currently:
  - `add-app-stack` — scaffolds a new stack following the convention above.
  - `install-bento` — drives a complete bento install end-to-end on a
    fresh VPS via SSH using `BENTO_UNATTENDED=1` (no TUI). Owns the
    watch-output → match-pattern → run-recovery loop the operator used
    to walk manually; reports back with credentials, per-app URLs,
    bootstrap invite links, and the handoff HTML path.

Skills are optional sugar — every step is also written out in plain prose
above. A human can follow the recipe without Claude.

---

## External attributions

- **Hardening script** — adapted from
  [felipefontoura/ubinkaze](https://github.com/felipefontoura/ubinkaze)
  (`stable` branch). Copied as `lib/hardening.sh`; OS check relaxed to any
  `apt-get`-capable distro.
- **UI** — Charm's [`gum`](https://github.com/charmbracelet/gum), installed
  from the Charm apt repo or downloaded as a release binary.
- **Paperclip** — upstream image
  [`ghcr.io/paperclipai/paperclip`](https://github.com/paperclipai/paperclip).
  Ships claude-code, codex, and opencode out of the box; extra CLIs are
  installed via `docker exec` on the running container.

---

## When in doubt

- Read an existing stack with similar shape (`plunk` for simple,
  `n8n` for multi-service, `paperclip` for custom build, `chatwoot` for
  Rails-style migration bootstrap).
- Smoke-verify before committing: `bash -n`, `jq -e .`,
  `docker compose config`.
- Commit atomically. Each commit should leave the repo in a coherent state.
