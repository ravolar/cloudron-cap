# Cap for Cloudron.
#
# Thin packaging layer: Cap's web app and media server, run side by side under supervisor.
#
#   cap-web       copied unmodified from Cap's official image (node:24-alpine, Next.js standalone;
#                 ships glibc builds of sharp too). Cap only publishes `latest`, so it is pinned by
#                 digest.
#   media server  built from Cap's source at the exact commit the pinned cap-web image was built
#                 from (CAP_SOURCE_SHA, read from the image's signed SLSA provenance by update.yml),
#                 the same way Cap's own apps/media-server/Dockerfile does. Cap's cap-media-server
#                 `latest` image is published independently of cap-web and can be months apart, so
#                 using it would pair the web app with a different version of its media server.

ARG CAP_SOURCE_SHA=c5f22d7640ebb418e33ba55db732b950a7a4a02a

FROM ghcr.io/capsoftware/cap-web:latest@sha256:8ee4cbd3fd87f88f538831aed06c954c525db9c2426a62abeaf0ca307c5e1ce9 AS web

FROM oven/bun:1.4.0@sha256:5ff609364c049b54eb0ff560ec96319729a972078ef2c755d758f0c6ef89c2d6 AS media
ARG CAP_SOURCE_SHA
RUN apt-get update \
    && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/*
# Only apps/media-server of the monorepo, at exactly CAP_SOURCE_SHA.
WORKDIR /src
RUN set -eux; \
    git init -q .; \
    git remote add origin https://github.com/CapSoftware/Cap.git; \
    git sparse-checkout set apps/media-server; \
    git fetch -q --depth 1 --filter=blob:none origin "${CAP_SOURCE_SHA}"; \
    git checkout -q --detach FETCH_HEAD; \
    test "$(git rev-parse HEAD)" = "${CAP_SOURCE_SHA}"; \
    mkdir -p /app; \
    cp apps/media-server/package.json apps/media-server/bun.lock /app/; \
    cp -a apps/media-server/src /app/src
WORKDIR /app
RUN bun install --frozen-lockfile --production \
    && bun -e "await import('node-av'); await import('hono'); console.log('media dependencies load')"

FROM cloudron/node-base:24-20260920@sha256:d984683ec59bf2379130bf41cf3c2b6bc0453f327297d7183525cb05424e7b34

RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg \
    && rm -rf /var/lib/apt/lists/*

COPY --from=web /app /app/code/web
COPY --from=media /app /app/code/media
COPY --from=media /usr/local/bin/bun /usr/local/bin/bun
ARG CAP_SOURCE_SHA
LABEL org.opencontainers.image.revision="${CAP_SOURCE_SHA}"

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
    (cd /app/code/media && bun -e "await import('node-av'); console.log('node-av loads on this base')"); \
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
