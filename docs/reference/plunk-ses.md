# Plunk — AWS SES configuration set and event feedback

Plunk sends every email through SES with a **configuration set**
(`SES_CONFIGURATION_SET`), and learns what happened to it only from the
events SES publishes for that set: deliveries, opens, clicks, bounces and
complaints. The events travel SES → SNS topic → an HTTPS subscription on
Plunk's **API host**. If any link is missing, mail still goes out, but:

- the dashboard shows no deliveries, opens or clicks for any email;
- bounces and complaints never reach Plunk, so it keeps mailing dead and
  complaining addresses, which drags down the SES account's reputation
  (and, past AWS's thresholds, gets sending paused).

The set itself is not optional either: Plunk passes its name on every send,
and SES rejects a send whose configuration set doesn't exist. Leaving the
manifest default (`disabled`) with real SES keys means every send fails
(Plunk's set check logs `[SES] Configuration set "disabled" from
SES_CONFIGURATION_SET does not exist`).

## 1. Create the configuration set

AWS Console → SES (in `AWS_SES_REGION`) → Configuration sets → **Create set**.
Name it whatever you put in `SES_CONFIGURATION_SET` (e.g.
`<account>-plunk-tracking`). Defaults are fine; open and click tracking come
from the event destination below.

## 2. Create the SNS topic

AWS Console → SNS (same region) → Topics → **Create topic**: Standard, e.g.
`<account>-plunk-ses-events`. No subscription yet.

## 3. Add the event destination

Back in the configuration set → Event destinations → **Add destination**:

- Event types: **Sends, Deliveries, Opens, Clicks, Hard bounces,
  Complaints** (Plunk handles `Delivery`, `Open`, `Click`, `Bounce`,
  `Complaint`).
- Destination: **Amazon SNS**, the topic from step 2.

## 4. Subscribe Plunk to the topic

SNS → the topic → **Create subscription**:

- Protocol: **HTTPS**
- Endpoint: `https://<PLUNK_API_HOST>/webhooks/sns`
- Raw message delivery: **off** (Plunk verifies the SNS signature on the
  envelope).

Plunk confirms the subscription by itself; within seconds the status reads
**Confirmed**. If it stays *Pending confirmation*, the endpoint isn't
reachable — check the API router in Traefik.

The endpoint is on the **API** host (`PLUNK_API_HOST`), not the dashboard.
Older Plunk releases used `https://<dashboard>/api/webhooks/incoming/sns`;
that path returns 404 on the `next` image. A subscription left on it stays
*Confirmed* in SNS while every event is lost, so after an upgrade from the
old image, re-point it here and delete the old one.

## 5. Verify

Send one email to an address you can read, then list the project activity:

```bash
curl -s -H "Authorization: Bearer $PLUNK_SECRET_KEY" \
  "https://$PLUNK_API_HOST/activity?limit=20" | jq -r '.data[] | "\(.timestamp) \(.type)"'
```

Within a few seconds `email.sent` is followed by `email.delivered`; opening
the email and clicking a link add `email.opened` and `email.clicked`. Only
`email.sent` and nothing else means step 3 or 4 is broken. A quick probe of
the endpoint itself: `curl -X POST -d '{}' https://$PLUNK_API_HOST/webhooks/sns`
answers `403 Invalid SNS signature` when the route is live.

Events are not replayed: emails sent while the chain was broken never get
their delivery, open or click recorded in Plunk.
