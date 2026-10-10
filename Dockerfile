# Cap for Cloudron.
#
# Thin packaging layer: the web app and the media server are copied unmodified from Cap's official
# images and run side by side under supervisor. Both upstream images are only published as
# `latest`, so they are pinned by digest; bump the digests together.
#
#   cap-web           node:24-alpine, Next.js standalone build. Ships glibc builds of sharp too,
#                     so it runs on the glibc Node of the Cloudron base image.
#   cap-media-server  oven/bun (Debian), bun + node-av + ffmpeg from apt.

FROM ghcr.io/capsoftware/cap-web:latest@sha256:8ee4cbd3fd87f88f538831aed06c954c525db9c2426a62abeaf0ca307c5e1ce9 AS web
FROM ghcr.io/capsoftware/cap-media-server:latest@sha256:2dc90e055447026d7ff70656344cde74ec91b9d458a6050d9be6040a7074b62b AS media

FROM cloudron/node-base:24-20260920@sha256:d984683ec59bf2379130bf41cf3c2b6bc0453f327297d7183525cb05424e7b34

RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg \
    && rm -rf /var/lib/apt/lists/*

COPY --from=web /app /app/code/web
COPY --from=media /app /app/code/media
COPY --from=media /usr/local/bin/bun /usr/local/bin/bun

# Build-time gates: fail here, not on a user's server, if a native piece does not resolve on this base.
# sharp is resolved the way Next.js does it: from the next package inside the pnpm store.
RUN set -eux; \
    next_dir=$(ls -d /app/code/web/node_modules/.pnpm/next@*/node_modules/next | head -1); \
    node -e "const s = require(require.resolve('sharp', { paths: [process.argv[1]] })); \
      s({ create: { width: 4, height: 4, channels: 3, background: '#f00' } }).webp().toBuffer() \
        .then(b => console.log('sharp ok, libvips', s.versions.vips, b.length, 'bytes'))" "${next_dir}"; \
    for f in $(find /app/code/media/node_modules -name '*.node'); do \
        if ldd "$f" | grep -q 'not found'; then ldd "$f"; echo "unresolved libs in $f"; exit 1; fi; \
    done; \
    bun --version; \
    ffmpeg -hide_banner -version | head -1; \
    test -f /app/code/web/apps/web/server.js; \
    test -f /app/code/media/src/index.ts; \
    test -f /app/code/web/apps/web/.next/server/server-reference-manifest.json;

# Supervisor's own log and child logs default to /var/log, which is read-only on Cloudron.
RUN sed -e 's,^logfile=.*$,logfile=/run/supervisord.log,' \
        -e 's,^childlogdir=.*$,childlogdir=/run,' \
        -e 's,^\[supervisord\]$,[supervisord]\nuser=root,' \
        -i /etc/supervisor/supervisord.conf

COPY start.sh app-env.sh media-server.ts guard-proxy.mjs prune-workflows.py /app/pkg/
COPY supervisor/ /etc/supervisor/conf.d/
# Set modes explicitly: the build context can arrive with 0600 files (seen with Cloudron's
# on-server build), and the media server runs as `cloudron`, so it must be able to read its wrapper.
RUN chmod 0755 /app/pkg /app/pkg/start.sh /app/pkg/app-env.sh /app/pkg/prune-workflows.py \
    && chmod 0644 /app/pkg/media-server.ts /app/pkg/guard-proxy.mjs /etc/supervisor/conf.d/*.conf

# Fail the build if guard-proxy can't find the storage server actions in this Cap build (e.g. after
# an upstream rename), instead of shipping an image whose SSRF block silently does nothing.
RUN node /app/pkg/guard-proxy.mjs --check

CMD [ "/app/pkg/start.sh" ]
