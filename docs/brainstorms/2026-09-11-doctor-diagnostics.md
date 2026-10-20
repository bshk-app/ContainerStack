# Brainstorm: Doctor section in the UI

Date: 2026-09-11
Status: validated

## Problem

A user who suspects something is wrong has no single place to look. Warnings are
spread across nine separate message properties on `RuntimeViewModel`
(`runtimeFailure`, `runtimeMessage`, `containerMessage`, `resourceMessage`,
`stackMessage`, `errorMessage`, `imagesErrorMessage`, `containersErrorMessage`,
`serviceMessage`), each surfacing on its own screen.

The audience chosen for v1 is the preventive one: someone asking "is my
environment healthy?" — not someone already broken and demanding a repair, and
not us collecting a bug report.

A real diagnostic already exists, but only in the terminal. `cstack doctor`
(`Sources/CStackCLI/CStackCommands.swift:8-120`) checks the missing app root
first, then socket health, API/engine versions, storage path, container routes
via `NetworkRouteHealth`, and memory commitment — and it names a remedy
("Run: cstack runtime restart"). None of that is reachable from the app.

## Constraints

- `RuntimeViewModel.swift` is at exactly 690 lines on `main`, against
  `file_length: warning: 690` with `--strict`. Any line added to that file turns
  CI red. PRs #94 and #98 each fix this independently (to 664 and 644) but are
  unmerged. **Doctor must add nothing to `RuntimeViewModel.swift`.**
- The orchestration currently lives in `CStackCLI` and prints as it goes, so the
  app cannot reach it and no test can observe it.
- `CommandShell` (`Sources/CStackCLI/CStackRuntimeControl.swift:6`) is a
  non-injectable static `enum` in the CLI target. Core cannot import it.
- `DockerAPIClient` is a `public actor`, not a protocol. Tests already stub the
  layer below it (`DockerAPITransport` / `StubDockerTransport` in
  `Tests/ContainerStackCoreTests/TestSupport.swift`).
- The text output of `cstack doctor` must not change — it is the anchor of the
  parity test.

## Success criteria

One verdict instead of nine messages: CLI and UI produce the same answer for the
same state, proven by a test over a shared `DiagnosticReport`. A divergence
becomes a failing test rather than a user-visible bug.

## Chosen approach

### Core owns the logic, both surfaces render it

A pure value in `ContainerStackCore`:

```swift
struct DiagnosticCheck {
    enum Verdict { case ok, warning, failure, skipped }
    let id: CheckID       // .appRoot, .socket, .versions, .routes, .foreignBridge, .dockerContext
    let verdict: Verdict
    let summary: String
    let detail: String?
    let remedy: Remedy?   // .restartRuntime, .repairDockerContext, .manual(String)
}

struct DiagnosticReport { let checks: [DiagnosticCheck]; let ranAt: Date }
```

`DiagnosticRunner` assembles it and neither prints nor knows about SwiftUI.
`cstack doctor` becomes a formatter over the report. The UI renders the same
checks as rows: icon from `verdict`, `summary`, expandable `detail`, and a
button only where the remedy is executable in-process (`.restartRuntime` →
existing `restartRuntime()`; `.repairDockerContext` → existing repair).
`.manual` renders as text.

Check order is a rule, not cosmetics. `appRoot` leads because in that state the
socket answers `_ping` with 200 while `/info` fails, so every other check gives
a confidently wrong answer — already documented at `CStackCommands.swift:9-12`
and in `RuntimeState.resolve`.

### Placement and trigger

Doctor becomes a seventh `DashboardDestination` in the sidebar, next to
Overview (and therefore hideable via the existing `sidebarHiddenItems`
`@AppStorage`). The run starts automatically when the section opens.

That is affordable only because memory commitment is deferred: v1 costs one
`container system status` spawn, one `netstat -rn -f inet`, and two API calls
(`listContainers`, `listNetworks`) — no `inspectContainer` loop over running
containers.

### Failure modes

- **A stopped runtime is not six red rows.** Those checks are `.skipped` with a
  reason. Red is reserved for "should work and does not".
- **Each check catches its own error.** Today `try await client.health()`
  propagates and kills the whole CLI command; in the UI that would be a blank
  screen — a diagnostic failure that looks like the absence of problems.
- **Precedence is inherited from `RuntimeState.resolve`**: `foreignBridge` above
  `appRoot` above the socket branch. Under a foreign bridge the downstream
  checks are `.skipped`, because `missingAppRoot` describes the local runtime
  rather than whoever serves the socket, and would name the wrong remedy.
- **"Nothing to check" is not "could not check."** Already deliberately split in
  the code (#45): "no running container publishes ports" vs "could not read the
  routing table" are different strings, different icons, and the second is not
  a success.
- **Races.** The run is cancelled when the section closes and published under an
  epoch guard, per the #70 lesson. `.starting` does not flash red.

### Seams and testability

`DiagnosticRunner` takes the real `DockerAPIClient` built over
`StubDockerTransport` — the existing seam; no new protocol for the client.

The shell is the blocking gap. Doctor needs `container system status` and
`netstat -rn -f inet`, and `CommandShell.output` returns `""` on any failure via
`try?`. The two collapses are not equally harmful, and this was checked:

- `NetworkRouteHealth.canJudgeRoutes` is `!routes.trimmed.isEmpty`, so an empty
  string from a failed `netstat` already lands on "could not read the routing
  table" — the correct verdict.
- `RuntimeStatusParser.missingAppRoot("")` returns `nil` because `isRunning("")`
  is false. **A `container` binary that fails to spawn is indistinguishable from
  "the app root is fine."** That is the section-2 rule violated outright.

So the probe is typed, not stringly, and does not launder a process failure into
empty output:

```swift
public protocol SystemProbe: Sendable {
    func runtimeStatus() async -> ProbeResult   // .output(String) | .failed(reason)
    func routingTable() async -> ProbeResult
}
```

The production implementation lives in Core over `ProcessRunner.run`
(`Sources/ContainerStackCore/ProcessRunner.swift:104`, which throws
`ProcessRunnerError`), not over `CommandShell.output`. Tests supply fixture
strings and fixture failures. This is a precondition of testability, not
opportunistic refactoring.

UI state lives in a separate `@MainActor final class DoctorViewModel`
(`report`, `isRunning`, epoch counter). It implements no repair of its own.

The parity test: one fixture set (transport responses + two probe results) →
one `DiagnosticReport` → assert the `cstack doctor` text contains the expected
lines, and that the UI model exposes the same verdicts.

## Non-goals

- Memory commitment and the per-container `inspectContainer` loop (v2).
- New kinds of repair (restoring the app root, evicting a foreign bridge). A
  button appears only where the repair already exists and is proven.
- A "copy diagnostics for an issue" button. `DiagnosticReport` is serialisable,
  so it stays cheap later, but that was a different framing, rejected at the
  first question.
- Removing the nine existing message properties. Doctor does not replace the
  per-screen banners in v1.
- Changing the text output of `cstack doctor`.
- Killing or evicting a foreign bridge: the process is someone else's.

## Open questions

- Does `DiagnosticReport` need a single aggregate verdict for a sidebar badge,
  or is the row list enough for v1?
- Where should the docker-context check live, given that
  `repairStaleContextRecordIfNeeded()` currently runs as a side effect of
  polling rather than on demand?
- Should v2's memory-commitment check sit behind its own button inside the
  section, rather than joining the automatic run?
