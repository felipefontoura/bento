# Plunk — AWS S3 for uploads

Plunk's `next`-architecture image (`ghcr.io/useplunk/plunk`) stores uploaded
campaign images and attachments in an S3-compatible bucket. Upstream's own
Docker Compose spins up a self-hosted MinIO container for this, but bento
skips MinIO: uploaded objects need a **publicly reachable URL** (email
recipients' mail clients load them directly), and MinIO on a private VPS
network isn't reachable from the internet without exposing another public
hostname and running your own TLS termination for it. A real AWS S3 bucket
already has a public HTTPS endpoint, so bento points `S3_ENDPOINT` at AWS
directly and leaves `S3_ACCESS_KEY_ID`/`S3_ACCESS_KEY_SECRET` to the operator.

If you skip this (leave the manifest defaults as `disabled`), Plunk boots
fine and sends email normally — only image/attachment uploads in the
campaign editor are affected.

## 1. Create the bucket

AWS Console → S3 → **Create bucket**:

- Name: match the manifest default, `<stack-key>-uploads` (e.g.
  `plunk-uploads`, or `felipefontoura-plunk-uploads` if you prefer the
  `<account>-<app>-<service>` naming convention used for the SES IAM
  resources in [`bento-auth.md`](bento-auth.md)).
- Region: same region as your SES setup (`AWS_SES_REGION`).
- **Uncheck** "Block all public access" — objects need to be world-readable.
  The bucket itself stays private to list; only the bucket policy below
  grants read on individual objects.

## 2. Bucket policy (public read, objects only)

Bucket → Permissions → Bucket policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "PublicReadObjects",
      "Effect": "Allow",
      "Principal": "*",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::<bucket-name>/*"
    }
  ]
}
```

This grants anonymous `GetObject` on objects inside the bucket — not
`ListBucket`, so the bucket's contents can't be enumerated.

## 3. IAM user + least-privilege policy

Create a dedicated IAM user (e.g. `<account>-plunk-s3`, matching the
semantic-naming convention) with an inline policy scoped to this one bucket:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject", "s3:DeleteObject", "s3:ListBucket"],
      "Resource": [
        "arn:aws:s3:::<bucket-name>",
        "arn:aws:s3:::<bucket-name>/*"
      ]
    }
  ]
}
```

Create an access key for this user and fill the manifest prompts:
`S3_ACCESS_KEY_ID`, `S3_ACCESS_KEY_SECRET` (hidden), `S3_BUCKET`.

## Other S3-compatible providers

`S3_ENDPOINT`, `S3_PUBLIC_URL`, and `S3_FORCE_PATH_STYLE` are independent
manifest prompts, not concatenated from `AWS_SES_REGION`/`S3_BUCKET` — so any
S3-compatible provider works, not just AWS:

| Provider | `S3_ENDPOINT` | `S3_FORCE_PATH_STYLE` |
|---|---|---|
| AWS S3 | `https://s3.<region>.amazonaws.com` | `false` |
| Backblaze B2 | `https://s3.<region>.backblazeb2.com` | `false` |
| Cloudflare R2 | `https://<account_id>.r2.cloudflarestorage.com` | `true` |
| MinIO (self-hosted) | `http://minio:9000` (internal) | `true` |

`S3_PUBLIC_URL` is whatever URL actually serves the bucket's objects
publicly — for R2 that's a configured custom domain or the `r2.dev`
subdomain, for B2 the friendly bucket URL, for a fronting CDN its own
hostname. Steps 1-3 above are AWS-specific; a non-AWS provider's own console
has the equivalent bucket-creation, public-read, and access-key steps.
