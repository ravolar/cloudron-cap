# Cap for Cloudron

Unofficial [Cloudron](https://cloudron.io) community package for [Cap](https://cap.so), the open
source alternative to Loom: record your screen and camera in the browser or the desktop app and
share a link that plays instantly.

The package runs Cap's official `cap-web` and `cap-media-server` images, unmodified, in one
Cloudron app, hardened for servers that host many other apps. It is in production use on
Cloudron 10.0 and tested on 10.1.

This project is not affiliated with or supported by Cap Software, Inc.

* [What you get](#what-you-get)
* [Requirements](#requirements)
* [Installation](#installation)
* [Configuration](#configuration)
* [Object storage](#object-storage)
* [Email](#email)
* [Security model](#security-model)
* [Resources](#resources)
* [Operations](#operations)
* [Troubleshooting](#troubleshooting)
* [Migrating an existing Cap installation](#migrating-an-existing-cap-installation)
* [How it works](#how-it-works)
* [Development and releasing](#development-and-releasing)
* [License](#license)

## What you get

* Cap web app and media server (video processing with ffmpeg) in one container, started and
  supervised together.
* Cloudron's MySQL addon as the database, included in Cloudron backups. Cap runs its own
  database migrations at startup.
* Recordings in any S3-compatible storage you configure (AWS S3, Cloudflare R2, Backblaze B2,
  MinIO, ...).
* Login links by email through Resend.
* A small guard proxy in front of Cap that closes endpoints which are risky on a shared server
  (see [Security model](#security-model)) and rate-limits expensive anonymous endpoints.
* Daily cleanup of finished video-processing job state.
* Updates through Cloudron like any other app, published from this repository.

## Requirements

* Cloudron **10.0** or newer.
* An **S3-compatible bucket** for recordings, reachable from viewers' browsers, with CORS rules
  for the app's origin (see [Object storage](#object-storage)). Cloudron has no object-storage
  addon, and recordings are **not** part of Cloudron backups.
* A **Resend** account with a verified sending domain, if users should receive login links by
  email. Cap does not support other mail providers, so the Cloudron mail server is not used.
* Free disk space of about three times your largest recording, for transcoding.
* Memory: about 0.5 GB at idle; allow 3 GB or more for transcoding (the default limit is 3 GB).

## Installation

1. In the Cloudron dashboard open **App Store → Add custom app → Community app** and enter:

   ```
   https://raw.githubusercontent.com/ravolar/cloudron-cap/main/CloudronVersions.json
   ```

   (CLI: `cloudron install --versions-url <url> --location cap.example.com`)
2. When the app runs, open its **File Manager** and edit `/app/data/env.sh`: object storage,
   Resend and, before anyone else gets the URL, `CAP_ALLOWED_SIGNUP_DOMAINS`.
3. **Restart** the app and check its log (see [Operations](#operations)).
4. On a server shared with other apps, give Cap a **CPU limit** in the app's Resources view and
   consider turning off automatic updates (see [Updates](#updates)).

If your domain's DNS is not managed by Cloudron (provider "manual" or "no-op"), create the DNS
record for the app's hostname yourself **before** installing, so the certificate can be issued.

## Configuration

All operator settings live in `/app/data/env.sh`, created with comments on first start. Edit it
with the dashboard's **File Manager** or web terminal and restart the app.

The file is read without being executed, so only plain assignments are accepted:
`NAME="value"` (no `$`, backticks or backslashes inside double quotes) or `NAME='value'`, one per
line, no `export`, no leading spaces, Unix line endings, optional ` # comment` after a value.
Anything else makes the app refuse to start, with the offending line numbers in the log.

| Variable | Required | Description |
|---|---|---|
| `CAP_AWS_ACCESS_KEY`, `CAP_AWS_SECRET_KEY` | yes | Credentials for the bucket. Prefer a key limited to this bucket. |
| `CAP_AWS_BUCKET` | yes | Bucket name. The bucket must exist. |
| `CAP_AWS_REGION` | yes | Region, e.g. `us-east-1` (MinIO), `auto` (R2), `eu-central-003` (B2). |
| `S3_PUBLIC_ENDPOINT` | yes | Endpoint URL used by browsers, **with** `https://`. |
| `S3_INTERNAL_ENDPOINT` | no | Endpoint the server uses, e.g. a LAN address of MinIO. Defaults to `S3_PUBLIC_ENDPOINT`. |
| `S3_PATH_STYLE` | no | `"true"` (default in the template) for path-style URLs; needed by MinIO. |
| `RESEND_API_KEY` | no | Resend API key (starts with `re_`). |
| `RESEND_FROM_DOMAIN` | no | A domain verified in Resend, e.g. `example.com` (not the key). |
| `CAP_ALLOWED_SIGNUP_DOMAINS` | recommended | Comma-separated email domains allowed to sign up. **Empty means anyone can sign up and upload.** |
| `CAP_VIDEOS_DEFAULT_PUBLIC` | no | Default visibility of new recordings. |
| `ASSEMBLY_API_KEY` | no | AssemblyAI key for transcriptions. |
| `AI_PROVIDER`, `AI_MODEL` | no | AI titles and summaries: `groq`, `openai` or `anthropic`, with the matching key below. |
| `GROQ_API_KEY`, `OPENAI_API_KEY`, `ANTHROPIC_API_KEY` | no | Keys for the AI provider. |
| `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` | no | Google login. |
| `CAP_ALLOW_CUSTOM_STORAGE` | no | `"true"` re-enables per-organisation custom S3 storage, which the guard proxy blocks by default (see [Security model](#security-model)). |
| `MEDIA_SERVER_MAX_CONCURRENT_VIDEO_PROCESSES` | no | Parallel transcodes, default `1`. Raise only together with a CPU limit. |
| `WORKFLOW_RETENTION_DAYS` | no | Days to keep the state of finished processing jobs, default `30`. |

Not configurable here, because the package derives them from the Cloudron environment on every
start: `DATABASE_URL`, `WEB_URL`, `NEXTAUTH_URL`, `MEDIA_SERVER_URL`, `MEDIA_SERVER_WEBHOOK_URL`.
This Cap version does not read `DEEPGRAM_API_KEY`, `RESEND_FROM`, `CAP_BLOCKED_SIGNUP_DOMAINS` or
`STRIPE_*` (cap.so's own billing).

### Secrets

`NEXTAUTH_SECRET`, `DATABASE_ENCRYPTION_KEY` and `MEDIA_SERVER_WEBHOOK_SECRET` are generated on
first start into `/app/data/.secrets/secrets.env` (root-only; edit it from the web terminal) and
never regenerated. **Keep `DATABASE_ENCRYPTION_KEY`**: encrypted database columns cannot be read
without it.

## Object storage

Browsers upload recordings straight to the bucket with presigned URLs and play them from there,
so:

* `S3_PUBLIC_ENDPOINT` must be reachable from viewers' browsers over HTTPS.
* The bucket needs **CORS rules** for the app's origin allowing `GET`, `HEAD` and `PUT` with any
  request headers. For example (S3/MinIO/R2 style):

  ```json
  [{"AllowedOrigins": ["https://cap.example.com"], "AllowedMethods": ["GET", "HEAD", "PUT", "POST"],
    "AllowedHeaders": ["*"], "ExposeHeaders": ["ETag"], "MaxAgeSeconds": 3600}]
  ```

  Backblaze B2: the web UI's CORS options only allow downloads. Set a custom rule with the B2
  CLI or API (operations `s3_get`, `s3_head`, `s3_put`, `s3_post`; rule names need at least 6
  characters).
* At startup Cap tries to create the bucket and set a public-read policy. Providers that refuse
  (e.g. B2) log an error and Cap continues.
* Cloudron backups don't include the bucket, and deleting a recording in Cap may remove its files
  from it. Protect the bucket on the storage side (versioning, replication or backups).

## Email

Cap emails login links through Resend. Set `RESEND_API_KEY` and `RESEND_FROM_DOMAIN` (a domain
verified in your Resend account). Without Resend, users can't receive login links by email.

## Security model

The package assumes that a vulnerability in Cap could be exploited and limits what a compromised
app process can reach on a shared Cloudron.

* **Privilege separation.** `start.sh` runs as root, never sources a file and never acts on a path
  the app user can rename or replace: `/app/data` and `env.sh` are root-owned (the app can read
  `env.sh` and write only `workflow-data`), `.secrets` is root-only, `/run/cap` is recreated on
  every start, and symlinks in place of these files make the app refuse to start. Operator
  settings are loaded by `app-env.sh` as the app user, right before each Cap process starts, so
  values such as `NODE_OPTIONS` never reach root.
* **Guard proxy** (`guard-proxy.mjs`) owns the public port and forwards to Next.js on
  `127.0.0.1:3001`. It
  * blocks per-organisation **custom S3 storage** (configuring it via `/api/desktop/s3/*` writes
    or the storage server actions, including no-JS form submissions): the server would connect to
    any host a user enters, including other apps on the Cloudron network, and return the
    response. Re-enable with `CAP_ALLOW_CUSTOM_STORAGE="true"` if you trust all users;
  * blocks internal endpoints from outside: `/api/cron/*`, `/api/dev-reset-transcript`,
    `/.well-known/workflow/v1/{flow,step}`;
  * rate-limits per client IP: OG image rendering (30/min), the image optimizer (2000/min), the
    Loom downloader and the docs AI (10/min).
* The **media server** listens on `127.0.0.1` only and runs in production mode.
* Cap's internal callers (workflow queue, media-server webhooks) talk to Next.js directly on the
  loopback port, bypassing the proxy.
* Restrict sign-up with `CAP_ALLOWED_SIGNUP_DOMAINS`; open sign-up is logged as a warning.

## Resources

* **CPU**: Cloudron sets no CPU limit by default. ffmpeg uses several cores per transcode, so on a
  shared server set a limit in the app's Resources view (e.g. 15–25 % of the host).
* **Memory**: the manifest default is 3 GB; next-server uses about 0.5 GB at idle.
* **Disk**: transcoding uses about three times the recording size in `/run/cap/tmp`. It is a
  Docker volume, so Cloudron does not count it in the app's disk usage; it shares the server's
  disk with all other apps.
* **MySQL**: Cap keeps roughly 10–20 connections to the shared MySQL addon.

## Operations

### Logs

Dashboard → app → Logs, or `cloudron logs -f --app <location>`. A healthy start shows:

```
==> Securing data directories
==> Setting up runtime directories
==> Waiting for MySQL
==> Starting Cap
[guard-proxy] blocking 4 storage server actions
[guard-proxy] listening on :3000 -> 127.0.0.1:3001
Started server: http://127.0.0.1:3456
Found existing S3 bucket
💿 Migrations run successfully!
```

`Tinybird is disabled` warnings are expected (cap.so analytics).

### Updates

New Cap images are packaged automatically: every 3 hours GitHub Actions checks for new images,
builds them and publishes a new version to `CloudronVersions.json` only after the smoke test and
an upgrade test with data have passed for the exact image (see
[Development and releasing](#development-and-releasing)). Cloudron then offers the update in the
app's **Updates** view (and installs it by itself only where automatic updates are on); it backs up the app before updating, so a bad update
can be rolled back from **Backups**. On servers with critical apps, keep automatic updates off and
apply updates by hand.

### Backups and restore

Cloudron backs up `/app/data` (`env.sh`, `.secrets/`, workflow state) and a dump of the MySQL
database; restore, clone and import work as for any app. **Recordings are not included**: they
stay in your bucket.

### Maintenance task

A Cloudron scheduler task (`prune-workflows`, daily at 04:23) deletes the on-disk state of
finished video-processing jobs older than `WORKFLOW_RETENTION_DAYS`. Running jobs are never
touched.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| App doesn't start; log shows `env.sh may only contain NAME="value" lines` | A line in `env.sh` isn't a plain assignment. Quote the value; use single quotes for values with `$`, backticks or backslashes. |
| `has Windows (CRLF) line endings` / `contains control characters` | Re-save `env.sh` with Unix line endings and without control characters. |
| `is a symbolic link ... Refusing to start` | One of the package's files was replaced by a symlink. Inspect it from the web terminal, replace it with a regular file and restart. |
| `object storage is not configured` | Fill in `CAP_AWS_*` and `S3_PUBLIC_ENDPOINT` in `env.sh`. |
| S3 errors such as `Invalid URL` | `S3_PUBLIC_ENDPOINT`/`S3_INTERNAL_ENDPOINT` must include `https://` (or `http://`). |
| Uploads fail in the browser, recordings don't play | The bucket's CORS rules don't allow the app's origin or `PUT`; see [Object storage](#object-storage). |
| Login emails don't arrive | Check `RESEND_API_KEY` (starts with `re_`) and that `RESEND_FROM_DOMAIN` is a domain verified in Resend. |
| `Failed to queue transcription: Missing necessary environment variables` | Transcription needs `ASSEMBLY_API_KEY`; without it recordings work, just without transcripts. |
| `403 Forbidden` when saving custom storage settings | Blocked by design; see [Security model](#security-model). |
| `Server Reference ID did not match the expected format` | Requests with a malformed `Next-Action` header from bots or old clients; harmless. |

## Migrating an existing Cap installation

This procedure moved a production Cap from Docker Compose to Cloudron with all its data.

1. **Prepare DNS and storage.** Make sure the bucket's CORS rules allow the Cloudron hostname. If
   Cloudron doesn't manage the domain's DNS, point the hostname at the Cloudron server (lower
   the record's TTL beforehand) or use a temporary hostname that already resolves to it.
2. **Freeze the old installation**: stop its `cap-web` and `cap-media-server` containers, keep
   its MySQL running.
3. Dump the old database **without** `--databases`, so the dump has no `CREATE DATABASE`/`USE`
   and can be loaded whatever the old database was called:

   ```
   mysqldump --single-transaction --routines --triggers --no-tablespaces \
     --set-gtid-purged=OFF --default-character-set=utf8mb4 <olddb> > cap.sql
   ```

   Check the collation with
   `SELECT DISTINCT table_collation FROM information_schema.tables WHERE table_schema='<olddb>'`.
   Cloudron's MySQL 8.4 uses `utf8mb4_0900_ai_ci`; convert only if the old tables use another one.
4. **Install** the app (see [Installation](#installation)), wait until it runs, note its database
   credentials and **stop** it:

   ```
   docker inspect <app-id> --format '{{range .Config.Env}}{{println .}}{{end}}' | grep CLOUDRON_MYSQL_
   ```

5. Load the dump through the platform MySQL container; its `DROP TABLE IF EXISTS` statements
   replace the fresh schema:

   ```
   docker exec -i -e MYSQL_PWD=<password> mysql mysql -h127.0.0.1 -u<user> <database> < cap.sql
   ```

6. Write the old secrets into `/app/data/.secrets/secrets.env` (`NEXTAUTH_SECRET` keeps existing
   logins valid, `DATABASE_ENCRYPTION_KEY` is required, `MEDIA_SERVER_WEBHOOK_SECRET`) and the
   old settings into `/app/data/env.sh` (see [Configuration](#configuration) for which ones apply).
7. **Start** the app. Check the log for `Migrations run successfully` and `Found existing S3
   bucket`, log in with an existing account, play a few recordings, then make a short test
   recording and delete it.
8. Keep the old installation stopped, not removed, until you are sure.

**Rollback**: point the hostname back at the old server and start its containers. Recordings are
in the same bucket either way; only database rows created after the switch would need to be
carried back.

## How it works

| File | Purpose |
|---|---|
| `Dockerfile` | Copies the official images onto `cloudron/node-base:24`, pinned by digest (upstream only publishes `latest`), installs ffmpeg, and checks native pieces (sharp, the media server's addon, bun, ffmpeg) and the guard proxy's action lookup at build time. |
| `start.sh` | Runs as root: secures directories, writes the `env.sh` template and secrets on first start, validates both files, derives database URL and internal endpoints, waits for MySQL, starts supervisor. Never loads `env.sh`. |
| `app-env.sh` | Runs as the app user: loads `env.sh`, then the secrets and derived values, and starts one Cap process. |
| `supervisor/cap.conf` | Three processes: guard proxy (`:3000`), Next.js (`127.0.0.1:3001`), media server (`127.0.0.1:3456`). |
| `guard-proxy.mjs` | The public-port proxy described in [Security model](#security-model). |
| `media-server.ts` | Starts upstream's media server bound to `127.0.0.1`. |
| `prune-workflows.py` | The daily cleanup task. |
| `CloudronManifest.json` | Cloudron manifest (addons: localstorage, mysql, scheduler). |
| `CloudronVersions.json` | The published versions feed that Cloudron reads. |
| `test/smoke.sh` | Smoke test of a built image (used by CI and by the release workflow). |

## Development and releasing

Build and run a working copy on a test Cloudron (on-server build, no registry needed):

```bash
cloudron install --location cap.example.com
cloudron logs -f --app cap.example.com
```

`test/upgrade.sh <old image> <new image>` does what a Cloudron update does: it starts the old image,
adds a user, an organisation and a public video, replaces the container with the new image on the
same data and database, and checks migrations, the data, the video's share page, secrets and
settings, the guard proxy and a restart.

`test/smoke.sh <image>` runs an image the way Cloudron does (read-only root filesystem, data and
runtime volumes) next to MySQL 8.4 and a MinIO bucket, and checks start-up, migrations, storage
access, the media server, the guard proxy's blocks, file ownership and a restart. It needs only
Docker and curl.

| Workflow | When | What |
|---|---|---|
| `ci.yml` | every PR and push to main | lint, image build with the build-time checks, smoke test, upgrade test from the last published version |
| `update.yml` (**Update Cap**) | every 3 hours, and by hand | automatic releases, below |

**Releasing is automatic.** `update.yml` runs every 3 hours (or by hand: Actions → **Update Cap** →
Run workflow). It

1. checks whether Cap published new images (Cap only publishes `latest`, so digests are compared)
   and stops if nothing changed, unless *release package changes* is ticked (then add a CHANGELOG
   line in *notes*);
2. pins the new digests, bumps the patch version, sets `upstreamVersion` from Cap's own
   `package.json`, writes the CHANGELOG entry;
3. builds the image and runs the smoke test and the upgrade test from the last published version;
4. only if everything passes, pushes `ghcr.io/ravolar/cloudron-cap:X.Y.Z`, adds it to
   `CloudronVersions.json` as published, commits and tags `vX.Y.Z`.

If any step fails, nothing is published and the run opens a GitHub issue (or comments on the open
one); the next scheduled run retries.

To withdraw a published version, mark it revoked (`cloudron versions revoke --version X.Y.Z`, or
set its `publishState` to `revoked`) and commit `CloudronVersions.json`. Installations already
on that version keep it; new installs and updates skip it.

Repository settings needed once: Actions → General → Workflow permissions **Read and write**; the
GHCR package must be public.

## License

Cap is © Cap Software, Inc.; its web app and media server are licensed under the
[GNU AGPLv3](https://github.com/CapSoftware/Cap/blob/main/LICENSE). This package runs Cap's
official images unmodified; the source of the Cap version in each release is linked by the
image digests in the `Dockerfile` and available from the
[Cap repository](https://github.com/CapSoftware/Cap).
