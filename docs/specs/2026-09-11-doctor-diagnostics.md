# Spec: Doctor diagnostics section

Version: 1.0
Date: 2026-09-11
Source brainstorm: docs/brainstorms/2026-09-11-doctor-diagnostics.md

## 1. Overview

ContainerStack already owns a real diagnostic — `cstack doctor` — but it is
reachable only from a terminal, and its logic is welded to `print` inside the
CLI target. This spec moves the orchestration into `ContainerStackCore` as a
pure `DiagnosticReport`, then renders that report twice: as the unchanged
`cstack doctor` text, and as a new **Doctor** section in the app sidebar for a
user asking "is my environment healthy?" before anything visibly breaks.

## 2. Requirements

### 2.1 Functional requirements

- **[F-001]** `DiagnosticRunner` produces a `DiagnosticReport` containing one
  `DiagnosticCheck` per requested `CheckID`, and performs no printing and no
  SwiftUI access.
  *Acceptance:* unit test builds a runner over `StubDockerTransport` plus
  fixture probes and asserts the returned value; `ContainerStackCore` does not
  import SwiftUI (compiler-enforced).

- **[F-002]** The caller passes the check set explicitly:
  `DiagnosticRunner.run(checks: Set<CheckID>)`. `cstack doctor` passes the full
  set including `.memoryCommitment`; the UI v1 passes the set without it.
  *Acceptance:* test asserts the UI check set issues no `inspectContainer`
  request against the stub transport, while the CLI set does.

- **[F-003]** `cstack doctor` becomes a formatter over `DiagnosticReport` and
  its stdout text is byte-identical to today's for the same runtime state.
  *Acceptance:* golden-output test over fixtures for healthy, missing-app-root,
  and unroutable-network states.

- **[F-004]** `appRoot` is evaluated before every other check, and a positive
  result marks the remaining checks `.skipped`.
  *Acceptance:* test with a fixture where `container system status` reports a
  non-existent root asserts ordering and the skip.

- **[F-005]** Under a foreign bridge the `appRoot` and socket-dependent checks
  are `.skipped`, mirroring the precedence in `RuntimeState.resolve`.
  *Acceptance:* test asserts `foreignBridge` wins and that no remedy naming a
  local runtime restart is emitted.

- **[F-006]** Doctor is a `DashboardDestination` case rendered in the sidebar
  and hideable through the existing `sidebarHiddenItems` storage.
  *Acceptance:* the case is `CaseIterable` and the existing hide toggle covers
  it with no per-case special handling.

- **[F-007]** Opening the section starts a run automatically; leaving cancels
  it; a result from a superseded run is discarded.
  *Acceptance:* test drives two overlapping runs and asserts only the newer
  epoch publishes.

- **[F-008]** A check renders an action button only when its `remedy` is
  executable in-process (`.restartRuntime`, `.repairDockerContext`). `.manual`
  renders as text.
  *Acceptance:* view-model test asserts button presence per remedy case.

- **[F-009]** A failing probe never presents as a passing check.
  *Acceptance:* fixture where `runtimeStatus()` returns `.failed` asserts the
  app-root check is `.failure`, not `.ok` and not `.skipped`.

- **[F-010]** A stopped runtime yields `.skipped` checks with a reason, not
  `.failure`.
  *Acceptance:* fixture with a non-responding socket asserts zero `.failure`
  verdicts.

### 2.2 Non-functional requirements

- **[NFR-001] Performance.** A UI v1 run issues exactly two process spawns
  (`container system status`, `netstat -rn -f inet`) and two Docker API calls
  (`listContainers`, `listNetworks`), independent of container count. No
  `inspectContainer` call. *Acceptance:* stub counts requests and asserts the
  count does not change between 0 and 20 running containers.
- **[NFR-002] Latency bound.** Each probe inherits
  `ProcessRunner.diagnosticTimeout` (10s, `ProcessRunner.swift:38`) rather than
  `lifecycleTimeout` (120s), so a wedged binary cannot hang the section.
- **[NFR-003] Line budget.** The change adds zero lines to
  `Sources/ContainerStackApp/RuntimeViewModel.swift`, which is at exactly 690
  lines against `file_length: warning: 690` under `--strict`.
  *Acceptance:* `git diff` shows that file untouched; SwiftLint passes.
- **[NFR-004] Safety.** Doctor terminates no process. A foreign bridge is named,
  never evicted.
- **[NFR-005] Observability.** `DiagnosticReport` is `Codable`, so a future
  "copy report" affordance needs no re-modelling. No such UI in v1.

## 3. Architecture

### 3.1 System context

```
container system status ─┐
netstat -rn -f inet ─────┤→ SystemProbe ─┐
                                         ├→ DiagnosticRunner → DiagnosticReport ─┬→ cstack doctor (text)
DockerAPIClient (actor) ─────────────────┘                                       └→ DoctorViewModel → DoctorView
```

`DiagnosticReport` is the only thing crossing from Core to either surface.

### 3.2 Component breakdown

- **`DiagnosticCheck` / `DiagnosticReport`** (new,
  `Sources/ContainerStackCore/DiagnosticReport.swift`)
  - *Responsibility:* carry one verdict set; no behaviour.
  - *Depends on:* nothing.

- **`DiagnosticRunner`** (new,
  `Sources/ContainerStackCore/DiagnosticRunner.swift`)
  - *Responsibility:* run the requested checks in precedence order and assemble
    the report.
  - *Interface:* `func run(checks: Set<CheckID>) async -> DiagnosticReport`
  - *Depends on:* `DockerAPIClient` (`DockerAPIClient.swift:291`), `SystemProbe`,
    `NetworkRouteHealth`, `RuntimeStatusParser`
    (`RuntimeProcessConfiguration.swift:177`), `MemoryCommitment`
    (`MemoryCommitment.swift:14`) and `HostMemory` (`:70`) for the CLI check set.

- **`SystemProbe`** (new protocol, Core; production impl over
  `ProcessRunner.run`, `ProcessRunner.swift:104`)
  - *Responsibility:* run the two external commands and report success or
    failure without laundering failure into empty output.
  - *Interface:* `func runtimeStatus() async -> ProbeResult`,
    `func routingTable() async -> ProbeResult`

- **`CStackCLI.doctor`** (changed, `Sources/CStackCLI/CStackCommands.swift:8`)
  - *Responsibility:* format a report. All check logic leaves this function,
    including `reportMemoryCommitment` (`:84` and below).

- **`DoctorViewModel`** (new, `Sources/ContainerStackApp/DoctorViewModel.swift`)
  - *Responsibility:* own `report`, `isRunning`, and the epoch counter; invoke
    existing repairs. Implements no repair itself.
  - *Depends on:* `RuntimeViewModel.restartRuntime()`
    (`RuntimeViewModel+Control.swift:14`) and the docker-context repair
    (`RuntimeViewModel+DockerContext.swift:160`).

- **`DoctorView`** (new, `Sources/ContainerStackApp/DoctorView.swift`);
  **`DashboardDestination`** (changed, `DashboardView.swift:4`) gains a case;
  the sidebar hide toggle (`AppChrome.swift:108`) needs no change.

### 3.3 Data model

```swift
public enum CheckID: String, CaseIterable, Codable, Sendable {
    case appRoot, socket, versions, routes, foreignBridge, dockerContext, memoryCommitment
}

public enum Verdict: Codable, Sendable { case ok, warning, failure, skipped }

public enum Remedy: Codable, Sendable {
    case restartRuntime
    case repairDockerContext
    case manual(String)
}

public struct DiagnosticCheck: Codable, Sendable {
    public let id: CheckID
    public let verdict: Verdict
    public let summary: String     // non-empty
    public let detail: String?
    public let remedy: Remedy?     // nil when verdict == .ok
}

public struct DiagnosticReport: Codable, Sendable {
    public let checks: [DiagnosticCheck]   // ordered by precedence, one per requested CheckID
    public let ranAt: Date
}

public enum ProbeResult: Sendable {
    case output(String)
    case failed(reason: String)
}
```

Constraint: `checks.map(\.id)` is exactly the requested set — a check is never
silently dropped; not-run is expressed as `.skipped`.

## 4. API contract

**`DiagnosticRunner.run(checks:) async -> DiagnosticReport`**
- *Input:* non-empty `Set<CheckID>`. An empty set returns an empty report with
  `ranAt` set (not an error).
- *Output:* one `DiagnosticCheck` per requested id, precedence-ordered.
- *Errors:* none thrown. Every failure — transport, probe, parse — is folded
  into that check's `.failure` verdict with its own message; one failing check
  never aborts the others.
- *Idempotency:* pure with respect to the system; running twice changes nothing
  and may return different verdicts if the system changed.

**`SystemProbe.runtimeStatus() / .routingTable() async -> ProbeResult`**
- *Errors:* a non-zero exit, a spawn failure, or a timeout must surface as
  `.failed(reason:)`. Returning `.output("")` for a failed process is
  forbidden — see section 5.

**Remedy invocation (UI)** — `.restartRuntime` and `.repairDockerContext` call
existing app functions; the section re-runs the report on completion. No new
repair is introduced.

## 5. Failure modes

| Dependency | Failure | Behaviour |
|---|---|---|
| `container system status` | spawn fails / times out | `.failed(reason:)` → app-root check `.failure`. **Must not** become `""`: `RuntimeStatusParser.missingAppRoot("")` returns `nil` because `isRunning("")` is false, which would render a broken probe as a healthy app root. |
| `netstat -rn -f inet` | spawn fails / times out | `.failed` → routes check `.failure`. Today an empty string already lands on "could not read the routing table" via `NetworkRouteHealth.canJudgeRoutes` (`NetworkRouteHealth.swift:98`), so this is a tightening, not a change of verdict. |
| Docker API | `/info` fails while `_ping` succeeds | The app-root check leads precisely because of this state; other checks are `.skipped`. |
| Docker API | transport error on any call | That check is `.failure`; siblings still run. Today `try await client.health()` propagates and kills the whole command. |
| Docker API | no running containers | Routes check `.skipped` with "nothing to check" — kept distinct from "could not check" (issue #45). |
| Socket | held by a foreign bridge | `foreignBridge` check reports; dependent checks `.skipped`; no local-restart remedy offered. |
| Runtime | stopped, or `.starting` | All dependent checks `.skipped` with a reason; nothing red, nothing flashing. |
| UI | section closed mid-run | Task cancelled; a late result from a superseded epoch is discarded. |

`CommandShell.output` (`Sources/CStackCLI/CStackRuntimeControl.swift:29`) is the
current source of the laundering: it wraps `ProcessRunner.run` in `try?` and
returns `""`. The Core probe does not reuse it.

## 6. Observability

- `DiagnosticReport` is `Codable`; a serialised report is the intended artefact
  to attach to a bug report later.
- `summary` strings stay identical between CLI and UI, so a user-quoted line is
  greppable in the source.
- No new logging subsystem, no metrics, no telemetry in v1.

## 7. Non-goals

- Memory commitment in the **UI** v1 (it stays in the CLI check set).
- Any new repair: restoring a missing app root, evicting a foreign bridge,
  rewriting a docker context beyond the existing repair.
- A "copy diagnostics" button.
- Removing or consolidating the nine existing per-screen message properties on
  `RuntimeViewModel`; the banners stay.
- Changing `cstack doctor`'s text, exit codes, or flags.
- Background/scheduled runs, notifications, or a sidebar badge.
- Touching `RuntimeViewModel.swift` at all.

## 8. Open questions

1. Does `DiagnosticReport` need an aggregate verdict for a sidebar badge, or is
   the row list enough for v1? (Brainstorm left open; a badge implies background
   runs, which are a non-goal — likely defer.)
2. The docker-context check currently has no on-demand entry point:
   `repairStaleContextRecordIfNeeded()` runs as a side effect of polling
   (`RuntimeViewModel+DockerContext.swift:160`). Does Doctor need a read-only
   context check extracted from it, or does it reuse the polled result?
3. Should v2's memory-commitment check sit behind its own button in the section
   rather than joining the automatic run?
4. `MemoryCommitment` verdicts (`.within` / `.approaching` / `.exceeding`) map
   onto `Verdict` awkwardly — is `.approaching` a `.warning`? Needed only when
   v2 brings this check to the UI, but the CLI mapping must be decided now to
   keep F-003 byte-identical.
5. Exact `CheckID` granularity for "versions": today the CLI prints API version,
   engine version, container count and image count as one block. One check or
   several?

## 9. Success criteria

One verdict instead of nine messages: CLI and UI produce the same answer for the
same state, proven by a test over a shared `DiagnosticReport`. A divergence
becomes a failing test rather than a user-visible bug.

Measured as: a single fixture set (transport responses plus two `ProbeResult`
values) drives both renderers; the CLI golden text and the `DoctorViewModel`
verdicts are asserted from that one report, over the check set both share.
