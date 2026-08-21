#!/usr/bin/env bash
# An exit code is a fact about a container, not about the daemon that watched it (socktainer #20).
# Within one bridge lifetime it was always right, so the claim only means something across a restart.
#
# Runs its own bridge on its own socket and its own data root, so the restart is of an instance
# nobody else is using: restarting the machine's bridge would fight whatever supervises it, and a
# restart that cannot be undone takes the rest of a suite down with it.
set -uo pipefail

readonly BRIDGE="${SOCKTAINER_BIN:-$HOME/.local/bin/socktainer}"
readonly DOCKER_BIN="${DOCKER_BIN:-docker}"
readonly WORK="$(mktemp -d /tmp/exit-code-durability.XXXXXX)"
readonly SOCKET="$WORK/container.sock"
readonly ROOT="$WORK/root"
readonly NAME="durability-probe-$$"

passed=0
failed=0
pass() { printf 'PASS  %s%s\n' "$1" "${2:+: $2}"; passed=$((passed + 1)); }
fail() { printf 'FAIL  %s%s\n' "$1" "${2:+: $2}"; failed=$((failed + 1)); }

stop_bridge() {
    local pid="${1:-}"
    [[ -n "$pid" ]] || return 0
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || return 0; sleep 1; done
    kill -9 "$pid" 2>/dev/null || true
}

start_bridge() {
    "$BRIDGE" --no-check-compatibility --no-docker-context --socket "$SOCKET" --app-root "$ROOT" \
        >>"$WORK/bridge.log" 2>&1 &
    local pid=$!
    for _ in $(seq 1 40); do
        [[ -S "$SOCKET" ]] && timeout 5 curl -s --unix-socket "$SOCKET" "http://localhost/_ping" >/dev/null 2>&1 && {
            echo "$pid"
            return 0
        }
        sleep 1
    done
    echo ""
    return 1
}

cleanup() {
    timeout 60 "$DOCKER_BIN" --host "unix://$SOCKET" rm -f "$NAME" >/dev/null 2>&1 || true
    stop_bridge "${bridge_pid:-}"
    rm -rf "$WORK"
}
trap cleanup EXIT

[[ -x "$BRIDGE" ]] || { printf 'No bridge binary at %s (set SOCKTAINER_BIN)\n' "$BRIDGE" >&2; exit 1; }
mkdir -p "$ROOT"

bridge_pid="$(start_bridge)"
[[ -n "$bridge_pid" ]] || { fail "the bridge came up on its own socket"; exit 1; }
pass "the bridge came up on its own socket"

timeout 120 "$DOCKER_BIN" --host "unix://$SOCKET" run -d --name "$NAME" alpine:3.20 sh -c 'exit 42' >/dev/null 2>&1
sleep 4
before="$(timeout 30 "$DOCKER_BIN" --host "unix://$SOCKET" ps -a --filter "name=$NAME" --format '{{.Status}}' 2>/dev/null)"
if [[ "$before" == "Exited (42)"* ]]; then
    pass "the code is right while the bridge that saw it is running" "$before"
else
    fail "the code is right while the bridge that saw it is running" "$before"
fi

# The restart this whole script exists for.
stop_bridge "$bridge_pid"
bridge_pid="$(start_bridge)"
[[ -n "$bridge_pid" ]] || { fail "the bridge came back"; exit 1; }
pass "the bridge came back"

after="$(timeout 30 "$DOCKER_BIN" --host "unix://$SOCKET" ps -a --filter "name=$NAME" --format '{{.Status}}' 2>/dev/null)"
code="$(timeout 30 "$DOCKER_BIN" --host "unix://$SOCKET" inspect "$NAME" --format '{{.State.ExitCode}}' 2>/dev/null)"
finished="$(timeout 30 "$DOCKER_BIN" --host "unix://$SOCKET" inspect "$NAME" --format '{{.State.FinishedAt}}' 2>/dev/null)"
if [[ "$after" == "Exited (42)"* && "$code" == "42" ]]; then
    pass "the code survived the restart" "$after, FinishedAt=$finished"
else
    fail "the code survived the restart" "list=$after, inspect=$code"
fi

# The other half of #20: absent is not zero. A container this bridge never watched must not be
# reported as having exited cleanly.
unknown="$(timeout 30 "$DOCKER_BIN" --host "unix://$SOCKET" inspect "$NAME" --format '{{.State.ExitCode}}' 2>/dev/null)"
rm -f "$ROOT/socktainer-container-exit-codes.json"
stop_bridge "$bridge_pid"
bridge_pid="$(start_bridge)"
forgotten="$(timeout 30 "$DOCKER_BIN" --host "unix://$SOCKET" inspect "$NAME" --format '{{.State.ExitCode}}' 2>/dev/null)"
if [[ "$unknown" == "42" && "$forgotten" != "0" && -n "$forgotten" ]]; then
    pass "a container whose record is gone does not claim a clean 0" "reports $forgotten"
else
    fail "a container whose record is gone does not claim a clean 0" "with record=$unknown, without=$forgotten"
fi

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
