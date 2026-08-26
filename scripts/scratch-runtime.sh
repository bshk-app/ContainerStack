#!/usr/bin/env bash
# A runtime that can be thrown away: Apple Container's daemon and a socktainer bridge, both on a
# temporary root, running a command and then discarded (ContainerStack #48 step 2).
#
# Why it exists: anything worth measuring about the runtime damages it. Killing a vmnet helper to
# reproduce a route loss leaves the network undeletable; a mutating API sweep created 65 volumes and
# removed a real container. Both of those were paid for on a working runtime in one session.
#
# What it costs: Apple Container runs one daemon per user, so the machine's runtime is stopped for
# the duration and restored afterwards. Containers running at that moment are stopped with it — the
# script says so and refuses unless the machine is idle or --force is given.
#
#   scripts/scratch-runtime.sh -- docker --host "unix://$SCRATCH_SOCKET" run --rm alpine:3.20 true
#
# The command receives SCRATCH_SOCKET, SCRATCH_ROOT and SCRATCH_DOCKER in its environment.
set -uo pipefail

readonly BRIDGE="${SOCKTAINER_BIN:-$HOME/.local/bin/socktainer}"
readonly DOCKER_BIN="${DOCKER_BIN:-docker}"
readonly REAL_ROOT="$HOME/Library/Application Support/com.apple.container"

force=no
if [[ "${1:-}" == "--force" ]]; then
    force=yes
    shift
fi
[[ "${1:-}" == "--" ]] && shift
(($# > 0)) || {
    printf 'usage: %s [--force] -- <command...>\n' "$0" >&2
    exit 2
}

[[ -x "$BRIDGE" ]] || { printf 'No bridge binary at %s (set SOCKTAINER_BIN)\n' "$BRIDGE" >&2; exit 1; }

# Refuse to stop someone's work by surprise. `container ls` reads the daemon that is running now.
running="$(timeout 60 container ls --format json 2>/dev/null | python3 -c '
import json, sys
try:
    rows = json.load(sys.stdin)
except Exception:
    print("")
else:
    print(" ".join(r.get("configuration", {}).get("id", "?") for r in rows))
' 2>/dev/null)"
if [[ -n "${running// /}" && "$force" != "yes" ]]; then
    printf 'Containers are running on the real runtime: %s\n' "$running" >&2
    printf 'Stopping the daemon would stop them. Re-run with --force if that is fine.\n' >&2
    exit 1
fi

work="$(mktemp -d /tmp/scratch-runtime.XXXXXX)"
export SCRATCH_ROOT="$work/root"
export SCRATCH_SOCKET="$work/container.sock"
export SCRATCH_DOCKER="$DOCKER_BIN --host unix://$SCRATCH_SOCKET"
mkdir -p "$SCRATCH_ROOT"
# Declared before the trap is installed: `set -u` would abort restore() on any exit that happens
# before the bridge starts — including the daemon failing to come up — and an aborted trap leaves
# the machine's runtime stopped, which is the thing the trap exists to prevent.
bridge_pid=""
app_was_running=no
if pgrep -f "/Applications/ContainerStack.app/Contents/MacOS/ContainerStack" >/dev/null 2>&1; then
    app_was_running=yes
fi

restore() {
    local status=$?
    printf '\n=== discarding the scratch runtime ===\n'
    [[ -n "$bridge_pid" ]] && kill "$bridge_pid" 2>/dev/null
    # Stop the daemon while it still points at the scratch root, so it tears down what it made
    # there rather than leaving VMs attached to a directory that is about to vanish.
    timeout 180 container system stop >/dev/null 2>&1
    sleep 2
    rm -rf "$work"
    # Back to the machine's own root, and it takes more than `start --app-root`: the root is baked
    # into the launchd job that `system start` registered, so a daemon that is still loaded comes
    # back on the scratch root no matter what the flag says — and if the experiment wedged it,
    # `system stop` does not unload it either. Boot the job out, make sure nothing is left running,
    # then register the real one. Measured the hard way: a run left the daemon on a deleted /tmp
    # root, and every image and volume vanished from the lists until this sequence put it back.
    launchctl bootout "gui/$(id -u)/com.apple.container.apiserver" >/dev/null 2>&1
    sleep 2
    pkill -f "/usr/local/bin/container-apiserver" >/dev/null 2>&1
    sleep 2
    timeout 240 container system start --app-root "$REAL_ROOT" >/dev/null 2>&1
    sleep 4
    # The image index only reappears once the plugins re-register; if it is empty the daemon is on
    # the wrong root and the person needs to know now, not when their images look deleted.
    local root_now images_now
    root_now="$(timeout 60 container system status 2>&1 | awk '/appRoot/{$1=""; sub(/^ +/, ""); print}')"
    [[ "$root_now" == "$REAL_ROOT"* ]] || printf 'WARNING: daemon is on %s, not %s\n' "$root_now" "$REAL_ROOT" >&2
    # The images plugin does not re-register on the first start after a bootout, and until it does
    # every image reads as missing — which looks exactly like data loss to the person watching.
    images_now="$(timeout 60 container image ls 2>&1 | tail -n +2 | wc -l | tr -d ' ')"
    if [[ "$images_now" == "0" ]]; then
        timeout 180 container system stop >/dev/null 2>&1
        sleep 2
        timeout 240 container system start --app-root "$REAL_ROOT" >/dev/null 2>&1
        sleep 4
        images_now="$(timeout 60 container image ls 2>&1 | tail -n +2 | wc -l | tr -d ' ')"
    fi
    printf 'images visible again: %s\n' "$images_now"
    local status_line
    status_line="$(timeout 60 container system status 2>&1 | awk '/status/{print $2}')"
    printf 'real runtime: %s\n' "${status_line:-unknown}"
    # The app's own bridge died with the daemon it was talking to — its XPC connection is invalid
    # and it exits. Bring the app back so the machine ends where it started.
    if [[ "$app_was_running" == "yes" ]]; then
        pkill -f "/Applications/ContainerStack.app/Contents/Helpers/socktainer" 2>/dev/null
        rm -f "$HOME/.containerstack/docker.sock"
        open /Applications/ContainerStack.app 2>/dev/null
        for _ in $(seq 1 40); do
            [[ -S "$HOME/.containerstack/docker.sock" ]] \
                && timeout 5 curl -s --unix-socket "$HOME/.containerstack/docker.sock" "http://localhost/_ping" >/dev/null 2>&1 \
                && break
            sleep 1
        done
        printf 'app bridge: %s\n' \
            "$(timeout 5 curl -s -o /dev/null -w '%{http_code}' --unix-socket "$HOME/.containerstack/docker.sock" "http://localhost/_ping" 2>/dev/null)"
    fi
    exit $status
}
trap restore EXIT

if [[ "$app_was_running" == "yes" ]]; then
    printf '=== quitting the app so its bridge does not outlive the daemon ===\n'
    osascript -e 'tell application id "app.bshk.containerstack" to quit' >/dev/null 2>&1
    sleep 3
fi

printf '=== stopping the real runtime ===\n'
timeout 180 container system stop >/dev/null 2>&1
sleep 2

printf '=== starting a runtime on %s ===\n' "$SCRATCH_ROOT"
timeout 300 container system start --app-root "$SCRATCH_ROOT" --disable-kernel-install >/dev/null 2>&1
for _ in $(seq 1 30); do
    [[ "$(timeout 30 container system status 2>&1 | awk '/status/{print $2}')" == "running" ]] && break
    sleep 2
done
if [[ "$(timeout 30 container system status 2>&1 | awk '/status/{print $2}')" != "running" ]]; then
    printf 'the scratch daemon did not come up\n' >&2
    exit 1
fi

# The kernel is not copied into a fresh root, and every container needs one.
if [[ -d "$REAL_ROOT/kernels" ]]; then
    # `cp -R src dst` copies *into* dst when it exists, which nests kernels/kernels and leaves the
    # guest with no kernel to boot — the container then fails with a bare "Something went wrong".
    mkdir -p "$SCRATCH_ROOT/kernels"
    cp -R "$REAL_ROOT/kernels/." "$SCRATCH_ROOT/kernels/" 2>/dev/null
fi

printf '=== starting a bridge on %s ===\n' "$SCRATCH_SOCKET"
"$BRIDGE" --no-check-compatibility --no-docker-context --socket "$SCRATCH_SOCKET" --app-root "$SCRATCH_ROOT" \
    >"$work/bridge.log" 2>&1 &
bridge_pid=$!
for _ in $(seq 1 40); do
    [[ -S "$SCRATCH_SOCKET" ]] && timeout 5 curl -s --unix-socket "$SCRATCH_SOCKET" "http://localhost/_ping" >/dev/null 2>&1 && break
    sleep 1
done
if ! timeout 5 curl -s --unix-socket "$SCRATCH_SOCKET" "http://localhost/_ping" >/dev/null 2>&1; then
    printf 'the bridge did not come up; log:\n' >&2
    tail -5 "$work/bridge.log" >&2
    exit 1
fi

printf '=== running: %s ===\n' "$*"
"$@"
