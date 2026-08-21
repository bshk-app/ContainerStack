#!/usr/bin/env bash
set -uo pipefail

# Compare OrbStack and ContainerStack on the same host, back to back.
#
#   ./scripts/benchmark-compare.sh [iterations]
#
# Refuses to run on a busy machine: container benchmarks on a loaded host measure
# the load, not the runtime. Override with BENCH_FORCE=1 and expect noisy numbers.

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly HARNESS="${SCRIPT_DIR}/benchmark-runtime.sh"
readonly ITERATIONS="${1:-5}"
readonly ORB_SOCKET="${ORB_SOCKET:-${HOME}/.orbstack/run/docker.sock}"
readonly CSTACK_SOCKET="${CSTACK_SOCKET:-${HOME}/.socktainer/container.sock}"
readonly MIN_IDLE_CPU="${BENCH_MIN_IDLE_CPU:-70}"
readonly MAX_LOAD="${BENCH_MAX_LOAD:-4}"

idle_cpu() {
    top -l 1 -n 0 | awk -F'[,%]' '/CPU usage/ {for (i=1;i<=NF;i++) if ($i ~ /idle/) {gsub(/[^0-9.]/,"",$(i-1)); print $(i-1); exit}}'
}

load_average() {
    uptime | sed 's/.*load averages*: //' | awk '{print $1}' | tr -d ','
}

check_quiet() {
    local idle load
    idle="$(idle_cpu)"
    load="$(load_average)"
    printf 'host state: idle-cpu=%s%% load1=%s\n' "$idle" "$load"

    [[ -n "${BENCH_FORCE:-}" ]] && { printf 'BENCH_FORCE set, continuing on a busy host\n'; return; }

    awk -v idle="$idle" -v min="$MIN_IDLE_CPU" 'BEGIN {exit !(idle+0 < min+0)}' && {
        printf 'Refusing to benchmark: only %s%% CPU idle (need %s%%).\n' "$idle" "$MIN_IDLE_CPU" >&2
        printf 'Quiet the machine or set BENCH_FORCE=1.\n' >&2
        exit 2
    }
    awk -v load="$load" -v max="$MAX_LOAD" 'BEGIN {exit !(load+0 > max+0)}' && {
        printf 'Refusing to benchmark: load average %s above %s.\n' "$load" "$MAX_LOAD" >&2
        printf 'Quiet the machine or set BENCH_FORCE=1.\n' >&2
        exit 2
    }
}

run_one() {
    local label="$1" socket="$2"
    if [[ ! -S "$socket" ]]; then
        printf 'No %s socket at %s.\n' "$label" "$socket" >&2
        printf 'A one-armed run is not a comparison: start %s first.\n' "$label" >&2
        exit 3
    fi
    [[ -x "$HARNESS" ]] || { printf 'Harness not found: %s\n' "$HARNESS" >&2; exit 4; }
    "$HARNESS" "$label" "$socket" "$ITERATIONS"
}

wait_for_socket() {
    local socket="$1" attempts="${2:-30}"
    for _ in $(seq "$attempts"); do
        [[ -S "$socket" ]] && return 0
        sleep 1
    done
    return 1
}

# OrbStack only exposes its socket while the app runs.
if [[ ! -S "$ORB_SOCKET" && -d /Applications/OrbStack.app ]]; then
    printf 'Starting OrbStack for the comparison...\n'
    open -a OrbStack
    wait_for_socket "$ORB_SOCKET" 60 || true
fi

check_quiet

report_dir="${BENCH_REPORT_DIR:-${ROOT}/claudedocs}"
report="${report_dir}/benchmark_$(date +%Y%m%d-%H%M%S).txt"
mkdir -p "$report_dir"

{
    printf '# Runtime comparison\n'
    printf 'date: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'host: %s %s\n' "$(hostname)" "$(uname -srm)"
    printf 'cpu: %s\n' "$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown)"
    printf 'memory: %s GiB\n' "$(( $(sysctl -n hw.memsize) / 1073741824 ))"
    printf 'iterations: %s\n\n' "$ITERATIONS"
} | tee "$report"

run_one orbstack "$ORB_SOCKET" | tee -a "$report"
run_one containerstack "$CSTACK_SOCKET" | tee -a "$report"

printf '\nReport: %s\n' "$report"
