#!/usr/bin/env bash
set -uo pipefail

### Measure Docker Engine API endpoint coverage of a running daemon.
#
#   ./scripts/docker-api-coverage.sh <docker-socket-path> [api-version]
#
# Builds the operation inventory from the upstream Moby swagger, then probes each
# operation against the target socket and classifies the response:
#
#   IMPLEMENTED  route answered in a Docker-shaped way (2xx, or 404/409 with a
#                {"message": ...} body — i.e. the route exists, the object does not)
#   STUB         route is registered but reports not-implemented (501, or a
#                501-shaped message)
#   MISSING      no such route (404 without a Docker-shaped body, or 405)
#   SKIPPED      mutating operation not safe to probe blind
#
# Only non-mutating probes run. Path parameters are filled with a sentinel that
# cannot exist, so nothing in the target is created, changed or deleted.
#
# This measures AXIS 1 (endpoints) only. A route that answers correctly here can
# still return wrong fields; that is what apiv2-conformance.sh is for.

readonly SOCKET="${1:?usage: docker-api-coverage.sh <docker-socket-path> [api-version]}"
readonly API_VERSION="${2:-1.51}"
readonly SWAGGER_REF="${SWAGGER_REF:-v28.5.2}"
readonly SWAGGER_URL="https://raw.githubusercontent.com/moby/moby/${SWAGGER_REF}/api/swagger.yaml"
readonly SENTINEL="containerstack-probe-nonexistent-0000"

# Families you have deliberately declared out of scope. Operations tagged with
# these are counted separately and excluded from the coverage denominator.
readonly OUT_OF_SCOPE_TAGS="${OUT_OF_SCOPE_TAGS:-Swarm Node Service Task Secret Config Plugin}"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

log() { printf '%s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

command -v curl >/dev/null || die "curl not found"
command -v jq   >/dev/null || die "jq not found"
command -v python3 >/dev/null || die "python3 not found"
[[ -S "$SOCKET" ]] || die "not a socket: $SOCKET"

# --------------------------------------------------------------------------
# 1. Operation inventory from the spec
# --------------------------------------------------------------------------
log "==> fetching swagger ${SWAGGER_REF}"
curl -fsSL "$SWAGGER_URL" -o "$workdir/swagger.yaml" || die "cannot fetch $SWAGGER_URL"

# Plain line parsing, stdlib only: no PyYAML dependency.
# Emits TSV: method <TAB> path <TAB> tag
python3 - "$workdir/swagger.yaml" > "$workdir/ops.tsv" <<'PY'
import re, sys

lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
start = next(i for i, l in enumerate(lines) if re.match(r"^paths:\s*$", l))
METHODS = {"get", "post", "put", "delete", "head", "patch"}

out, path, method = [], None, None
for l in lines[start + 1:]:
    if re.match(r"^[a-zA-Z]", l):
        break
    m = re.match(r"^  (/\S*):\s*$", l)
    if m:
        path, method = m.group(1), None
        continue
    m = re.match(r"^    ([a-z]+):\s*$", l)
    if m and m.group(1) in METHODS:
        method = m.group(1)
        out.append([method, path, ""])
        continue
    m = re.search(r'tags:\s*\["([^"]+)"', l)
    if m and out and out[-1][2] == "":
        out[-1][2] = m.group(1)

for method, p, tag in out:
    print(f"{method}\t{p}\t{tag or '?'}")
PY

total_ops=$(wc -l < "$workdir/ops.tsv" | tr -d ' ')
log "==> ${total_ops} operations in spec"

# --------------------------------------------------------------------------
# 2. Probe
# --------------------------------------------------------------------------
# Fill every {param} with a sentinel that cannot exist.
_concrete_path() {
    printf '%s' "$1" | sed -E "s/\{[^}]+\}/${SENTINEL}/g"
}

# An operation is unsafe to probe blind if it creates or destroys state at a
# path with no {id} to redirect it at a nonexistent object.
_is_unsafe() {
    local method="$1" path="$2"
    [[ "$path" == *"{"* ]] && return 1          # sentinel makes it safe
    case "$method:$path" in
        post:*/create|post:/build|post:/commit|post:/session|post:/grpc) return 0 ;;
        post:*/prune|delete:*) return 0 ;;
        post:/containers/*|post:/images/*|post:/networks/*|post:/volumes/*) return 0 ;;
        post:/swarm/*|post:/auth) return 0 ;;
    esac
    return 1
}

printf 'method\tpath\ttag\tstatus\tverdict\tdetail\n' > "$workdir/results.tsv"

probe() {
    local method="$1" path="$2" tag="$3"
    local concrete status body verdict detail

    if _is_unsafe "$method" "$path"; then
        printf '%s\t%s\t%s\t-\tSKIPPED\tmutating, not probed\n' "$method" "$path" "$tag" \
            >> "$workdir/results.tsv"
        return
    fi

    concrete="$(_concrete_path "$path")"
    status="$(curl -s -o "$workdir/body.out" -w '%{http_code}' \
        --max-time 15 --unix-socket "$SOCKET" \
        -X "$(printf '%s' "$method" | tr '[:lower:]' '[:upper:]')" \
        "http://localhost/v${API_VERSION}${concrete}" 2>/dev/null)"
    body="$(head -c 400 "$workdir/body.out" 2>/dev/null | tr -d '\n')"

    # Docker-shaped error bodies carry a "message" field. That is the signal that
    # a real route handled the request rather than a router fallthrough.
    local shaped=0
    jq -e 'has("message")' "$workdir/body.out" >/dev/null 2>&1 && shaped=1

    case "$status" in
        2*)     verdict=IMPLEMENTED; detail="ok" ;;
        501)    verdict=STUB;        detail="501" ;;
        404|409|400)
                if [[ $shaped -eq 1 ]] && ! grep -qiE 'not implemented|page not found' <<<"$body"; then
                    verdict=IMPLEMENTED; detail="$status, object absent"
                elif grep -qiE 'not implemented' <<<"$body"; then
                    verdict=STUB;    detail="not-implemented body"
                else
                    verdict=MISSING; detail="$status, no docker-shaped body"
                fi ;;
        405)    verdict=MISSING;     detail="405 method not allowed" ;;
        000)    verdict=MISSING;     detail="no response / timeout" ;;
        5*)     verdict=IMPLEMENTED; detail="$status server error (route exists)" ;;
        *)      verdict=MISSING;     detail="status $status" ;;
    esac

    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$method" "$path" "$tag" "$status" "$verdict" "$detail" >> "$workdir/results.tsv"
}

log "==> probing ${SOCKET} at API v${API_VERSION}"
while IFS=$'\t' read -r method path tag; do
    probe "$method" "$path" "$tag"
done < "$workdir/ops.tsv"

# --------------------------------------------------------------------------
# 3. Report
# --------------------------------------------------------------------------
target_version="$(curl -s --unix-socket "$SOCKET" "http://localhost/v${API_VERSION}/version" 2>/dev/null \
    | jq -r '"\(.Version // "?") api=\(.ApiVersion // "?") min=\(.MinAPIVersion // "?")"' 2>/dev/null)"

out="docker-api-coverage-$(date +%Y%m%d-%H%M%S).tsv"
cp "$workdir/results.tsv" "$out"

echo
echo "=============================================================="
echo " Docker Engine API endpoint coverage"
echo "=============================================================="
echo " target socket : $SOCKET"
echo " target version: ${target_version:-unavailable}"
echo " spec          : moby ${SWAGGER_REF} (API v${API_VERSION})"
echo " raw results   : $out"
echo

python3 - "$workdir/results.tsv" "$OUT_OF_SCOPE_TAGS" <<'PY'
import sys, collections

rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[1], encoding="utf-8")][1:]
oos = set(sys.argv[2].split())

in_scope  = [r for r in rows if r[2] not in oos]
out_scope = [r for r in rows if r[2] in oos]

def tally(rs):
    c = collections.Counter(r[4] for r in rs)
    return c

ci, co = tally(in_scope), tally(out_scope)
probed = sum(v for k, v in ci.items() if k != "SKIPPED")
impl   = ci.get("IMPLEMENTED", 0)

print(f" in-scope operations   : {len(in_scope)}")
print(f" out-of-scope (declared): {len(out_scope)}  [{' '.join(sorted(oos))}]")
print()
print(" in-scope verdicts:")
for k in ("IMPLEMENTED", "STUB", "MISSING", "SKIPPED"):
    print(f"   {ci.get(k,0):>4}  {k}")
print()
if probed:
    print(f" ENDPOINT COVERAGE (probed, in-scope): {impl}/{probed} = {100*impl/probed:.1f}%")
print(f"   denominator excludes {ci.get('SKIPPED',0)} mutating operations not probed blind")
print()

gaps = [r for r in in_scope if r[4] in ("STUB", "MISSING")]
if gaps:
    print(" gap list (in-scope, not implemented):")
    for r in sorted(gaps, key=lambda r: (r[2], r[1])):
        print(f"   {r[4]:<11} {r[0].upper():<6} {r[1]:<48} {r[5]}")
PY

echo
echo "NOTE: this is AXIS 1 only. Endpoint presence is a precondition, not readiness."
echo "      Run apiv2-conformance.sh for field-level (axis 2) divergences."
