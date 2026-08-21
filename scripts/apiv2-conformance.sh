#!/usr/bin/env bash
set -uo pipefail

### Run Podman's Docker-compat API test suite against any Docker-compatible socket.
#
#   ./scripts/apiv2-conformance.sh <docker-socket-path> [api-version]
#
# Podman's test/apiv2/*.at suite is the closest thing that exists to a Docker
# Engine API conformance kit: it was written to validate a NON-Docker daemon
# against the Docker API, and it drives the socket with curl rather than a Go
# client. That matters — the Go client silently normalises responses (fills
# defaults, tolerates absent fields), so a Go-driven suite hides exactly the
# field-shape divergences this is meant to find.
#
# This harness supplies its own implementation of the suite's helpers (`t`,
# `like`, `_show_ok`) instead of Podman's runner, because that runner bootstraps
# a Podman service and assumes Podman's rootless/root model. The `t` semantics
# below follow test/apiv2/README.md:
#
#     t METHOD ENDPOINT [key=value ...] EXPECTED_CODE [.field=value | .field~regex | literal]
#
# Requests to /libpod/ paths are auto-skipped: those are Podman-native, not
# Docker-compatible, and no Docker daemon implements them.
#
# Nothing is run against your machine automatically — this script only tests the
# socket you pass it, and it creates/destroys containers on that daemon. Point it
# at a scratch runtime, not one holding work you care about.

readonly SOCKET="${1:?usage: apiv2-conformance.sh <docker-socket-path> [api-version]}"
readonly API_VERSION="${2:-1.51}"
readonly PODMAN_REPO="${PODMAN_REPO:-https://github.com/containers/podman.git}"
readonly PODMAN_REF="${PODMAN_REF:-main}"
readonly DOCKER_BIN="${DOCKER_BIN:-docker}"
readonly IMAGE="${IMAGE:-docker.io/library/alpine:3.20}"
readonly CACHE_ROOT="${CACHE_ROOT:-${HOME}/Library/Caches/ContainerStack/podman-apiv2}"

# Files whose SETUP is Podman-native (pods, quadlets, kube play, manifest lists,
# short-name aliasing). Their subject matter has no Docker API equivalent, so
# running them produces noise rather than findings.
readonly DEFAULT_SKIP="36-quadlets.at 40-pods.at 80-kube.at 15-manifest.at \
70-short-names.at 47-subnet-pools.at 28-containersAnnotations.at 50-secrets.at"
readonly SKIP_FILES="${SKIP_FILES:-$DEFAULT_SKIP}"

log()  { printf '%s\n' "$*" >&2; }
die()  { log "ERROR: $*"; exit 1; }

command -v curl >/dev/null || die "curl not found"
command -v jq   >/dev/null || die "jq not found"
command -v git  >/dev/null || die "git not found"
command -v "$DOCKER_BIN" >/dev/null || die "$DOCKER_BIN not found"
[[ -S "$SOCKET" ]] || die "not a socket: $SOCKET"

export WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

readonly RESULTS="$WORKDIR/results.tsv"
printf 'file\tmethod\tpath\texpected\tactual\tverdict\tdetail\n' > "$RESULTS"

# --------------------------------------------------------------------------
# 1. Vendor the suite
# --------------------------------------------------------------------------
mkdir -p "$(dirname "$CACHE_ROOT")"
if [[ ! -d "$CACHE_ROOT/.git" ]]; then
    log "==> cloning podman (sparse: test/apiv2)"
    git clone --filter=blob:none --no-checkout "$PODMAN_REPO" "$CACHE_ROOT" \
        || die "clone failed"
    git -C "$CACHE_ROOT" sparse-checkout init --cone
    git -C "$CACHE_ROOT" sparse-checkout set test/apiv2
fi
git -C "$CACHE_ROOT" fetch --depth 1 origin "$PODMAN_REF" || die "fetch failed"
git -C "$CACHE_ROOT" checkout --detach FETCH_HEAD >/dev/null 2>&1 || die "checkout failed"
readonly PODMAN_SHA="$(git -C "$CACHE_ROOT" rev-parse HEAD)"
readonly AT_DIR="$CACHE_ROOT/test/apiv2"
[[ -d "$AT_DIR" ]] || die "no test/apiv2 in $PODMAN_REF"
log "==> podman @ ${PODMAN_SHA:0:12}"

# --------------------------------------------------------------------------
# 2. Suite helpers (see test/apiv2/README.md for the contract)
# --------------------------------------------------------------------------
CURRENT_FILE=""

_record() {  # file method path expected actual verdict detail
    # Fields must never contain tabs or newlines: the .at files pass multi-line
    # values (whole header blocks) into `like`, and unsanitised they split one
    # result into many bogus TSV rows and corrupt every downstream tally.
    local -a clean=()
    local f
    for f in "$@"; do
        f="${f//$'\t'/ }"
        f="${f//$'\n'/ }"
        f="${f//$'\r'/ }"
        clean+=("${f:0:200}")
    done
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${clean[@]}" >> "$RESULTS"
}

_json_body() {
    local out="{" first=1 kv k v
    for kv in "$@"; do
        k="${kv%%=*}"; v="${kv#*=}"
        (( first )) || out+=","
        first=0
        # Embed JSON/number/bool values raw; quote everything else.
        if [[ "$v" =~ ^[\{\[] ]] || [[ "$v" =~ ^(true|false|null|-?[0-9]+)$ ]]; then
            out+="\"$k\":$v"
        else
            out+="\"$k\":\"${v//\"/\\\"}\""
        fi
    done
    printf '%s}' "$out"
}

t() {
    local method="$1"; shift
    local path="$1";   shift

    local -a params=()
    while (($#)) && ! [[ "$1" =~ ^[0-9]{3}$ ]]; do params+=("$1"); shift; done
    local expected="${1:-200}"; (($#)) && shift
    local -a asserts=("$@")

    # Podman prepends its own version to bare paths; use the target's instead.
    local raw_path="$path"
    [[ "$path" == /* ]] || path="/v${API_VERSION}/${path}"

    # Self-diagnosis. The .at files reference variables that Podman's own runner
    # exports (image ids, container ids captured by earlier podman-native steps).
    # Under `set +u` an unset one expands to nothing and silently SHIFTS every
    # argument, so the status code lands in the path slot. Emulating Podman's
    # whole runner environment is a rabbit hole; detecting the corruption is not.
    # These are harness artefacts and must never be counted as daemon defects.
    if [[ "$raw_path" =~ ^[0-9]{3}$ ]]; then
        _record "$CURRENT_FILE" "$method" "$raw_path" "-" "-" "HARNESS_ARTIFACT" \
            "status code in path slot: unset variable shifted args"
        return 0
    fi
    if [[ "${path#/v${API_VERSION}}" == *"//"* ]]; then
        _record "$CURRENT_FILE" "$method" "$path" "-" "-" "HARNESS_ARTIFACT" \
            "empty path segment: unset variable"
        return 0
    fi

    if [[ "$path" == *"/libpod/"* ]]; then
        _record "$CURRENT_FILE" "$method" "$path" "$expected" "-" "SKIP_LIBPOD" "podman-native route"
        return 0
    fi

    # Data guard. The .at files call prune endpoints directly over the API, not
    # only through the CLI, so blocking this in the `podman` shim alone is not
    # enough. Never prune, and never delete a volume/network that existed before
    # this run started.
    if [[ "$path" == */prune || "$path" == */prune\?* ]]; then
        _record "$CURRENT_FILE" "$method" "$path" "$expected" "-" "GUARD_SKIP" "prune blocked by data guard"
        return 0
    fi
    if [[ "$method" == "DELETE" && ( "$path" == */volumes/* || "$path" == */networks/* ) ]]; then
        local target="${path##*/}"; target="${target%%\?*}"
        if [[ " ${PROTECTED_OBJECTS:-} " == *" $target "* ]]; then
            _record "$CURRENT_FILE" "$method" "$path" "$expected" "-" "GUARD_SKIP" "pre-existing object $target"
            return 0
        fi
    fi

    local -a curl_args=(-s -o "$WORKDIR/body.out" -D "$WORKDIR/curl.headers.out"
                        -w '%{http_code}' --max-time 60 --unix-socket "$SOCKET"
                        -X "$method")

    if (( ${#params[@]} == 1 )) && [[ "${params[0]}" == *.tar || "${params[0]}" == *.json || "${params[0]}" == *.yaml ]]; then
        local ctype="application/json"
        [[ "${params[0]}" == *.tar  ]] && ctype="application/x-tar"
        [[ "${params[0]}" == *.yaml ]] && ctype="application/yaml"
        curl_args+=(-H "Content-Type: $ctype" --data-binary "@${params[0]}")
    elif (( ${#params[@]} )); then
        curl_args+=(-H "Content-Type: application/json" --data "$(_json_body "${params[@]}")")
    fi

    local actual
    actual="$(curl "${curl_args[@]}" "http://localhost${path}" 2>/dev/null)"
    local body; body="$(head -c 300 "$WORKDIR/body.out" 2>/dev/null | tr -d '\n')"

    if [[ "$actual" != "$expected" ]]; then
        local verdict=FAIL_STATUS
        if [[ "$actual" == "501" ]] || grep -qiE 'not implemented' <<<"$body"; then
            verdict=NOT_IMPL
        elif [[ "$actual" == "000" ]]; then
            verdict=NO_RESPONSE
        fi
        _record "$CURRENT_FILE" "$method" "$path" "$expected" "$actual" "$verdict" "${body:0:160}"
        return 0
    fi

    # Status matched. Now the part that finds real divergence: field shape.
    local a field want got
    for a in ${asserts+"${asserts[@]}"}; do
        if [[ "$a" == .* ]]; then
            if [[ "$a" == *"~"* ]]; then
                field="${a%%~*}"; want="${a#*~}"
                got="$(jq -r "$field" "$WORKDIR/body.out" 2>/dev/null)"
                if ! [[ "$got" =~ $want ]]; then
                    _record "$CURRENT_FILE" "$method" "$path" "$expected" "$actual" \
                        "FAIL_FIELD" "$field ~ $want, got: ${got:0:80}"
                    return 0
                fi
            elif [[ "$a" == *"="* ]]; then
                field="${a%%=*}"; want="${a#*=}"
                got="$(jq -r "$field" "$WORKDIR/body.out" 2>/dev/null)"
                if [[ "$got" != "$want" ]]; then
                    _record "$CURRENT_FILE" "$method" "$path" "$expected" "$actual" \
                        "FAIL_FIELD" "$field = $want, got: ${got:0:80}"
                    return 0
                fi
            else
                if ! jq -e "$a" "$WORKDIR/body.out" >/dev/null 2>&1; then
                    _record "$CURRENT_FILE" "$method" "$path" "$expected" "$actual" \
                        "FAIL_FIELD" "missing $a"
                    return 0
                fi
            fi
        else
            if [[ "$body" != *"$a"* ]]; then
                _record "$CURRENT_FILE" "$method" "$path" "$expected" "$actual" \
                    "FAIL_FIELD" "body !~ $a, got: ${body:0:80}"
                return 0
            fi
        fi
    done

    _record "$CURRENT_FILE" "$method" "$path" "$expected" "$actual" "PASS" ""
}

like() {
    local actual="$1" want="$2" msg="${3:-like}"
    if [[ "$actual" =~ $want ]]; then
        _record "$CURRENT_FILE" "-" "$msg" "-" "-" "PASS" ""
    else
        _record "$CURRENT_FILE" "-" "$msg" "$want" "-" "FAIL_FIELD" "${actual:0:120}"
    fi
}

_show_ok() {
    local ok="$1" msg="${2:-}"
    if [[ "$ok" == "1" ]]; then
        _record "$CURRENT_FILE" "-" "$msg" "-" "-" "PASS" ""
    else
        _record "$CURRENT_FILE" "-" "$msg" "-" "-" "FAIL_FIELD" "explicit _show_ok 0"
    fi
}

# Podman-runner helpers the .at files may reference. No-ops here.
skip_if_rootless() { :; }
skip_if_remote()   { :; }
start_service()    { :; }
stop_service()     { :; }
podman_reset()     { :; }

# --------------------------------------------------------------------------
# 3. `podman` shim -> docker against the target socket
# --------------------------------------------------------------------------
_docker() { "$DOCKER_BIN" -H "unix://$SOCKET" "$@"; }

podman() {
    # Data guard, CLI side. Mirrors the guard inside `t`.
    if [[ " $* " == *" prune "* ]]; then
        return 0
    fi
    case "${1:-}" in
        rm)
            # `podman rm -a -f` has no docker equivalent; expand it.
            # Containers only — never -v, so volumes are never taken with them.
            if [[ " $* " == *" -a "* || " $* " == *" --all "* ]]; then
                local ids id keep
                ids=""
                for id in $(_docker ps -aq 2>/dev/null); do
                    keep=0
                    for protected in ${PROTECTED_CONTAINERS:-}; do
                        [[ "$id" == "$protected"* || "$protected" == "$id"* ]] && keep=1 && break
                    done
                    [[ "$keep" == "0" ]] && ids="$ids $id"
                done
                [[ -n "${ids// /}" ]] && _docker rm -f $ids >/dev/null 2>&1
                return 0
            fi
            ;;
        volume|network)
            # Refuse removal of anything that predates this run.
            if [[ "${2:-}" == "rm" || "${2:-}" == "remove" ]]; then
                local obj
                for obj in "${@:3}"; do
                    [[ "$obj" == -* ]] && continue
                    if [[ " ${PROTECTED_OBJECTS:-} " == *" $obj "* ]]; then
                        return 0
                    fi
                done
            fi
            ;;
        pod|generate|kube|manifest|play|quadlet|machine|farm)
            return 0 ;;   # podman-native verbs: no-op, the file is skipped anyway
    esac
    _docker "$@"
}
export -f _docker podman 2>/dev/null || true

# --------------------------------------------------------------------------
# 4. Run
# --------------------------------------------------------------------------
# Snapshot pre-existing volumes and networks. Anything in this set is protected
# from deletion for the whole run; anything created during the run is fair game.
PROTECTED_OBJECTS="$(
    { _docker volume ls -q 2>/dev/null; _docker network ls --format '{{.Name}}' 2>/dev/null; } \
        | tr '\n' ' '
)"
export PROTECTED_OBJECTS
# Containers get the same treatment, and need it more: the `rm -a` expansion below asks the daemon
# for every id it knows, which is how a sweep takes a person's stopped service with it. Anything
# already present when the run starts is not this run's to delete.
PROTECTED_CONTAINERS="$(_docker ps -aq 2>/dev/null | tr '\n' ' ')"
export PROTECTED_CONTAINERS
log "==> data guard protects: ${PROTECTED_OBJECTS:-<nothing>}"
log "==> and pre-existing containers: ${PROTECTED_CONTAINERS:-<none>}"

log "==> pulling $IMAGE on target"
_docker pull "$IMAGE" >/dev/null 2>&1 || log "    WARNING: pull failed; image-dependent tests will fail"

shopt -s nullglob
for f in "$AT_DIR"/*.at; do
    base="$(basename "$f")"
    if [[ " $SKIP_FILES " == *" $base "* ]]; then
        log "--- skip $base (podman-native)"
        _record "$base" "-" "-" "-" "-" "SKIP_FILE" "podman-native subject"
        continue
    fi
    log "--- $base"
    CURRENT_FILE="$base"
    # Subshell: a broken file must not abort the run. Results survive via $RESULTS.
    ( set +e +u; cd "$AT_DIR"; source "$f" ) >/dev/null 2>&1
done

# --------------------------------------------------------------------------
# 5. Report
# --------------------------------------------------------------------------
target_version="$(curl -s --unix-socket "$SOCKET" "http://localhost/v${API_VERSION}/version" 2>/dev/null \
    | jq -r '"\(.Version // "?") api=\(.ApiVersion // "?") min=\(.MinAPIVersion // "?")"' 2>/dev/null)"

out="apiv2-conformance-$(date +%Y%m%d-%H%M%S).tsv"
cp "$RESULTS" "$out"

echo
echo "=============================================================="
echo " Podman apiv2 suite vs Docker-compatible socket"
echo "=============================================================="
echo " target socket  : $SOCKET"
echo " target version : ${target_version:-unavailable}"
echo " suite          : containers/podman @ ${PODMAN_SHA:0:12}"
echo " api version    : v${API_VERSION}"
echo " raw results    : $out"
echo

python3 - "$RESULTS" <<'PY'
import sys, collections
rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[1], encoding="utf-8")][1:]
c = collections.Counter(r[5] for r in rows)

order = ["PASS", "FAIL_FIELD", "FAIL_STATUS", "NOT_IMPL", "NO_RESPONSE",
         "HARNESS_ARTIFACT", "GUARD_SKIP", "SKIP_LIBPOD", "SKIP_FILE"]
print(" verdicts:")
for k in order:
    if c.get(k):
        print(f"   {c[k]:>5}  {k}")
extra = set(c) - set(order)
for k in sorted(extra):
    print(f"   {c[k]:>5}  {k}")

graded = c.get("PASS",0)+c.get("FAIL_FIELD",0)+c.get("FAIL_STATUS",0)+c.get("NOT_IMPL",0)+c.get("NO_RESPONSE",0)
if graded:
    print(f"\n PASS RATE (graded assertions): {c.get('PASS',0)}/{graded} = {100*c.get('PASS',0)/graded:.1f}%")

print("\n --- FAIL_FIELD: status correct, response shape wrong (AXIS 2) ---")
ff = [r for r in rows if r[5] == "FAIL_FIELD"][:40]
if not ff:
    print("   none")
for r in ff:
    print(f"   {r[0]:<26} {r[1]:<5} {r[2]:<44} {r[6][:70]}")

print("\n --- NOT_IMPL: route registered but unimplemented ---")
ni = sorted({(r[1], r[2]) for r in rows if r[5] == "NOT_IMPL"})
if not ni:
    print("   none")
for m, p in ni[:30]:
    print(f"   {m:<5} {p}")
PY

echo
echo "TRIAGE: not every failure is a daemon defect. Three buckets —"
echo "  (a) real divergence            -> file against the bridge"
echo "  (b) podman-specific expectation-> add the file to SKIP_FILES"
echo "  (c) harness artefact           -> the \`t\` reimplementation or podman shim"
echo "Work bucket (a) first; FAIL_FIELD is where the durable bugs live."
