#!/usr/bin/env bash
set -uo pipefail

# Acceptance checks for the Stacks feature and the bridge fixes it depends on.
#
# Read-only against your own containers: everything runs in a throwaway project directory under
# /tmp and a container named `cstack-verify-*`, and every step cleans up after itself. It does not
# start or stop the ContainerStack runtime — point it at a socket that is already serving.
#
#   ./scripts/verify-stacks.sh [socket-path]
#
# Default socket: ~/.containerstack/docker.sock

readonly SOCKET="${1:-$HOME/.containerstack/docker.sock}"
readonly PROJECT_DIR="$(mktemp -d /tmp/cstack-verify.XXXXXX)"
readonly PROJECT_NAME="cstack-verify"
readonly DOCKER_BIN="${DOCKER_BIN:-docker}"

export DOCKER_HOST="unix://${SOCKET}"

passed=0
failed=0

pass() { printf 'PASS  %s%s\n' "$1" "${2:+: $2}"; passed=$((passed + 1)); }
fail() { printf 'FAIL  %s%s\n' "$1" "${2:+: $2}"; failed=$((failed + 1)); }

cleanup() {
    (cd "$PROJECT_DIR" && timeout 90 "$DOCKER_BIN" compose -p "$PROJECT_NAME" down --volumes >/dev/null 2>&1) || true
    timeout 60 "$DOCKER_BIN" buildx rm "${PROJECT_NAME}-builder" >/dev/null 2>&1 || true
    timeout 30 "$DOCKER_BIN" rm -f "${PROJECT_NAME}-id" "${PROJECT_NAME}-cp" "${PROJECT_NAME}-ps" \
        "${PROJECT_NAME}-exit" "${PROJECT_NAME}-created" "${PROJECT_NAME}-booted" "${PROJECT_NAME}-nostart" \
        "${PROJECT_NAME}-rmfail" "${PROJECT_NAME}-code" "${PROJECT_NAME}-ev" >/dev/null 2>&1 || true
    rm -rf "$PROJECT_DIR"
}
trap cleanup EXIT

[[ -S "$SOCKET" ]] || {
    printf 'No socket at %s — start the runtime from the app, or pass the path as $1.\n' "$SOCKET" >&2
    exit 1
}

mkdir -p "$PROJECT_DIR/static"
printf 'verify-ok\n' > "$PROJECT_DIR/static/index.html"
cat > "$PROJECT_DIR/compose.yaml" <<'YAML'
# comment that must survive every edit
services:
  webserver:
    image: lipanski/docker-static-website:latest
    restart: always
    ports:
      - "3080:3000"
    volumes:
      - ./static:/home/static
YAML

compose() { (cd "$PROJECT_DIR" && timeout 180 "$DOCKER_BIN" compose -p "$PROJECT_NAME" "$@"); }

serves() {
    local port="$1"
    for _ in $(seq 1 15); do
        if curl --max-time 3 -sS "http://127.0.0.1:${port}/" 2>/dev/null | grep -q verify-ok; then
            return 0
        fi
        sleep 1
    done
    return 1
}

printf '=== stack lifecycle ===\n'
if compose up -d >/dev/null 2>&1; then pass "compose up"; else fail "compose up"; fi
if serves 3080; then pass "published port 3080 serves the bind mount"; else fail "published port 3080 serves the bind mount"; fi

printf '\n=== editing a running stack (needs rename) ===\n'
# What the app's Ports form writes, then Up.
python3 - "$PROJECT_DIR/compose.yaml" <<'PY'
import sys
path = sys.argv[1]
lines = open(path).read().split("\n")
index = lines.index('      - "3080:3000"')
lines.insert(index + 1, '      - "3081:3000"')
open(path, "w").write("\n".join(lines))
PY
if compose up -d >/dev/null 2>&1; then pass "up recreates the changed service"; else fail "up recreates the changed service"; fi
if serves 3081; then pass "the added port serves"; else fail "the added port serves"; fi
if serves 3080; then pass "the original port still serves"; else fail "the original port still serves"; fi
if grep -q "# comment that must survive" "$PROJECT_DIR/compose.yaml"; then
    pass "the comment survived the edit"
else
    fail "the comment survived the edit"
fi

printf '\n=== two host ports on one container port (used to kill the daemon) ===\n'
if timeout 30 "$DOCKER_BIN" inspect "${PROJECT_NAME}-webserver-1" --format '{{json .Config.ExposedPorts}}' >/dev/null 2>&1; then
    pass "inspect answers with both ports published"
else
    fail "inspect answers with both ports published"
fi
if timeout 30 "$DOCKER_BIN" version --format '{{.Server.Version}}' >/dev/null 2>&1; then
    pass "the daemon is still alive afterwards"
else
    fail "the daemon is still alive afterwards"
fi

printf '\n=== internal labels are socktainer'"'"'s own ===\n'
labels="$(timeout 30 "$DOCKER_BIN" inspect "${PROJECT_NAME}-webserver-1" --format '{{json .Config.Labels}}' 2>/dev/null)"
if printf '%s' "$labels" | grep -q socktainer; then
    fail "no socktainer label in inspect output" "$(printf '%s' "$labels" | tr ',' '\n' | grep socktainer | head -2)"
else
    pass "no socktainer label in inspect output"
fi
leaked=0
for key in socktainer.docker-id socktainer.healthcheck socktainer.dns.names socktainer.restart-policy; do
    count="$(timeout 30 "$DOCKER_BIN" ps -a --filter "label=$key" --format '{{.Names}}' 2>/dev/null | grep -c . || true)"
    [[ "$count" == "0" ]] || { leaked=$((leaked + 1)); printf '      %s matched %s container(s)\n' "$key" "$count"; }
done
if [[ "$leaked" == "0" ]]; then
    pass "internal labels match nothing in filters"
else
    fail "internal labels match nothing in filters" "$leaked key(s) visible"
fi

printf '\n=== rename keeps the container id, as Docker does ===\n'
if timeout 60 "$DOCKER_BIN" run -d --name "${PROJECT_NAME}-id" alpine:3.20 sh -c 'sleep 30' >/dev/null 2>&1; then
    before="$(timeout 30 "$DOCKER_BIN" inspect "${PROJECT_NAME}-id" --format '{{.Id}}' 2>/dev/null)"
    timeout 30 "$DOCKER_BIN" stop "${PROJECT_NAME}-id" >/dev/null 2>&1
    if timeout 60 "$DOCKER_BIN" rename "${PROJECT_NAME}-id" "${PROJECT_NAME}-id2" >/dev/null 2>&1; then
        after="$(timeout 30 "$DOCKER_BIN" inspect "${PROJECT_NAME}-id2" --format '{{.Id}}' 2>/dev/null)"
        if [[ -n "$before" && "$before" == "$after" ]]; then
            pass "id preserved across rename" "${before:0:12}"
        else
            fail "id preserved across rename" "${before:0:12} -> ${after:0:12}"
        fi
        # A client that kept the pre-rename id must still reach the container.
        if [[ "$(timeout 30 "$DOCKER_BIN" inspect "${before:0:12}" --format '{{.Name}}' 2>/dev/null)" == *"${PROJECT_NAME}-id2" ]]; then
            pass "the id a client already held still resolves"
        else
            fail "the id a client already held still resolves"
        fi
        timeout 30 "$DOCKER_BIN" rm -f "${PROJECT_NAME}-id2" >/dev/null 2>&1
    else
        fail "docker rename"
    fi
else
    fail "docker run for the rename check"
fi

printf '\n=== the API answers the way clients expect ===\n'
api() { timeout 20 curl -s --unix-socket "$SOCKET" "http://localhost/v1.51/$1"; }
api_code() { timeout 20 curl -s -o /dev/null -w '%{http_code}' -X "${2:-GET}" --unix-socket "$SOCKET" "http://localhost/v1.51/$1"; }

# An idle daemon still owes `docker events` its response head, or the client hangs waiting for one.
head_file="$PROJECT_DIR/events.head"
timeout 6 curl -s -N -D "$head_file" -o /dev/null --unix-socket "$SOCKET" "http://localhost/v1.51/events" >/dev/null 2>&1
if grep -qi '^HTTP/1.1 200' "$head_file" 2>/dev/null && grep -qi '^content-type: application/json' "$head_file" 2>/dev/null; then
    pass "events responds on an idle daemon"
else
    fail "events responds on an idle daemon" "no head within 6s"
fi

# A filter the daemon cannot read must be refused, not dropped: dropping it widens the request, and
# on a prune that deletes more than the client asked for.
#
# Both probes are reads. Asking `images/prune` this question would be the sharper test — it is the
# route where a dropped filter destroys something — but the probe is only safe while the answer is
# 400: the moment strictness regressed, this script would itself prune the user's dangling images. So
# the shared decoder is checked here, and the prune route's own strictness is pinned by a unit test
# (`DockerFilterValidationTests.imagePruneRejectsBadFilters`), where a lenient parser costs nothing.
if [[ "$(api_code 'containers/json?filters=notjson')" == "400" && "$(api_code 'images/json?filters=notjson')" == "400" ]]; then
    pass "an unreadable filter is refused, not ignored"
else
    fail "an unreadable filter is refused, not ignored"
fi

# 501 tells a client the endpoint is missing; 500 tells it to retry.
if [[ "$(api_code 'containers/nope/unpause' POST)" == "501" ]]; then
    pass "an unimplemented endpoint answers 501"
else
    fail "an unimplemented endpoint answers 501"
fi

if timeout 20 curl -s -D - -o /dev/null --unix-socket "$SOCKET" "http://localhost/v1.51/networks" | grep -qi '^content-type: application/json'; then
    pass "a JSON body carries a JSON content type"
else
    fail "a JSON body carries a JSON content type"
fi

# One image is one entry per digest carrying every name, with no nulls where Docker omits the key.
image_report="$(api 'images/json' | python3 -c '
import json, sys

images = json.load(sys.stdin)
nulls = sorted({k for i in images for k, v in i.items() if v is None})
ids = [i["Id"] for i in images]
leaked = [t for i in images for t in i["RepoTags"] if t.startswith("untagged@") or t == "<none>:<none>"]
print("nulls=%s dupes=%s leaked=%s" % (",".join(nulls) or "-", len(ids) - len(set(ids)), ",".join(leaked) or "-"))
' 2>/dev/null)"
if [[ "$image_report" == "nulls=- dupes=0 leaked=-" ]]; then
    pass "image list is one entry per digest, no nulls, no internal markers"
else
    fail "image list is one entry per digest, no nulls, no internal markers" "$image_report"
fi

# `docker run` and `docker wait` reported the exit code all along; inspect said 0, so anything
# reading the result there saw success for a failed container.
timeout 60 "$DOCKER_BIN" rm -f "${PROJECT_NAME}-exit" >/dev/null 2>&1 || true
timeout 90 "$DOCKER_BIN" run --name "${PROJECT_NAME}-exit" alpine:3.20 sh -c 'exit 7' >/dev/null 2>&1
state="$(timeout 30 "$DOCKER_BIN" inspect "${PROJECT_NAME}-exit" --format '{{.State.ExitCode}}/{{.State.Dead}}/{{.State.Status}}' 2>/dev/null)"
if [[ "$state" == "7/false/exited" ]]; then
    pass "a failed container inspects as failed"
else
    fail "a failed container inspects as failed" "$state (want 7/false/exited)"
fi

# Fields dockerd always sends, even empty: a client indexing an absent key nil-dereferences instead
# of missing. `docker inspect --format` cannot see this — it renders a parsed struct, where an absent
# key and an empty one are the same zero value — so the check reads the raw response.
fields_report="$(api "containers/${PROJECT_NAME}-exit/json" | python3 -c '
import json, sys

c = json.load(sys.stdin)
wanted = {
    "Config.Labels": "Labels" in c.get("Config", {}),
    "HostConfig.Binds": "Binds" in c.get("HostConfig", {}),
    "HostConfig.PortBindings": "PortBindings" in c.get("HostConfig", {}),
    "RestartPolicy.MaximumRetryCount": "MaximumRetryCount" in c.get("HostConfig", {}).get("RestartPolicy", {}),
    "Driver": bool(c.get("Driver")),
}
print(",".join(sorted(k for k, ok in wanted.items() if not ok)) or "all-present")
' 2>/dev/null)"
if [[ "$fields_report" == "all-present" ]]; then
    pass "inspect carries the fields dockerd always sends"
else
    fail "inspect carries the fields dockerd always sends" "missing: $fields_report"
fi
timeout 30 "$DOCKER_BIN" rm -f "${PROJECT_NAME}-exit" >/dev/null 2>&1 || true

# Versions clients can compare: a "v" prefix reads as 0 in Docker's own comparison, and Os says
# where containers run, not where the daemon does.
version_report="$(api 'version' | python3 -c '
import json, re, sys

v = json.load(sys.stdin)
bare = all(re.fullmatch(r"\d+\.\d+", v[k] or "") for k in ("ApiVersion", "MinAPIVersion"))
print("bare=%s os=%s daemon_is_not_api=%s" % (bare, v.get("Os"), v.get("Version") != v.get("ApiVersion")))
' 2>/dev/null)"
if [[ "$version_report" == "bare=True os=linux daemon_is_not_api=True" ]]; then
    pass "version fields are comparable"
else
    fail "version fields are comparable" "$version_report"
fi

# A bounded events query must close; `docker events --since --until` blocks forever otherwise.
started_at="$(date +%s)"
timeout 8 curl -s -o /dev/null --unix-socket "$SOCKET" "http://localhost/v1.51/events?stream=false&since=$((started_at - 3600))"
events_rc=$?
if [[ "$events_rc" == "0" ]]; then
    pass "a bounded events query closes"
else
    fail "a bounded events query closes" "curl rc=$events_rc after $(( $(date +%s) - started_at ))s"
fi

# A window that had activity in it has to answer with that activity. The bridge kept no events at
# all, so `docker events --since --until` came back empty however busy the daemon had been (#6):
# a client reconnecting after a gap could never learn what it missed.
history_from="$(date +%s)"
timeout 90 "$DOCKER_BIN" run --rm --name "${PROJECT_NAME}-ev" alpine:3.20 true >/dev/null 2>&1
sleep 2
history_actions="$(timeout 30 curl -s --unix-socket "$SOCKET" \
    "http://localhost/v1.51/events?since=$((history_from - 3))&until=$(date +%s)" 2>/dev/null | python3 -c '
import json, sys

wanted = sys.argv[1]
events = [json.loads(line) for line in sys.stdin if line.strip()]
containers = [
    e for e in events
    if e.get("Type") == "container" and e.get("Actor", {}).get("Attributes", {}).get("name") == wanted
]
ids = {e["Actor"]["ID"] for e in containers}
print(",".join(e["Action"] for e in containers), "|", "64" if ids and all(len(i) == 64 for i in ids) else "short")
' "${PROJECT_NAME}-ev" 2>/dev/null)"
# dockerd 29.4.0 answers the same window with create, start, die, destroy and a 64-char Actor.ID;
# attach appears because the run is attached.
if [[ "$history_actions" == *"create"* && "$history_actions" == *"start"* && "$history_actions" == *"die"* \
    && "$history_actions" == *"destroy"* && "$history_actions" == *"| 64" ]]; then
    pass "a past window replays the events it contained"
else
    fail "a past window replays the events it contained" "$history_actions"
fi

# A name that cannot be a reference is a client error, not a missing image and not a daemon fault.
bad_name='%C3%9C%F1%BD%97%94%01%C2%B7x'
if [[ "$(api_code "images/${bad_name}/json")" == "400" && "$(api_code "images/create?fromImage=${bad_name}" POST)" == "400" ]]; then
    pass "a malformed image name is refused, not reported missing"
else
    fail "a malformed image name is refused, not reported missing"
fi

# One live container serves the copy and attach checks below.
timeout 60 "$DOCKER_BIN" rm -f "${PROJECT_NAME}-cp" >/dev/null 2>&1 || true
timeout 90 "$DOCKER_BIN" run -d --name "${PROJECT_NAME}-cp" alpine:3.20 sh -c 'sleep 120' >/dev/null 2>&1

# `docker cp` of a directory: a single file always worked, a directory answered 500 because the walk
# followed `/etc/mtab -> /proc/mounts` straight out of the filesystem.
copy_dir="$PROJECT_DIR/etc-copy"
timeout 120 "$DOCKER_BIN" cp "${PROJECT_NAME}-cp:/etc" "$copy_dir" >/dev/null 2>&1
copied="$(ls "$copy_dir" 2>/dev/null | wc -l | tr -d ' ')"
links="$(find "$copy_dir" -maxdepth 1 -type l 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$copied" -gt 10 && "$links" -ge 1 ]]; then
    pass "a directory copies out, symlinks and all" "$copied entries, $links symlink(s)"
else
    fail "a directory copies out, symlinks and all" "$copied entries, $links symlink(s)"
fi

# What the container writes while it runs has to come back out. The archive used to be read from
# rootfs.ext4 on the host, which a running guest does not write to, so every runtime-created file
# answered 404 while `docker exec cat` printed it. The file below cannot come from the image.
runtime_payload="written-at-$(date +%s)"
timeout 60 "$DOCKER_BIN" exec "${PROJECT_NAME}-cp" sh -c "echo $runtime_payload > /tmp/runtime.txt" >/dev/null 2>&1
timeout 60 "$DOCKER_BIN" cp "${PROJECT_NAME}-cp:/tmp/runtime.txt" "$PROJECT_DIR/runtime-out.txt" >/dev/null 2>&1
runtime_read="$(cat "$PROJECT_DIR/runtime-out.txt" 2>/dev/null || echo missing)"
# HEAD is what clients call before copying; it must agree with GET about what exists.
runtime_head="$(curl -s -o /dev/null -w '%{http_code}' --unix-socket "$SOCKET" -I \
    "http://localhost/v1.51/containers/${PROJECT_NAME}-cp/archive?path=/tmp/runtime.txt" 2>/dev/null)"
if [[ "$runtime_read" == "$runtime_payload" && "$runtime_head" == "200" ]]; then
    pass "a file the container wrote while running copies out"
else
    fail "a file the container wrote while running copies out" "read=$runtime_read, HEAD=$runtime_head"
fi

# The round trip a person actually performs, and the mode it has to survive: an executable copied in
# and back out is still executable, which is lost if the bytes travel as a plain file.
#
# The mode is read out of the tar the GET returns and off the extracted file, not with `exec stat`
# inside the container: that would measure what the PUT wrote and call the read verified.
printf '#!/bin/sh\necho copied\n' > "$PROJECT_DIR/rt-in.sh"
chmod 755 "$PROJECT_DIR/rt-in.sh"
timeout 60 "$DOCKER_BIN" cp "$PROJECT_DIR/rt-in.sh" "${PROJECT_NAME}-cp:/tmp/rt.sh" >/dev/null 2>&1
timeout 60 "$DOCKER_BIN" cp "${PROJECT_NAME}-cp:/tmp/rt.sh" "$PROJECT_DIR/rt-out.sh" >/dev/null 2>&1
timeout 30 curl -s -o "$PROJECT_DIR/rt.tar" --unix-socket "$SOCKET" \
    "http://localhost/v1.51/containers/${PROJECT_NAME}-cp/archive?path=/tmp/rt.sh" 2>/dev/null
# `tar -tv` renders the header's mode: `-rwxr-xr-x` is what an executable has to read as.
tar_mode="$(tar -tvf "$PROJECT_DIR/rt.tar" 2>/dev/null | awk 'NR==1 {print $1}')"
host_mode="$(stat -f '%Lp' "$PROJECT_DIR/rt-out.sh" 2>/dev/null)"
if diff -q "$PROJECT_DIR/rt-in.sh" "$PROJECT_DIR/rt-out.sh" >/dev/null 2>&1; then rt_same=yes; else rt_same=no; fi
if [[ "$rt_same" == "yes" && "$tar_mode" == "-rwxr-xr-x" && "$host_mode" == "755" ]]; then
    pass "an executable copied in comes back byte-for-byte, still executable"
else
    fail "an executable copied in comes back byte-for-byte, still executable" \
        "identical=$rt_same, tar header=$tar_mode, extracted=$host_mode"
fi

# Resolution before validation: a client must be able to tell a missing container from a bad request.
if [[ "$(api_code "containers/nosuch99/attach" POST)" == "404" \
    && "$(api_code "containers/${PROJECT_NAME}-cp/attach" POST)" == "400" ]]; then
    pass "attach separates a missing container from a malformed request"
else
    fail "attach separates a missing container from a malformed request"
fi

# `docker build` with no environment overrides — the BuildKit path, which is the default since
# Docker 23 and failed twice over: the builder's configuration could not be written into a container
# that had only been created, and once past that BuildKit's own bind mount inside the guest was
# refused because `--privileged` was being dropped (#9).
#
# On its own builder, created and removed here. The failure needs a builder that has never booted,
# and the one a person uses is not this run's to delete — taking `buildx_buildkit_default` out from
# under them is exactly the kind of sweep this script promises not to do.
build_dir="$PROJECT_DIR/buildkit"
mkdir -p "$build_dir"
printf 'FROM alpine:3.20\nRUN echo built-by-buildkit > /marker\n' > "$build_dir/Dockerfile"
timeout 60 "$DOCKER_BIN" buildx rm "${PROJECT_NAME}-builder" >/dev/null 2>&1 || true
timeout 90 "$DOCKER_BIN" buildx create --name "${PROJECT_NAME}-builder" --driver docker-container >/dev/null 2>&1
build_out="$(cd "$build_dir" && timeout 600 "$DOCKER_BIN" buildx build --builder "${PROJECT_NAME}-builder" \
    --load -t "${PROJECT_NAME}-built" . 2>&1)"
build_ran="$(timeout 120 "$DOCKER_BIN" run --rm "${PROJECT_NAME}-built" cat /marker 2>/dev/null)"
timeout 60 "$DOCKER_BIN" image rm -f "${PROJECT_NAME}-built" >/dev/null 2>&1 || true
timeout 90 "$DOCKER_BIN" buildx rm "${PROJECT_NAME}-builder" >/dev/null 2>&1 || true
if [[ "$build_ran" == "built-by-buildkit" ]]; then
    pass "docker build through BuildKit produces an image that runs"
else
    fail "docker build through BuildKit produces an image that runs" \
        "ran='$build_ran', build said: $(printf '%s' "$build_out" | grep -iE 'error|rootfs|mount' | head -1)"
fi

# A start that cannot happen has to say so, in a message a person can act on, and it has to end.
# It used to answer `unable to upgrade to tcp, received 500` — the reason was in the daemon's log
# only — and one run in this very suite never returned at all (#19). dockerd 29.4.0 exits 127 here.
timeout 60 "$DOCKER_BIN" rm -f "${PROJECT_NAME}-nostart" >/dev/null 2>&1 || true
nostart_began="$(date +%s)"
nostart_out="$(timeout 120 "$DOCKER_BIN" run --name "${PROJECT_NAME}-nostart" alpine:3.20 /nonexistent-binary 2>&1)"
nostart_code=$?
nostart_took=$(( $(date +%s) - nostart_began ))
timeout 30 "$DOCKER_BIN" rm -f "${PROJECT_NAME}-nostart" >/dev/null 2>&1 || true
# The bound is the other half of the fix: a message alone still passes while the client wedges.
if [[ "$nostart_code" == "127" && "$nostart_out" == *"/nonexistent-binary"* && "$nostart_took" -lt 60 ]]; then
    pass "a start that cannot happen names the reason and exits 127" "${nostart_took}s"
else
    fail "a start that cannot happen names the reason and exits 127" \
        "exit=$nostart_code, took=${nostart_took}s, said: $(printf '%s' "$nostart_out" | head -c 90)"
fi

# `docker run --rm` on a start that fails must not leave the name taken: the container never runs,
# so nothing else ever reaps it (moby removes it on this path, daemon/start.go).
timeout 60 "$DOCKER_BIN" rm -f "${PROJECT_NAME}-rmfail" >/dev/null 2>&1 || true
timeout 120 "$DOCKER_BIN" run --rm --name "${PROJECT_NAME}-rmfail" alpine:3.20 /nonexistent-binary >/dev/null 2>&1
rmfail_left="$(timeout 30 "$DOCKER_BIN" ps -a --filter "name=${PROJECT_NAME}-rmfail" --format '{{.Names}}' 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$rmfail_left" == "0" ]]; then
    pass "a --rm container whose start failed does not linger"
else
    fail "a --rm container whose start failed does not linger" "$rmfail_left left behind"
fi
timeout 30 "$DOCKER_BIN" rm -f "${PROJECT_NAME}-rmfail" >/dev/null 2>&1 || true

# An exit code is a fact about a container, not about the daemon that watched it: it used to live in
# memory only, so a restart turned a crash into a clean zero (#20). Within one lifetime the code was
# always right, so what this checks is that the record reaches disk — the reload half is exercised
# by the unit suite and was measured live (`Exited (42)` read back after the bridge was restarted).
# Restarting the bridge from inside this script is deliberately not done: it fights whatever
# supervises the process, and a restart it cannot undo takes every check after it down.
timeout 60 "$DOCKER_BIN" rm -f "${PROJECT_NAME}-code" >/dev/null 2>&1 || true
timeout 90 "$DOCKER_BIN" run -d --name "${PROJECT_NAME}-code" alpine:3.20 sh -c 'exit 42' >/dev/null 2>&1
sleep 3
code_list="$(timeout 30 "$DOCKER_BIN" ps -a --filter "name=${PROJECT_NAME}-code" --format '{{.Status}}' 2>/dev/null)"
code_inspect="$(timeout 30 "$DOCKER_BIN" inspect "${PROJECT_NAME}-code" --format '{{.State.ExitCode}}' 2>/dev/null)"
exit_store="$HOME/Library/Application Support/com.apple.container/socktainer-container-exit-codes.json"
code_on_disk="$(python3 -c '
import json, sys
try:
    records = json.load(open(sys.argv[1]))
except Exception as error:
    print(f"unreadable: {error}")
else:
    print("42" if any(str(r.get("code")) == "42" for r in records.values()) else "absent")
' "$exit_store" 2>/dev/null)"
if [[ "$code_list" == "Exited (42)"* && "$code_inspect" == "42" && "$code_on_disk" == "42" ]]; then
    pass "an exit code is reported and written down" "$code_list"
else
    fail "an exit code is reported and written down" \
        "list=$code_list, inspect=$code_inspect, on disk=$code_on_disk"
fi
timeout 30 "$DOCKER_BIN" rm -f "${PROJECT_NAME}-code" >/dev/null 2>&1 || true

# `docker ps` is where a person looks to see whether a container failed.
timeout 60 "$DOCKER_BIN" rm -f "${PROJECT_NAME}-ps" >/dev/null 2>&1 || true
timeout 90 "$DOCKER_BIN" run --name "${PROJECT_NAME}-ps" alpine:3.20 sh -c 'exit 7' >/dev/null 2>&1
# The state can trail the CLI's return by a beat under load — read it again rather than call a
# timing difference a wrong answer. The claim here is the state and the code, not the ordering.
for _ in $(seq 1 10); do
    ps_status="$(timeout 30 "$DOCKER_BIN" ps -a --filter "name=${PROJECT_NAME}-ps" --format '{{.Status}}' 2>/dev/null)"
    [[ "$ps_status" == "Exited"* ]] && break
    sleep 1
done
if [[ "$ps_status" == "Exited (7)"*"ago" ]]; then
    pass "a failed container reads as failed in docker ps" "$ps_status"
else
    fail "a failed container reads as failed in docker ps" "$ps_status"
fi
# `-cp` stays up: the inspect check below reads a live container. The trap removes both.
timeout 30 "$DOCKER_BIN" rm -f "${PROJECT_NAME}-ps" >/dev/null 2>&1 || true

# A container created and never started is `created`, not `exited`: Compose lists containers by
# state to decide what needs starting.
timeout 60 "$DOCKER_BIN" rm -f "${PROJECT_NAME}-created" >/dev/null 2>&1 || true
timeout 90 "$DOCKER_BIN" create --name "${PROJECT_NAME}-created" alpine:3.20 sleep 60 >/dev/null 2>&1
created_state="$(timeout 30 "$DOCKER_BIN" ps -a --filter "name=${PROJECT_NAME}-created" --format '{{.State}}/{{.Status}}' 2>/dev/null)"
created_filter="$(timeout 30 "$DOCKER_BIN" ps -a --filter status=created --format '{{.Names}}' 2>/dev/null | grep -c "${PROJECT_NAME}-created")"
exited_filter="$(timeout 30 "$DOCKER_BIN" ps -a --filter status=exited --format '{{.Names}}' 2>/dev/null | grep -c "${PROJECT_NAME}-created")"
if [[ "$created_state" == "created/Created" && "$created_filter" == "1" && "$exited_filter" == "0" ]]; then
    pass "a container that never ran reads as created"
else
    fail "a container that never ran reads as created" \
        "$created_state, created filter=$created_filter, exited filter=$exited_filter"
fi
timeout 30 "$DOCKER_BIN" rm -f "${PROJECT_NAME}-created" >/dev/null 2>&1 || true

# The mirror of the check above, and the reason it needs its own: `created` cannot be decided by
# the absence of a start time alone. A start that boots the guest and then fails leaves no start
# time either, as does every container that outlives a daemon restart, and calling those `created`
# tells Compose a finished service has never run.
#
# The same container is watched across the transition, so a daemon answering one constant state
# cannot pass. Started detached on purpose: an attached `run` on a container whose init fails hangs
# waiting on the attach stream, and no timeout reclaims it.
timeout 60 "$DOCKER_BIN" rm -f "${PROJECT_NAME}-booted" >/dev/null 2>&1 || true
timeout 60 "$DOCKER_BIN" create --name "${PROJECT_NAME}-booted" alpine:3.20 /nonexistent-binary >/dev/null 2>&1
before_start="$(timeout 30 "$DOCKER_BIN" ps -a --filter "name=${PROJECT_NAME}-booted" --format '{{.State}}' 2>/dev/null)"
timeout 60 "$DOCKER_BIN" start "${PROJECT_NAME}-booted" >/dev/null 2>&1 || true
booted_state=""
for _ in $(seq 1 20); do
    booted_state="$(timeout 30 "$DOCKER_BIN" ps -a --filter "name=${PROJECT_NAME}-booted" --format '{{.State}}' 2>/dev/null)"
    [[ "$booted_state" == "created" || "$booted_state" == "running" ]] || break
    sleep 1
done
booted_exited="$(timeout 30 "$DOCKER_BIN" ps -a --filter status=exited --format '{{.Names}}' 2>/dev/null | grep -c "${PROJECT_NAME}-booted")"
booted_created="$(timeout 30 "$DOCKER_BIN" ps -a --filter status=created --format '{{.Names}}' 2>/dev/null | grep -c "${PROJECT_NAME}-booted")"
if [[ "$before_start" == "created" && "$booted_state" == "exited" && "$booted_exited" == "1" && "$booted_created" == "0" ]]; then
    pass "a container that booted and failed reads as exited"
else
    fail "a container that booted and failed reads as exited" \
        "before start=$before_start, after=$booted_state, exited filter=$booted_exited, created filter=$booted_created"
fi
timeout 30 "$DOCKER_BIN" rm -f "${PROJECT_NAME}-booted" >/dev/null 2>&1 || true

# Docker's ErrorResponse has one property, and its text names the object: tooling shows it to a
# person and logs get grepped later.
errors_report="$(python3 - "$SOCKET" <<'PY' 2>/dev/null
import json, socket, sys

def request(method, path):
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    connection.settimeout(10)
    connection.connect(sys.argv[1])
    connection.sendall(f"{method} {path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n".encode())
    raw = b""
    while chunk := connection.recv(65536):
        raw += chunk
    connection.close()
    body = raw.split(b"\r\n\r\n", 1)[1]
    if b"\r\n" in body and body[:1] != b"{":  # chunked
        body = b"".join(part for part in body.split(b"\r\n") if part[:1] == b"{")
    return json.loads(body)

checks = {
    "unrouted": (request("PUT", "/v1.51/containers/json"), "page not found"),
    "container": (request("GET", "/v1.51/containers/c2ada9df5af8/json"), "No such container: c2ada9df5af8"),
    "network": (request("GET", "/v1.51/networks/nosuchnet"), "network nosuchnet not found"),
}
problems = []
for name, (body, expected) in checks.items():
    if sorted(body.keys()) != ["message"]:
        problems.append(f"{name} keys={sorted(body.keys())}")
    elif body["message"] != expected:
        problems.append(f"{name} message={body['message']!r}")
print(",".join(problems) or "ok")
PY
)"
if [[ "$errors_report" == "ok" ]]; then
    pass "an error body is just a message, and it names the object"
else
    fail "an error body is just a message, and it names the object" "$errors_report"
fi

# The fields dockerd always serialises, whether or not the runtime can honour them: a client typed
# against Docker's schema fails on an absent key, not on a zero value.
inspect_report="$(api "containers/${PROJECT_NAME}-cp/json" | python3 -c '
import json, sys

c = json.load(sys.stdin)
host = ["Memory", "CpuShares", "NanoCpus", "Ulimits", "CapAdd", "Devices", "LogConfig", "Isolation", "CgroupnsMode"]
missing = [f"HostConfig.{k}" for k in host if k not in c.get("HostConfig", {})]
missing += [f"Config.{k}" for k in ("Domainname", "Volumes") if k not in c.get("Config", {})]
missing += [k for k in ("ExecIDs", "LogPath") if k not in c]
missing += [f"NetworkSettings.{k}" for k in ("SandboxKey", "IPAddress", "MacAddress") if k not in c.get("NetworkSettings", {})]
print(",".join(missing) or "all-present")
' 2>/dev/null)"
if [[ "$inspect_report" == "all-present" ]]; then
    pass "inspect serialises the fields dockerd always sends"
else
    fail "inspect serialises the fields dockerd always sends" "missing: $inspect_report"
fi
timeout 30 "$DOCKER_BIN" rm -f "${PROJECT_NAME}-cp" >/dev/null 2>&1 || true

# The Stacks screen is built from these labels, so a project started outside the app appears in it.
# The project this script brought up was started by plain `docker compose`, exactly like a terminal.
labels_report="$(api "containers/json?all=true&filters=%7B%22label%22%3A%5B%22com.docker.compose.project%22%5D%7D" | python3 -c '
import json, sys

containers = json.load(sys.stdin)
wanted = [
    "com.docker.compose.project",
    "com.docker.compose.service",
    "com.docker.compose.project.working_dir",
    "com.docker.compose.project.config_files",
]
mine = [c for c in containers if (c.get("Labels") or {}).get("com.docker.compose.project") == "cstack-verify"]
if not mine:
    print("the label filter returned none of this project'"'"'s containers")
else:
    missing = sorted({label for c in mine for label in wanted if label not in (c.get("Labels") or {})})
    print(",".join(missing) or "all-present")
' 2>/dev/null)"
if [[ "$labels_report" == "all-present" ]]; then
    pass "a project started outside the app is discoverable from its labels"
else
    fail "a project started outside the app is discoverable from its labels" "$labels_report"
fi

printf '\n=== teardown ===\n'
if compose down --volumes >/dev/null 2>&1; then pass "compose down"; else fail "compose down"; fi

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[[ "$failed" == "0" ]]
