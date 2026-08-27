#!/usr/bin/env bash
# Bring an external Compose project's infrastructure up on ContainerStack and prove it is
# actually usable from the host — not just "created".
#
# The default service set is the usual dependency tier of a web stack — postgres, redis, minio,
# chroma, mailpit — named explicitly so Compose profiles that additionally build images stay out
# of the run. Override it with SERVICES="a b c" for a project that runs something else.
#
# What it checks, in order, because each step can pass while the next one fails on Apple
# Container: the containers start, the ones that declare a healthcheck turn healthy (Compose
# `depends_on: condition: service_healthy` depends on this), the published ports answer FROM THE
# HOST (the failure mode this runtime is known for — a dead vmnet helper leaves ports accepting
# and then hanging), and each service answers a real protocol-level request.
#
#   scripts/verify-compose-project.sh --project DIR [--context NAME] [-f OVERLAY.yml]
#                                     [--timeout SEC] [--down]
#
# `-f` adds an overlay (repeatable) — e.g. ContainerStack-only resource limits — without editing
# the project's own docker-compose.override.yml, which its everyday stack uses.
#
# Leaves the stack running by default so the test suites can use it; `--down` tears it down.
# Exits non-zero on the first failed gate, after dumping the diagnostics for it.

set -uo pipefail

PROJECT_DIR=""
DOCKER_CONTEXT_NAME="containerstack"
HEALTH_TIMEOUT=240
TEAR_DOWN=0
CSTACK="${CSTACK:-/Applications/ContainerStack.app/Contents/MacOS/cstack}"
# Naming any file with -f suppresses Compose's automatic docker-compose.override.yml pickup, so
# the project's own files are listed explicitly whenever an overlay is supplied.
EXTRA_COMPOSE_FILES=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --project) PROJECT_DIR="${2:?--project needs a directory}"; shift 2 ;;
        --context) DOCKER_CONTEXT_NAME="${2:?--context needs a name}"; shift 2 ;;
        --timeout) HEALTH_TIMEOUT="${2:?--timeout needs seconds}"; shift 2 ;;
        --file|-f) EXTRA_COMPOSE_FILES+=("${2:?--file needs a path}"); shift 2 ;;
        --down) TEAR_DOWN=1; shift ;;
        -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
        *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done

# shellcheck disable=SC2206  # deliberate word splitting: SERVICES is a space-separated override.
read -r -a SERVICES <<< "${SERVICES:-postgres redis minio chroma mailpit}"

compose() {
    local files=()
    if [[ ${#EXTRA_COMPOSE_FILES[@]} -gt 0 ]]; then
        files+=(-f "$PROJECT_DIR/docker-compose.yml")
        [[ -f "$PROJECT_DIR/docker-compose.override.yml" ]] \
            && files+=(-f "$PROJECT_DIR/docker-compose.override.yml")
        local overlay
        for overlay in "${EXTRA_COMPOSE_FILES[@]}"; do
            files+=(-f "$overlay")
        done
    fi
    docker --context "$DOCKER_CONTEXT_NAME" compose ${files[@]+"${files[@]}"} "$@"
}

inspect_container() {
    docker --context "$DOCKER_CONTEXT_NAME" inspect --format "$2" "$1" 2>/dev/null
}

pass() { printf '  ok    %s\n' "$1"; }
fail() {
    printf '  FAIL  %s\n' "$1" >&2
    printf '\n=== docker compose ps ===\n' >&2
    compose ps >&2 2>&1
    printf '\n=== cstack doctor ===\n' >&2
    [[ -x "$CSTACK" ]] && "$CSTACK" doctor >&2 2>&1 || printf 'cstack not found at %s\n' "$CSTACK" >&2
    local service
    for service in "${SERVICES[@]}"; do
        printf '\n=== logs: %s (last 40) ===\n' "$service" >&2
        compose logs --tail 40 "$service" >&2 2>&1
    done
    exit 1
}

has_service() {
    local candidate
    for candidate in "${SERVICES[@]}"; do
        [[ "$candidate" == "$1" ]] && return 0
    done
    return 1
}

# ── Preflight ────────────────────────────────────────────────────────────────
printf 'Preflight\n'
[[ -n "$PROJECT_DIR" ]] || { printf '%s\n' "--project DIR is required" >&2; exit 2; }
command -v docker >/dev/null 2>&1 || fail "docker CLI not on PATH"
[[ -f "$PROJECT_DIR/docker-compose.yml" ]] || fail "no docker-compose.yml in $PROJECT_DIR"
docker context inspect "$DOCKER_CONTEXT_NAME" >/dev/null 2>&1 \
    || fail "docker context '$DOCKER_CONTEXT_NAME' is not registered (enable it in ContainerStack)"
cd "$PROJECT_DIR" || fail "cannot enter $PROJECT_DIR"

# The runtime has to be answering before Compose is asked to do anything, otherwise every later
# failure reads as a Compose problem.
engine="$(docker --context "$DOCKER_CONTEXT_NAME" version --format '{{.Server.Version}}' 2>/dev/null)"
[[ -n "$engine" ]] || fail "the runtime's Docker endpoint is not answering"
pass "docker context $DOCKER_CONTEXT_NAME reachable"
printf '  info  engine %s\n' "$engine"

# ── Bring the infrastructure up ──────────────────────────────────────────────
printf '\nStarting %s\n' "${SERVICES[*]}"
compose up -d "${SERVICES[@]}" || fail "compose up failed"
pass "compose up -d returned"

# ── Readiness ────────────────────────────────────────────────────────────────
# A service is gated on its healthcheck when it declares one, and on running otherwise, so the
# gate matches what Compose's own `service_healthy` conditions wait for.
printf '\nWaiting for readiness (timeout %ss)\n' "$HEALTH_TIMEOUT"
for service in "${SERVICES[@]}"; do
    container="$(compose ps -q "$service" 2>/dev/null | head -1)"
    [[ -n "$container" ]] || fail "$service has no container"
    declares_health="$(inspect_container "$container" '{{if .State.Health}}yes{{else}}no{{end}}')"

    if [[ "$declares_health" != "yes" ]]; then
        state="$(inspect_container "$container" '{{.State.Status}}')"
        [[ "$state" == "running" ]] || fail "$service is $state, not running"
        pass "$service running (no healthcheck declared)"
        continue
    fi

    deadline=$(( $(date +%s) + HEALTH_TIMEOUT ))
    state=""
    while [[ $(date +%s) -lt $deadline ]]; do
        state="$(inspect_container "$container" '{{.State.Health.Status}}')"
        [[ "$state" == "healthy" ]] && break
        [[ "$state" == "unhealthy" ]] && break
        [[ -z "$state" ]] && break
        sleep 2
    done
    [[ "$state" == "healthy" ]] || fail "$service never became healthy (last state: ${state:-unknown})"
    pass "$service healthy"
done

# ── Published ports, from the host ───────────────────────────────────────────
# This is the gate that catches the runtime's weak spot: the port is published, the TCP handshake
# completes, and then nothing answers because the network's vmnet helper died.
printf '\nProbing published ports from the host\n'
host_port() {
    compose port "$1" "$2" 2>/dev/null | tail -1 | awk -F: '{print $NF}'
}

probe_tcp() {
    local label="$1" port="$2"
    [[ -n "$port" ]] || fail "$label has no published host port"
    nc -z -G 5 127.0.0.1 "$port" >/dev/null 2>&1 || fail "$label port $port refuses connections"
    pass "$label accepts TCP on $port"
}

declare PG_PORT="" REDIS_PORT="" MINIO_PORT="" CHROMA_PORT="" MAILPIT_WEB_PORT=""
has_service postgres && { PG_PORT="$(host_port postgres 5432)"; probe_tcp postgres "$PG_PORT"; }
has_service redis && { REDIS_PORT="$(host_port redis 6379)"; probe_tcp redis "$REDIS_PORT"; }
has_service minio && { MINIO_PORT="$(host_port minio 9000)"; probe_tcp minio "$MINIO_PORT"; }
has_service chroma && { CHROMA_PORT="$(host_port chroma 8000)"; probe_tcp chroma "$CHROMA_PORT"; }
has_service mailpit && {
    MAILPIT_WEB_PORT="$(host_port mailpit 8025)"
    probe_tcp mailpit-web "$MAILPIT_WEB_PORT"
}

# ── Protocol-level answers ───────────────────────────────────────────────────
# A completed handshake is not a working service: published ports have hung after connect on this
# runtime, so every service is asked a question it must answer.
printf '\nAsking each service a real question\n'

http_ok() {
    local label="$1" url="$2" code
    code="$(curl --silent --show-error --max-time 15 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null)"
    [[ "$code" =~ ^2 ]] || fail "$label answered HTTP ${code:-nothing} for $url"
    pass "$label answered HTTP $code"
}

if has_service redis; then
    # Spoken by hand so no redis-cli is needed on the host. The connection is held open past the
    # request: `printf ... | nc` closes stdin and macOS nc then exits before the reply lands,
    # which reported a healthy Redis as silent.
    redis_reply="$({ printf 'PING\r\n'; sleep 2; } | nc -G 5 -w 5 127.0.0.1 "$REDIS_PORT" 2>/dev/null | tr -d '\r\n')"
    [[ "$redis_reply" == "+PONG" ]] \
        || fail "redis replied '${redis_reply:-nothing}' instead of +PONG on $REDIS_PORT"
    pass "redis replied +PONG on $REDIS_PORT"
fi

if has_service postgres; then
    # In-container, because `psql` is not assumed on the host, and `pg_isready` is exactly what a
    # Compose healthcheck gate uses. The superuser name comes from the project's env rather than a
    # guess: a wrong guess would report a healthy server as broken.
    compose exec -T postgres sh -c 'pg_isready -U "${POSTGRES_USER:-postgres}"' >/dev/null 2>&1 \
        || fail "pg_isready failed inside the postgres container"
    pass "pg_isready succeeded in-container"

    # `-d` is explicit: without it psql connects to a database named after the user, which only
    # exists when the superuser happens to be `postgres`.
    if ! compose exec -T postgres sh -c \
        'psql -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-postgres}" -tAc "select 1 from pg_available_extensions where name = '"'"'vector'"'"'"' \
        2>/dev/null | grep -q 1; then
        printf '  info  no pgvector in this image (fine unless the project needs it)\n'
    else
        pass "pgvector extension available"
    fi
fi

has_service minio && http_ok minio "http://127.0.0.1:${MINIO_PORT}/minio/health/live"
has_service chroma && http_ok chroma "http://127.0.0.1:${CHROMA_PORT}/api/v2/heartbeat"
has_service mailpit && http_ok mailpit "http://127.0.0.1:${MAILPIT_WEB_PORT}/api/v1/info"

# ── Published-port durability ────────────────────────────────────────────────
# The failure this runtime is known for appears after a network has been up for a while, so the
# ports are probed again now that the checks above have exercised the stack.
printf '\nRe-probing ports after the protocol checks\n'
has_service postgres && probe_tcp postgres "$PG_PORT"
has_service minio && probe_tcp minio "$MINIO_PORT"

printf '\nAll gates passed.\n'

if [[ "$TEAR_DOWN" == "1" ]]; then
    printf '\nTearing down (--down)\n'
    compose down || fail "compose down failed"
    pass "compose down returned"
else
    printf '\nStack left running. Tear down with:\n'
    printf '  docker --context %s compose -f %s/docker-compose.yml down\n' \
        "$DOCKER_CONTEXT_NAME" "$PROJECT_DIR"
fi
