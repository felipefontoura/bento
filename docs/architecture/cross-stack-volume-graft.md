# Cross-stack volume grafting

How bento lets one stack publish a binary tree (or any read-only artifact)
that another stack consumes — without coupling either stack's `compose.yml`
to the other, and without building custom Docker images.

The first real consumer is the `hermes` → `paperclip` pair, where Paperclip's
`hermes_local` adapter needs `/opt/hermes/bin/hermes` accessible inside the
Paperclip container. The pattern generalises.

## When to use this

You have two stacks where:

1. **Producer** ships a self-contained artifact tree on disk (a Python venv,
   a Node prefix, a chromium bundle, a static asset directory).
2. **Consumer** needs to exec or read that tree at a known path — typically
   because some bundled tool inside the consumer image (an adapter, an
   integration library, an SDK) shells out by absolute path.
3. You don't want to fork the consumer image just to install the producer's
   bytes. Custom Dockerfiles add CI/build/registry pipelines and bind the two
   together at image build time.
4. You don't want the consumer's `compose.yml` to declare the producer's
   volume as `external: true`, because that breaks the consumer's standalone
   deploy when the producer isn't present.

If all four are true, this is the pattern.

## How it works

```
┌─ producer stack ────────────────────────────────────────────┐
│  image: upstream/whatever:latest                            │
│  entrypoint: ["sleep", "infinity"]                          │
│  volumes:                                                   │
│    - producer-bin:/path/in/image          ← named-volume    │
│                                             seeding fills   │
│                                             the empty       │
│                                             volume from the │
│                                             image on first  │
│                                             mount           │
└─────────────────────────────────────────────────────────────┘
                          │
                          ▼
              ┌──────────────────────┐
              │  producer-bin        │
              │  (named volume)      │
              └──────────────────────┘
                          │
                          │  mounted read-only by install.sh
                          │  via `docker service update --mount-add`
                          ▼
┌─ consumer stack (compose.yml stays clean of producer) ──────┐
│  image: ghcr.io/whoever/consumer:latest                     │
│  volumes:                                                   │
│    - consumer-data:/wherever                                │
│    (no reference to producer-bin here)                      │
└─────────────────────────────────────────────────────────────┘
```

Three primitives:

### 1. Named-volume seeding

Docker has a quiet feature: when you mount an **empty** named volume on a path
that has content in the image, Docker copies the image's content into the
volume on the first attach. The container then sleeps forever — the running
process is irrelevant; all we needed was the bytes on disk in the volume.

```yaml
services:
  producer:
    image: upstream/whatever:latest
    entrypoint: ["sleep", "infinity"]
    volumes:
      - producer-bin:/path/in/image

volumes:
  producer-bin:
    driver: local
```

After `docker stack deploy producer`, the volume `producer_producer-bin`
contains a snapshot of `/path/in/image` from the image. The consumer can
mount that volume read-only and see the same tree at any path it likes.

### 2. Symmetric install.sh graft

The consumer's `compose.yml` doesn't declare the producer's volume because we
want the consumer to be standalone-portable. Instead, both stacks have an
`install.sh` post-deploy hook that calls the shared helper:

```bash
# stacks/app/producer/install.sh
source "${BENTO_REPO_ROOT}/lib/install-helpers.sh"
graft_external_volume_to_service consumer_consumer producer_producer-bin /path/in/consumer

# stacks/app/consumer/install.sh  (append to existing install.sh)
graft_external_volume_to_service consumer_consumer producer_producer-bin /path/in/consumer
```

`graft_external_volume_to_service`:

- Returns 0 silently if the consumer service doesn't exist yet.
- Returns 0 silently if the producer volume doesn't exist yet.
- Returns 0 silently if the target path is already mounted on the consumer.
- Otherwise: `docker service update --mount-add type=volume,source=<vol>,target=<path>,readonly <service>` (rolling update with `start-first`).

Idempotent on both sides. Symmetric: whichever stack deploys last wires the
mount. Either side rerunning is a no-op.

### 3. Soft skip when peer absent

Operator deploys only the consumer (no producer): consumer's install.sh logs
"`hermes_hermes-bin volume not present — running without …`" and continues.
Consumer runs in degraded mode — features that require the producer's tree
just fail at use-time with a sensible error from the bundled tool, not at
deploy-time.

## Behaviour matrix

| Producer deployed | Consumer deployed | Outcome |
|---|---|---|
| no | no | nothing |
| no | yes | consumer runs standalone (degraded, no producer features) |
| yes | no | producer seeds its volume, sleeps idle |
| yes | yes | mount grafted by whichever was deployed last; symmetric re-runs are no-ops |

## Operational gotchas

### Upgrading the producer

The named volume keeps its first seed. To pull a new producer image and
re-seed:

```bash
docker stack rm producer
docker volume rm producer_producer-bin
docker pull upstream/whatever:latest
docker stack deploy -c stacks/app/producer/compose.yml producer
```

Or via bento: `bento install --apps producer` after wiping the volume.

### Consumer redeploy drops the mount?

It depends on the redeploy path:

- **`bento install --apps consumer`** runs the consumer's install.sh, which
  re-grafts. Mount survives.
- **Portainer "Update the stack" on the consumer** does NOT rerun
  install.sh. The mount survives because Swarm preserves the service spec
  including the runtime mount additions; only a `docker stack rm consumer &&
  docker stack deploy ...` cycle would lose the mount, and then bento's next
  `install --apps consumer` re-grafts it.

### Cross-stack circular dep?

There isn't one. `compose.yml` files are mutually unaware. The coupling lives
entirely in the install.sh hooks, which run AFTER `docker stack deploy`
succeeds.

## How to add a new pair

1. Write the producer stack's `compose.yml` with `entrypoint: ["sleep",
   "infinity"]` (no app process), declaring the named volume on the path you
   want to expose.
2. Add `stacks/app/<producer>/install.sh` with a single line:
   ```bash
   source "${BENTO_REPO_ROOT}/lib/install-helpers.sh"
   graft_external_volume_to_service <consumer-service> <volume-name> <target-path>
   ```
3. If the consumer stack also has an install.sh (most do), append the same
   line. If it doesn't, create one — three lines minimum (shebang +
   `source` + the call).
4. Document in the producer's `manifest.json` description that "deploying
   this stack grafts `<target>` into `<consumer>`".
5. No changes to the consumer's `compose.yml`. Ever.

## Why not just …

| Alternative | Why it loses |
|---|---|
| **Fork the consumer image to install producer** | Adds CI/build/registry pipeline. Consumer team's upstream updates require a rebuild. Coupling at image-build time. |
| **`external: true` volume in consumer's compose.yml** | Consumer fails to deploy when producer isn't present. Breaks standalone-portability. |
| **Compose profiles** | Docker Swarm ignores `profiles`. Only works with `docker compose`, not `docker stack deploy`. |
| **Compose `condition: service_started` in `depends_on`** | Swarm honours only the basic `depends_on` list form, not conditions. No way to express "mount this only if X exists". |
| **`docker compose override` files** | Swarm doesn't support override files. |
| **K8s init container** | Not Swarm. If you ever migrate, swap in an init container that copies into an emptyDir + sidecar pattern. |
| **HTTP gateway producer (e.g. Hermes gateway mode)** | Loses subprocess semantics. The consumer's bundled tool that calls `hermes` as a CLI doesn't work over HTTP. Different design space. |

## Reference implementation

Concrete files:

- `stacks/app/hermes/compose.yml` — producer (sidecar + named-volume seeding)
- `stacks/app/hermes/install.sh` — 8 lines, one call to the helper
- `stacks/app/paperclip/install.sh` (tail block) — 4 lines, same call from the
  consumer side
- `lib/install-helpers.sh::graft_external_volume_to_service` — the helper

Open the helper to read the contract:

```bash
graft_external_volume_to_service <peer-service> <volume> <target-path> [readonly|rw]
```

That's the API. Everything else is plumbing.
