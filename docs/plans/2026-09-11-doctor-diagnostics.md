# Plan: Doctor diagnostics section

Date: 2026-09-11
Spec: docs/specs/current.md (v1.1)
Gaps: docs/specs/spec-gaps.md
Executor: worker sub-agent (via `subagent-driven` or `batch-execute`)

## Goal

`cstack doctor`'s orchestration lives in `ContainerStackCore` as a pure
`DiagnosticReport`. Two surfaces render it: the CLI, whose text is unchanged
except for a new foreign-bridge state, and a new **Doctor** section in the app
sidebar that runs on open (throttled to 30s), shows one row per check, and
offers a button only where a proven repair already exists.

## Definition of done

The repo's real gates — CI runs exactly these (`.github/workflows/ci.yml`):

- `swift build --product ContainerStack && swift build --product cstack && swift build --product ContainerStackRuntime` — 0 errors. Product names come from `Package.swift:10-27`; there is no `container-stack-runtime` product, and asking for one fails with `Could not find target named 'container-stack-runtime-product'`.
- `swift-format` is reachable on this machine only as `xcrun swift-format`.
- `swift test` — 0 failures
- `swift-format lint --strict -r -p Sources Tests` — 0 diagnostics
- `swiftlint --strict` with the pinned version in `.swiftlint-version` (0.65.1) — 0 violations, **including `file_length` (`RuntimeViewModel.swift` must stay untouched, NFR-003)**
- `COMMENT_BLOCK_DIFF_BASE=origin/main scripts/hooks/check-new-comment-blocks.sh` — comment gate.
  **The variable is not optional.** It defaults to `HEAD` (`:30`), so on a clean
  tree the diff is empty and the gate passes vacuously while reporting success.
  CI avoids this by setting `origin/${{ github.base_ref }}` (`ci.yml:80`).
- `spec-auditor` — `DRIFT: none`

## Dependencies

New deps: **none**. Everything used already exists in-tree: `ProcessRunner`,
`RuntimeState`, `BridgeOwnership`, `ProcessTable`, `NetworkRouteHealth`,
`RuntimeStatusParser`, `MemoryCommitment`, `HostMemory`, `DiagnosticCadence`.

## Blocked before starting

Nothing. OQ-2 blocked T-018 in the first draft of this plan and has since been
closed (spec-gaps decision 8): Doctor gets its own read-only context check. The
five remaining open questions do not gate any task here. (T-022 had to render a
repair in progress and closed OQ-6 as decision 9; four remain.)

## Ordering note

Tasks T-001…T-004 build test doubles. They come first because without them
roughly half the acceptance criteria in the spec cannot be written at all
(gap G-05).

---

### [T-001] StubDockerTransport can fail  `[DONE:2026-09-18]`

**Files:**
- Modify: `Tests/ContainerStackCoreTests/TestSupport.swift:5-27`

**Step 1 — RED**

```swift
@Test func stubTransportThrowsTheQueuedError() async throws {
    let stub = StubDockerTransport(results: [.failure(UnixSocketError.timedOut)])
    await #expect(throws: UnixSocketError.self) { try stub.send(request: Data()) }
}

@Test func stubTransportThrowsWhenExhausted() async throws {
    let stub = StubDockerTransport(results: [])
    await #expect(throws: StubDockerTransport.Exhausted.self) { try stub.send(request: Data()) }
}
```

**Step 2 — Verify RED**

```bash
swift test --filter stubTransportThrows
```

Expected: compile failure — `incorrect argument label 'results'`.

**Step 3 — GREEN**

Add alongside the existing initialiser (do **not** replace it — every existing
test calls `init(responses:)`):

```swift
struct Exhausted: Error {}

init(results: [Result<Data, Error>]) { self.results = results }
init(responses: [Data]) { self.results = responses.map { .success($0) } }
```

and in `send(request:timeout:)` replace `return responses.removeFirst()` with:

```swift
guard !results.isEmpty else { throw Exhausted() }
return try results.removeFirst().get()
```

**Step 4 — Verify GREEN**

```bash
swift test
```

Expected: `PASS`, and every pre-existing test still passes — the old label is
preserved.

**Step 5 — Commit**

```bash
git add Tests/ContainerStackCoreTests/TestSupport.swift
git commit -m "test: let StubDockerTransport fail and report exhaustion"
```

**Depends on:** none

---

### [T-002] Transport responses keyed by path  `[DONE:2026-09-18]`

**Files:**
- Modify: `Tests/ContainerStackCoreTests/TestSupport.swift`

**Step 1 — RED**

```swift
@Test func keyedStubAnswersByPathNotByOrder() async throws {
    let stub = StubDockerTransport(byPath: [
        "/networks": .success(jsonResponse("[]")),
        "/containers/json?all=0": .success(jsonResponse("[]")),
    ])
    _ = try stub.send(request: Data("GET /networks HTTP/1.1\r\n\r\n".utf8))
    #expect(stub.paths == ["/networks"])
}
```

**Step 2 — Verify RED**

```bash
swift test --filter keyedStubAnswersByPath
```

Expected: compile failure — no `init(byPath:)`.

**Step 3 — GREEN**

```swift
private var byPath: [String: Result<Data, Error>] = [:]

init(byPath: [String: Result<Data, Error>]) { self.byPath = byPath }
```

In `send`, after recording `paths`: if `byPath` is non-empty, look the path up
and `throw Exhausted()` when absent; otherwise fall through to the queue.

**Step 4 — Verify GREEN**

```bash
swift test --filter keyedStubAnswersByPath
```

Expected: `PASS`.

**Step 5 — Commit**

```bash
git add Tests/ContainerStackCoreTests/TestSupport.swift
git commit -m "test: key stub transport responses by request path"
```

**Depends on:** T-001

---

### [T-003] Report value types  `[DONE:2026-09-18]`

**Files:**
- Create: `Sources/ContainerStackCore/DiagnosticReport.swift`
- Test: `Tests/ContainerStackCoreTests/DiagnosticReportTests.swift`

**Step 1 — RED**

```swift
@Test func reportRoundTripsThroughJSON() throws {
    let report = DiagnosticReport(
        checks: [
            DiagnosticCheck(
                id: .appRoot, verdict: .indeterminate, summary: "s",
                detail: nil, remedy: .manual("m"), duration: .seconds(1)
            )
        ],
        ranAt: Date(timeIntervalSince1970: 0)
    )
    let data = try JSONEncoder().encode(report)
    #expect(try JSONDecoder().decode(DiagnosticReport.self, from: data) == report)
}
```

**Step 2 — Verify RED**

```bash
swift test --filter reportRoundTrips
```

Expected: `cannot find 'DiagnosticReport' in scope`.

**Step 3 — GREEN**

Write the types exactly as specified in spec §3.3 (`CheckID`, `Verdict` with
`.indeterminate`, `Remedy`, `DiagnosticCheck` with `duration`,
`DiagnosticReport`, `ProbeResult`). Add `Equatable` to make the test above
expressible.

**Step 4 — Verify GREEN**

```bash
swift test --filter reportRoundTrips
```

Expected: `PASS`.

**Step 5 — Commit**

```bash
git add Sources/ContainerStackCore/DiagnosticReport.swift Tests/ContainerStackCoreTests/DiagnosticReportTests.swift
git commit -m "feat(core): add the DiagnosticReport value types"
```

**Depends on:** none

---

### [T-004] SystemProbe protocol and fakes  `[DONE:2026-09-18]`

**Files:**
- Create: `Sources/ContainerStackCore/SystemProbe.swift`
- Create: `Tests/ContainerStackCoreTests/SystemProbeFakes.swift`

**Step 1 — RED**

```swift
@Test func recordingProbeCountsCalls() async {
    let probe = RecordingSystemProbe(runtimeStatus: .output("x"))
    _ = await probe.runtimeStatus()
    #expect(probe.callCount == 1)
}
```

**Step 2 — Verify RED**

```bash
swift test --filter recordingProbeCountsCalls
```

Expected: `cannot find 'RecordingSystemProbe' in scope`.

**Step 3 — GREEN**

Protocol with the four methods from spec §3.2 (`runtimeStatus`,
`routingTable`, `socketHolder(socketPath:)`, `processTable`), then a
`RecordingSystemProbe` actor holding canned `ProbeResult`s, a `callCount` and a
per-call timeout log, plus a `GatedSystemProbe` exposing a
`CheckedContinuation` (needed by T-020, not T-016 — T-016 is the text renderer).

**Step 4 — Verify GREEN**

```bash
swift test --filter recordingProbeCountsCalls
```

Expected: `PASS`.

**Step 5 — Commit**

```bash
git add Sources/ContainerStackCore/SystemProbe.swift Tests/ContainerStackCoreTests/SystemProbeFakes.swift
git commit -m "feat(core): add SystemProbe and its test fakes"
```

**Depends on:** T-003

---

### [T-005] Production probe does not launder failure  `[DONE:2026-09-18]`

**Files:**
- Modify: `Sources/ContainerStackCore/SystemProbe.swift`
- Test: `Tests/ContainerStackCoreTests/SystemProbeTests.swift`

**Step 1 — RED**

```swift
@Test func aMissingBinaryIsFailedNotEmptyOutput() async {
    let probe = ShellSystemProbe(containerPath: "/nonexistent/container", socketPath: "/tmp/x.sock")
    guard case .failed = await probe.runtimeStatus() else {
        Issue.record("a missing binary must not report empty output"); return
    }
}
```

**Step 2 — Verify RED**

```bash
swift test --filter aMissingBinaryIsFailed
```

Expected: `cannot find 'ShellSystemProbe' in scope`.

**Step 3 — GREEN**

Implement over `ProcessRunner.run(..., output: .capture(includingStandardError: false), timeout: ProcessRunner.diagnosticTimeout)`, mapping a
thrown `ProcessRunnerError` to `.failed(reason:)`. **Do not** use
`CommandShell.output` or `RuntimeShell` — both wrap the call in `try?` and
return `""` (gap G-01's sibling defect, spec §5).

**Step 4 — Verify GREEN**

```bash
swift test --filter aMissingBinaryIsFailed
```

Expected: `PASS`.

**Step 5 — Commit**

```bash
git add Sources/ContainerStackCore/SystemProbe.swift Tests/ContainerStackCoreTests/SystemProbeTests.swift
git commit -m "feat(core): run diagnostic probes without swallowing failure"
```

**Depends on:** T-004

---

### [T-006] Runner returns one check per requested id  `[DONE:2026-09-18]`

**Files:**
- Create: `Sources/ContainerStackCore/DiagnosticRunner.swift`
- Test: `Tests/ContainerStackCoreTests/DiagnosticRunnerTests.swift`

**Step 1 — RED**

```swift
@Test func everyRequestedCheckAppearsExactlyOnce() async {
    let report = await makeRunner().run(checks: [.appRoot, .routes])
    #expect(Set(report.checks.map(\.id)) == [.appRoot, .routes])
    #expect(report.checks.count == 2)
}
```

**Step 2 — Verify RED**

```bash
swift test --filter everyRequestedCheckAppears
```

Expected: `cannot find 'DiagnosticRunner' in scope`.

**Step 3 — GREEN**

Runner holding `DockerAPIClient`, `SystemProbe` and a clock; `run(checks:)`
returns `.skipped` placeholders for every requested id. Nothing else yet.

**Step 4 — Verify GREEN**

```bash
swift test --filter everyRequestedCheckAppears
```

Expected: `PASS`.

**Step 5 — Commit**

```bash
git add Sources/ContainerStackCore/DiagnosticRunner.swift Tests/ContainerStackCoreTests/DiagnosticRunnerTests.swift
git commit -m "feat(core): add DiagnosticRunner returning one check per request"
```

**Depends on:** T-003, T-004

---

### [T-007] Named check sets (F-002)  `[DONE:2026-09-18]`

**Files:**
- Modify: `Sources/ContainerStackCore/DiagnosticReport.swift` — `CheckID` is
  declared there, not in `DiagnosticRunner.swift`; the extension belongs beside
  the type it extends.

**Step 1 — RED**

```swift
@Test func theTwoCheckSetsAreExactlyThese() {
    #expect(CheckID.cliSet == [.appRoot, .socket, .versions, .routes, .foreignBridge, .memoryCommitment])
    #expect(CheckID.uiSet == [.appRoot, .socket, .versions, .routes, .foreignBridge, .dockerContext])
}
```

**Step 2 — Verify RED**

```bash
swift test --filter theTwoCheckSetsAre
```

Expected: `type 'CheckID' has no member 'cliSet'`.

**Step 3 — GREEN**

```swift
public extension CheckID {
    static let cliSet: Set<CheckID> = [.appRoot, .socket, .versions, .routes, .foreignBridge, .memoryCommitment]
    static let uiSet: Set<CheckID> = [.appRoot, .socket, .versions, .routes, .foreignBridge, .dockerContext]
}
```

**Step 4 — Verify GREEN**

```bash
swift test --filter theTwoCheckSetsAre
```

Expected: `PASS`.

**Step 5 — Commit**

```bash
git add Sources/ContainerStackCore/DiagnosticRunner.swift Tests/ContainerStackCoreTests/DiagnosticRunnerTests.swift
git commit -m "feat(core): name the CLI and UI check sets"
```

**Depends on:** T-006

---

### [T-008] Precedence is projected, not re-derived (F-004)  `[DONE:2026-09-18]`

**Files:**
- Modify: `Sources/ContainerStackCore/DiagnosticRunner.swift`

**Step 1 — RED**

```swift
@Test func aForeignBridgeOutranksAMissingAppRoot() async {
    let report = await makeRunner(
        runtimeStatus: .output(statusWithMissingRoot),
        socketHolder: .output(foreignLsofOutput)
    ).run(checks: CheckID.uiSet)
    #expect(report.check(.foreignBridge)?.verdict == .failure)
    #expect(report.check(.appRoot)?.verdict == .skipped)
}
```

**Step 2 — Verify RED**

```bash
swift test --filter aForeignBridgeOutranks
```

Expected: `FAIL` — both are still `.skipped` placeholders.

**Step 3 — GREEN**

Gather the signals, call `RuntimeState.resolve(...)` **once**, and switch on the
resulting `RuntimeState` to assign verdicts. No `if foreignBridge != nil` branch
in the runner — that rule lives only in `resolve`.

**Step 4 — Verify GREEN**

```bash
swift test --filter aForeignBridgeOutranks
```

Expected: `PASS`.

**Step 5 — Commit**

```bash
git add Sources/ContainerStackCore/DiagnosticRunner.swift Tests/ContainerStackCoreTests/DiagnosticRunnerTests.swift
git commit -m "feat(core): project RuntimeState onto check verdicts"
```

**Depends on:** T-007

---

### [T-009] App-root check  `[DONE:2026-09-18]`

**Files:** modify runner + tests.
Uses `RuntimeStatusParser.missingAppRoot` (`RuntimeProcessConfiguration.swift:232`).
Summary/remedy text must match today's CLI: `"Runtime storage: MISSING — storing into <root>, which no longer exists."` and `.restartRuntime`.

**Depends on:** T-008

---

### [T-010] Probe failure never reads as healthy (F-009)  `[DONE:2026-09-18]`

**Step 1 — RED:** `runtimeStatus` returns `.failed`; assert the app-root check is
`.failure`, never `.ok` and never `.skipped`. This is the defect that motivated
the whole probe redesign — `missingAppRoot("")` returns `nil`, which reads as a
healthy root.

**Depends on:** T-009

---

### [T-011] Socket and versions via health, without retrying a hang  `[DONE:2026-09-18]`

**Files:** modify runner.
Use `requestRetryingImmediateFailures` (`DockerAPIClient.swift:450`), not
`requestWithRetry`: `.timedOut` is retryable in the general policy
(`DockerRetryPolicy.swift:31-32`), and three 5s attempts × three calls inside
`health()` is where ~46s of the old 117s worst case came from.

**Step 1 — RED:** transport returns `.failure(UnixSocketError.timedOut)`; assert
the socket check is `.indeterminate` and that the stub recorded **one** attempt
per path, not three.

**Depends on:** T-008, T-001

---

### [T-012] Routes check  `[DONE:2026-09-18]`

Reuses `NetworkRouteHealth.publishingNetworks` / `.uncheckablePublishingNetworks` / `.canJudgeRoutes`.
Three distinct outcomes must stay distinct (issue #45): no publisher, cannot
judge, unroutable.

**Depends on:** T-008

---

### [T-012a] Aggregate verdict on the report (F-013)  `[DONE:2026-09-18]`

**Why now:** T-012 wired `unroutableNetworks` into `RuntimeState.resolve`, and
the T-012 reviewer proved that wiring is unpinnable — mutating it to `[]` left
all 450 tests green, because `.running` and `.degraded` project identically and
`DiagnosticReport` exposes only `checks`/`ranAt`.

**Files:** modify `Sources/ContainerStackCore/DiagnosticReport.swift`; test in
`Tests/ContainerStackCoreTests/DiagnosticReportTests.swift` and
`Tests/ContainerStackCoreTests/DiagnosticRunnerRoutesTests.swift`.

Derive it, do not store it: worst verdict present, ordering
`.failure` > `.warning` > `.indeterminate` > `.ok` > `.skipped`. Empty and
all-skipped reports are `.skipped`.

**Step 1 — RED (the one that matters):** a degraded run's aggregate differs
from a healthy run's. Then mutate the runner to pass `unroutableNetworks: []`
and confirm **that** test fails — if it still passes, the aggregate has not
closed the hole it exists to close.

Table-driven cases pin the ordering and both edges.

**Depends on:** T-012

---

### [T-013] Foreign-bridge check  `[DONE:2026-09-18]`

Uses `BridgeOwnership.holder(lsofOutput:)` + `ProcessTable.pids(forExecutable:in:)`
— both already in Core (`BridgeOwnership.swift:11`, `RuntimeControl.swift:5`).
A failed `lsof` or `ps` gives `.indeterminate`, never "ours" (spec §5).

Done: the check's own wording (new, no CLI line behind it), `.ok` when our bridge
holds the socket, `.indeterminate` for either dead probe and for a holder `lsof`
cannot see, and a `.manual` remedy on the failure — F-005 rules out `.restartRuntime`.
The orphaned `ourBridgeRunning` is gone: `BridgeMeasurement` replaced the tuple.

**Depends on:** T-008

---

### [T-014] Memory-commitment check (CLI set only)  `[DONE:2026-09-19]`

Mapping decided in `spec-gaps.md`: `.within` → `.ok`, `.approaching` →
`.warning`, `.exceeding` → `.warning` with `.manual` remedy, host memory
unknown → `.indeterminate`, any failed `inspectContainer` → `.indeterminate`.

**Step 1 — RED:** assert the UI set issues **zero** `inspectContainer` requests
while the CLI set issues one per running container.

**Depends on:** T-008

---

### [T-015] Total 20s budget and concurrent probes (NFR-002)  `[DONE:2026-09-19]`

**Step 1 — RED:** a probe fake that never returns; assert the report is
published within 20s and the unfinished checks are `.indeterminate`.
**GREEN:** `withThrowingTaskGroup` running the four probes concurrently, plus an
overall deadline.

**Depends on:** T-013

> **Landed as `d2fc5ac`, with one deviation.** Not `withThrowingTaskGroup` plus a
> deadline: `ProcessRunner.run` blocks on a semaphore no cancellation reaches, so
> the budget *abandons* the gathering instead of cancelling it — a gate resumed by
> whichever of the gathering and the budget arrives first, then one snapshot of an
> actor-held struct. The probes still run concurrently, which is what NFR-002 asks.

---

### [T-014a] `.exceeding` survives a partial inspect failure  `[DONE:2026-09-18]`

**Files:** modify `Sources/ContainerStackCore/DiagnosticRunner.swift` (the
`commitmentCheck`/`memoryCheck` path) and
`Tests/ContainerStackCoreTests/DiagnosticRunnerMemoryTests.swift`.

Today any failed `inspectContainer` makes the whole memory check
`.indeterminate`. That is right when a missing sample could still change the
answer — `.within` and `.approaching` — but wrong for `.exceeding`, which is
monotone: an uninspected limit only adds to the committed total, so nothing
further can un-exceed it. Amber there hides a real risk and drops the `.manual`
remedy while the CLI text still prints the HIGH lines.

**Step 1 — RED:** a fixture where the inspected containers already exceed host
memory *and* one inspect failed asserts `.warning`, the `.manual` remedy, and a
`detail` that says the measurement was incomplete. A sibling case pins that
`.within` with a failed inspect stays `.indeterminate`.

**Watch:** `aPartiallyFailedInspectIsIndeterminateAndNamesTheGap` already pins
today's behaviour. Narrow it to the non-monotone verdicts rather than deleting
it, and re-check it still fails if the whole exception is removed.

**Depends on:** T-014

---

### [T-015b] Per-check `duration` (NFR-005)  `[DONE:2026-09-20]`


`DiagnosticRunner+Verdicts.swift` passes `duration: .zero` at all six projection
sites, so NFR-005's "an incident can name which probe consumed the budget" is
unmet — and T-015 is what made it worth having, because a run can now end with
checks that never answered and nothing recording which one ate the 20s. The
`Codable` half of NFR-005 is done; this is the other half.

Also unmet from the same NFR: a run with any `.indeterminate` check should log
one line naming them.

**Step 1 — RED:** with a probe parked behind a gate and a budget that expires,
assert the timed-out check's `duration` is at least the budget rather than `.zero`.

**Note:** no `TODO` marker in the source — SwiftLint's `todo` rule plus
`--strict` makes one a build failure, so this entry is the marker.

**Depends on:** T-015

---

### [T-016] DoctorTextRenderer + goldens (F-003, F-012)  `[DONE:2026-09-20]`

**Files:**
- Create: `Sources/ContainerStackCore/DoctorTextRenderer.swift`
- Test: `Tests/ContainerStackCoreTests/DoctorTextRendererTests.swift`

Four goldens: healthy, missing-app-root, unroutable-network, foreign-bridge.

> **Honest caveat for the executor:** the spec says the first three goldens are
> "pinned from today's binary". There is no CLI test target and `doctor` prints,
> so they cannot be captured mechanically. Derive them line by line from
> `Sources/CStackCLI/CStackCommands.swift:8-145` and diff the derivation against
> that source in review. Do not invent wording.

**Depends on:** T-014

---

### [T-016a] Stop the CLI dropping and reordering lines  `[DONE:2026-09-20]`

The T-016 goldens exposed four lines today's `cstack doctor` prints that the
renderer never emits, plus an order change. Dropping output is a regression,
not the sanctioned addition F-003 allows.

**Files:** `Sources/ContainerStackCore/DiagnosticRunner.swift`,
`DiagnosticRunner+Projection.swift`, `DoctorTextRenderer.swift`, and their tests.

Four fixes, each with its own failing golden first:

1. **A healthy app root is not capturable.** `AppRootMeasurement` has only
   `.missing` / `.intact` / `.unmeasurable`, so the CLI's
   `Runtime storage: <root>` (`CStackCommands.swift:38`) can never be rendered.
   `.intact` has to carry the root.
2. **`Docker socket: healthy` above a missing root** (`:24`) is dropped because
   the socket check is `.skipped` there. `resolve` only yields `.detached` when
   the socket responded, so the fact is known -- the projection discards it.
3. **`Container routes: reachable` is swallowed** when another publisher has no
   subnet: `routesMeasurement` returns `noSubnetReported` *instead of*
   `.reachable` (`DiagnosticRunner.swift:481`), while the CLI prints both `:67`
   and `:81`. `RoutesMeasurement`'s own comment says this must not happen.
4. **`Container memory limits: no running containers`** is in F-003's table but
   projects to `.skipped`, which renders nothing. The routes check's sibling
   state projects to `.ok`. Move the projection, not the table.

**Then the order.** The CLI prints storage *after* socket and versions; report
precedence puts `appRoot` first, and `foreignBridge` before everything. Fixing
the four drops does not fix this. Give the renderer its own CLI print order,
independent of `CheckID`'s precedence order -- precedence is about which check
outranks which, not about what a human reads first. Pin both orders separately
so a change to one cannot silently move the other.

**Watch:** T-008's rule stands -- `RuntimeState.resolve` remains the only
precedence authority. None of these fixes may re-rank anything; they restore
facts the projection already had and threw away.

**Depends on:** T-016

---

### [T-016b] Our own wording for probe failures  `[DONE:2026-09-20]`

Amber rows render a second line from `error.localizedDescription`.
`UnixSocketError` (`DockerAPIClient.swift:686`) conforms only to
`Error, Equatable, Sendable`, so that text is Foundation's `NSError` bridge --
wording nobody chose, which can change with macOS. The T-016 golden cannot
catch drift because it computes the expectation from the same expression.

**Files:** `Sources/ContainerStackCore/DockerAPIClient.swift` (or wherever
`UnixSocketError` is best extended), plus the renderer goldens.

Give the error type `LocalizedError` with our own text, then rewrite the
affected goldens as **string literals** rather than derived expressions -- that
is what turns them into a drift detector instead of a tautology.

**Depends on:** T-016a

---

### [T-016c] The parse error reaches stdout too  `[DONE:2026-09-20]`

Same defect as T-016b, found by its reviewer and more exposed than
`UnixSocketError` was. `DockerHTTPParseError` (`DockerHTTPResponse.swift:15`)
declares `Error, Equatable, Sendable` only, and is thrown at
`DockerAPIClient.swift:490` inside the single shared
`request(method:path:body:timeout:)` -- so it rides `ping()`, `/version`,
`/info`, `/containers/json` and `/networks` alike. `DiagnosticRunner`'s bare
catches at `:392`, `:410`, `:439` and `:463` each render
`error.localizedDescription`, so Foundation's bridge text -- module name plus
enum case index -- can reach four rendered doctor lines today.

**Files:** `Sources/ContainerStackCore/DockerHTTPResponse.swift` and the
renderer goldens.

Same treatment as T-016b: `LocalizedError` + `CustomStringConvertible` with our
own wording, `errorDescription` delegating to `description` so the two paths
cannot diverge, and a test pinning **both** paths per case -- T-016b shipped
with `CustomStringConvertible` unpinned and its reviewer had to add that.

Goldens covering it must be literals, never interpolations of the error.

**Depends on:** T-016b

---

### [T-016d] `CancellationError` wording — app surface only, not the CLI  `[MOVED TO BACKLOG:2026-09-30]`

The T-016c reviewer listed `CancellationError` as the last type able to reach
`DiagnosticRunner`'s generic `error.localizedDescription` catches (`:392`,
`:410`, `:439`, `:463`) with Foundation bridge text, escaping from
`try await Task.sleep(for: retryPolicy.delay)` at `DockerAPIClient.swift:467`.

**Re-checked: it cannot reach them.** `signals(for:)` runs the gather in an
*unstructured* `Task {}` whose handle is discarded (`DiagnosticRunner.swift:273`),
and an unstructured task does not inherit cancellation from its caller. Only the
budget timer is cancelled (`:282`). The comment at `:268` states the same
property: "nothing cancellation reaches, so the budget stops waiting and never
stops the probe." The reviewer's reproduction cancelled a task directly, which
the runner never does.

So no rendered `cstack doctor` line can carry that text, and this does not gate
T-017 or anything else in the CLI.

What remains is the **app** surface, where tasks genuinely are cancelled and the
same client is used. Worth doing for that reason alone, at ordinary priority:
wrap the retry-loop cancellation in a `DockerAPIError` case with chosen wording.
Scope it to the app's error presentation and pin both description paths, as
T-016b/c did.

**Moved to backlog (2026-09-30), not done.** The wrap above would regress the
app. `RuntimeViewModel.refresh()` catches `CancellationError` and returns
quietly. A wrapped cancellation would fall into its general `catch`, which clears
the inventory and raises a runtime failure every time a `.task` refresh is
cancelled. The fix belongs at the app's call sites, not in the client:
`refreshImages` and `refreshContainers` (`RuntimeViewModel+Containers.swift`)
should leave their state untouched on cancellation instead of showing
"…could not be listed: CancellationError()". `probeRuntime` records a cancelled
`ping()` as a failed probe. That fix lives in `RuntimeViewModel.swift`, where
NFR-003 allows no new lines, and none of it is part of this spec. See Backlog.

**Depends on:** T-016c

---

### [T-017] CLI becomes a formatter  `[DONE:2026-09-20]`

**Files:** modify `Sources/CStackCLI/CStackCommands.swift:8-145` — `doctor`
becomes `print(DoctorTextRenderer.render(await runner.run(checks: .cliSet)))`.
All parsing and branching leaves the CLI.

**Depends on:** T-016

---

### [T-017a] A dead socket makes `cstack doctor` print nothing  `[DONE:2026-09-22]`

Found by the T-017 reviewer, reproduced against the binary:
`cstack doctor --socket /tmp/nonexistent.sock` writes **one byte** — `print`'s
own newline — and exits 0. Every check is `.skipped`, so the renderer emits an
empty string.

A refused socket is `SocketMeasurement.silent`, not `.unmeasurable`, so the
`.offline` branch of `project` (`DiagnosticRunner+Projection.swift:57`) never
reaches the `indeterminate` arm that F-003's table sanctions for "socket timed
out". Only a timeout does.

This also loses a line today's CLI prints. `resolve` is handed
`missingAppRoot: socket.responds ? appRoot.missingRoot : nil`
(`DiagnosticRunner.swift:362`), so a missing app root measured while the socket
is down cannot reach `.detached`. The old CLI pinged, printed
`Docker socket: not responding` (`CStackCommands.swift:24`) and then all three
missing-root lines regardless of the socket. That state now renders silence,
which F-003's rule 1 does not permit.

The gating is deliberate — it is how `RuntimeViewModel.applyState` calls
`resolve`, and F-004 keeps one ranking — so the repair is a spec decision about
whether a missing app root outranks a dead socket, not a projection tweak.

**Decision:** Keep stopped checks `.skipped` (F-010). When the renderer has no
visible checks and the socket was requested but skipped, print the old socket
line instead of silence. Do not project a missing root as a failure behind a
refusing socket: explicitly except the old CLI's three storage lines in F-003.
Two runner-to-renderer goldens pin both a plain stopped socket and a stopped
socket with a measured missing root. No CLI branching or second precedence
rule.

**Depends on:** T-017

---

### [T-018] Read-only docker-context check (UI set)  `[DONE:2026-09-30]`

**Files:** modify `Sources/ContainerStackCore/DiagnosticRunner.swift`;
test in `Tests/ContainerStackCoreTests/DiagnosticRunnerTests.swift`.

Build it from the pure pieces that already exist — do **not** call
`repairStaleContextRecordIfNeeded()`, which repairs as a side effect:

- `DockerCLI.recordedSocketPath(for:using:)` (`DockerCLI.swift:156`) — the
  `using:` variant takes the command runner, which is the test seam;
- `DockerContext.shouldRepairStaleRecord(activeContext:installed:takeoverEnabled:recordedSocketPath:currentSocketPath:)`
  (`DockerContext.swift:63-75`) — pure, and explicitly not a reachability check.

**Step 1 — RED:** a fixture whose recorded endpoint differs from the current
socket asserts the `dockerContext` check is `.warning` with the
`.repairDockerContext` remedy; a second fixture where they match asserts `.ok`;
a third where the command runner throws asserts `.indeterminate`.
**Also assert the check performs no repair** — the injected runner records the
commands it was asked to run, and `context use` / `context update` must not
appear.

**Done (2c4c790):** `shouldRepairStaleRecord` also needs the takeover preference,
the installation and the active context. The runner cannot measure the first, and
spawning for the last would be a sixth process. So the caller supplies all three
as `DiagnosticRunner.DockerContextSetting`, and nil makes the check
`.indeterminate`. The review added two more rules: an input the rule cannot judge
is `.indeterminate`, never `.ok`, and the listing runs off the cooperative pool.
The audit found NFR-001's "fixed" spawn count had not held since T-012, and the
spec now states it as a bound (c1303aa).

**Depends on:** T-008, T-019

---

### [T-018a] A test-support target both test targets can import  `[DONE:2026-09-30]`

**Blocks T-020.** `Package.swift:56-64` gives `ContainerStackAppTests` a
dependency on `ContainerStackApp` only, and SwiftPM has no way for one test
target to import another. So `GatedSystemProbe`, which lives in
`ContainerStackCoreTests`, is invisible to `DoctorViewModelTests` — and T-020's
single-flight proof needs exactly that fake.

**Files:** modify `Package.swift`; move the fakes out of
`Tests/ContainerStackCoreTests/SystemProbeFakes.swift`.

Add a non-test library target (e.g. `DiagnosticTestSupport`, depending on
`ContainerStackCore`), move `RecordingSystemProbe`/`GatedSystemProbe` into it,
and add it to both test targets' dependencies.

**Step 1 — RED:** a trivial test in `ContainerStackAppTests` that imports the
new module and constructs `GatedSystemProbe`; it fails to compile today.

**Watch:** the new target ships in the package but is referenced only by tests.
Confirm it does not enter any of the three shipped products, and that
`swiftlint --strict` and the `file_length`/`type_body_length` caps still pass on
the moved file.

**Done (d041e7c):** the file list above was one short. `Project.swift` (Tuist)
needs the same target, because `scripts/smoke-test.sh` builds the core tests
from `Tests/ContainerStackCoreTests/**` there. It is a static framework with
`ENABLE_TESTING_SEARCH_PATHS`, since the fakes import `Testing`. The old file
keeps only the fakes' own tests, as `SystemProbeFakeTests.swift`.

**Depends on:** T-004

---

### [T-019] `repairDockerContextRecord() async -> Bool`  `[DONE:2026-09-26]`

**Files:** modify `Sources/ContainerStackApp/RuntimeViewModel+DockerContext.swift:160-188`.
Extract the repair so it returns success; the polled caller keeps ignoring the
result (its empty `catch` was deliberate), Doctor renders failure.

**Depends on:** none

---

### [T-020] DoctorViewModel: single-flight + cadence (F-007, F-011)  `[DONE:2026-09-30]`

**Files:**
- Create: `Sources/ContainerStackApp/DoctorViewModel.swift`
- Test: `Tests/ContainerStackAppTests/DoctorViewModelTests.swift`

**Step 1 — RED:** with `GatedSystemProbe` suspending run A, request another run;
assert the probe call count does **not** increase and no second report appears;
resume A and assert one publish. A second case: two opens inside 30s issue one
run's worth of spawns; the explicit button issues a second.

**NFR-003:** this file is new. `RuntimeViewModel.swift` must not gain a line —
check with `git diff --exit-code Sources/ContainerStackApp/RuntimeViewModel.swift`.

**From T-018:** build the runner with `dockerContextSetting:` read from the app's
own state (`takesOverDockerContext`, `isDockerContextInstalled`,
`activeDockerContext`). The default is nil, which renders the context row amber on
every run.

**Done (e0192f0):** `appeared()` / `checkAgain()` / `disappeared()`. Returning
while a run is still going adopts it (its generation becomes the current one), so
the result is shown and no second run starts. A discarded run still holds the
30s window. The audit rejected resetting the window on a discard: on a wedged
runtime every return visit would then buy another five uncancellable spawns. So
the view offers "Check again" instead. F-008's view-model half is left to T-022.

**Depends on:** T-015, T-018, T-018a, T-019

---

### [T-021] Sidebar destination (F-006)  `[DONE:2026-09-30]`

**Files:** modify `Sources/ContainerStackApp/DashboardView.swift:4-22` (add
`.doctor`) and `Sources/ContainerStackApp/AppChrome.swift:95-97` (add it to
`dockerItems` — membership there is what makes it both visible and hideable).

**Step 1 — RED:** `#expect(DashboardDestination.dockerItems.contains(.doctor))`.

**Done (079aa15), with part of T-022 moved in:** adding the case forces the
exhaustive detail switch in `DashboardView` to render something, and a
placeholder would ship a stub. So the read-only `DoctorView` landed here:
- rows with an icon and tint per verdict (G-03);
- manual advice shown as text;
- a header with the `ranAt` stamp and "Check again" (F-011).

The hidden-row parsing moved into static helpers on `DashboardDestination` (same
key, same format) so F-006's hide and persist clauses are asserted.

**Depends on:** T-020

---

### [T-022] Remedy buttons and the repair in progress (F-008)  `[DONE:2026-09-30]`

**Files:** modify `Sources/ContainerStackApp/DoctorView.swift` (created at
T-021 with the read-only rows) and `Sources/ContainerStackApp/DoctorViewModel.swift`
and its tests for F-008's view-model half: invoking a remedy, one operation for
two taps, and no automatic re-run until the repair settles. F-008's acceptance is
a view-model test, and T-020 covered only F-007/F-011.
Button only for an in-process remedy, bound to `canRestartRuntime`, disabled while
`isRestarting` (F-008).

**Done:** closes OQ-6 as spec-gaps decision 9 (the user was asked and gave no
answer). Touches only the listed files. Findings from review and audit rounds:
- A restart started from the sidebar makes the report as stale as the section's
  own, so it drops the report too.
- A run already in flight when a restart begins is never shown, and one fresh run
  follows it.
- A section that is not open starts nothing (§7). It owes the run to its next
  visit, which pays it at once.
- The model watches the app's restart flag through observation, not a view's
  `onChange`. A restart that fails at its first step can flip the flag and back
  before anything renders.
- `perform` waits for the model's look at its own restart's edges, so they leave
  nothing owed.

Each rule has a test that fails when the rule is removed.

**Depends on:** T-021

---

### [T-023] Skipped rows name their check (F-015)  `[DONE:2026-10-04]`

**Files:** `Sources/ContainerStackCore/DiagnosticReport.swift` (`CheckID.title`),
`Sources/ContainerStackCore/DiagnosticRunner+Verdicts.swift` (`skipped`), and the
tests that pinned the old summary.

**Step 1 — RED:** under a foreign bridge, every skipped check's summary starts
with its own title and its `detail` is the reason.

**Done (1b95433).** `notRun` leads with the title too and keeps no detail; F-015
was narrowed to say so after review.

**Depends on:** T-022

---

### [T-024] Another ContainerStack copy's bridge (F-014)  `[DONE:2026-10-04]`

**Files:** `Sources/ContainerStackCore/BridgeOwnership.swift` (classification and
`ForeignBridge`), `RuntimeState.swift` (payload, title, detail),
`RuntimeControl.swift` (`stopBridge` carries the socket; what it signals),
`DiagnosticRunner.swift` and `+Projection.swift`, the app's
`RuntimeViewModel+Staleness.swift` and `+Control.swift`, `CStackRuntimeControl.swift`.
`RuntimeViewModel.swift` changes in place only (NFR-003).

**Step 1 — RED:** classification of ours, sibling and foreign holders; the
projection's remedy per kind; the stop plan signals a sibling and never a
foreign holder.

**Done.** Codex reviewed the change. Two of its findings were real and are fixed,
each with a test that fails without it:
- The poll's automatic recovery would have stopped a sibling. The plan now takes
  `replacingSibling`, and only a person's request passes `true`.
- The stop read only the first pid `lsof` listed. It now looks at every one.
Three were rejected. Doctor reading an unnamed holder as unknown, not foreign,
predates this change and has its own test. The bare restart hint matches every
other restart hint (backlog). `notRun` has no reason to carry (F-015 narrowed).
`RuntimeViewModel.swift` changed type only, line for line (NFR-003 amended).

**Depends on:** T-023

---

## Backlog (out of scope, recorded not planned)

- Split `SystemProbe` for interface segregation (architecture review; deferred).
- Aggregate verdict / sidebar badge (OQ-1).
- Memory commitment in the UI behind its own button (OQ-3, v2).
- `CheckID` granularity for "versions" (OQ-5).
- Two `ShellSystemProbeTests` fail under Tuist + xcodebuild ("this process is
  shutting down") but pass under `swift test`. Found at T-018a, and identical on
  the commit before it, so pre-existing: some test leaves `ProcessRunner`'s
  shutdown flag set in the shared test process.
- `ProcessRunnerTests` "a descendant that inherits stdout cannot outlive the
  deadline" (0.3s deadline) failed once under load during T-020's gates, then
  passed 5/5 alone and in the full re-run. It is timing-sensitive and unrelated
  to the Doctor work.
- Restart hints ignore `cstack --socket` (found in T-024's review). Every
  "Run: cstack runtime restart" line is printed bare, so `cstack --socket X
  doctor` points at a restart of the default socket. That restart stops and
  starts the bridge there, not on `X`. Print `--socket X` whenever the report's
  socket is not the default.
- Ownership reads only the first pid `lsof` lists (found in T-024's review).
  A wedged bridge whose socket file was replaced still lists under the path,
  ahead of the bridge now serving it, so ownership can read "ours" while a
  sibling serves. The bridge stop already looks at every listed pid.
- A cancelled app request reads as a failure (was T-016d). A `.task` refresh
  cancelled during the retry loop's sleep leaves "Images/Containers could not be
  listed: CancellationError()" on screen. A cancelled monitor `ping()` counts as
  a failed probe. Fix at the call sites by treating `CancellationError` as no
  result, as `refresh()` already does. Do not wrap it in `DockerAPIError`, which
  would defeat that `catch`.
