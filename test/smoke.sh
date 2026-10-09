#!/bin/bash
# Smoke test: run the package image the way Cloudron does (read-only root filesystem, /app/data,
# /run and /tmp as writable volumes, the .next runtime dir as a volume seeded from the image) next
# to MySQL 8.4 and a MinIO bucket, and check that Cap comes up healthy and the package's safety
# measures are in place. Then restart and check again.
#
#   test/smoke.sh <image>
#
# Needs docker and curl. Leaves nothing behind (containers, network, volumes, temp dir).
set -euo pipefail

IMAGE=${1:?usage: test/smoke.sh <image>}
MYSQL_IMAGE="mysql:8.4"
MINIO_IMAGE="pgsty/minio:RELEASE.2026-08-04T00-00-00Z@sha256:b6bfe7239bfc83fb90d31612d9704d86039dd714f7904b3f1ad68f211e602372"
ID="capsmoke$$"
PORT=${SMOKE_PORT:-18300}
WORK=$(mktemp -d)
FAILED=0

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

echo "==> Starting MySQL and MinIO"
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

echo "==> Preparing /app/data (operator settings, as the File Manager would)"
mkdir -p "${WORK}/data"
cat > "${WORK}/data/env.sh" <<'EOF'
CAP_AWS_ACCESS_KEY="smokeadmin"
CAP_AWS_SECRET_KEY="smokesecret123"
CAP_AWS_BUCKET="cap-smoke"
CAP_AWS_REGION="us-east-1"
S3_PUBLIC_ENDPOINT="http://minio.invalid:9000"
S3_INTERNAL_ENDPOINT="http://minio:9000"
S3_PATH_STYLE="true"
CAP_ALLOWED_SIGNUP_DOMAINS="example.com"
EOF

start_app() {
    docker run -d --name "${ID}-app" --network "${ID}" --read-only \
        --network-alias app -p "127.0.0.1:${PORT}:3000" \
        -v "${WORK}/data:/app/data" -v "${ID}-run:/run" -v "${ID}-tmp:/tmp" \
        -v "${ID}-next:/app/code/web/apps/web/.next" \
        -e CLOUDRON_APP_ORIGIN="http://localhost:${PORT}" \
        -e CLOUDRON_MYSQL_HOST="${ID}-mysql" -e CLOUDRON_MYSQL_PORT=3306 \
        -e CLOUDRON_MYSQL_USERNAME=capuser -e CLOUDRON_MYSQL_PASSWORD='p+w/d=1' \
        -e CLOUDRON_MYSQL_DATABASE=capdb \
        "${IMAGE}" >/dev/null
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

run_checks() {
    local logs
    logs=$(docker logs "${ID}-app" 2>&1)
    check "Cap answers /api/status" curl -fs -o /dev/null "http://127.0.0.1:${PORT}/api/status"
    check "login page renders" curl -fs -o /dev/null "http://127.0.0.1:${PORT}/login"
    check "database migrations ran" grep -q "Migrations run successfully" <<<"${logs}"
    check "object storage reachable" grep -qE "(Created|Found existing) S3 bucket" <<<"${logs}"
    check "guard proxy found the storage actions" grep -q "blocking 4 storage server actions" <<<"${logs}"
    check "no open sign-up warning (env.sh was loaded)" bash -c "! grep -q 'CAP_ALLOWED_SIGNUP_DOMAINS is empty' <<<\"\$1\"" _ "${logs}"
    check "media server healthy on loopback" app_exec curl -fs -o /dev/null http://127.0.0.1:3456/health
    check "only port 3000 listens on all interfaces" app_exec bash -c \
        'test "$(cat /proc/net/tcp /proc/net/tcp6 | awk "\$4==\"0A\"{print \$2}" | grep -E "^0+:" | sed "s/.*://" | sort -u | tr "\n" " ")" = "0BB8 "'
    check "internal endpoint blocked (/api/cron)" test "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/api/cron/x")" = 403
    check "custom S3 storage blocked" test "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'content-type: application/json' -d '{}' "http://127.0.0.1:${PORT}/api/desktop/s3/config/test")" = 403
    local action
    action=$(app_exec node -e 'const m=require("/app/code/web/apps/web/.next/server/server-reference-manifest.json");for(const [i,v] of Object.entries(m.node))if(v.exportedName==="testOrganizationS3Config"){console.log(i);break}')
    check "storage server action blocked (no-JS form)" test "$(curl -s -o /dev/null -w '%{http_code}' -X POST -F '$ACTION_REF_1=' -F "\$ACTION_1:0={\"id\":\"${action}\"}" "http://127.0.0.1:${PORT}/login")" = 403
    check "/app/data is root-owned" test "$(app_exec stat -c %U:%a /app/data)" = "root:755"
    check "env.sh readable by the app only via group" test "$(app_exec stat -c %U:%G:%a /app/data/env.sh)" = "root:cloudron:640"
    check "secrets are root-only" test "$(app_exec stat -c %U:%a /app/data/.secrets/secrets.env)" = "root:600"
    check "app user cannot read the secrets" bash -c "! docker exec -u cloudron ${ID}-app cat /app/data/.secrets/secrets.env"
    check "app user cannot write env.sh" bash -c "! docker exec -u cloudron ${ID}-app sh -c 'echo x >> /app/data/env.sh'"
    check "Cap processes run as the app user (uid 1000)" test "$(app_exec bash -c 'for p in /proc/[0-9]*; do case "$(cat "$p/comm" 2>/dev/null)" in node|bun|next-server*) awk "/^Uid:/{print \$2}" "$p/status";; esac; done | sort -u | tr -d "\n"')" = "1000"
    check "cleanup task runs" app_exec gosu cloudron:cloudron /app/pkg/prune-workflows.py --dry-run
}

echo "==> First start"
start_app
if wait_ready; then pass "app started"; else fail "app started"; docker logs "${ID}-app" 2>&1 | tail -40; exit 1; fi
run_checks

echo "==> Restart"
docker restart "${ID}-app" >/dev/null
if wait_ready; then pass "app restarted"; else fail "app restarted"; docker logs "${ID}-app" 2>&1 | tail -40; exit 1; fi
check "still healthy after restart" curl -fs -o /dev/null "http://127.0.0.1:${PORT}/api/status"
check "secrets kept across restart" test "$(app_exec stat -c %U:%a /app/data/.secrets/secrets.env)" = "root:600"

if [[ ${FAILED} -ne 0 ]]; then
    echo "==> SMOKE TEST FAILED"
    docker logs "${ID}-app" 2>&1 | tail -60
    exit 1
fi
echo "==> Smoke test passed"
