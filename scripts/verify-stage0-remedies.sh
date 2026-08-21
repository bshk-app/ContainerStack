#!/usr/bin/env bash
# Which remedy actually clears the two dead ends of Stage 0? (ContainerStack #1 remainder, #50)
#
# Both are states where the message a person gets does not contain the way out, so the message has to
# name a remedy — and a named remedy has to be measured. #47 was closed twice on an unmeasured one.
#
#   pending      a network whose vmnet helper died refuses to be deleted: "has a pending operation".
#                Ladder: delete again -> restart the runtime -> stop the daemon and remove the
#                network's directory. The first rung that works is the one worth printing.
#
#   erased-root  the app root is deleted under a running runtime. `CONTAINER_APP_ROOT` is baked into
#                the launchd job's environment, so `system stop` + `system start --app-root <other>`
#                reuses the job and comes back on the deleted root. Ladder: plain restart -> bootout
#                and start -> a second cycle for the images plugin.
#
# Run inside a disposable runtime, never on a working one — the pending arm leaves a wedged network
# and the erased-root arm deletes the root it runs on:
#
#   scripts/scratch-runtime.sh -- bash -c 'exec scripts/verify-stage0-remedies.sh pending "$SCRATCH_SOCKET"'
set -uo pipefail

readonly ARM="${1:?usage: $0 <pending|erased-root> <socket>}"
readonly SOCKET="${2:?usage: $0 <pending|erased-root> <socket>}"
readonly DOCKER_BIN="${DOCKER_BIN:-docker}"
readonly REAL_ROOT="$HOME/Library/Application Support/com.apple.container"
readonly AGENT="gui/$(id -u)/com.apple.container.apiserver"

passed=0
failed=0
pass() { printf 'PASS  %s%s\n' "$1" "${2:+: $2}"; passed=$((passed + 1)); }
fail() { printf 'FAIL  %s%s\n' "$1" "${2:+: $2}"; failed=$((failed + 1)); }
note() { printf '      %s\n' "$1"; }

D() { timeout 240 "$DOCKER_BIN" --host "unix://$SOCKET" "$@"; }
status_root() {
    timeout 60 container system status 2>/dev/null |
        awk '/^appRoot/{$1=""; sub(/^ +/, ""); sub(/\/$/, ""); print}'
}
# `container images list` is not a command — the CLI resolves it as a plugin and fails with
# `Plugin 'container-images' not found`, which counts as zero images and reads exactly like a broken
# store. Three rungs of a ladder were built to chase that artifact. The subcommand is `image ls`.
image_count() { timeout 120 container image ls 2>/dev/null | tail -n +2 | grep -c . ; }

# A restarted daemon answers `system status` before it answers real requests: a 5s sleep here got
# "XPC timeout for request to networkList" and the arm scored that as the remedy failing. Wait for a
# request that needs the network service, not for the process.
await_daemon() {
    for _ in $(seq 1 30); do
        timeout 20 container network list >/dev/null 2>&1 && return 0
        sleep 2
    done
    return 1
}

[[ -S "$SOCKET" ]] || { printf 'No socket at %s\n' "$SOCKET" >&2; exit 1; }

# ---------------------------------------------------------------- pending operation
if [[ "$ARM" == "pending" ]]; then
    readonly NET="pend-net"
    readonly BOX="pend-box"

    D network create "$NET" >/dev/null 2>&1 || { fail "created the network"; exit 1; }
    # A container is what makes the helper exist. PID 1 traps TERM so a stop is a stop and not a
    # SIGKILL — the same correction the network-recovery harness needed.
    D run -d --name "$BOX" --network "$NET" alpine:3.20 \
        sh -c 'trap "exit 0" TERM INT; while true; do sleep 3600 & wait $!; done' >/dev/null 2>&1
    sleep 5

    helper="$(pgrep -f "container-network-vmnet start --id $NET" | head -1)"
    [[ -n "$helper" ]] || { fail "found the network's helper"; exit 1; }
    kill -9 "$helper" 2>/dev/null
    note "helper $helper killed"

    # Killing the helper is not enough: with no container attached, the network deletes in 5s
    # (measured). What wedges it is the container restart — the repair the app used to advise — which
    # hangs inside the daemon while the network is marked busy, so the delete after it never returns
    # and the one after that reports the pending operation.
    printf '  wedging it the way a user does: restarting the container\n'
    t0=$SECONDS
    timeout 45 "$DOCKER_BIN" --host "unix://$SOCKET" restart "$BOX" >/dev/null 2>&1
    note "restart gave up or returned after $((SECONDS - t0))s"

    # Is the bridge wedged as a whole, or only this network's removal? A route-level bound can only
    # help if requests still reach the route. Ask for something that touches nothing.
    ping="$(timeout 10 curl -s -o /dev/null -w '%{http_code}' --unix-socket "$SOCKET" http://localhost/_ping 2>/dev/null)"
    ps_out="$(timeout 15 "$DOCKER_BIN" --host "unix://$SOCKET" ps -a --format '{{.Names}}' 2>&1 | tr '\n' ' ')"
    if [[ "$ping" == "200" ]]; then
        note "the bridge still answers _ping (200) — the wedge is per-network, a route bound can work"
    else
        note "the bridge does NOT answer _ping (got '${ping:-nothing}') — it is wedged as a whole"
    fi
    note "ps says: ${ps_out:-<nothing>}"

    # Referring containers are refused separately and by name, so remove it to keep that out of the
    # way — bounded, because a wedged container can hold this too.
    timeout 60 "$DOCKER_BIN" --host "unix://$SOCKET" rm -f "$BOX" >/dev/null 2>&1

    # The contract: whatever state the runtime is in, the client gets an answer and the answer carries
    # the way out. Before this the first delete simply never returned — two attempts, 120s each, no
    # message at all, which is a worse dead end than the raw "pending operation" it was meant to fix.
    # Asked over the socket rather than through the docker CLI: the contract is the API answer, and
    # the CLI adds its own retry and connection handling on top. Measured live, the bridge answers this
    # at 63s with the remedy; through `docker network rm` one run instead waited out 150s and has not
    # been reproduced since — unexplained, not yet filed.
    printf '  rung 1: delete the network and see what comes back\n'
    t0=$SECONDS
    answer="$(timeout 130 curl -s -m 120 -w '\n%{http_code}' -X DELETE \
        --unix-socket "$SOCKET" "http://localhost/v1.51/networks/$NET" 2>&1)"
    took=$((SECONDS - t0))
    note "answered after ${took}s: $(printf '%s' "$answer" | tr '\n' ' ')"

    if [[ "$answer" == *"restart the runtime"* ]]; then
        pass "the refusal names the remedy" "${took}s"
    elif [[ "$answer" == *"204"* ]]; then
        fail "the refusal names the remedy" "the network deleted itself, nothing to diagnose"
    else
        fail "the refusal names the remedy" "$(printf '%s' "$answer" | tr '\n' ' ')"
    fi
    if ((took < 100)); then
        pass "the client is not left hanging" "${took}s, inside the bridge's 60s bound plus slack"
    else
        fail "the client is not left hanging" "${took}s"
    fi

    printf '  rung 2: restart the runtime\n'
    timeout 120 container system stop >/dev/null 2>&1
    timeout 180 container system start --app-root "${SCRATCH_ROOT:?refusing to restart without a scratch root}" >/dev/null 2>&1
    await_daemon || note "the daemon never became ready; what follows may be measuring that instead"
    after_restart="$(timeout 120 container network delete "$NET" 2>&1)"
    if [[ -z "$after_restart" ]]; then
        pass "restarting the runtime makes it deletable" "removed after restart"
        remedy="restart the runtime"
    else
        fail "restarting the runtime makes it deletable" "$after_restart"
        printf '  rung 3: stop the daemon and remove the directory\n'
        timeout 120 container system stop >/dev/null 2>&1
        rm -rf "${SCRATCH_ROOT:?}/networks/$NET"
        timeout 180 container system start --app-root "$SCRATCH_ROOT" >/dev/null 2>&1
        await_daemon || note "the daemon never became ready"
        gone="$(timeout 120 container network list 2>/dev/null | grep -c "$NET")"
        if [[ "$gone" == "0" ]]; then
            pass "removing the directory clears it" "network gone after directory removal"
            remedy="stop the runtime and remove the network directory"
        else
            fail "removing the directory clears it" "still listed"
            remedy="unknown"
        fi
    fi
    note "remedy to print: $remedy"

# ---------------------------------------------------------------- runtime on a deleted root
elif [[ "$ARM" == "erased-root" ]]; then
    root_before="$(status_root)"
    [[ -n "$root_before" && -d "$root_before" ]] || { fail "runtime starts on a root that exists" "$root_before"; exit 1; }
    note "runtime is on $root_before"
    [[ "$root_before" == /tmp/* ]] || {
        fail "the root is disposable" "refusing to delete $root_before"
        exit 1
    }

    rm -rf "$root_before"
    sleep 3
    root_after="$(status_root)"
    if [[ "$root_after" == "$root_before" && ! -d "$root_after" ]]; then
        pass "the runtime keeps reporting the deleted root" "appRoot=$root_after, exists=no"
    else
        fail "the runtime keeps reporting the deleted root" "appRoot=${root_after:-<none>}"
    fi

    # The pair of inputs the app resolves its state on. They disagree in this state, which is what made
    # the banner alternate: the poll asks _ping and the full refresh asks /info.
    api="$(timeout 30 curl -s -o /dev/null -w '%{http_code}' --unix-socket "$SOCKET" http://localhost/_ping 2>/dev/null)"
    info="$(timeout 30 curl -s -o /dev/null -w '%{http_code}' --unix-socket "$SOCKET" http://localhost/v1.51/info 2>/dev/null)"
    if [[ "$api" == "200" && "$info" != "200" ]]; then
        pass "the ping succeeds while the API call fails" "_ping=$api /info=$info"
    else
        note "_ping=$api /info=$info"
        fail "the ping succeeds while the API call fails" "the app resolves on this pair"
    fi

    # The shared decision, through the client that can be driven from a script. `cstack doctor` and the
    # app read the same `container system status` and the same parser.
    doctor="$(timeout 120 .build/debug/cstack doctor --socket "$SOCKET" 2>&1)"
    if [[ "$doctor" == *"Runtime storage: MISSING"* && "$doctor" == *"cstack runtime restart"* ]]; then
        pass "the state is named, with the remedy" "$(printf '%s' "$doctor" | grep -c .) lines, no launchd"
    else
        fail "the state is named, with the remedy" "$(printf '%s' "$doctor" | tr '\n' ' ' | cut -c1-140)"
    fi
    if [[ "$doctor" == *"launchctl"* || "$doctor" == *"bootout"* ]]; then
        fail "the remedy does not mention launchd" "it does"
    fi

    # Measure the ladder in the order the app would climb it, one rung per run of the daemon, because
    # an earlier rung that already fixes the root leaves the later ones with nothing to prove. That is
    # how the first pass of this arm produced two meaningless results.
    #
    # Rung 1 is exactly what the app's "Restart Runtime" does: `container system start` with no flag
    # (RuntimeProcessConfiguration.containerStartArguments).
    printf '  rung 1: the restart the app already has — stop, then bare start\n'
    timeout 120 container system stop >/dev/null 2>&1
    timeout 180 container system start >/dev/null 2>&1
    await_daemon || note "the daemon never became ready after the bare restart"
    root_bare="$(status_root)"
    if [[ "$root_bare" == "$REAL_ROOT" ]]; then
        pass "a bare start moves a deleted root back to the default" "appRoot=$root_bare"
        moved=yes
    else
        fail "a bare start moves a deleted root back to the default" "still ${root_bare:-<none>}"
        moved=no
    fi
    if [[ -d "$root_before" ]]; then
        note "the deleted root was recreated (empty) — the app cannot detect it by absence any more"
    else
        note "the deleted root is still absent"
    fi

    # The store is a separate service from the API: `network list` answering says nothing about
    # whether images are readable, and a runtime that answers with an empty image list is not
    # recovered. Capture what the command actually says rather than counting rows of nothing.
    images="$(image_count)"
    if ((images == 0)); then
        note "images: 0 — the command said: $(timeout 60 container image ls 2>&1 | head -2 | tr '\n' ' ')"
    fi
    for i in $(seq 1 15); do
        ((images > 0)) && break
        sleep 4
        images="$(image_count)"
    done
    if ((images > 0)); then
        pass "the store is readable after the same restart" "$images images"
    else
        fail "the store is readable after the same restart" "0 images after 60s"
    fi
    note "root-moved-by-bare-start=$moved  images=$images"
else
    printf 'unknown arm %s\n' "$ARM" >&2
    exit 2
fi

printf '\n%s passed, %s failed\n' "$passed" "$failed"
((failed == 0))
