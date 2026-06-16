---
name: status
description: Read-only health check of a VPS running bento, via SSH. Reports Swarm service replicas for every BENTO_MANAGED stack, HTTPS reachability of each app, host resources (disk/memory/uptime), and any services stuck below desired replicas. Use when the user says "is my server ok", "check my bento VPS", "what's running", "status of my apps". Makes no changes.
---

This skill is READ-ONLY — it never mutates the host. Run it freely without a
confirmation prompt. All output stays in English.

# When to invoke

- "is my VPS healthy?"
- "what's running on my bento server?"
- "check `<host>`"
- "are my apps up?"

# Inputs

- VPS host (ask if missing), SSH user (default `root`).

# Checks (all read-only)

1. SSH + host basics:
   ```bash
   ssh "$user@$host" "uptime; echo '---'; free -m | awk 'NR<=2'; echo '---'; df -h / | tail -1"
   ```
   Flag if disk free < 2 GB or memory is exhausted.

2. Confirm bento is installed and read its view of the world:
   ```bash
   ssh "$user@$host" "jq -r '.bootstrap.base_domain, (.stacks | keys[])' ~/.config/bento/state.json"
   ```

3. Swarm services for every managed stack:
   ```bash
   ssh "$user@$host" "docker service ls --filter label=BENTO_MANAGED=true --format '{{.Name}}\t{{.Replicas}}\t{{.Image}}'"
   ```
   A service showing `0/1` (or any `n/m` with n<m) is unhealthy — call it out.

4. HTTPS reachability per app — read each manifest's `post_deploy_url`, then:
   ```bash
   ssh "$user@$host" "curl -sI --max-time 15 https://<app>.<base_domain>/ | head -1"
   ```
   (Run from the VPS so it works even if SSH is the only thing exposed to you.)

5. Recent service failures, if anything looked off:
   ```bash
   ssh "$user@$host" "docker service ps --filter 'desired-state=running' --format '{{.Name}}\t{{.CurrentState}}\t{{.Error}}' \$(docker service ls --filter label=BENTO_MANAGED=true -q) | grep -iE 'reject|fail|error' || echo 'no recent task errors'"
   ```

# Report back

A compact table: per stack → replicas (✓/✗), HTTPS status, image tag. Then a
one-line host summary (uptime, mem, disk). End with a verdict — "all green" or a
short list of what needs attention — and, when a stack is wedged, suggest the
next step (Portainer logs link, `/bento:update`, or `/bento:deploy` to
re-create it).
