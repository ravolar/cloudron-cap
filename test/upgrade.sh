#!/bin/bash
# Upgrade test: what a Cloudron update does to a running installation. Start the previously
# published image next to MySQL 8.4 and a MinIO bucket, add data (a user, an organisation and a
# public video), then replace the container with the candidate image on the same /app/data, /run,
# .next volume and database, and check that the update kept everything: migrations, data, the
# video's share page, secrets and settings.
#
#   test/upgrade.sh <old image> <new image>
#
# Needs docker and curl. Leaves nothing behind (containers, network, volumes, temp dir).
set -euo pipefail

OLD_IMAGE=${1:?usage: test/upgrade.sh <old image> <new image>}
NEW_IMAGE=${2:?usage: test/upgrade.sh <old image> <new image>}
MYSQL_IMAGE="mysql:8.4"
MINIO_IMAGE="pgsty/minio:RELEASE.2026-08-04T00-00-00Z@sha256:b6bfe7239bfc83fb90d31612d9704d86039dd714f7904b3f1ad68f211e602372"
ID="capupgrade$$"
PORT=${UPGRADE_PORT:-18310}
WORK=$(mktemp -d)
FAILED=0
VIDEO_ID="upgradetestvid1"
VIDEO_NAME="Upgrade test recording"

cleanup() {
    docker rm -f "${ID}-app" "${ID}-mysql" "${ID}-minio" >/dev/null 2>&1 || true
    docker volume rm "${ID}-next" "${ID}-run" "${ID}-tmp" >/dev/null 2>&1 || true
    docker network rm "${ID}" >/dev/null 2>&1 || true
    # the data dir is root-owned after start.sh ran; remove it from a container
    docker run --rm -v "${WORK}:/w" --entrypoint sh "${MYSQL_IMAGE}" -c 'rm -rf /w/* /w/.[!.]*' >/dev/null 2>&1 || true
    rmdir "${WORK}" 2>/dev/null || true
}
trap cleanup EXIT

pass() { echo "  ok    $1"; }
fail() { echo "  FAIL  $1"; FAILED=1; }
check() { local name=$1; shift; if "$@" >/dev/null 2>&1; then pass "${name}"; else fail "${name}"; fi; }
app_exec() { docker exec "${ID}-app" "$@"; }
sql() { docker exec "${ID}-mysql" mysql -N -ucapuser -p'p+w/d=1' capdb -e "$1" 2>/dev/null; }

start_app() {
    docker run -d --name "${ID}-app" --network "${ID}" --read-only \
        --network-alias app -p "127.0.0.1:${PORT}:3000" \
        -v "${WORK}/data:/app/data" -v "${ID}-run:/run" -v "${ID}-tmp:/tmp" \
        -v "${ID}-next:/app/code/web/apps/web/.next" \
        -e CLOUDRON_APP_ORIGIN="http://localhost:${PORT}" \
        -e CLOUDRON_MYSQL_HOST="${ID}-mysql" -e CLOUDRON_MYSQL_PORT=3306 \
        -e CLOUDRON_MYSQL_USERNAME=capuser -e CLOUDRON_MYSQL_PASSWORD='p+w/d=1' \
        -e CLOUDRON_MYSQL_DATABASE=capdb \
        "$1" >/dev/null
}

wait_ready() {
    for _ in $(seq 1 90); do
        if curl -fs -o /dev/null "http://127.0.0.1:${PORT}/api/status" &&
            docker logs "${ID}-app" 2>&1 | grep -q "Migrations run successfully"; then
            return 0
        fi
        if docker logs "${ID}-app" 2>&1 | grep -qE "MIGRATION_FAILED|Refusing to start|==> ERROR"; then
            return 1
        fi
        sleep 2
    done
    return 1
}

share_page_ok() {
    local page
    page=$(curl -fs "http://127.0.0.1:${PORT}/s/${VIDEO_ID}") && grep -q "${VIDEO_NAME}" <<<"${page}"
}

secrets_sum() { app_exec sha256sum /app/data/.secrets/secrets.env /app/data/env.sh; }

echo "==> Old version: ${OLD_IMAGE}"
docker network create "${ID}" >/dev/null
docker run -d --name "${ID}-mysql" --network "${ID}" \
    -e MYSQL_ROOT_PASSWORD=rootpw -e MYSQL_DATABASE=capdb -e MYSQL_USER=capuser -e MYSQL_PASSWORD='p+w/d=1' \
    "${MYSQL_IMAGE}" >/dev/null
docker run -d --name "${ID}-minio" --network "${ID}" --network-alias minio \
    -e MINIO_ROOT_USER=smokeadmin -e MINIO_ROOT_PASSWORD=smokesecret123 \
    "${MINIO_IMAGE}" server /data >/dev/null
for _ in $(seq 1 90); do
    docker exec "${ID}-mysql" mysqladmin ping -h127.0.0.1 -ucapuser -p'p+w/d=1' --silent >/dev/null 2>&1 && break
    sleep 2
done

mkdir -p "${WORK}/data"
cat > "${WORK}/data/env.sh" <<'EOF'
CAP_AWS_ACCESS_KEY="smokeadmin"
CAP_AWS_SECRET_KEY="smokesecret123"
CAP_AWS_BUCKET="cap-upgrade"
CAP_AWS_REGION="us-east-1"
S3_PUBLIC_ENDPOINT="http://minio.invalid:9000"
S3_INTERNAL_ENDPOINT="http://minio:9000"
S3_PATH_STYLE="true"
CAP_ALLOWED_SIGNUP_DOMAINS="example.com"
EOF

docker pull -q "${OLD_IMAGE}" >/dev/null
start_app "${OLD_IMAGE}"
if wait_ready; then pass "old version started"; else fail "old version started"; docker logs "${ID}-app" 2>&1 | tail -40; exit 1; fi

echo "==> Creating data on the old version"
sql "INSERT INTO users (id, email, name) VALUES ('upgradetestusr1', 'upgrade@example.com', 'Upgrade Test')"
sql "INSERT INTO organizations (id, name, ownerId) VALUES ('upgradetestorg1', 'Upgrade Org', 'upgradetestusr1')"
# createdAt explicitly: the generated effectiveCreatedAt column can't use the default here
sql "INSERT INTO videos (id, ownerId, orgId, name, public, createdAt) VALUES ('${VIDEO_ID}', 'upgradetestusr1', 'upgradetestorg1', '${VIDEO_NAME}', 1, NOW())"
check "user, organisation and video stored" test "$(sql "SELECT COUNT(*) FROM videos WHERE id='${VIDEO_ID}'")" = 1
check "share page renders on the old version" share_page_ok
before_tables=$(sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='capdb'")
before_secrets=$(secrets_sum)
if [[ ${FAILED} -ne 0 ]]; then
    echo "==> UPGRADE TEST FAILED (could not create data on the old version)"
    docker logs "${ID}-app" 2>&1 | tail -40
    exit 1
fi

echo "==> Updating to: ${NEW_IMAGE}"
# Like a Cloudron update: the container is replaced; /app/data, /run, /tmp, the .next runtime dir
# and the database stay. (Cloudron recreates runtimeDirs from the new image; emulate that.)
docker rm -f "${ID}-app" >/dev/null
docker volume rm "${ID}-next" >/dev/null
start_app "${NEW_IMAGE}"
if wait_ready; then pass "new version started on the old data"; else fail "new version started on the old data"; docker logs "${ID}-app" 2>&1 | tail -40; exit 1; fi

check "database migrations ran" bash -c "docker logs ${ID}-app 2>&1 | grep -q 'Migrations run successfully'"
check "no tables lost" test "$(sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='capdb'")" -ge "${before_tables}"
check "user kept" test "$(sql "SELECT email FROM users WHERE id='upgradetestusr1'")" = "upgrade@example.com"
check "video kept" test "$(sql "SELECT name FROM videos WHERE id='${VIDEO_ID}'")" = "${VIDEO_NAME}"
check "share page renders after the update" share_page_ok
check "secrets and settings unchanged" test "$(secrets_sum)" = "${before_secrets}"
check "guard proxy found the storage actions" bash -c "docker logs ${ID}-app 2>&1 | grep -q 'blocking 4 storage server actions'"

echo "==> Restart after the update"
docker restart "${ID}-app" >/dev/null
if wait_ready; then pass "restarts cleanly after the update"; else fail "restarts cleanly after the update"; fi
check "share page renders after the restart" share_page_ok

if [[ ${FAILED} -ne 0 ]]; then
    echo "==> UPGRADE TEST FAILED"
    docker logs "${ID}-app" 2>&1 | tail -60
    exit 1
fi
echo "==> Upgrade test passed"
