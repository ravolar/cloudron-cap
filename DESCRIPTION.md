Cap is an open source alternative to Loom: record your screen and camera, then share a link
that plays instantly in the browser, with comments, reactions, transcriptions and AI summaries.

This is an **unofficial community package**, not affiliated with or supported by Cap Software.
It runs Cap's official `cap-web` and `cap-media-server` images, unmodified, in one container.

### What you need

* **S3-compatible object storage** for recordings (AWS S3, Cloudflare R2, MinIO, ...). Cloudron
  has no object-storage addon, so the bucket and its credentials are configured in
  `/app/data/env.sh`. Recordings are therefore **not** part of Cloudron backups.
* Optionally a **Resend** account, so Cap can email login links. Cap does not support other
  mail providers, so the Cloudron mail server can't be used.
* Free disk space of about three times your largest recording, for transcoding.

The database (MySQL) is provided by Cloudron and is included in backups.
