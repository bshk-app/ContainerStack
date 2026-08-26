#!/usr/bin/env bash
# Does restarting a container bring back a network whose vmnet helper died?
#
# The app offers that as the repair (#47). This measures one arm per run, because the first arm can
# leave the daemon unable to bring up a second network, and a wedged daemon turns the next arm into
# noise:
#
#   scripts/scratch-runtime.sh -- bash -c 'exec scripts/verify-network-recovery.sh control "$SCRATCH_SOCKET"'
#   scripts/scratch-runtime.sh -- bash -c 'exec scripts/verify-network-recovery.sh bridge  "$SCRATCH_SOCKET"'
#   scripts/scratch-runtime.sh -- bash -c 'exec scripts/verify-network-recovery.sh cli     "$SCRATCH_SOCKET"'
#
#   control — a network created through the bridge, helper left alone, container restarted.
#             It measures the harness: if this arm fails, nothing the other two say means anything.
#   bridge  — the same network, helper killed first. `NetworkCreateRoute.createPinned` pins a subnet
#             on every network the bridge creates, so this is the shape a user always has.
#   cli     — created by Apple's CLI, which leaves the subnet unpinned. The one arm that has ever
#             recovered was this shape.
#
# The workload is a real daemon, not `sh` running a loop: POSIX sh as PID 1 installs no SIGTERM
# handler, so a container built that way is always SIGKILLed on stop and always exits 137 — which
# reads as a failed restart on every arm and says nothing about the network.
set -uo pipefail

readonly ARM="${1:-control}"
readonly SOCKET="${2:-$HOME/.containerstack/docker.sock}"
readonly DOCKER_BIN="${DOCKER_BIN:-docker}"
readonly PORT=18093
readonly NET="recov-$ARM"
readonly BOX="recov-$ARM-box"

passed=0
failed=0
pass() { printf 'PASS  %s%s\n' "$1" "${2:+: $2}"; passed=$((passed + 1)); }
fail() { printf 'FAIL  %s%s\n' "$1" "${2:+: $2}"; failed=$((failed + 1)); }
note() { printf '      %s\n' "$1"; }

D() { timeout 240 "$DOCKER_BIN" --host "unix://$SOCKET" "$@"; }

serves() { timeout 10 curl -s -m 6 "http://127.0.0.1:$PORT/" 2>/dev/null; }
state_of() { D ps -a --filter "name=$BOX" --format '{{.Status}}' 2>/dev/null; }
subnet_of() { timeout 60 container ls 2>/dev/null | awk -v b="$BOX" '$1 == b {print $6}'; }

[[ -S "$SOCKET" ]] || { printf 'No socket at %s\n' "$SOCKET" >&2; exit 1; }

case "$ARM" in
    control | bridge | runtime) D network create "$NET" >/dev/null 2>&1 ;;
    cli) timeout 120 container network create "$NET" >/dev/null 2>&1 ;;
    *) printf 'unknown arm %s\n' "$ARM" >&2; exit 2 ;;
esac

# PID 1 has to die on TERM, or every stop is a SIGKILL and every arm ends in 137 whatever the
# network did. alpine's busybox has no httpd and its `nc` cannot keep listening, so the listener is
# a loop — but with a trap and an interruptible `wait`, which is what makes the shell answer the
# signal instead of ignoring it as PID 1. Measured: `docker stop` on this returns in 1s with
# `Exited (0)`, against 137 for the same loop without the trap.
D run -d --name "$BOX" --network "$NET" -p "$PORT:80" alpine:3.20 \
    sh -c 'trap "exit 0" TERM INT; while true; do printf "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi" | nc -l -p 80 & wait $!; done' >/dev/null 2>&1

for _ in $(seq 1 30); do
    [[ "$(serves)" == "hi" ]] && break
    sleep 2
done
subnet_before="$(subnet_of)"
if [[ "$(serves)" != "hi" ]]; then
    fail "$ARM: serves before anything is broken" "state=$(state_of)"
    exit 1
fi
note "$ARM: up on ${subnet_before:-?}, port answers"

if [[ "$ARM" != "control" ]]; then
    helper="$(pgrep -f "container-network-vmnet start --id $NET" | head -1)"
    [[ -n "$helper" ]] || { fail "$ARM: found the network's helper"; exit 1; }
    kill -9 "$helper" 2>/dev/null
    sleep 4
    if [[ "$(serves)" == "hi" ]]; then
        fail "$ARM: killing the helper breaks forwarding" "still serving"
        exit 1
    fi
    note "$ARM: helper dead, port no longer answers"
fi

# The repair being measured. Polled, not slept: a restart measured 6.4s on an idle machine and is
# slower after a helper kill, so a flat wait reads the middle of one and calls it a failure.
restart_began="$(date +%s)"
if [[ "$ARM" == "runtime" ]]; then
    # What the app's "Restart Runtime" does: the daemon goes down and comes back, and the container
    # is started again on the other side. The bridge stays where it is; only the runtime cycles.
    timeout 240 container system stop >/dev/null 2>&1
    sleep 3
    timeout 300 container system start --app-root "${SCRATCH_ROOT:?runtime arm must run inside scratch-runtime.sh}" >/dev/null 2>&1
    sleep 5
    D start "$BOX" >/dev/null 2>&1
else
    D restart "$BOX" >/dev/null 2>&1
fi
restart_took=$(( $(date +%s) - restart_began ))
for _ in $(seq 1 45); do
    [[ "$(state_of)" == Up* && "$(serves)" == "hi" ]] && break
    sleep 2
done

after="$(serves)"
state="$(state_of)"
subnet_after="$(subnet_of)"
if [[ "$after" == "hi" ]]; then
    pass "$ARM: restarting the container restores forwarding" "${restart_took}s, ${subnet_before:-?} -> ${subnet_after:-?}"
    [[ "$subnet_before" != "$subnet_after" ]] && note "$ARM: the address changed; anything holding it must reconnect"
else
    fail "$ARM: restarting the container restores forwarding" "state=$state, restart took ${restart_took}s, port='$after'"
fi

# Whether the network can be taken away afterwards is its own answer: a user who cannot delete it has
# no way back short of stopping the daemon. The container goes first — a network with something
# attached is refused for an ordinary reason, and counting that as damage would be wrong.
D rm -f "$BOX" >/dev/null 2>&1
sleep 2
if D network rm "$NET" >/dev/null 2>&1; then
    note "$ARM: the network could be removed afterwards"
else
    note "$ARM: the network could NOT be removed afterwards (pending operation)"
fi

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
