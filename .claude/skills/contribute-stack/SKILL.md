---
name: contribute-stack
description: For CONTRIBUTORS working inside a local clone of the bento repo — scaffold a new application stack (stacks/<category>/<key>/ with compose.yml + manifest.json + optional install.sh) following repo conventions, then commit it for a PR upstream. This is NOT an operator/end-user skill; it edits and commits repo files. To DEPLOY an app onto a running VPS, use the bento plugin's deploy skill instead.
---

# contribute-stack

Use this skill when a CONTRIBUTOR asks to add a new application stack to the
bento repo. Always start by reading `CLAUDE.md` for current conventions —
prefer its rules over anything stated here if they ever drift.

> **Context guard — check before doing anything.** This skill operates on a
> local clone of the bento repo: it creates files under `stacks/`, edits
> `README.md`, and makes a git commit. Confirm you are in that context —
> `CLAUDE.md` and a `stacks/app/` directory must exist in the working tree:
>
> ```bash
> test -f CLAUDE.md && test -d stacks/app && echo BENTO_REPO_OK
> ```
>
> If that fails, STOP. This is a contributor skill, not an operator one. The
> user is probably trying to **deploy** an app onto their own VPS — point them
> at the bento plugin's `/bento:deploy` skill, which does it over SSH without a
> local clone. Do not try to scaffold files outside a bento checkout.

**Every comment, message, and doc you produce must be in English.** Even
when the user prompts you in Portuguese, the artifacts going into the
repo stay English-only.

## When to invoke

Trigger phrases include:
- "add a new stack for <App>"
- "I want to bundle <App> into bento"
- "create a stack: <App>"
- "scaffold <App>"

If the user is just asking to **deploy** an existing stack via the menu,
that is not this skill — point them at `Step 3` in the install menu.

## Required inputs

Ask for these up front if missing:

1. **Stack key** — short, kebab-case, lowercase (e.g. `n8n`, `cli-proxy-api`).
   Will be the directory name and the user-visible label in the menu.
2. **Upstream GitHub repo** — `<owner>/<repo>` (e.g. `n8n-io/n8n`). This is
   non-negotiable: the skill fetches the project's own reference
   `docker-compose.yml` and `.env.example` before writing anything.
3. **Public-facing host** — does this app expose an HTTP UI/API behind
   Traefik? If yes, the default host pattern is `<key>.${BASE_DOMAIN}`.
   If no, no Traefik labels are needed.

Everything else (image tag, env vars, secrets, dependencies, ports,
healthcheck endpoint) is **derived from the upstream repo** in step 1
below — do not invent any of it from training data.

## Execution

Always run these steps **in order** with `TaskCreate` so progress is visible:

### 1. Fetch the upstream reference (mandatory)

Use `gh` to pull the project's own docker artifacts. **Do not guess env
vars or image tags from training data** — open-source projects keep these
in the repo, and that is the source of truth.

```bash
OWNER_REPO="<owner>/<repo>"

# Latest stable release tag — pin this in compose.yml, not :latest.
gh api "repos/${OWNER_REPO}/releases/latest" --jq '.tag_name'

# Reference docker-compose. Try the common paths.
for path in docker-compose.yml docker-compose.yaml compose.yml \
            compose.yaml docker/docker-compose.yml; do
    gh api "repos/${OWNER_REPO}/contents/${path}" --jq '.content // empty' \
        2>/dev/null | base64 -d && echo "--- from ${path}" && break
done

# Env example.
gh api "repos/${OWNER_REPO}/contents/.env.example" --jq '.content' \
    2>/dev/null | base64 -d

# README, especially the "Docker" / "Self-hosting" section.
gh api "repos/${OWNER_REPO}/readme" --jq '.content' | base64 -d
```

If `gh api contents/<path>` returns nothing, search:

```bash
gh api search/code -X GET \
    -f q="repo:${OWNER_REPO} filename:docker-compose"
```

For projects whose docs live outside the GitHub repo (their own website,
Notion, etc.), use `WebFetch` against the documented deployment page.

From the upstream artifacts, extract:

- **Image and tag** — pin the latest stable release.
- **All env vars** with purpose + default + whether secret.
- **Required ports** the app listens on.
- **Dependencies** — Postgres? Redis? S3-compatible? Mail relay?
- **Volumes** the app expects.
- **Multi-service shape** — does it deploy a separate worker/webhook/UI?

### 2. Read the closest existing bento stack

Pick the analogue and read its three files. **n8n is the gold standard for
parametrization quality** — copy its env-block layout (commented
categories, one-line WHY per var) unless the app is genuinely simpler.

- **Gold standard / categorized env block / multi-service**: `stacks/app/n8n/`.
- **Rails-style with DB migrations**: `stacks/app/chatwoot/`.
- **Genuinely tiny (no meaningful knobs)**: `stacks/app/cli-proxy-api/`.

(No stack ships a `build:` directive today — bento prefers upstream images
to keep first-boot fast and the host's disk pressure low on small VPS.
If you genuinely need to build, `lib/stacks.sh` still picks it up.)

Mirror the patterns exactly. Do not invent new structure or naming.

### 3. Create the directory

`stacks/app/<your-key>/`

### 4. Write `compose.yml`

Use the upstream reference as the base, then translate to bento
conventions. Aim for n8n's quality bar (see CLAUDE.md → Quality bar).

Parametrize everything that varies per deployment:

| Was hardcoded | Replace with |
|---|---|
| `Host(\`xxx.website.com\`)` | `` Host(`${KEY_HOST}`) `` |
| `APP_URI=https://xxx.website.com` | `APP_URI=https://${KEY_HOST}` |
| `JWT_SECRET=secret` | `JWT_SECRET=${KEY_JWT_SECRET}` |
| `postgresql://app:secret@postgres:5432/db` | `postgresql://postgres:${POSTGRES_PASSWORD}@postgres:5432/db` |
| `external: true` (volumes other than `network_public`) | `driver: local` |

Do NOT add a Swarm healthcheck to an app service. Bento removed them
on purpose: `wget`-based probes on small VPS were SIGKILLing healthy
containers (missing binary, slow boot, SSR compile inside the
`start_period`). Traefik does the user-facing health check externally.
The only healthchecks bento keeps are the cheap DB ones
(`pg_isready`, `redis-cli ping`, `rabbitmq-diagnostics ping`).

Always include a `logging:` block with `json-file` + `max-size: 10m`
+ `max-file: 3` — keeps a chatty debug app from filling the disk.

Use `network_public` external and as the only network attached.

**Env block layout** — group variables into commented sections with the
same pattern n8n uses:

```yaml
environment:
  # =============================================================================
  # Core Application
  # =============================================================================

  # Brief WHY this matters or what it controls.
  - SOME_VAR=${SOME_VAR}

  # =============================================================================
  # Database
  # =============================================================================

  # …
```

Categories that recur across stacks: `Core Application`,
`Observability / Logging`, `Public URLs / Reverse Proxy`,
`Database (PostgreSQL)`, `Cache / Queue (Redis)`, `Security`, `Email (SMTP)`,
`OAuth / Authentication`, `Storage (S3)`, `Workers / Queue Mode`, `Timezone`.

### 5. Write `manifest.json`

Required keys: `name`, `category` (`"app"`), `description`, `env[]`.

For each env in the compose, add a corresponding entry. Pick the right
resolution mode:

- `default: "<key>.${BASE_DOMAIN}"` + `prompt` — for hostnames the user may
  want to override.
- `generate: "openssl rand -hex 32"` + `hide: true` — for secrets.
- `from_state: "POSTGRES_PASSWORD"` — to reuse the postgres password
  without re-prompting.
- `prompt: "…"` + `hide: true` — for sensitive user-supplied values (API keys).
- `prompt: "…"` only — for non-sensitive optional values.

Set `depends_on: ["postgres"]` (or `["postgres", "redis"]`) if applicable.
Add `post_deploy_url: "https://${KEY_HOST}"` so the menu prints the right
URL at the end.

Validate with `jq -e .` before moving on.

### 6. Write `install.sh` ONLY if needed

Decide:
- **No install.sh** if the app self-bootstraps on first browser visit
  (n8n, plunk, typebot pattern).
- **Yes install.sh** if you need to: create a Postgres DB, run migrations,
  seed initial data, bootstrap an admin user via internal CLI/exec.

Template:

```bash
#!/bin/bash
set -euo pipefail
source "${BENTO_REPO_ROOT}/lib/install-helpers.sh"

ensure_database <dbname>
```

For Rails-style migrations, model on `stacks/app/chatwoot/install.sh`:
wait for the web service to be healthy, then `docker exec` the migration
command.

Make it executable: `chmod +x stacks/app/<your-key>/install.sh`.

### 7. Update README

Insert an alphabetical entry under `### Applications`:

```markdown
- **[<App Name>](stacks/app/<your-key>):** <one-line description>.
```

### 8. Smoke verify

Run all of these from the repo root and ensure each passes:

```bash
bash -n stacks/app/<your-key>/install.sh           # if it exists
jq -e . stacks/app/<your-key>/manifest.json
docker compose -f stacks/app/<your-key>/compose.yml config >/dev/null
grep -rn 'website\.com\|=secret$' stacks/app/<your-key>/ || echo "clean"
```

If any check fails, fix before reporting back to the user.

### 9. Commit

Single atomic commit:

```
feat(<your-key>): add <App Name> stack
```

If the install script is non-trivial, consider a follow-up commit:

```
feat(<your-key>): bootstrap database on first deploy
```

## Failure modes to watch for

- **Skipping the upstream fetch and inventing env vars** — the most common
  cause of a broken stack. Always fetch first.
- **Pinning `:latest` when the upstream has tagged releases** — defeats
  reproducibility. Use the tag from `releases/latest`.
- **Stack key mismatches directory name** — `manifest.json` `name` field
  must equal the directory name.
- **Forgetting `chmod +x` on install.sh** — `lib/stacks.sh` checks `-x`
  before running it, so a non-executable script is silently skipped.
- **Using `${VAR:?…}` for a default-able value** — that aborts with no
  default; prefer `${VAR:-default}` or proper manifest entries.
- **Flat env block without categories** — fails the quality bar. Group
  with comment headers like n8n does.
- **Reaching for a custom Dockerfile too quickly** — `lib/stacks.sh`
  auto-detects `build:` and runs `docker compose build` before the
  Portainer stack create, so a custom image will work, but the
  operational cost (big images, slow first deploy, disk pressure) is
  steep. Prefer extending the upstream image at runtime via
  `docker exec` whenever possible. If you must use a Dockerfile,
  context = `.` (the stack directory), dockerfile = `Dockerfile`.

## Reporting back

After finishing, tell the user:
- Upstream sources consulted (which `docker-compose.yml`, `.env.example`,
  README sections you read).
- Stack key chosen and directory created.
- Image tag pinned and what release it came from.
- Which env vars will be auto-generated vs prompted vs reused from state.
- Whether an install script was needed and what it does.
- The smoke checks that passed.
- Where the post-deploy URL will land.
