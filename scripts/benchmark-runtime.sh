#!/usr/bin/env bash
set -uo pipefail

# Benchmark one container runtime through its Docker socket.
#
#   ./scripts/benchmark-runtime.sh <label> <docker-socket-path> [iterations]
#
# Every measurement is gated on the operation actually succeeding, and the
# filesystem cases additionally verify the produced data on the host. A runtime
# that cannot perform a step reports FAILED instead of a fast time.

readonly LABEL="${1:?usage: benchmark-runtime.sh <label> <socket-path> [iterations]}"
readonly SOCKET="${2:?usage: benchmark-runtime.sh <label> <socket-path> [iterations]}"
readonly ITERATIONS="${3:-5}"
readonly IMAGE="${BENCH_IMAGE:-docker.io/library/alpine:3.20}"
readonly DOCKER_BIN="${DOCKER_BIN:-docker}"
readonly WRITE_MIB=256
readonly SMALL_FILES=3000

export DOCKER_HOST="unix://${SOCKET}"
unset DOCKER_CONTEXT

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

log() { printf '%s\n' "$*" >&2; }
now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }
record() { printf '%s\t%s\t%s\n' "$LABEL" "$1" "$2" >> "$workdir/results.tsv"; }
docker_quiet() { "$DOCKER_BIN" "$@" >/dev/null 2>&1; }

median() {
    sort -n | awk '{v[NR]=$1} END {if (NR==0) {print "NA"; exit} print (NR%2) ? v[(NR+1)/2] : int((v[NR/2]+v[NR/2+1])/2)}'
}

# timed <metric> <command...> — records elapsed ms only when the command succeeds.
timed() {
    local metric="$1"
    shift
    local start elapsed
    start="$(now_ms)"
    if "$@" >/dev/null 2>&1; then
        elapsed=$(( $(now_ms) - start ))
        record "$metric" "$elapsed"
        printf '%s\n' "$elapsed"
    else
        record "$metric" "FAILED"
        printf 'FAILED\n'
    fi
}

require() {
    command -v "$1" >/dev/null 2>&1 || { log "missing command: $1"; exit 1; }
}

require "$DOCKER_BIN"
require python3

[[ -S "$SOCKET" ]] || { log "socket not listening: $SOCKET"; exit 1; }
"$DOCKER_BIN" version >/dev/null 2>&1 || { log "docker cannot reach $SOCKET"; exit 1; }

log "== $LABEL: preparing (image $IMAGE) =="
docker_quiet pull "$IMAGE" || { log "cannot pull $IMAGE"; exit 1; }

# 1. container start -> exit latency
log "== $LABEL: container round trip x$ITERATIONS =="
samples="$workdir/roundtrip"
failures=0
for _ in $(seq "$ITERATIONS"); do
    start="$(now_ms)"
    if docker_quiet run --rm "$IMAGE" /bin/true; then
        printf '%s\n' "$(( $(now_ms) - start ))" >> "$samples"
    else
        failures=$(( failures + 1 ))
    fi
done
if [[ -s "$samples" && "$failures" -eq 0 ]]; then
    record "run_roundtrip_ms" "$(median < "$samples")"
else
    record "run_roundtrip_ms" "FAILED($failures/$ITERATIONS)"
fi

# 2. cpu-bound work inside the guest
log "== $LABEL: guest cpu loop =="
timed "guest_cpu_loop_ms" "$DOCKER_BIN" run --rm "$IMAGE" \
    /bin/sh -c 'i=0; while [ $i -lt 300000 ]; do i=$((i+1)); done' >/dev/null

# 3. image pull from a cold local store
log "== $LABEL: cold pull =="
if docker_quiet rmi -f "$IMAGE"; then
    timed "cold_pull_ms" "$DOCKER_BIN" pull "$IMAGE" >/dev/null
else
    record "cold_pull_ms" "SKIPPED_RMI_FAILED"
fi
docker_quiet pull "$IMAGE"

# 4. write throughput into a managed volume, verified by reading the blob back
log "== $LABEL: volume write ${WRITE_MIB} MiB =="
volume="bench-$RANDOM"
if docker_quiet volume create "$volume"; then
    timed "volume_write_${WRITE_MIB}mib_ms" "$DOCKER_BIN" run --rm -v "$volume:/data" "$IMAGE" \
        /bin/sh -c "dd if=/dev/zero of=/data/blob bs=1M count=${WRITE_MIB} conv=fsync && [ \$(wc -c < /data/blob) -eq $(( WRITE_MIB * 1024 * 1024 )) ]" >/dev/null
    docker_quiet volume rm -f "$volume"
else
    record "volume_write_${WRITE_MIB}mib_ms" "FAILED_VOLUME_CREATE"
fi

# 5. bind mount write throughput, verified against the file the host can see
log "== $LABEL: bind mount write ${WRITE_MIB} MiB =="
mkdir -p "$workdir/bind"
timed "bind_write_${WRITE_MIB}mib_ms" "$DOCKER_BIN" run --rm -v "$workdir/bind:/host" "$IMAGE" \
    /bin/sh -c "dd if=/dev/zero of=/host/blob bs=1M count=${WRITE_MIB} conv=fsync" >/dev/null
expected_bytes=$(( WRITE_MIB * 1024 * 1024 ))
actual_bytes=$(stat -f %z "$workdir/bind/blob" 2>/dev/null || echo 0)
if [[ "$actual_bytes" -ne "$expected_bytes" ]]; then
    record "bind_write_verified" "NO(host_bytes=$actual_bytes)"
else
    record "bind_write_verified" "YES"
fi
rm -f "$workdir/bind/blob"

# 6. bind mount metadata cost, verified by counting the files on the host
log "== $LABEL: bind mount ${SMALL_FILES} small files =="
timed "bind_create_${SMALL_FILES}_files_ms" "$DOCKER_BIN" run --rm -v "$workdir/bind:/host" "$IMAGE" \
    /bin/sh -c "i=0; while [ \$i -lt ${SMALL_FILES} ]; do echo x > /host/f\$i; i=\$((i+1)); done" >/dev/null
host_files=$(find "$workdir/bind" -type f | wc -l | tr -d ' ')
if [[ "$host_files" -eq "$SMALL_FILES" ]]; then
    record "bind_files_verified" "YES"
else
    record "bind_files_verified" "NO(host_files=$host_files)"
fi
rm -rf "$workdir/bind"

# 7. published port reachability and request latency
log "== $LABEL: published port =="
port=$((20000 + RANDOM % 10000))
server=$("$DOCKER_BIN" run -d -p "$port:80" "$IMAGE" \
    /bin/sh -c "while true; do printf 'HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nok\n' | nc -l -p 80; done" 2>/dev/null)
if [[ -n "$server" ]]; then
    reachable=""
    for _ in $(seq 30); do
        if curl --max-time 2 -sS "http://127.0.0.1:$port/" >/dev/null 2>&1; then reachable=yes; break; fi
        sleep 1
    done
    if [[ -n "$reachable" ]]; then
        timed "published_port_request_ms" curl --max-time 5 -sS "http://127.0.0.1:$port/" >/dev/null
    else
        record "published_port_request_ms" "UNREACHABLE"
    fi
    docker_quiet rm -f "$server"
else
    record "published_port_request_ms" "CREATE_FAILED"
fi

# 8. idle footprint, attributed to the runtime under test only.
# The GUI state is reported next to it: comparing a running GUI against a quit one
# would make the lighter arm look better for the wrong reason.
log "== $LABEL: idle footprint =="
sleep 3
case "$LABEL" in
    orbstack)
        pattern='OrbStack|orbstack|vmnetd'
        gui_pattern='/Applications/OrbStack.app/Contents/MacOS/OrbStack'
        ;;
    containerstack)
        pattern='socktainer|container-apiserver|container-runtime-linux|container-network-vmnet|container-core-images|ContainerStackRuntime|ContainerStack.app'
        gui_pattern='ContainerStack.app/Contents/MacOS/ContainerStack'
        ;;
    *)
        pattern="$LABEL"
        gui_pattern="$LABEL"
        ;;
esac

rss_kib=$(ps -A -o rss=,command= | grep -Ei "$pattern" | grep -v grep \
    | awk '{sum += $1} END {print (sum ? sum : 0)}')
record "runtime_rss_mib" "$(( rss_kib / 1024 ))"
record "gui_running" "$(pgrep -f "$gui_pattern" >/dev/null 2>&1 && echo yes || echo no)"
record "idle_cpu_pct" "$(top -l 1 -n 0 | awk -F'[,%]' '/CPU usage/ {for (i=1;i<=NF;i++) if ($i ~ /idle/) {gsub(/[^0-9.]/,"",$(i-1)); print $(i-1); exit}}')"
record "load1" "$(uptime | sed 's/.*load averages*: //' | awk '{print $1}' | tr -d ',')"

printf '\n### %s\n' "$LABEL"
printf 'host: %s | load: %s | idle-cpu: %s\n' \
    "$(uname -srm)" \
    "$(uptime | sed 's/.*load averages*: //')" \
    "$(top -l 1 -n 0 | awk -F', ' '/CPU usage/ {print $3}')"
printf 'server: %s\n' "$("$DOCKER_BIN" version --format '{{.Server.Version}} api={{.Server.APIVersion}}' 2>/dev/null)"
cat "$workdir/results.tsv"
