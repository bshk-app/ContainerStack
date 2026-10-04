# Spec: Doctor diagnostics section

Version: 1.1 (revised after spec-panel; 4 reviewers, 9 verified defects)
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
  `DiagnosticRunner.run(checks: Set<CheckID>)`. Neither set is "all":
  - CLI: `{appRoot, socket, versions, routes, foreignBridge, memoryCommitment}`
  - UI v1: `{appRoot, socket, versions, routes, foreignBridge, dockerContext}`

  `memoryCommitment` is CLI-only (cost — see NFR-001); `dockerContext` is
  UI-only (the CLI has `cstack context` as a separate subcommand,
  `CStackCommands.swift:279`). `foreignBridge` is **new to the CLI** and is a
  deliberate scope addition, not an accident — see F-003.
  *Acceptance:* assert exact set equality for both callers
  (`cliChecks == [...]`, `uiChecks == [...]`), not merely the absence of an
  `inspectContainer` request — an absence passes for a wrong set too.

- **[F-003]** `cstack doctor` becomes a formatter over `DiagnosticReport`.

  **The original "byte-identical except one sanctioned diff" wording was not
  achievable, and is replaced.** The reason is structural, not incidental:
  `doctor` is declared `async throws` (`CStackCommands.swift:8`) and reaches the
  API through `try` (`:31` `health()`, `:51` `listNetworks()`). Whenever a
  measurement fails, today's binary **aborts** — it prints no line for that
  check and exits non-zero. So for every state in which the Doctor must say
  "could not measure", there is no existing output to be identical to. F-009 and
  F-010 require exactly those states to render as `.indeterminate`. The old
  F-003 and F-010 could not both hold.

  The rule is now:

  1. **For every state today's `cstack doctor` actually prints, stdout stays
     byte-identical, except the stopped-socket/missing-root combination below.**
     This protects users' scripts and is pinned by goldens.
  2. **States where today's binary aborts instead of printing gain new lines.**
     They are enumerated below; nothing may be added to this list without
     amending the spec, so a golden can never bless wording nobody chose.
  3. **One behavioural addition:** the foreign-bridge check, new to the CLI,
     which prints a bridge-ownership line and skips the checks it makes
     meaningless. This was the originally sanctioned diff.

  **Stopped-socket decision (T-017a):** A refusing socket resolves to `.offline`;
  all requested checks stay `.skipped` with reasons (F-010). When that produces
  no visible checks, the CLI renderer prints `Docker socket: not responding`
  instead of an empty line. This is the same first line the old CLI printed.
  If `container system status` also reports a missing app root, the old CLI
  appended three storage lines even though the socket was down; the new CLI
  omits them. A missing root is gated on an answering socket in both the app
  and Doctor's `RuntimeState.resolve` call, so claiming `.detached` or offering
  a restart in this state would contradict the shared precedence rule. This
  is an explicit exception to rule 1, not an unreviewed golden change.
  Enumerated lines (runner checks, except the stopped-socket renderer fallback):

  | State | Line | Today's CLI |
  |---|---|---|
  | status probe unreadable | `Runtime storage: UNKNOWN — the runtime status could not be read.` | aborts |
  | socket timed out | `Docker socket: UNKNOWN — the socket did not answer before the timeout.` | aborts at `:31` |
  | version call failed | `API version: UNKNOWN — the Docker API did not answer.` | aborts at `:31` |
  | network listing failed | `Container routes: UNKNOWN — the Docker API did not answer.` | aborts at `:51` |
  | foreign bridge | bridge-ownership line, and `Docker bridge: ours` when it is not foreign | no such check |
  | bridge holder unidentifiable | `Docker bridge: UNKNOWN — the process holding the socket could not be identified.` | no such check |
  | no running containers | `Container memory limits: no running containers to check` | returns at `:46` before the memory report |
  | container listing failed | `Container memory limits: UNKNOWN — the Docker API did not answer.` | aborts at `:43` |
  | refusing socket | `Docker socket: not responding` (all checks remain `.skipped`) | same socket line; may also print missing-root lines, per exception above |

  Consequence to accept deliberately: `cstack doctor` **stops exiting non-zero
  by throwing** in these states, and reports them instead. That is the point — a
  diagnostic that dies when the runtime hangs fails exactly when it is needed.

  *Acceptance:* golden-output tests over fixtures for healthy,
  missing-app-root, unroutable-network, **foreign-bridge**, and a refusing
  socket both with and without a measured missing app root, plus one golden
  per row of the table above. The first three goldens are pinned from today's
  binary before the refactor; the rest are new or explicitly excepted above.
  Rendering is a pure function so no stdout capture is needed — see F-012.

- **[F-004]** Precedence is **not re-derived**. The runner gathers the signals
  for the requested checks, calls `RuntimeState.resolve`
  (`Sources/ContainerStackCore/RuntimeState.swift:25-60`) **once**, and projects
  the resulting `RuntimeState` onto per-check verdicts. The ordering
  (`foreignBridge` → `detached`/appRoot → socket-dependent) therefore exists in
  exactly one place, and a future change to `resolve` cannot leave Doctor
  disagreeing with the rest of the app.
  *Acceptance:* a test asserts the runner calls `resolve` and that no branch in
  `DiagnosticRunner` compares `foreignBridge` against `missingAppRoot` itself;
  plus fixtures for `.detached` alone and `.foreignBridge` + missing root
  together, asserting the projected verdicts in both.

- **[F-005]** Under a foreign bridge the `appRoot` and socket-dependent checks
  are `.skipped`, because `missingAppRoot` describes the local runtime rather
  than whoever serves the socket and would name the wrong remedy. This is a
  consequence of the projection in F-004, not a second rule.
  *Acceptance:* test asserts `foreignBridge` wins and that no remedy naming a
  local runtime restart is emitted — in **both** the CLI and UI check sets,
  since the CLI now measures bridge ownership too. *Amended by F-014:* a
  holder that is another ContainerStack copy's bridge gets `.restartRuntime`,
  because that restart now stops it.

- **[F-006]** Doctor is a new `DashboardDestination` case **added to
  `DashboardDestination.dockerItems`** (`AppChrome.swift:95-97`). `CaseIterable`
  alone renders nothing: the sidebar iterates the explicit `dockerItems` /
  `generalItems` lists, and only `dockerItems` is filtered by `hidden`
  (`AppChrome.swift:117` vs `:122`). Membership in `dockerItems` is what makes
  the row both visible and hideable, with no change to `AppChrome`.
  *Acceptance:* assert `dockerItems.contains(.doctor)`; assert the row
  disappears when `.doctor` is in `sidebarHiddenItems` and that the preference
  persists across a re-read of the storage.

- **[F-007]** **Single-flight.** At most one Doctor run exists at a time. A
  request arriving while a run is in flight does not start a second run and
  does not queue one — it coalesces onto the running one (the section simply
  shows `isRunning`). Leaving the section discards the *result* of the run in
  flight; it does **not** stop the work, because `ProcessRunner.run` is
  synchronous and waits on a `DispatchSemaphore` (`ProcessRunner.swift:198`),
  so `Task.cancel()` cannot interrupt a probe. A generation counter decides
  only whether a finished run publishes, never which of two runs wins — there
  are never two.

  Rationale: overlap would be worst exactly when it hurts most. A run costs
  up to five uncancellable spawns in the UI set (NFR-001) and can occupy the full 20s
  (NFR-002) precisely when the runtime is wedged; letting a second start would
  multiply spawns against an already-stuck system.
  *Acceptance:* with a gated probe fake suspending run A, requesting another
  run asserts (a) the probe call count does not increase, and (b) no second
  report is produced; resuming A then publishes once if the section is still
  open, and publishes nothing if it was left. A separate case asserts that a
  run started after the previous one finished does execute. No test asserts by
  sleeping.

- **[F-008]** A check renders an action button only when its `remedy` is
  executable in-process (`.restartRuntime`, `.repairDockerContext`). `.manual`
  renders as text. The button is bound to `canRestartRuntime`
  (`RuntimeViewModel+Control.swift:8`) and is disabled while `isRestarting`;
  the report shows an in-progress state rather than a stale verdict, and the
  automatic re-run is suppressed until the repair settles.
  *Acceptance:* view-model test asserts button presence per remedy case, and
  that invoking a repair twice performs one operation.

- **[F-009]** A failing probe never presents as a passing check.
  *Acceptance:* a matrix test — for **each** probe and transport failure, assert
  every check that depends on it is `.failure` or `.indeterminate` and never
  `.ok`; a single-probe fixture is not sufficient, since another check could
  return `.ok` and pass a narrow assertion.

- **[F-010]** A **stopped** runtime yields `.skipped` checks with a reason, not
  `.failure`. A **wedged** runtime — one that times out rather than refusing —
  yields `.indeterminate`, never `.skipped`, because the two are
  indistinguishable at the socket and "nothing red" on an unusable system reads
  as healthy.
  *Acceptance:* a fixture with a refusing socket asserts `.skipped` and zero
  `.failure`; a fixture whose probes and transport time out asserts every
  affected check is `.indeterminate` and that the report is not all-grey.

- **[F-011]** The automatic run is throttled by `DiagnosticCadence`
  (`Sources/ContainerStackApp/DiagnosticCadence.swift`) at 30s. Within the
  window the section shows the cached report with its `ranAt` stamp and a
  "Check again" button that bypasses the cadence. Rationale: spawning
  `container system status` per tick was already a measured problem in this
  codebase (~1200 spawns/hour), and section switching is unbounded.
  *Acceptance:* two opens inside 30s issue one run's worth of spawns; the
  explicit button issues a second.

- **[F-012]** Rendering is a pure function in Core:
  `DoctorTextRenderer.render(_ report: DiagnosticReport) -> String`; the CLI
  becomes `print(render(report))`. Required because `Package.swift` declares
  only `ContainerStackCoreTests` and `ContainerStackAppTests` — there is no CLI
  test target — and stdout capture via `dup2` is unsafe under swift-testing's
  in-process parallelism.
  *Acceptance:* F-003's goldens compare the returned `String`; a separate
  assertion proves `DiagnosticRunner` writes nothing to stdout/stderr.

- **[F-013]** `DiagnosticReport` carries an aggregate `verdict`, derived from
  its checks by a stated rule rather than stored: the worst verdict present,
  ordering `.failure` > `.warning` > `.indeterminate` > `.ok` > `.skipped`. An
  all-`.skipped` report is `.skipped`; an empty report is `.skipped`.
  Rationale: without it the report exposes only `checks`/`ranAt`, `.running`
  and `.degraded` project identically, and the `unroutableNetworks` signal the
  runner feeds `resolve` cannot be observed at all — mutating it to `[]` left
  every test green. This is a testability requirement, not a badge: F-006's
  sidebar entry stays unadorned in v1.
  *Acceptance:* a test asserts a degraded run's aggregate differs from a
  healthy run's, and fails if the runner stops forwarding `unroutableNetworks`.
  Table-driven cases pin the ordering, including the two empty/all-skipped
  edges.

- **[F-014]** **Another ContainerStack copy's bridge.** Ownership was decided by
  the exact path of this build's bridge, so every other copy of ContainerStack
  (the installed app against a dev build, or two installs) read as foreign.
  Measured on 2026-10-03: the installed app's `socktainer` had held
  `~/.containerstack/docker.sock` for 25 days with launchd as its parent and no
  app or agent left to stop it, and the dev build could only report it.
  The holder of the socket is now one of three things:
  - **ours**: a pid of this build's bridge, as before;
  - **a sibling**: its executable is `<bundle>/Contents/Helpers/socktainer` and
    that bundle's identifier is `app.bshk.containerstack`;
  - **foreign**: anything else, including a holder `lsof` could not name.
  Both non-ours kinds keep `RuntimeState.foreignBridge`, and so keep its
  precedence and its closed mutation gate (F-004, F-005). The state carries the
  holder's pid and command, and the sibling's bundle path.
  The `foreignBridge` check names the holder by pid and command. For a sibling
  its remedy is `.restartRuntime`. The restart's bridge stop
  (`RuntimeControlStep.stopBridge`, in the app and in `cstack runtime`; a stop
  runs the same step) sends
  `SIGTERM` to this build's bridge and to every holder `lsof` lists that is a
  sibling, and to nothing else. A foreign holder keeps the `.manual` remedy,
  which now names its pid.
  Nothing stops a sibling unless a person asks: no poll, no report and no
  helper start does it. The plan carries this as `replacingSibling`. It is
  true only for the sidebar's Restart and Stop, the Doctor's remedy and
  `cstack runtime`. The poll's automatic recovery and the stale-build restart
  at launch run the same plan with it false. A sibling supervised by another copy's registered
  LaunchAgent can be started again by launchd. If it takes the socket back, the
  next report names it again.
  *Acceptance:* classification tests for all three kinds, including a bundle
  path with a space and a bundle whose identifier differs. A projection test
  asserts a sibling gets `.restartRuntime` and a foreign holder gets a
  `.manual` remedy naming its pid. A stop-plan test asserts the sibling's pid
  is signalled and a foreign holder's is not, including a sibling listed after
  another holder. A restart-plan test asserts only `replacingSibling: true`
  carries the socket to the bridge stop.

- **[F-015]** A `.skipped` check names itself. Its summary is
  `<check title>: not checked`. When a higher-precedence state decided, its
  reason moves to `detail`. A check with nothing measured, such as storage
  when the status names no root, has no detail, as before. Measured on
  2026-10-01: under a foreign bridge the UI showed five identical grey rows,
  and nothing said which check each row was. The CLI prints no skipped check
  (F-003), so its output does not change.
  *Acceptance:* a projection test asserts every check skipped by a foreign
  bridge or a stopped runtime leads with its own title and carries the reason
  in `detail`.

### 2.2 Non-functional requirements

- **[NFR-001] Performance.** Process spawns per run are bounded by the check set
  and never grow with container count:
  - CLI set: **at most four** — `container system status`, `netstat -rn -f inet`,
    `/usr/sbin/lsof -Fpcn -- <socketPath>`, `/bin/ps -A -o pid=,command=`.
  - UI set: **at most five** — those four plus `docker context ls --format ...`,
    which `DockerCLI.recordedSocketPath(for:)` (`DockerCLI.swift:152`) shells for
    the `dockerContext` check.

  **Amended at T-018:** the bound is reached only when there is a route to judge.
  `netstat` is spawned only when a running container publishes on a network with a
  subnet (T-012); with nothing running, nothing publishing, or no subnet reported,
  the routes check has no table to read and the run spawns one process fewer. The
  listing is likewise not spawned when the caller gives no context setting. The
  original wording said "fixed", which that behaviour never was.

  The `lsof`/`ps` pair is what bridge ownership costs, because the Docker API
  cannot answer it (`RuntimeViewModel+Staleness.swift:110-112`); the CLI pays
  them too now that `foreignBridge` is in its set (F-002).

  Docker API calls: `health()` plus `listContainers` and `listNetworks` for
  both sets; the CLI set adds one `inspectContainer` **per running container**
  for `memoryCommitment`, which is exactly why the UI omits it.
  *Acceptance:* a recording `SystemProbe` fake counts probe spawns, the
  `dockerContext` check's injected listing counts its own (decision 8 keeps it out
  of `SystemProbe`), and the stub counts request paths. With a running container
  publishing on a network with a subnet, assert exact counts (`spawns == 4` for the
  CLI set and `== 5` for the UI set); with no running container, assert the same
  sets without `netstat` (`== 3` / `== 4`). The UI set's API paths equal
  `["/_ping", "/version", "/info", "/containers/json", "/networks"]` in order.
  Neither count may change between 1 and 20 publishing containers, and the UI
  set's API paths may not change between 0 and 20 running containers (the CLI set
  adds one `inspectContainer` per running container by design).
- **[NFR-002] Total time budget.** The whole run is bounded at **20s**, not per
  probe. Three facts force this, all verified:
  - `health()` is three retried calls, not one (`DockerAPIClient.swift:313,
    321, 322`);
  - `requestWithRetry` retries `.timedOut` (`DockerRetryPolicy.swift:31-32`)
    with `maxAttempts: 3` and a 5s request timeout — 15.5s per call;
  - four probes at `diagnosticTimeout` (10s, `ProcessRunner.swift:38`) are 40s
    if run sequentially.

  Worst case as originally specified was therefore ≈117s, not 10s. Required
  measures: run the four probes **concurrently**; use
  `requestRetryingImmediateFailures` (`DockerAPIClient.swift:450`) for
  diagnostic calls, which deliberately excludes `.timedOut` — a diagnostic
  exists to *report* a hang, not to outlast it three times; enforce an overall
  deadline after which unfinished checks are `.indeterminate` (F-010).
  *Acceptance:* a probe fake that never returns; assert the report is published
  within 20s and that the timed-out checks are `.indeterminate`. The 10s
  per-spawn timeout is **not** assertable through the fake — §3.2's method
  signatures carry no timeout parameter, so none crosses the boundary. Assert it
  instead in T-005 against the production `ShellSystemProbe`, which must pass
  `ProcessRunner.diagnosticTimeout` (`ProcessRunner.swift:38`).
- **[NFR-003] Line budget.** The change adds zero lines to
  `Sources/ContainerStackApp/RuntimeViewModel.swift`, which is at exactly 690
  lines against `file_length: warning: 690` under `--strict`.
  *Acceptance:* `git diff` shows that file untouched; SwiftLint passes.
  *Amended by F-014:* the foreign-bridge cache there changes type from the
  socket path to `ForeignBridge`, line for line, so the banner can name the
  holder. The file stays at 690 lines and nothing else in it changes.
- **[NFR-004] Safety.** Doctor terminates no process. A foreign bridge is named
  by its pid and command, not only by the socket, and is never evicted.
  *Amended by F-014:* the restart a person presses stops another ContainerStack
  copy's bridge. A report never does.
- **[NFR-005] Observability.** `DiagnosticReport` is `Codable`, so a future
  "copy report" affordance needs no re-modelling. No such UI in v1. Each
  `DiagnosticCheck` carries a `duration`, so an incident can name which probe
  consumed the budget, and a run where any check is `.indeterminate` logs one
  line naming them.
  *Acceptance:* a JSON round-trip test over a fixture report, with `ranAt`
  supplied by an injected clock so the round-trip is deterministic.

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
    (`MemoryCommitment.swift:14`) and `HostMemory` (`:70`) for the CLI check set;
    `DockerCLI.recordedSocketPath(for:)` (`DockerCLI.swift:152`) and
    `DockerContext.shouldRepairStaleRecord` (`DockerContext.swift:63`) for the UI
    check set's `dockerContext` (decision 8), with the takeover preference,
    installation and active context supplied by the caller rather than spawned.

- **`SystemProbe`** (new protocol, Core; production impl over
  `ProcessRunner.run`, `ProcessRunner.swift:104`)
  - *Responsibility:* run the external commands and report success or failure
    without laundering failure into empty output.
  - *Interface:* `func runtimeStatus() async -> ProbeResult`,
    `func routingTable() async -> ProbeResult`,
    `func socketHolder(socketPath: String) async -> ProbeResult` (`lsof`),
    `func processTable() async -> ProbeResult` (`ps`)
  - *Note:* the last two are required only by the `foreignBridge` check, which
    **both** sets run — F-002 put `foreignBridge` in the CLI set too, and
    NFR-001 counts `lsof` and `ps` among the CLI's four spawns. The parsing they
    feed already lives in Core —
    `BridgeOwnership` (`BridgeOwnership.swift:11`) and `ProcessTable`
    (`RuntimeControl.swift:5`); only the two spawns are new to Core. The
    app-side `RuntimeShell` (`RuntimeViewModel+Control.swift:191`) is not
    reused, for the same laundering reason as `CommandShell`.

- **`CStackCLI.doctor`** (changed, `Sources/CStackCLI/CStackCommands.swift:8`)
  - *Responsibility:* format a report. All check logic leaves this function,
    including `reportMemoryCommitment` (`:84` and below).

- **`DoctorViewModel`** (new, `Sources/ContainerStackApp/DoctorViewModel.swift`)
  - *Responsibility:* own `report`, `isRunning`, the single-flight handle and
    the generation counter (F-007); invoke
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

public enum Verdict: Codable, Sendable {
    case ok, warning, failure
    /// Not applicable: the runtime is stopped, or a higher-precedence check
    /// made this one meaningless. Rendered grey.
    case skipped
    /// Could not be measured: a probe or request timed out, or the overall
    /// deadline expired. Rendered amber, never grey -- a wedged runtime is
    /// indistinguishable from a stopped one at the socket, and "nothing red"
    /// on an unusable system reads as healthy.
    case indeterminate
}

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
    public let duration: Duration  // NFR-005: which probe ate the budget
}

public struct DiagnosticReport: Codable, Sendable {
    public let checks: [DiagnosticCheck]   // ordered by precedence, one per requested CheckID
    public let ranAt: Date                 // from an injected clock, not Date()
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

**`SystemProbe.runtimeStatus() / .routingTable() / .socketHolder(socketPath:) /
.processTable() async -> ProbeResult`**
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
| Docker API | `/info` fails while `_ping` succeeds | The app-root check leads the socket-dependent checks precisely because of this state; the rest are `.skipped`. A foreign bridge still outranks it (F-004). |
| Docker API | transport error on any call | That check is `.failure`; siblings still run. Today `try await client.health()` propagates and kills the whole command. |
| Docker API | no running containers | Routes check `.skipped` with "nothing to check" — kept distinct from "could not check" (issue #45). |
| Socket | held by a foreign bridge | `foreignBridge` check reports; dependent checks `.skipped`; no local-restart remedy offered. |
| `lsof` / `ps` | spawn fails / times out | Bridge-ownership check `.failure`, and the checks it gates stay `.skipped` rather than running on an unknown owner — an unknown holder is not the same as "ours". |
| Runtime | stopped, or `.starting` | All dependent checks `.skipped` with a reason; nothing red, nothing flashing. |
| UI | section closed mid-run | The run continues to completion — probes are uncancellable — and its result is discarded on publish (F-007). Spawns are not orphaned: `ProcessRunner` bounds and reaps them. |

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
- Any new repair: restoring a missing app root, evicting a foreign bridge
  (another ContainerStack copy's bridge is the F-014 exception),
  rewriting a docker context beyond the existing repair.
- A "copy diagnostics" button.
- Removing or consolidating the nine existing per-screen message properties on
  `RuntimeViewModel`; the banners stay.
- Changing `cstack doctor`'s text, exit codes, or flags.
- Background/scheduled runs, notifications, or a sidebar badge.
- Touching `RuntimeViewModel.swift` at all.

## 7a. Test infrastructure this feature requires

Half the acceptance criteria above are unwritable against today's doubles. These
are part of the work, not preconditions someone else supplies:

- **`StubDockerTransport` must be able to fail.** `send` always returns
  `responses.removeFirst()` (`Tests/ContainerStackCoreTests/TestSupport.swift:19-25`);
  no path throws, so F-009, F-010 and §5's "transport error on any call" cannot
  be expressed. Change to `init(responses: [Result<Data, Error>])`. An exhausted
  queue must `throw`, not trap — today it crashes the test process, which is the
  worst possible way to report an NFR-001 regression.
- **Responses must be keyed by path.** The queue is path-blind, so swapping two
  calls silently feeds `/networks` JSON to `listContainers` and the test still
  passes.
- **A recording `SystemProbe` fake** with a call log, so spawn counts (NFR-001)
  are assertable. It cannot log timeouts: §3.2's signatures do not take one.
- **A gated `SystemProbe` fake** exposing a `CheckedContinuation`, so F-007's
  coalescing and discard-on-leave branches are reachable without `Task.sleep`.
- **An injected clock** for `ranAt`.

## 8. Open questions

1. ~~Aggregate verdict.~~ **Resolved: `DiagnosticReport` carries one.** Not for
   a badge — that is still a non-goal — but because without it the report
   exposes only `checks`/`ranAt`, and `.running` and `.degraded` project
   identically. Mutating `unroutableNetworks` to `[]` in the runner left all 450
   tests green, so the wiring T-012 added is unpinnable as the type stands. An
   aggregate is the smallest surface that makes a degraded run observably
   different from a healthy one. See [F-013].
2. ~~Docker-context check seam.~~ **Resolved.** Doctor gets its own read-only
   check, built from pieces that already exist and already are pure:
   `DockerCLI.recordedSocketPath(for:)` (`DockerCLI.swift:152`, with an
   injectable `using:` variant at `:156` for tests) and
   `DockerContext.shouldRepairStaleRecord(...)` (`DockerContext.swift:63-75`,
   whose own comment states it is "not a reachability check"). Doctor must not
   reach `repairStaleContextRecordIfNeeded()`, which repairs as a side effect —
   a diagnostic that mutates while reporting is not a diagnostic. Cost: the
   fifth spawn in NFR-001.
3. Should v2's memory-commitment check sit behind its own button in the section
   rather than joining the automatic run?
4. `MemoryCommitment` verdicts (`.within` / `.approaching` / `.exceeding`) map
   onto `Verdict` awkwardly — is `.approaching` a `.warning`? Needed only when
   v2 brings this check to the UI, but the CLI mapping must be decided now to
   keep F-003 byte-identical.
5. Exact `CheckID` granularity for "versions": today the CLI prints API version,
   engine version, container count and image count as one block. One check or
   several?
6. ~~Presentation while a repair runs.~~ **Resolved at T-022 (spec-gaps decision
   9): a dedicated in-progress state.** The report is dropped when a repair
   starts and re-run when it settles. A sidebar restart shows the same state.
7. `repairStaleContextRecordIfNeeded()` is `private` and swallows its error in
   an empty `catch` (`RuntimeViewModel+DockerContext.swift:186-188`, comment:
   "Best-effort: retried on the next launch"). Doctor's button needs an outcome,
   so it must be extracted as something like
   `repairDockerContextRecord() async -> Bool`. Confirm that widening it is
   acceptable, since the empty catch was deliberate for the polled path.
8. Does the 20s total budget (NFR-002) apply to the CLI too? The CLI has no
   section to block and a human waiting at a prompt may prefer completeness
   over a deadline.
9. **Decided: `helperRunning` is false for any caller that did not itself launch
   the helper.** The flag means "a helper this caller launched is running", which
   is what the app passes (`runtimeProcess?.isRunning == true`,
   `RuntimeViewModel.swift:531`) — a `Process` handle it owns, `nil` whenever the
   bridge was started by launchd or a previous session. The runner launches
   nothing, from a CLI or from a freshly-opened section, so it passes `false`
   (`DiagnosticRunner.swift:54`) rather than scanning the process table. This
   makes the Doctor's inputs identical to the app's for every bridge the app did
   not launch. The process-table scan was actively wrong: it is read at
   `RuntimeState.swift:52`, reachable only when `socketResponds == false` and
   `failure == nil` — a bridge that answers but is unhealthy, since `ping()`
   returns false without throwing on a non-`OK` body
   (`DockerAPIClient+Resources.swift:186-189`). Against a launchd-started bridge
   that resolved `.starting`, which projects every check to `.skipped` with no
   remedy and, in the app, disables the manual restart (#44). The runner keeps
   measuring bridge ownership for the `foreignBridge` check, which is a separate
   question about who holds the socket.

## 9. Success criteria

One verdict instead of nine messages: CLI and UI produce the same answer for the
same state, proven by a test over a shared `DiagnosticReport`. A divergence
becomes a failing test rather than a user-visible bug.

Measured as: a single fixture set (transport responses plus two `ProbeResult`
values) drives both renderers; the CLI golden text and the `DoctorViewModel`
verdicts are asserted from that one report, over the check set both share.
