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
five remaining open questions do not gate any task here.

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

### [T-014] Memory-commitment check (CLI set only)

Mapping decided in `spec-gaps.md`: `.within` → `.ok`, `.approaching` →
`.warning`, `.exceeding` → `.warning` with `.manual` remedy, host memory
unknown → `.indeterminate`, any failed `inspectContainer` → `.indeterminate`.

**Step 1 — RED:** assert the UI set issues **zero** `inspectContainer` requests
while the CLI set issues one per running container.

**Depends on:** T-008

---

### [T-015] Total 20s budget and concurrent probes (NFR-002)

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

### [T-015b] Per-check `duration` (NFR-005)

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

### [T-016] DoctorTextRenderer + goldens (F-003, F-012)

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

### [T-017] CLI becomes a formatter

**Files:** modify `Sources/CStackCLI/CStackCommands.swift:8-145` — `doctor`
becomes `print(DoctorTextRenderer.render(await runner.run(checks: .cliSet)))`.
All parsing and branching leaves the CLI.

**Depends on:** T-016

---

### [T-018] Read-only docker-context check (UI set)

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

**Depends on:** T-008, T-019

---

### [T-019] `repairDockerContextRecord() async -> Bool`
### [T-018a] A test-support target both test targets can import

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

**Depends on:** T-004

---


**Files:** modify `Sources/ContainerStackApp/RuntimeViewModel+DockerContext.swift:160-188`.
Extract the repair so it returns success; the polled caller keeps ignoring the
result (its empty `catch` was deliberate), Doctor renders failure.

**Depends on:** none

---

### [T-020] DoctorViewModel: single-flight + cadence (F-007, F-011)

**Files:**
- Create: `Sources/ContainerStackApp/DoctorViewModel.swift`
- Test: `Tests/ContainerStackAppTests/DoctorViewModelTests.swift`

**Step 1 — RED:** with `GatedSystemProbe` suspending run A, request another run;
assert the probe call count does **not** increase and no second report appears;
resume A and assert one publish. A second case: two opens inside 30s issue one
run's worth of spawns; the explicit button issues a second.

**NFR-003:** this file is new. `RuntimeViewModel.swift` must not gain a line —
check with `git diff --exit-code Sources/ContainerStackApp/RuntimeViewModel.swift`.

**Depends on:** T-015, T-018a, T-019

---

### [T-021] Sidebar destination (F-006)

**Files:** modify `Sources/ContainerStackApp/DashboardView.swift:4-22` (add
`.doctor`) and `Sources/ContainerStackApp/AppChrome.swift:95-97` (add it to
`dockerItems` — membership there is what makes it both visible and hideable).

**Step 1 — RED:** `#expect(DashboardDestination.dockerItems.contains(.doctor))`.

**Depends on:** T-020

---

### [T-022] DoctorView rows

**Files:** create `Sources/ContainerStackApp/DoctorView.swift`.
Icon per verdict — `.indeterminate` renders amber, never grey (G-03). Button
only for an in-process remedy, bound to `canRestartRuntime`, disabled while
`isRestarting` (F-008).

**Depends on:** T-021

---

## Backlog (out of scope, recorded not planned)

- Split `SystemProbe` for interface segregation (architecture review; deferred).
- Aggregate verdict / sidebar badge (OQ-1).
- Memory commitment in the UI behind its own button (OQ-3, v2).
- `CheckID` granularity for "versions" (OQ-5).
