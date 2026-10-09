#!/bin/bash
set -eu

# Cap on Cloudron. Runs as root for setup, then hands cap-web and the media server to supervisor
# (both drop to the `cloudron` user).
#
#   /app/data/env.sh     operator settings (S3 storage, Resend, optional integrations); edit + restart
#   /app/data/.secrets   generated once; never regenerated, or encrypted DB fields become unreadable

SECRETS=/app/data/.secrets/secrets.env

# Root must never act on paths the app user (cloudron) can rename or replace, or a compromised app
# could plant symlinks and steer the root steps below. So /app/data itself is root-owned and the
# app user only gets its own subdirectory (workflow-data); env.sh is root-owned and only readable
# by the app; /run/cap is recreated, root-owned, on every start.
echo "==> Securing data directories"
chown root:root /app/data
chmod 755 /app/data
for path in /app/data/env.sh /app/data/.secrets "${SECRETS}" /app/data/workflow-data; do
    if [[ -L "${path}" ]]; then
        echo "==> ERROR: ${path} is a symbolic link, which this package never creates. Refusing to start."
        echo "    Inspect it from the web terminal, remove the link and restart."
        sleep 30
        exit 1
    fi
done
for dir in /app/data/.secrets /app/data/workflow-data; do
    if [[ -e "${dir}" && ! -d "${dir}" ]]; then
        echo "==> ERROR: ${dir} should be a directory. Refusing to start."
        sleep 30
        exit 1
    fi
done
mkdir -p /app/data/.secrets /app/data/workflow-data
chown root:root /app/data/.secrets
chmod 700 /app/data/.secrets
# Check the secrets file again now that the app user can no longer write into its directory.
if [[ -L "${SECRETS}" ]] || [[ -e "${SECRETS}" && ! -f "${SECRETS}" ]]; then
    echo "==> ERROR: ${SECRETS} is not a regular file. Refusing to start."
    sleep 30
    exit 1
fi

echo "==> Setting up runtime directories"
# Also drops media-server work dirs from a crashed or killed run, which upstream never cleans.
rm -rf /run/cap
mkdir -p /run/cap/home /run/cap/tmp
chmod 755 /run/cap
chown cloudron:cloudron /run/cap/home /run/cap/tmp

if [[ ! -f /app/data/env.sh ]]; then
    echo "==> First run: writing /app/data/env.sh template"
    cat > /app/data/env.sh <<'EOF'
# Cap settings. Restart the app after editing (Cloudron dashboard -> Restart).

# --- Object storage (required) -----------------------------------------------------------
# Cap stores recordings in S3-compatible storage (AWS S3, Cloudflare R2, MinIO, ...).
# The bucket must exist. S3_PUBLIC_ENDPOINT must be reachable from viewers' browsers.
CAP_AWS_ACCESS_KEY=""
CAP_AWS_SECRET_KEY=""
CAP_AWS_BUCKET=""
CAP_AWS_REGION="auto"
S3_PUBLIC_ENDPOINT=""
# Endpoint the server uses; defaults to S3_PUBLIC_ENDPOINT when empty.
S3_INTERNAL_ENDPOINT=""
S3_PATH_STYLE="true"

# --- Email (login links) -------------------------------------------------------------------
# Cap sends login links through Resend (https://resend.com).
# RESEND_API_KEY is the key (starts with "re_"); RESEND_FROM_DOMAIN is a domain verified in
# Resend, e.g. "example.com" - not the key.
RESEND_API_KEY=""
RESEND_FROM_DOMAIN=""

# --- Sign-up ------------------------------------------------------------------------------
# Comma-separated email domains allowed to sign up, e.g. "example.com,example.org".
# Empty means ANYONE can sign up and upload recordings - set this before going public.
CAP_ALLOWED_SIGNUP_DOMAINS=""

# CAP_BLOCKED_SIGNUP_DOMAINS=""
# CAP_VIDEOS_DEFAULT_PUBLIC="true"

# --- Optional integrations ------------------------------------------------------------------
# ASSEMBLY_API_KEY=""        # transcriptions (AssemblyAI; this Cap build does not read DEEPGRAM_API_KEY)
# AI_PROVIDER=""             # AI titles/summaries: groq, openai or anthropic
# AI_MODEL=""
# GROQ_API_KEY=""
# OPENAI_API_KEY=""
# ANTHROPIC_API_KEY=""
# GOOGLE_CLIENT_ID=""        # Google login
# GOOGLE_CLIENT_SECRET=""

# --- Security -------------------------------------------------------------------------------
# Custom per-organisation S3 storage lets users point the server at any host, including other
# apps on this Cloudron. It is blocked unless set to "true".
# CAP_ALLOW_CUSTOM_STORAGE="false"

# --- Resources ------------------------------------------------------------------------------
# Parallel video transcodes (default 1). Each needs RAM, CPU and about 3x the recording size
# of disk; set a CPU limit for the app in the Cloudron dashboard before raising it.
# MEDIA_SERVER_MAX_CONCURRENT_VIDEO_PROCESSES="1"
# Days to keep the state of finished video-processing jobs (pruned daily). Default 30.
# WORKFLOW_RETENTION_DAYS="30"
EOF
fi

# Secrets are generated on first run only. When migrating an existing Cap, replace them with the
# old installation's values BEFORE the first login (DATABASE_ENCRYPTION_KEY above all).
if [[ ! -f "${SECRETS}" ]]; then
    echo "==> First run: generating secrets"
    ( umask 077; cat > "${SECRETS}" <<EOF
NEXTAUTH_SECRET=$(openssl rand -hex 32)
DATABASE_ENCRYPTION_KEY=$(openssl rand -hex 32)
MEDIA_SERVER_WEBHOOK_SECRET=$(openssl rand -hex 32)
EOF
    )
fi
chown root:root "${SECRETS}"
chmod 600 "${SECRETS}"

# Both files are sourced below as root, so they may only contain plain assignments: NAME="value"
# or NAME='value', no $, backticks or backslashes inside double quotes, no "export", no leading
# spaces. Anything that could run a command is refused.
check_env_file() {
    local file=$1 bad
    # Only space and tab count as blanks: grep's [[:space:]] would also accept vertical tab and
    # form feed, which bash does not treat as blanks, so "x"<VT>#$(cmd) would run cmd.
    local sp=$' \t'
    if grep -q $'\r' "${file}"; then
        echo "==> ERROR: ${file} has Windows (CRLF) line endings, which would corrupt the values."
        echo "    Re-save it with Unix (LF) line endings and restart."
        return 1
    fi
    if LC_ALL=C grep -q $'[\x01-\x08\x0b\x0c\x0e-\x1f\x7f]' "${file}"; then
        echo "==> ERROR: ${file} contains control characters. Remove them and restart."
        return 1
    fi
    if ! bash -n "${file}"; then
        echo "==> ERROR: ${file} has a syntax error (see above). Fix it and restart."
        return 1
    fi
    if bad=$(grep -nvE "^[${sp}]*(#.*)?$|^[A-Za-z_][A-Za-z0-9_]*=(\"[^\"\$\`\\]*\"|'[^']*'|[A-Za-z0-9_./:@,+-]*)([${sp}]+#.*)?[${sp}]*$" "${file}"); then
        echo "==> ERROR: ${file} may only contain NAME=\"value\" lines (quote every value; use single"
        echo "    quotes if it contains \$, \` or a backslash; no 'export', no leading spaces). Offending lines:"
        echo "${bad}" | cut -d: -f1 | sed 's/^/    line /'
        return 1
    fi
}

chown root:cloudron /app/data/env.sh
chmod 640 /app/data/env.sh
if ! check_env_file /app/data/env.sh || ! check_env_file "${SECRETS}"; then
    sleep 30
    exit 1
fi

# This script runs as root and never sources a file: values like NODE_OPTIONS, LD_PRELOAD or PATH
# would affect the root-run commands below. The three secrets are read as text, by name; env.sh is
# loaded by app-env.sh, as the cloudron user, right before each Cap process starts.
file_value() {
    # Quoted value: take what is inside the quotes (a "#" there is part of the value); unquoted:
    # drop a trailing " # comment". The validator has already restricted the line shapes.
    grep -E "^$2=" "$1" | tail -n 1 | cut -d= -f2- |
        sed -E "s/^\"([^\"]*)\".*/\1/; t; s/^'([^']*)'.*/\1/; t; s/[[:blank:]]+#.*$//"
}
for name in NEXTAUTH_SECRET DATABASE_ENCRYPTION_KEY MEDIA_SERVER_WEBHOOK_SECRET; do
    value=$(file_value "${SECRETS}" "${name}")
    if [[ -z "${value}" ]]; then
        echo "==> ERROR: ${name} is missing or empty in ${SECRETS}. Refusing to start."
        sleep 30
        exit 1
    fi
    export "${name}=${value}"
done

# Platform-derived settings: recomputed on every start because addon credentials can change.
db_password=$(node -e 'process.stdout.write(encodeURIComponent(process.argv[1]))' "${CLOUDRON_MYSQL_PASSWORD}")
export DATABASE_URL="mysql://${CLOUDRON_MYSQL_USERNAME}:${db_password}@${CLOUDRON_MYSQL_HOST}:${CLOUDRON_MYSQL_PORT}/${CLOUDRON_MYSQL_DATABASE}"
export WEB_URL="${CLOUDRON_APP_ORIGIN}"
export NEXTAUTH_URL="${CLOUDRON_APP_ORIGIN}"
export MEDIA_SERVER_URL="http://127.0.0.1:3456"
# Internal callers go straight to Next on 3001, bypassing guard-proxy on the public port 3000.
export MEDIA_SERVER_WEBHOOK_URL="http://127.0.0.1:3001"
export WORKFLOW_LOCAL_BASE_URL="http://127.0.0.1:3001"
# The media server only trusts cap.so as the origin of media authorizations unless told otherwise.
export MEDIA_SERVER_WEB_ORIGIN="${CLOUDRON_APP_ORIGIN}"
export FFMPEG_PATH=/usr/bin/ffmpeg
export HOME=/run/cap/home
# Cap's background jobs (video processing workflows) keep their state on disk; the default is a
# directory next to the code, which is read-only here. /app/data keeps it across restarts.
export WORKFLOW_LOCAL_DATA_DIR=/app/data/workflow-data
export TMPDIR=/run/cap/tmp

# Hand secrets and derived values to app-env.sh, which applies them after env.sh so they win.
# The app processes get these values in their environment anyway, so the file is readable by them.
cap_env=$(mktemp /run/cap/.cap.env.XXXXXX)
for name in NEXTAUTH_SECRET DATABASE_ENCRYPTION_KEY MEDIA_SERVER_WEBHOOK_SECRET DATABASE_URL \
    WEB_URL NEXTAUTH_URL MEDIA_SERVER_URL MEDIA_SERVER_WEBHOOK_URL WORKFLOW_LOCAL_BASE_URL \
    MEDIA_SERVER_WEB_ORIGIN FFMPEG_PATH HOME WORKFLOW_LOCAL_DATA_DIR TMPDIR; do
    printf '%s=%q\n' "${name}" "${!name}"
done > "${cap_env}"
chown root:cloudron "${cap_env}"
chmod 640 "${cap_env}"
mv -f "${cap_env}" /run/cap/cap.env

# Warnings only: read the values as text, without evaluating env.sh.
env_value() { file_value /app/data/env.sh "$1"; }
if [[ -z "$(env_value CAP_ALLOWED_SIGNUP_DOMAINS)" ]]; then
    echo "==> WARNING: CAP_ALLOWED_SIGNUP_DOMAINS is empty: anyone can sign up and upload recordings."
fi
if [[ -z "$(env_value CAP_AWS_BUCKET)" || -z "$(env_value S3_PUBLIC_ENDPOINT)" ]]; then
    echo "==> WARNING: object storage is not configured. Edit /app/data/env.sh and restart."
fi

echo "==> Waiting for MySQL"
for attempt in $(seq 1 60); do
    if mysqladmin ping --silent -h "${CLOUDRON_MYSQL_HOST}" -P "${CLOUDRON_MYSQL_PORT}" \
        -u "${CLOUDRON_MYSQL_USERNAME}" --password="${CLOUDRON_MYSQL_PASSWORD}" 2>/dev/null; then
        break
    fi
    if [[ ${attempt} == 60 ]]; then
        echo "==> ERROR: MySQL did not become ready in 2 minutes; exiting so Cloudron restarts the app."
        exit 1
    fi
    echo "==> MySQL not ready yet (${attempt}/60)"
    sleep 2
done

# Backups and restores can reset ownership, so fix it on every start. chown -R does not follow
# symlinks it finds inside these trees.
if ! chown -R cloudron:cloudron /app/data/workflow-data /app/code/web/apps/web/.next; then
    # e.g. the nightly prune removed files mid-walk; the app user still owns what it needs
    echo "==> WARNING: could not re-own every file under workflow-data/.next (continuing)"
fi

# Cap web runs its database migrations itself shortly after boot (look for MIGRATION_FAILED in logs).
echo "==> Starting Cap"
exec /usr/bin/supervisord --configuration /etc/supervisor/supervisord.conf --nodaemon
