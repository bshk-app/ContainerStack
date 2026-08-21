#!/usr/bin/env python3
"""Differential Docker Engine API conformance: target vs a live reference daemon.

    ./scripts/api-diff.py --reference ~/.orbstack/run/docker.sock \
                          --target    ~/.socktainer/container.sock \
                          --scenarios scripts/api-scenarios.json

Why differential instead of a ported test suite: expectations written by hand
encode whatever the author's daemon happened to return. Podman's apiv2 suite is
the clearest example — roughly half its corpus is scaffolding for libpod, and the
assertions that survive filtering still assert Podman's values (API 1.44, its own
test images, containers.conf behaviour). Running the same request against real
dockerd removes the entire class of problem: the reference answer is observed,
never authored, and it tracks upstream automatically.

Volatile values are normalised by SHAPE, not erased. A valid 64-hex id becomes
<ID>, a valid RFC3339 timestamp becomes <TS>. An empty string stays an empty
string. That is deliberate: it hides noise while still catching `StartedAt: ""`
where Docker returns `0001-01-01T00:00:00Z`, which is exactly the class of
divergence that breaks clients.

Exit code is the number of scenarios with divergences (0 = clean), so this can
gate CI.
"""
import argparse
import fnmatch
import http.client
import json
import re
import socket
import sys
import time
import uuid

# --------------------------------------------------------------------------
# transport
# --------------------------------------------------------------------------


class UnixHTTP(http.client.HTTPConnection):
    def __init__(self, path, timeout=60):
        super().__init__("localhost", timeout=timeout)
        self._path = path

    def connect(self):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(self.timeout)
        s.connect(self._path)
        self.sock = s


def request(sock_path, method, path, body=None, api="1.51", timeout=60):
    """Returns (status, parsed_body_or_raw_text). status None on transport failure."""
    conn = UnixHTTP(sock_path, timeout=timeout)
    try:
        headers = {"Host": "localhost"}
        payload = None
        if body is not None:
            payload = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        conn.request(method, f"/v{api}{path}", body=payload, headers=headers)
        resp = conn.getresponse()
        raw = resp.read()
        try:
            return resp.status, json.loads(raw)
        except (ValueError, UnicodeDecodeError):
            return resp.status, raw.decode("utf-8", "replace")[:400]
    except (OSError, socket.timeout, http.client.HTTPException) as exc:
        return None, f"<transport: {type(exc).__name__}: {exc}>"
    finally:
        conn.close()


# --------------------------------------------------------------------------
# normalisation — collapse volatility, preserve shape
# --------------------------------------------------------------------------

RE_SHA = re.compile(r"^sha256:[0-9a-f]{64}$")
RE_HEX64 = re.compile(r"^[0-9a-f]{64}$")
RE_HEX12 = re.compile(r"^[0-9a-f]{12,}$")
RE_TS = re.compile(r"^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}")
RE_UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
RE_PATH = re.compile(r"^/(var|Users|home|private|tmp)/")
RE_IP = re.compile(r"^\d{1,3}(\.\d{1,3}){3}$")
RE_MAC = re.compile(r"^([0-9a-f]{2}:){5}[0-9a-f]{2}$", re.I)
# An Engine API version is bare `major.minor` — no `v`. Collapsing a well-formed
# one lets the number drift between daemons without noise, while anything else
# stays visible, which is the whole point: `v1.51` is a valid string but not a
# valid API version, so a plain string-shaped normalisation would hide it.
RE_APIVER = re.compile(r"^\d+\.\d+$")

# Contract-bearing fields. Their VALUE varies between daemons but their FORMAT or
# vocabulary does not, so they must never be collapsed to a generic token:
#   ApiVersion/MinAPIVersion — `1.51`, never `v1.51`
#   Os                       — `linux`; containers are Linux whatever the host is
#   Version                  — the daemon version, not the API version
# These were volatile in the first draft and it hid all three known divergences.
CONTRACT_KEYS = {"ApiVersion", "MinAPIVersion", "Os", "Version"}

# Keys whose values are inherently per-daemon. Compared for PRESENCE and TYPE
# only — a difference in the value itself is not a finding.
VOLATILE_KEYS = {
    "Id", "ID", "Name", "Names", "Image", "ImageID", "Pid", "Size", "SizeRw",
    "SizeRootFs", "Created", "CreatedAt", "StartedAt", "FinishedAt", "Digest",
    "RepoDigests", "SandboxID", "SandboxKey", "EndpointID", "ResolvConfPath",
    "HostnamePath", "HostsPath", "LogPath", "MergedDir", "UpperDir", "WorkDir",
    "LowerDir", "Source", "Mountpoint", "Gateway", "IPAddress", "MacAddress",
    "GlobalIPv6Address", "Subnet", "IPPrefixLen", "Hostname", "Driver",
    "NetworkID", "Scope", "Platform", "Architecture", "Os", "OSType",
    "KernelVersion", "OperatingSystem", "ServerVersion",
    "GitCommit", "MemTotal", "NCPU", "DockerRootDir", "Root",
    # Counts reflect whatever else lives on each daemon, not conformance.
    "Containers", "ContainersRunning", "ContainersPaused", "ContainersStopped",
    "Images", "NGoroutines", "NEventsListener", "NFd",
}

# Note on ordering: norm() tests shape patterns BEFORE consulting this set, so
# listing a key here does not hide a malformed value. A well-formed timestamp
# becomes <TS> whatever its key; a malformed one falls through and stays visible.
# That is why `StartedAt: ""` vs `0001-01-01T00:00:00Z` is still reported even
# though StartedAt is listed above. BuildTime is left out of the set purely so
# its raw value is shown rather than <STR> when it fails to parse.


def norm(value, key=None):
    """Replace a volatile value with a shape token; leave shape anomalies visible."""
    if isinstance(value, dict):
        return {k: norm(v, k) for k, v in value.items()}
    if isinstance(value, list):
        return [norm(v, key) for v in value]
    if isinstance(value, str):
        if value == "":
            return ""                    # empty stays empty: that IS the finding
        if key in ("ApiVersion", "MinAPIVersion"):
            # Well-formed versions collapse so the number may differ; a malformed
            # one is returned as-is and shows up as a diff.
            return "<APIVER>" if RE_APIVER.match(value) else value
        if key in CONTRACT_KEYS:
            return value                 # compared literally
        if RE_SHA.match(value):
            return "<SHA>"
        if RE_HEX64.match(value):
            return "<ID>"
        if RE_TS.match(value):
            return "<TS>"
        if RE_UUID.match(value):
            return "<UUID>"
        if RE_IP.match(value):
            return "<IP>"
        if RE_MAC.match(value):
            return "<MAC>"
        if RE_PATH.match(value):
            return "<PATH>"
        if key in VOLATILE_KEYS:
            return "<STR>"
        if RE_HEX12.match(value):
            return "<HEX>"
        return value
    if isinstance(value, (int, float)) and key in VOLATILE_KEYS:
        return "<NUM>"
    return value


# --------------------------------------------------------------------------
# structural diff
# --------------------------------------------------------------------------


def diff(ref, tgt, path="$"):
    """Yield (kind, jsonpath, reference, target)."""
    if type(ref) is not type(tgt) and not (
        isinstance(ref, (int, float)) and isinstance(tgt, (int, float))
    ):
        yield ("TYPE_MISMATCH", path, _brief(ref), _brief(tgt))
        return
    if isinstance(ref, dict):
        for k in ref:
            if k not in tgt:
                yield ("MISSING_KEY", f"{path}.{k}", _brief(ref[k]), "<absent>")
            else:
                yield from diff(ref[k], tgt[k], f"{path}.{k}")
        for k in tgt:
            if k not in ref:
                yield ("EXTRA_KEY", f"{path}.{k}", "<absent>", _brief(tgt[k]))
        return
    if isinstance(ref, list):
        if ref and tgt:
            yield from diff(ref[0], tgt[0], f"{path}[0]")
        elif len(ref) != len(tgt):
            yield ("LIST_LENGTH", path, f"len={len(ref)}", f"len={len(tgt)}")
        return
    if ref != tgt:
        yield ("VALUE_MISMATCH", path, _brief(ref), _brief(tgt))


def _brief(v):
    s = json.dumps(v) if not isinstance(v, str) else v
    return s[:60]


def field_path(path):
    """`$GET /version.GoVersion` -> `.GoVersion`; the label is not part of the field."""
    i = path.find(".")
    return path[i:] if i >= 0 else ""


def is_expected(path, patterns):
    """A divergence the target cannot close, so it is noise rather than debt.

    Reported as a suppressed count, never dropped silently: a filter nobody can
    see becomes a filter nobody revisits, and the line between "does not apply
    to this runtime" and "not implemented yet" moves as the target matures.
    """
    tail = field_path(path)
    return any(fnmatch.fnmatch(tail, p) for p in patterns)


# --------------------------------------------------------------------------
# scenario execution
# --------------------------------------------------------------------------


def resolve(text, vars_):
    for k, v in vars_.items():
        text = text.replace("{{%s}}" % k, str(v))
    return text


def resolve_body(obj, vars_):
    if isinstance(obj, dict):
        return {k: resolve_body(v, vars_) for k, v in obj.items()}
    if isinstance(obj, list):
        return [resolve_body(v, vars_) for v in obj]
    if isinstance(obj, str):
        return resolve(obj, vars_)
    return obj


def dig(payload, jq):
    """Walk a dotted path into a parsed body. Returns None if any hop is absent."""
    cur = payload
    for part in jq.lstrip(".").split(".") if jq not in (".", "") else []:
        cur = cur.get(part) if isinstance(cur, dict) else None
        if cur is None:
            return None
    return cur


def settle(sock, step, vars_, api, timeout):
    """Poll a step's `await` condition before moving on.

    The two daemons do not reach the same state at the same moment: a container
    exits under Apple Container about a second later than under dockerd, so a
    scenario that inspects straight after `wait` compares a settled reference
    against a target still in transition and reports a divergence that is only
    a clock difference. Waiting on the condition makes the comparison about
    behaviour rather than speed.
    """
    spec = step.get("await")
    if not spec:
        return
    path = resolve(spec["path"], vars_)
    field, want = spec["field"], str(spec["value"])
    deadline = spec.get("timeout", 30)
    waited = 0.0
    while waited < deadline:
        _, payload = request(sock, "GET", path, None, api, timeout)
        if str(dig(payload, field)).lower() == want.lower():
            return
        time.sleep(0.5)
        waited += 0.5


def run_side(sock, scenario, base_vars, api, timeout):
    """Execute every step on one daemon. Returns (comparables, transcript)."""
    vars_ = dict(base_vars)
    comparables, transcript = [], []
    for step in scenario["steps"]:
        settle(sock, step, vars_, api, timeout)
        path = resolve(step["path"], vars_)
        body = resolve_body(step.get("body"), vars_) if "body" in step else None
        status, payload = request(sock, step["method"], path, body, api, timeout)
        transcript.append((step["method"], path, status))

        for name, jq in step.get("capture", {}).items():
            cur = payload
            for part in jq.lstrip(".").split(".") if jq != "." else []:
                cur = cur.get(part) if isinstance(cur, dict) else None
            if cur is not None:
                vars_[name] = cur

        if step.get("compare"):
            comparables.append({
                "label": step.get("label", f'{step["method"]} {step["path"]}'),
                "status": status,
                "body": payload,
            })
    return comparables, transcript


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--reference", required=True, help="socket of a real dockerd")
    ap.add_argument("--target", required=True, help="socket under test")
    ap.add_argument("--scenarios", default="scripts/api-scenarios.json")
    ap.add_argument("--api", default="1.51")
    ap.add_argument("--image", default="docker.io/library/alpine:3.20")
    ap.add_argument("--timeout", type=int, default=60)
    ap.add_argument("--only", help="run only scenarios whose name contains this")
    ap.add_argument("--no-expected", action="store_true",
                    help="report expected divergences too, to review the filter itself")
    args = ap.parse_args()

    doc = json.load(open(args.scenarios, encoding="utf-8"))
    scenarios = doc["scenarios"]
    expected = [] if args.no_expected else doc.get("expected_divergences", [])
    if args.only:
        scenarios = [s for s in scenarios if args.only in s["name"]]

    # Preflight. Without this, an absent reference daemon does not look like an
    # error — every scenario simply "diverges", and a run with no oracle at all
    # reads exactly like a run where the target is catastrophically broken.
    for role, sock in (("reference", args.reference), ("target", args.target)):
        status, payload = request(sock, "GET", "/_ping", api=args.api, timeout=10)
        if status is None:
            print(f"FATAL: {role} daemon unreachable at {sock}\n       {payload}",
                  file=sys.stderr)
            if role == "reference":
                print("       Start a real dockerd (OrbStack, Docker Desktop, "
                      "Colima) and point --reference at its socket.\n"
                      "       There is no conformance signal without an oracle.",
                      file=sys.stderr)
            return 2

    ns = "apidiff-" + uuid.uuid4().hex[:8]
    base = {"ns": ns, "image": args.image}

    print(f"reference : {args.reference}")
    print(f"target    : {args.target}")
    print(f"api       : v{args.api}   namespace: {ns}")
    print("=" * 74)

    failed, suppressed = 0, 0
    for sc in scenarios:
        ref_cmp, ref_tr = run_side(args.reference, sc, base, args.api, args.timeout)
        tgt_cmp, tgt_tr = run_side(args.target, sc, base, args.api, args.timeout)

        # If the reference dropped out mid-run, every subsequent comparison is
        # noise. Stop rather than emit findings against a daemon that is gone.
        if any(c["status"] is None for c in ref_cmp):
            print(f"\nFATAL: reference daemon stopped responding during "
                  f"'{sc['name']}'.\n       Results so far are valid; everything "
                  f"after this point would be fiction.", file=sys.stderr)
            return 2

        findings = []
        for i, rc in enumerate(ref_cmp):
            if i >= len(tgt_cmp):
                findings.append(("MISSING_STEP", rc["label"], "compared", "<absent>"))
                continue
            tc = tgt_cmp[i]
            if rc["status"] != tc["status"]:
                findings.append(
                    ("STATUS_MISMATCH", rc["label"], rc["status"], tc["status"]))
            findings.extend(diff(norm(rc["body"]), norm(tc["body"]),
                                 f'${rc["label"]}'))

        # A transport failure on the target is worth surfacing loudly.
        for (m, p, s), (_, _, ts) in zip(ref_tr, tgt_tr):
            if s is not None and ts is None:
                findings.append(("NO_RESPONSE", f"{m} {p}", s, "transport failure"))

        kept = [f for f in findings if not is_expected(f[1], expected)]
        suppressed += len(findings) - len(kept)

        if not kept:
            note = f"  ({len(findings)} expected)" if findings else ""
            print(f"  PASS  {sc['name']}{note}")
            continue

        failed += 1
        print(f"  DIFF  {sc['name']}  ({len(kept)} findings)")
        seen = set()
        for kind, where, r, t in kept:
            key = (kind, where)
            if key in seen:
                continue
            seen.add(key)
            print(f"          {kind:<16} {where}")
            print(f"            dockerd: {r}")
            print(f"            target : {t}")

    print("=" * 74)
    print(f"  {len(scenarios) - failed}/{len(scenarios)} scenarios clean")
    if suppressed:
        print(f"  {suppressed} divergences suppressed as expected "
              f"({len(expected)} patterns) — rerun with --no-expected to review them")
    print("\n  MISSING_KEY and TYPE_MISMATCH are the ones clients break on.")
    print("  EXTRA_KEY is usually benign — the target returning more than Docker.")
    return failed


if __name__ == "__main__":
    sys.exit(main())
