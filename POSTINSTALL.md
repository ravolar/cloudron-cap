Cap needs object storage before it can record anything.

1. Open the **File Manager** of this app and edit `/app/data/env.sh`.
2. Fill in the `CAP_AWS_*` and `S3_*` settings for your S3-compatible bucket and, optionally,
   `RESEND_API_KEY` / `RESEND_FROM_DOMAIN` for login emails.
3. **Restart** the app.

**Before sharing the URL:** set `CAP_ALLOWED_SIGNUP_DOMAINS` in `env.sh`, otherwise anyone can
sign up and upload recordings. On a server shared with other apps, also give Cap a CPU limit
(app → Resources); video transcoding uses ffmpeg.
