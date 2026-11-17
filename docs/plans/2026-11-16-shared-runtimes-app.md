# Plan: shared runtimes, stage 2 (the app)

Date: 2026-11-16
Spec: `docs/specs/2026-11-15-shared-runtimes.md` (v0.3), requirements F-101 to F-105.
Frozen contracts: §3.1 (the file), §3.2 (labels and reasons), §3.2a (`/info`).
socktainer: stage 1 is merged in the fork at `524be88`. Its user doc is `docs/shared-runtimes.md`
at that commit.
App base: `origin/main` at `46b4374` (#140). Between `f3a7d47` and `46b4374` only
`scripts/publish-cask.sh` changed, so the file references below are valid for both.
Design: the design project "ContainerStack — onboarding". `Settings.dc.html` shows the section
"Shared Runtimes" as the card of step `shared` and a footer. `cs-data.js` (step `shared`) gives the
card rows and the text.

The owner decided the open questions of this plan on 2026-11-16 (§7). The spec v0.4 has the
decisions in F-101 to F-105 and a "Later" note.

Each assumption has the mark **[A]**.

## 0. Facts this plan depends on

These facts come from the code. A worker must not change them without a new decision.

1. The app pins socktainer `da018a5` (`scripts/prepare-v1-runtime.sh`, `SOCKTAINER_REV`). That
   commit has no stage 1. `da018a5` is an ancestor of `524be88`, so the pin bump is a fast-forward.
   socktainer gets `cs-session` as a SwiftPM dependency (`beshkenadze/cs-session` 0.1.0, product
   `CSSessionBinary`). The runtime script needs no new toolchain step **[A: confirm with one
   `prepare-v1-runtime.sh` run]**.
2. The helper (`Sources/ContainerStackRuntime/ContainerStackRuntime.swift`) and `cstack runtime`
   (`Sources/CStackCLI/CStackRuntimeControl.swift`) both start the bridge with
   `RuntimeProcessConfiguration.socktainerArguments`. Today the arguments are fixed:
   `--no-check-compatibility --no-docker-context --socket <path> --startup-housekeeping`.
3. "Restart Docker Bridge" runs `RuntimeOperation.restartBridge`, which restarts the helper. The
   helper computes the bridge arguments again at each start.
4. The helper can adopt a bridge that already runs (`RuntimeStartupPlanner` decision
   `.bridgeAlreadyRunning`). It does not know the flags of an adopted bridge.
5. socktainer reads the file again when the modification time of the resolved file changes. It
   resolves a symlink first. It reads the file at each `create` and at each `/info`.
6. socktainer's decoder is strict (`RuntimeGroupsDocument.decode`):
   - `version` must be 1. Another integer gives the cause `runtime-groups.json: unsupported version N`.
   - Unknown keys in the document, a group or a rule are an error.
   - `name`: ASCII `[a-z0-9-]`, 1 to 32 characters, unique. `kind`: `exec` or `pod`.
     `idleMinutes`: 0, 5, 10, 30 or 60. `enabled`: a boolean.
   - A rule has `group` and exactly one of `image` (a non-empty string) and `stdioSession: true`.
   - A rule that names a group that is not in `groups` is an error.
   - Each error gives the cause `runtime-groups.json does not parse: <detail>`.
7. `/info` with the flag has the label `containerstack.shared-runtimes=on|off`. When it is `off`,
   `Warnings` has `shared runtimes are off: <cause>`. Possible causes:
   - `the removal of shared containers of a previous run has not finished` (transient, at start);
   - `the removal of shared containers of a previous run did not finish within <limit>`;
   - the cleanup error text;
   - a file cause from item 6, or `runtime-groups.json cannot be read: <error>`.
   Without the flag `/info` has no such label.
   `on` does not mean that a group is enabled. A valid file with no enabled group is `on`.
8. The label `containerstack.shared.socket` holds the `--socket` value with `~` expanded. It is not
   standardized. The app passes an absolute path (`RuntimeProcessConfiguration.socketPath`), so the
   app compares the label with that string, byte for byte.
9. A session is in `/containers/json` with its own ID. Its shared container is in the list too.
   On a session, `exec`, `archive`, `restart` and each other unsupported route return 409. `start`
   of a session that has started is not a supported user action. `inspect` returns no
   `HostConfig.Memory` **[A: the fork doc lists the fields of `inspect` and memory is not one]**.
10. The app's `DockerInfo` decodes no `Labels` and no `Warnings` today.
11. No Welcome window and no onboarding code exist in the app. The onboarding step is outside F-101
    to F-105 (see §7, decision 6).
12. The fork doc at `524be88` has no "Known limits" section. The case that the task names (SIGTERM
    while a shared container is being created leaves a stopped container) is not written in the
    fork. The spec covers it in F-015 and F-012: what the shutdown does not remove, the next start
    removes. F-105 covers the start without the flag. The fork doc gets a "Known limits" paragraph
    (§7, decision 8).

## 1. F-101: the bridge flag

### Decision (owner, 2026-11-16)

**The app passes `--shared-runtimes` only when the file needs it.** The rule:

| File state | Flag |
|---|---|
| Missing | No |
| Parses, and no group has `enabled: true` and `kind: "exec"` | No |
| Parses, and at least one group has `enabled: true` and `kind: "exec"` | Yes |
| Does not parse, has an unknown version, or cannot be read | Yes |

Reasons:

- F-014 and the owner's decision "both groups off by default". A user who never turns on a group
  runs no code of the feature. With the flag, every `create` waits for the cleanup at start
  (`SharedRuntimeService.admission()`), and every shutdown spends up to 400 ms on deletes. The user
  who did not opt in gets no benefit from these costs.
- An enabled group needs the flag. A change of the flag needs a restart of the bridge. The app
  already has "Restart Docker Bridge" and the Settings pattern "Saved. … after a Docker bridge
  restart." The restart is needed only on the change from "no flag" to "flag". A change of the
  idle time, of a pattern, or to "all groups off" needs no restart, because the bridge reads the
  file again.
- A file that does not parse gets the flag. Then socktainer reports the cause in `/info`, and
  Doctor shows the same cause that socktainer uses. The app does not guess the user's intent.

The cost of this choice: turning on the first group needs one restart. That restart interrupts
open builds, exec sessions, runner jobs and the sessions of other groups (there are none in this
case, because no group was on). The other choice, "always pass the flag", needs no restart. It
makes F-105 dead code in the normal case, and it runs the new code for all users of 1.0.0. The
owner chose "only when needed" (§7, decision 1).

### Files

| File | Change |
|---|---|
| `Sources/ContainerStackCore/RuntimeGroupsFile.swift` (new) | Codec and path of the file (F-102 uses it too). |
| `Sources/ContainerStackCore/SharedRuntimesFlag.swift` (new) | `SharedRuntimesFlag.needed(for: RuntimeGroupsFile.State) -> Bool`. The table above. |
| `Sources/ContainerStackCore/RuntimeProcessConfiguration.swift` | `socktainerArguments` gets the flag from a stored `sharedRuntimes: Bool`. `make(…)` gets a parameter `sharedRuntimes: Bool` with the default `false`. |
| `Sources/ContainerStackRuntime/ContainerStackRuntime.swift` | Reads the file once at start, calls `SharedRuntimesFlag.needed`, passes the result to `make`. Prints one line to `runtime.log`: `Shared runtimes: flag on` or `off`. |
| `Sources/CStackCLI/CStackRuntimeControl.swift` | `runtimeConfiguration(socketPath:)` uses the same rule, so `cstack runtime start` starts the same bridge as the helper. |

The rule is in Core, so the helper and the CLI cannot differ (DRY).

### Acceptance (unit, no runtime)

- `RuntimeProcessConfigurationTests`: the arguments without the flag are byte-equal to today; with
  `sharedRuntimes: true` they end with `--shared-runtimes`.
- `SharedRuntimesFlagTests`: one test for each row of the table. The fixture
  `runtime-groups.v1.json` gives "no flag". A copy with `mcp-catalog` enabled gives "flag". A copy
  with only a `pod` group enabled gives "no flag". A file with an unknown key gives "flag".

### Live check (this Mac or alex-mac)

- With no file: `ps -o command= -p <bridge pid>` has no `--shared-runtimes`. `docker info` has no
  `containerstack.shared-runtimes` label.
- Turn on `mcp-catalog` in Settings, restart the bridge: the process has the flag, and `docker info`
  shows `containerstack.shared-runtimes=on`.

## 2. F-102: Settings › Shared Runtimes

### The codec: `RuntimeGroupsFile` (Core)

Types:

```swift
public struct RuntimeGroupsDocument: Equatable, Sendable   // version, groups, rules
public struct RuntimeGroup: Equatable, Sendable            // name, kind, idleMinutes, enabled
public enum RuntimeGroupRule: Equatable, Sendable          // .image(group:pattern:), .stdioSession(group:)
public enum RuntimeGroupsFile {
    public enum State: Equatable, Sendable {
        case missing                       // defaults apply
        case valid(RuntimeGroupsDocument)
        case invalid(cause: String)        // the same text as socktainer's cause
    }
    public static func url(home: URL) -> URL              // ~/.containerstack/runtime-groups.json
    public static func read(at: URL) -> State
    public static func decode(_ data: Data) throws -> RuntimeGroupsDocument
    public static func encode(_ document: RuntimeGroupsDocument) -> Data
    public static func write(_ document: RuntimeGroupsDocument, to: URL, expecting: Date?) throws
}
```

Rules:

1. **The decoder is as strict as socktainer's (§0 item 6).** It gives the same error texts, so the
   Settings text and the `/info` cause agree. The app does not decode the file with `Codable`.
   `Codable` ignores unknown keys, and an unknown key is an error in socktainer. The app parses
   with `JSONSerialization`, as socktainer's `SharedRuntimeJSON` does: a `CFBoolean` is a boolean,
   an `NSNumber` of an integer type is an integer, each other number is not an integer. So
   `"idleMinutes": 10.0` and `"enabled": 1` are errors in both.
2. **The fixture is shared.** Copy `Tests/socktainerTests/Resources/runtime-groups.v1.json` from
   the fork at `524be88` into `Tests/ContainerStackCoreTests/Fixtures/`, byte for byte. A test
   decodes it and compares it with `RuntimeGroupsDocument.defaults`.
3. **The editor changes the parsed document, not a UI model.** A change sets one field of one
   group and keeps all other content: rules that the UI does not show, `pod` groups, groups that the
   UI does not know, and the order of groups and rules.
4. **The app never writes over a file that does not parse.** For `.invalid` the controls are
   disabled and Settings shows the cause. The user repairs the file by hand, or uses "Reset to
   Defaults" (see below).
5. **The app does not create the file at launch.** It creates the file at the first change in
   Settings: the default document with that one change.
6. **Atomic write.** Encode, write a temporary file in the same directory, rename it over the
   target. Use `Data.write(to:options: .atomic)` on the resolved path, as
   `ContainerConfigFile.save` does. A symlink stays a link. The rename gives the file a new
   modification time, so socktainer reads it at the next `create`. Create `~/.containerstack`
   when it is missing (mode 0700 **[A]**).
7. **Lost update.** Read the file and its modification time when Settings appears and after each
   write. Before a write, read the time again. If it changed, read the file again, apply the one
   change to the new document, and write. If the new file does not parse, do not write; show the
   cause.
8. **Encoding.** Two-space indent, keys in the order of §3.1, one group or rule per line, as the
   default document. Stable output gives a readable diff when the user opens the file. **[A]**
9. **Reset to Defaults** writes the default document. It shows a confirmation, because it removes
   the user's hand edits. The button shows only when the file is not valid (spec F-102; §7,
   decision 5).

### The `/info` cause

Foundation task (§5, W1-a): `DockerInfo` decodes `Labels` (`[String]`, `key=value` items) and
`Warnings` (`[String]`). A helper type in Core:

```swift
public enum SharedRuntimesStatus: Equatable, Sendable {
    case notRunning                 // no label: the bridge runs without the flag
    case on
    case off(cause: String)         // text after "shared runtimes are off: "
    case starting                   // off, with the transient cause of §0 item 7
}
public static func parse(info: DockerInfo) -> SharedRuntimesStatus
```

- `.starting` comes from one exact cause text. The app does not show it as an error. It asks
  again at the next health refresh.
- The app reads the status from the `/info` that its health refresh already fetches
  (`DockerAPIClient.health()`). `RuntimeViewModel.snapshot` keeps it, so the Settings model reads
  `model.snapshot?.info`. There is no new request and no change to a `RuntimeViewModel*` file.
- A `nil` snapshot (the bridge does not answer) is not `.notRunning`. The app then shows no status
  and offers no restart for shared runtimes.

### The view model: `SharedRuntimeSettings` (App)

`Sources/ContainerStackApp/SharedRuntimeSettings.swift` (new). `@MainActor @Observable`, as
`ContainerResourceSettings`.

- State: `fileState`, `problem: String?`, `bridgeStatus: SharedRuntimesStatus`.
- `setEnabled(_:group:)`, `setIdleMinutes(_:)` (writes the value to both groups; §7, decision 2), `resetToDefaults()`, `reload()`.
- `awaitsBridgeRestart`: `SharedRuntimesFlag.needed(fileState) && bridgeStatus == .notRunning`.
  It is true only on the change from "no flag" to "flag".
- `bridgeProblem: String?`: the cause from `.off(cause:)`, shown under the section.

### The view

In `SystemSettingsView` (`ContainerResourceViews.swift`), one new `Section`, header
"Shared Runtimes". From the design (`cs-data.js`, step `shared`):

- Toggle `mcp-catalog`, subtitle "Images mcp/*".
- Toggle `stdio-sessions`, subtitle "Plain docker run -i --rm sessions".
- Picker "Stop when idle for": Never, 5, 10, 30, 60 minutes. It writes the value to both groups.
  When the two groups have different values, it shows "Mixed".
- Footer: "A matching docker run -i --rm runs in one shared VM. Sessions of one group share one
  container, so they are one trust domain. A run with a TTY, mounts, ports or limits gets its own
  VM." Then "Saved immediately in <path>."
- When the file does not parse: the controls are disabled, the cause shows in red (as
  `settings.problem` today), and the "Reset to Defaults" button shows.
- When `bridgeProblem` is set: the cause shows in red under the controls.
- The existing restart section shows when `awaitsBridgeRestart` of any of the three settings is
  true. Its text gets one more case: "Shared runtimes start after a Docker bridge restart."

The section has no editor for the image pattern and no "add group" control. An idle time for each
group and groups with a user pattern are "Later" in the spec (§7, decision 2).

### Acceptance (unit, no runtime)

`Tests/ContainerStackCoreTests/RuntimeGroupsFileTests.swift`:

- The fixture decodes and is equal to the defaults; it encodes and decodes to the same value.
- One test for each error class of §0 item 6, with the exact cause text: unknown key at each of
  the three levels, unknown version, bad name, duplicate name, bad `idleMinutes`,
  `"idleMinutes": 10.0`, `enabled` that is not a boolean, `"enabled": 1`, a rule with two conditions, `stdioSession: false`, an empty pattern, a rule with an
  unknown group, not JSON.
- An edit keeps an extra rule, a `pod` group and the order.
- A write into a symlink keeps the link and changes the target.
- A write when the file changed on disk applies the change to the new content.
- A write when the file on disk does not parse throws and leaves the file unchanged.
- `SharedRuntimesStatus.parse`: no label, `on`, `off` with each cause text of §0 item 7, the
  transient cause.

`Tests/ContainerStackAppTests/SharedRuntimeSettingsTests.swift`: with a temporary home directory,
a missing file gives both toggles off and no file is created; one toggle creates the file;
`awaitsBridgeRestart` for each pair of (flag needed, bridge status).

### Live check (UI, needs a person or alex-mac)

- The section looks and works as the design in light and dark. The offscreen harness can show
  colors and rows only. Toggle focus, the popup and the window layout need the running app.
- Turn on `mcp-catalog`, restart the bridge, run the check 2 of the fork doc (`mcp/time` with no
  label): one session in a shared container.
- Write a bad key into the file by hand: Settings disables the controls and shows the cause;
  `docker info` shows the same cause.

## 3. F-103: Containers shows groups and sessions

### Model (Core)

`Sources/ContainerStackCore/ContainerGroup.swift`:

- `DockerContainerSummary` gets computed values (in `DockerAPIClient.swift`, foundation task
  W1-a): `sharedGroup` (`containerstack.shared.group`), `sharedSocket`, `sessionGroup`,
  `sessionContainerID` (`containerstack.session.container`), `skippedGroup` (the parsed
  `containerstack.group.skipped`: group and reason), `isSession`, `isSharedContainer`.
- `ContainerGroup` gets a kind:

  ```swift
  public enum Kind: Equatable, Sendable {
      case compose(project: String)
      case shared(container: DockerContainerSummary)   // the header row; containers = sessions
      case standalone
  }
  ```

  `project` stays as a computed value, so callers that read it do not change. `id` changes: today
  it is `project ?? "__standalone"`, so each shared group would get the standalone id. The new
  `id` is `compose:<project>`, `shared:<container id>` or `__standalone`. `ForEach`, the
  `collapsed` set of `ContainersView` and `withResource(group.id)` use it.
- `grouped(_:)`:
  1. A shared container makes one `.shared` group. Its containers are the sessions whose
     `sessionContainerID` equals its `id`.
  2. A session whose shared container is not in the list goes to `.standalone`. This happens for a
     short time while the container starts. **[A]**
  3. A shared container is never a row of `.standalone`.
  4. Order: compose groups, then shared groups by group name and container name, then standalone.
- `ResourceSearch.containerGroups` (`AppChrome.swift`) rebuilds `ContainerGroup` from `project`.
  It must keep the kind. A search that matches the shared container name keeps the group with all
  its sessions. A search that matches a session keeps the group with that session.
- `SkippedReason`: maps each reason of §3.2 to a sentence. Examples: `tty` → "The run has a TTY.",
  `mount` → "The run or its image has a mount or a volume.", `option:<field>` → "The run sets
  <field>." An unknown reason shows as it is.

### View (App)

- `ContainersView.swift`, `ContainerGroupHeader`: for `.shared`, the title is the group name, the
  subtitle is the container name, and the count is "N sessions". The header has no Up, Down or
  Restart. It has Stop only: a confirmation names the number of sessions that Stop ends ("Stop
  <name>? This ends N sessions."). It has no Start and no Delete (§7, decision 3). The bridge
  removes the container at the idle limit.
- `ContainerRow`: for a session, only Stop and Logs. No Start, no Delete. The same applies in
  `DashboardView` ("Recent containers" uses `ContainerRow`).
- `ContainerInspector.swift`:
  - For a session: header actions Stop only (no Start, Restart or Delete). The Info tab gets the
    row "Shared container" (name, from `sessionContainerID`) and "Group". The Ports tab is hidden.
  - For a shared container: the Info tab gets "Group" and "Sessions: N".
  - For a run with `containerstack.group.skipped`: the Info tab gets "Shared runtime: not used —
    <group>: <sentence>".
- `RuntimeViewModel+Resources.swift`, `start(group:)` and `stop(group:)`: not offered for a
  `.shared` group (the header has no such buttons). Guard them, so a session never gets `start`.

### Acceptance (unit, no runtime)

`Tests/ContainerStackCoreTests/ContainerGroupTests.swift`, with `DockerContainerSummary` fixtures
decoded from Docker API JSON that carries the §3.2 labels:

- One shared container and two sessions give one `.shared` group with two rows, and the shared
  container is not a standalone row.
- Two shared containers of one group give two groups.
- A session with a missing shared container is standalone.
- The ids of two shared groups, one compose group and the standalone group are all different.
- The actions of a `.shared` header are Stop only, and the confirmation text names the number of
  sessions. A session row offers Stop and Logs only.
- Compose and standalone groups do not change (the existing tests pass unchanged).

`ResourceSearchTests`: the search keeps the kind; a search by session name keeps the group.
`SkippedReasonTests`: each reason of §3.2 has a sentence; `option:Privileged` names the field.

### Live check (UI, needs alex-mac)

The group header, the row actions, the inspector rows and the list focus change the list layout.
The offscreen harness does not show list focus or the toolbar. Check in the running app on
alex-mac:

- Three sessions of `mcp/time` show as one group with three rows. Stop on a row ends that session
  only. Logs shows its output.
- A run with `-t` and a label from a rule shows the skipped reason in the inspector.

## 4. F-104: Doctor memory check

### Files

The memory check is CLI-only (`CheckID.cliSet`; it costs one `inspect` per running container, and
NFR-001 forbids that cost in the app). So F-104 changes `cstack doctor` only. The Doctor view of
the app does not show the line.

- `Sources/ContainerStackCore/DiagnosticRunner.swift`, `memoryMeasurement`: before it asks each
  container for its memory limit, it removes the sessions from `running`. A shared container stays
  and is counted one time, as each dedicated container. Sessions get no `inspect`, so they cannot
  add to `containersWithoutLimit` or to the failures.
- `Sources/ContainerStackCore/MemoryCommitment.swift`: two new fields, `sessions: Int` and
  `sharedContainers: Int`, default 0. `measure(…)` takes them as parameters.
- `Sources/ContainerStackCore/DiagnosticRunner+Projection.swift`, `trailingLines`: when
  `sessions > 0`, one more line: "N sessions in M shared containers". The line has no verdict of
  its own. The numbers count running sessions and running shared containers.

### Acceptance (unit, no runtime)

In `DiagnosticRunnerMemoryTests` (fake client): a listing with one shared container (limit 8 GiB), three
sessions and one dedicated container (limit 2 GiB) gives `configuredBytes` 10 GiB,
`containersWithoutLimit` 0, no `inspect` for a session, and the line "3 sessions in 1 shared
containers". A listing with no sessions gives the same text as today (the existing tests pass
unchanged).

Text: "3 sessions in 1 shared containers" is not good English. The plan uses
"3 sessions in 1 shared container" for M = 1 and "… shared containers" for M > 1. **[A: the spec
gives the text with "N" and "M" only.]**

### Live check

`cstack doctor` on alex-mac with three sessions shows the line, and the total is the total of the
dedicated case minus two VMs.

## 5. F-105: leftovers when the bridge runs without the flag

### The cleanup

When socktainer runs with the flag, it removes its own leftovers at start (F-012). Without the
flag it runs no code of the feature (F-014). The app removes the leftovers in that case.

Rule (one rule for all start paths): **after the bridge answers, if `/info` has no
`containerstack.shared-runtimes` label, force-remove each container (`all=1`) whose
`containerstack.shared.socket` label equals our socket path.**

- The rule reads `/info`, not the argument list. So it is also correct for an adopted bridge
  (§0 item 4): an adopted bridge with the flag owns those containers and they are not touched; an
  adopted bridge without the flag gets the cleanup.
- `all=1`: the leftover can be a stopped container (the creation that SIGTERM interrupted, §0
  item 12).
- It never removes a container with another socket label. The live check of the fork uses a second
  bridge with its own socket.
- It removes with `DELETE /containers/<id>?force=1` (`DockerAPIClient.removeContainer(id:force:)`).
  Without the flag the bridge treats the shared container as a normal container.
- A failure of one delete does not stop the others. Each result goes to `runtime.log`:
  `Removed shared container <name> left by an earlier bridge.` or `Could not remove … : <error>`.
- A failed `/info` is not "no label". When `/info` fails or does not decode, the sweep removes
  nothing and writes one line to `runtime.log`. (`RuntimeState` documents a state where the ping
  answers and `/info` fails.)
- It runs one time per bridge start, in a detached task, as `startBuilderIdleMonitor`. It waits
  for the socket with the existing wait helper, with a limit of 60 s.

Files:

| File | Change |
|---|---|
| `Sources/ContainerStackCore/SharedContainerSweep.swift` (new) | `SharedContainerSweep.leftovers(in: [DockerContainerSummary], socketPath:, status: SharedRuntimesStatus) -> [DockerContainerSummary]` (pure) and `run(client:socketPath:log:) async` (list, read `/info`, delete). |
| `Sources/ContainerStackRuntime/ContainerStackRuntime.swift` | Starts the sweep on the paths `.startBridge`, `.removeStaleSocket` and `.bridgeAlreadyRunning`. |
| `Sources/CStackCLI/CStackRuntimeControl.swift` | No change. The CLI starts a detached bridge with no supervisor. The next helper start runs the sweep. **[A]** |

### The Doctor check

New `CheckID.sharedRuntimes`, title "Shared runtimes" (`DiagnosticReport.swift`). It uses the
container listing that the routes and memory checks already fetch, and the `/info` of the versions
measurement. No new request on the normal path.

| Case | Verdict | Summary |
|---|---|---|
| No label in `/info` and no shared container in the list | ok (or skipped **[A]**) | "Shared runtimes: off" |
| Label `on` | ok | "Shared runtimes: on" |
| Label `off`, transient cause | indeterminate | "Shared runtimes: starting" |
| Label `off`, other cause | warning | "Shared runtimes are off: <cause>" |
| A shared container that no bridge owns | warning | "N shared containers have no bridge: <names>" |

"No bridge owns it" means one of:

1. Its socket label is our socket, and `/info` has no label (our bridge runs without the flag).
   The sweep missed it or failed.
2. Its socket label is another path, and that socket does not answer `GET /_ping` within 1 s.
   **[A: a live socket of another bridge means that bridge owns it; the check does not look at the
   other bridge's flags.]**

Remedy: `.manual("docker rm -f <names>")`. Doctor shows the command and has no button for it
(§7, decision 4).

The check goes into both sets, `CheckID.uiSet` and `CheckID.cliSet`. It costs no `inspect`: it
reads the listing and `/info`, which both sets already fetch for `routes` and `versions`. So the
app's Doctor shows the leftover report and the `/info` cause. The other socket's ping (case 2) is
the only new request, and only when such a container exists.

Files that the new case touches: `DiagnosticReport.swift` (case, title, both sets),
`DoctorTextRenderer.swift` (its fixed order list), `DiagnosticRunner.swift` (measurement),
`DiagnosticRunner+Projection.swift` (projection), `DiagnosticRunner+Verdicts.swift` (it
names checks by `CheckID`), `DoctorViewModel.swift` (its "all passed" test reads `uiSet`; a `skipped` or
`indeterminate` shared-runtimes row must not block "all passed" **[A]**). `DoctorView.swift`
switches over the verdict, not over `CheckID`, so it does not change. Tests:
`CheckIDSetsTests`, `DoctorTextRendererTests`, `DiagnosticRunnerTests`.

### Acceptance (unit, no runtime)

- `SharedContainerSweepTests.leftovers`: our socket and no label → removed; our socket and label
  `on` → kept; other socket → kept; a stopped container with our socket → removed; a session (no
  socket label) → kept.
- `SharedContainerSweepTests.run` on a fake client: one delete fails, the next delete still runs.
- `DiagnosticRunnerTests`: one test for each row of the Doctor table, and both "no bridge" cases.

### Live check (this Mac, second bridge, no change to the user's bridge)

On a second bridge with its own socket (`/private/tmp/cs-live/docker.sock`, as in the fork doc):
start with the flag, make one session, send SIGKILL to the bridge, start it again without the
flag, run the sweep against that socket from a test build. The shared container is gone. Doctor
pointed at that socket reports the leftover before the sweep.

## 6. Waves

Disjoint files in each wave. A wave starts when the waves before it are merged.

### Wave 0 (one worker, blocks all)

- **W0: pin.** `scripts/prepare-v1-runtime.sh`: `SOCKTAINER_REV` `da018a5` → `524be88`. Run the
  runtime build and `stage-containerstack-app.sh` once. Live: `docker info` has no shared label
  (F-014). Safe without stage 2 (spec §7).

### Wave 1 (three workers, in parallel)

- **W1-a: API foundation.** `DockerAPIClient.swift` (`DockerInfo.labels`, `warnings`; the label
  helpers on `DockerContainerSummary`), `SharedRuntimesStatus.swift` (new). Tests:
  `DockerAPIClientTests` decode, `SharedRuntimesStatusTests`.
- **W1-b: file codec and flag rule.** `RuntimeGroupsFile.swift`, `SharedRuntimesFlag.swift`
  (new), the fixture. Tests: `RuntimeGroupsFileTests`, `SharedRuntimesFlagTests`.
- **W1-c: skipped reasons.** `SkippedReason.swift` (new, Core) and its tests. Pure, no other file.

### Wave 2 (four workers, in parallel, after W1)

- **W2-a: F-101 flag.** `RuntimeProcessConfiguration.swift`, `ContainerStackRuntime.swift`
  (flag only), `CStackRuntimeControl.swift`, their tests. Uses W1-b.
- **W2-b: F-102 Settings.** `SharedRuntimeSettings.swift` (new), `ContainerResourceViews.swift`,
  `ContainerStackApp.swift` (creates the settings object). Uses W1-a, W1-b. **UI: live visual check
  needed.**
- **W2-c: F-103 Containers.** `ContainerGroup.swift`, `AppChrome.swift` (`ResourceSearch`),
  `ContainersView.swift`, `ContainerInspector.swift`, `DashboardView.swift`,
  `RuntimeViewModel+Resources.swift`, their tests. Uses W1-a, W1-c. **UI: live visual check on
  alex-mac needed (list layout, focus, inspector).**
- **W2-d: Doctor (F-104 and the F-105 check).** `MemoryCommitment.swift`, `DiagnosticRunner.swift`,
  `DiagnosticRunner+Projection.swift`, `DiagnosticRunner+Verdicts.swift`, `DiagnosticReport.swift`,
  `DoctorTextRenderer.swift`, `DoctorViewModel.swift`, their tests. One worker, because all these files are in one pipeline.
  Uses W1-a.

### Wave 3 (one worker, after W2-a)

- **W3: F-105 sweep.** `SharedContainerSweep.swift` (new), `ContainerStackRuntime.swift` (sweep
  start). It is after W2-a because both change `ContainerStackRuntime.swift`.

### Wave 4: live check and docs

- The live checks of §1 to §5 on this Mac (second bridge) and on alex-mac (UI).
- `docs/` user text for Settings › Shared Runtimes, and a CHANGELOG line through release-please.

Each wave ends with an independent review of the staged diff and `task test`.

## 7. Decisions and risks

### Decisions (owner, 2026-11-16)

The owner took each recommendation of this plan.

1. **The flag.** The app passes `--shared-runtimes` only when the file has an enabled group, or
   when the file is not valid (§1). With no enabled group the bridge runs without the flag.
   Turning on the first group needs one bridge restart; Settings has the button for it.
2. **Idle time and groups.** 1.0.0 follows the design: two group toggles and one idle time. The
   popup writes the same value to both groups. When the file has two different values (a hand
   edit), the popup shows "Mixed" until the user picks a value. An idle time for each group and
   groups that the user adds with an image pattern are "Later" in the spec. A user who needs them
   edits the file by hand.
3. **The shared container row.** It has Stop only, with a confirmation that names the number of
   sessions that it ends. No Delete and no Start (§3).
4. **A shared container that no bridge owns.** Doctor shows `docker rm -f <name>`. There is no
   button (§5).
5. **A file that is not valid.** Settings shows "Reset to Defaults" with a confirmation (§2,
   rule 9).

Decisions of the plan review (no owner question):

6. **The onboarding step** goes to the onboarding work. No Welcome window exists in the code. The
   step "Shared runtimes" ("New in 1.0.0") is built there, after W2-b, with `SharedRuntimeSettings`
   as its model. Stage 2 does not wait for it.
7. **The memory line** "N sessions in M shared containers" is in `cstack doctor` only, because the
   memory check is CLI-only (§4). The text uses the singular for one container.
8. **"Known limits" in the fork doc.** The fork gets one paragraph in `docs/shared-runtimes.md`:
   SIGTERM while a shared container is being created leaves a stopped container; the next start
   with the flag removes it (F-012); the app removes it when the bridge runs without the flag
   (F-105). This is a docs task in the fork, outside the waves of this plan.

### Risks

- **Decoder drift.** If socktainer changes its decoder, the app's text and the `/info` cause
  differ. Mitigation: the shared fixture; the Settings view shows the `/info` cause too when the
  bridge runs with the flag.
- **The restart interrupts work.** Turning on the first group restarts the bridge. The existing
  restart text names what it interrupts. Turning a group off needs no restart.
- **Rows that return 409.** Any new per-row action on a session returns 409. W2-c lists the
  actions that a session has; a test asserts that a session row offers only Stop and Logs.
- **Clock and modification time.** socktainer compares the exact modification time. An atomic
  rename always gives a new inode and a new time, so two writes in one second are both seen.
  **[A: APFS keeps nanoseconds.]**
- **A file outside the home.** The bridge reads `~/.containerstack/runtime-groups.json` of the user
  that runs it. The helper runs as the same user as the app. **[A]**
- **The sweep and a user's container.** The sweep removes only containers with the label
  `containerstack.shared.socket` equal to our socket. A user who sets that label by hand loses the
  container. Accepted.
