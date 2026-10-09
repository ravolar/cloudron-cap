#!/bin/bash
# Starts a Cap process with its environment. Runs as the `cloudron` user (supervisor's user=),
# never as root: operator settings from /app/data/env.sh can contain anything the validator
# accepts, including NODE_OPTIONS, LD_PRELOAD or PATH, so they must only ever reach processes
# that already run with the app's own privileges.
#
# Order: operator settings first, then the secrets and platform-derived values written by
# start.sh, which take precedence.
set -eu

set +u
set -o allexport
# shellcheck disable=SC1091
source /app/data/env.sh
# shellcheck disable=SC1091
source /run/cap/cap.env
set +o allexport
set -u

export S3_INTERNAL_ENDPOINT="${S3_INTERNAL_ENDPOINT:-${S3_PUBLIC_ENDPOINT:-}}"
# One transcode at a time unless the operator raises it: ffmpeg is not CPU-limited by default and
# shares the server with other apps.
export MEDIA_SERVER_MAX_CONCURRENT_VIDEO_PROCESSES="${MEDIA_SERVER_MAX_CONCURRENT_VIDEO_PROCESSES:-1}"

exec "$@"
