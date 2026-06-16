---
name: update
description: Update an existing bento install to the latest code and redeploy its managed stacks, via SSH. Re-runs the bento bootstrap unattended (re-clones the chosen ref, re-applies idempotently, redeploys BENTO_MANAGED stacks). Use when the user says "update bento", "pull the latest bento", "redeploy my stacks". Causes brief redeploy downtime and may trigger a reboot if a kernel/core lib upgraded — always confirm first.
---

You are operating bento on a remote machine. An update redeploys running
services (brief downtime) and may reboot the host. **Confirm with the user
before proceeding.** All artifacts stay in English.

# When to invoke

- "update bento on `<host>`"
- "pull the latest bento and redeploy"
- "bump my server to the newest stacks"

If the user wants to add NEW apps (not update existing), use `/bento:deploy`.
For a fresh server, `/bento:install`.

# Pre-flight

1. SSH reachable: `ssh -o ConnectTimeout=5 "$user@$host" "echo SSH_OK"`.
2. Confirm bento is installed: `ssh "$user@$host" "test -f ~/.config/bento/state.json && echo BENTO_OK"`. If absent, stop.
3. Read the saved bootstrap values so you re-apply with the SAME config:
   ```bash
   ssh "$user@$host" "jq -r '.bootstrap | .base_domain, .admin_email, .advertise_addr' ~/.config/bento/state.json"
   ```
4. Ask which ref to update to (default `stable`; `main` or a feature branch only if the user asks).
5. **Confirm** with the user: "This redeploys your running stacks (seconds of downtime each) and may reboot the VPS if a kernel/core library upgraded. Proceed?"

# Update — unattended

Re-run the bootstrap one-liner unattended with the saved values. boot.sh
re-clones the latest ref into `~/.local/share/bento`, install.sh re-applies
every step idempotently (hardening is a no-op when already done), reconciles
`state.stacks` against Portainer, and redeploys the managed stacks.

```bash
ssh "$user@$host" "\
  BENTO_UNATTENDED=1 \
  BENTO_REF=<ref> \
  BENTO_BASE_DOMAIN=<base_domain> \
  BENTO_ADMIN_EMAIL=<admin_email> \
  ${ADVERTISE_ADDR:+BENTO_ADVERTISE_ADDR=$ADVERTISE_ADDR} \
  bash <(curl -sSL https://raw.githubusercontent.com/felipefontoura/bento/<ref>/boot.sh)"
```

If the run prints `BENTO_REBOOT_SENTINEL`, the VPS will reboot and the
`bento-resume.service` unit continues on next boot — follow the
"Post-hardening reboot" steps from the `install` skill (poll SSH back, then
`journalctl -u bento-resume.service -f`).

> Surgical alternative (no hardening pass, no reboot risk): the interactive
> **Update** menu does a `git fetch + reset --hard` and redeploys only stacks
> whose `compose.yml`/`manifest.json` changed. It is interactive and not
> cleanly scriptable over SSH — if the user wants that precise behaviour,
> tell them to run `bash ~/.local/share/bento/install.sh` and pick **Update**.

# Verify

After the run settles, do the read-only checks from `/bento:status`:
`docker service ls --filter label=BENTO_MANAGED=true` all at expected replicas,
and `curl -sI` each app URL. Report what changed and flag any service stuck
below its desired replica count.
