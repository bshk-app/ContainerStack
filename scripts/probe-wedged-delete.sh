#!/usr/bin/env bash
# Why does a wedged `DELETE /networks/{id}` still hang for a client when the bridge bounds it at 60s?
#
# The route-level bound is proven in isolation (socktainer `NetworkDeleteRouteTests`: a client whose
# delete never returns is answered in 0.2s with the remedy). Live, `docker network rm` still waited out
# 150s. This asks the socket directly, so the docker CLI is not in the way, and prints the bridge's own
# log around the attempt.
#
#   SOCKTAINER_BIN=/path/to/socktainer scripts/scratch-runtime.sh -- \
#       bash -c 'exec scripts/probe-wedged-delete.sh "$SCRATCH_SOCKET"'
set -uo pipefail

readonly SOCKET="${1:?usage: $0 <socket>}"
readonly DOCKER_BIN="${DOCKER_BIN:-docker}"
readonly NET="probe-net"
readonly BOX="probe-box"

D() { timeout 120 "$DOCKER_BIN" --host "unix://$SOCKET" "$@"; }

D network create "$NET" >/dev/null 2>&1 || { printf 'could not create the network\n'; exit 1; }
D run -d --name "$BOX" --network "$NET" alpine:3.20 \
    sh -c 'trap "exit 0" TERM INT; while true; do sleep 3600 & wait $!; done' >/dev/null 2>&1
sleep 5

helper="$(pgrep -f "container-network-vmnet start --id $NET" | head -1)"
[[ -n "$helper" ]] || { printf 'no helper to kill\n'; exit 1; }
kill -9 "$helper" 2>/dev/null
printf 'helper %s killed\n' "$helper"

# The wedge: the container restart a person reaches for. The client giving up does not stop the
# operation inside the daemon.
timeout 45 "$DOCKER_BIN" --host "unix://$SOCKET" restart "$BOX" >/dev/null 2>&1
printf 'restart abandoned after 45s\n'
timeout 60 "$DOCKER_BIN" --host "unix://$SOCKET" rm -f "$BOX" >/dev/null 2>&1

printf '\n--- inspect the network (does the read hang too?) ---\n'
t0=$SECONDS
inspect="$(timeout 40 curl -s -m 35 -o /dev/null -w '%{http_code}' --unix-socket "$SOCKET" \
    "http://localhost/v1.51/networks/$NET" 2>&1)"
printf 'GET  /networks/%s -> %s after %ss\n' "$NET" "${inspect:-<no answer>}" "$((SECONDS - t0))"

printf '\n--- delete it, asking the socket directly ---\n'
t0=$SECONDS
body="$(timeout 130 curl -s -m 120 -w '\n%{http_code} after %{time_total}s' -X DELETE \
    --unix-socket "$SOCKET" "http://localhost/v1.51/networks/$NET" 2>&1)"
printf '%s\n' "${body:-<no answer at all>}"
printf 'elapsed: %ss\n' "$((SECONDS - t0))"

# The same wedge again, asked through the docker CLI this time. `verify-stage0-remedies.sh pending`
# saw it wait out 150s where curl was answered at 63s, and a fix that only reaches curl is not a fix.
printf '\n--- the same thing again, through the docker CLI ---\n'
readonly NET2="probe-net-2"
readonly BOX2="probe-box-2"
D network create "$NET2" >/dev/null 2>&1
D run -d --name "$BOX2" --network "$NET2" alpine:3.20 \
    sh -c 'trap "exit 0" TERM INT; while true; do sleep 3600 & wait $!; done' >/dev/null 2>&1
sleep 5
helper2="$(pgrep -f "container-network-vmnet start --id $NET2" | head -1)"
kill -9 "$helper2" 2>/dev/null
printf 'helper %s killed\n' "${helper2:-none}"
timeout 45 "$DOCKER_BIN" --host "unix://$SOCKET" restart "$BOX2" >/dev/null 2>&1
timeout 60 "$DOCKER_BIN" --host "unix://$SOCKET" rm -f "$BOX2" >/dev/null 2>&1

t0=$SECONDS
cli_out="$(timeout 130 "$DOCKER_BIN" --host "unix://$SOCKET" network rm "$NET2" 2>&1)"
printf 'docker network rm -> after %ss: %s\n' "$((SECONDS - t0))" "${cli_out:-<empty>}"

printf '\n--- what the bridge logged ---\n'
tail -25 "${SCRATCH_ROOT%/root}/bridge.log" 2>/dev/null | grep -viE "GET /_ping|/v1.51/(containers|images)/json" | tail -15
