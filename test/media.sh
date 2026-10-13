#!/bin/bash
# Media processing tests: runs Cap's own media-server test suites (probing, transcoding, audio,
# recording verification, real-world routes) inside the package image, with the image's ffmpeg and
# node-av. Our smoke and upgrade tests only check that the media server is up; these check that it
# can actually process video on this base image.
#
#   test/media.sh <image>
#
# Needs docker. Suites missing from a future Cap version are skipped, not failed.
set -euo pipefail

IMAGE=${1:?usage: test/media.sh <image>}
SUITES=(
    src/__tests__/lib/media-probe.integration.test.ts
    src/__tests__/lib/media-video.integration.test.ts
    src/__tests__/lib/media-audio.integration.test.ts
    src/__tests__/lib/media-size.test.ts
    src/__tests__/lib/media-transfer.test.ts
    src/__tests__/lib/job-manager.test.ts
    src/__tests__/lib/recording-verification.integration.test.ts
    src/__tests__/lib/media-routes-real-world.integration.test.ts
    src/__tests__/routes/video.test.ts
)

echo "==> Cap media-server tests in ${IMAGE}"
docker run --rm --read-only --tmpfs /tmp:exec --entrypoint bash -w /app/code/media \
    -e FFMPEG_PATH=/usr/bin/ffmpeg -e HOME=/tmp "${IMAGE}" -c '
        set -u
        ran=0; failed=0
        for suite in "$@"; do
            if [[ ! -f "${suite}" ]]; then echo "  skip  ${suite} (not in this Cap version)"; continue; fi
            ran=$((ran + 1))
            if out=$(timeout 900 bun test "${suite}" 2>&1); then
                echo "  ok    ${suite} ($(grep -oE "[0-9]+ pass" <<<"${out}" | tail -1))"
            else
                failed=1; echo "  FAIL  ${suite}"; tail -40 <<<"${out}"
            fi
        done
        [[ ${ran} -gt 0 ]] || { echo "no media test suites found"; exit 1; }
        if [[ ${failed} -ne 0 ]]; then echo "==> MEDIA TESTS FAILED"; exit 1; fi
        echo "==> Media tests passed"
    ' _ "${SUITES[@]}"
