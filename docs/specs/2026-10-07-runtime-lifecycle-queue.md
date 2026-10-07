# Spec: one queue for runtime Start, Stop and Restart

Version: 0.6 (five Codex design reviews: 9, 3, 1, 1 and 1 findings, all taken)
Date: 2026-10-07
Issue: #102. Follows the #70/#71 fix (#105).

## 1. Overview

Six callers start, stop or restart the runtime, each as an independent task on the main actor:
the sidebar's Start, Stop and Restart, the Doctor's Restart Runtime, automatic recovery from the
3 s probe, the stale-bridge restart, and the launch-time start. They interleave at every await.
#105 held the line with an attempt number for starts, a Stop count bumped at both ends of a
Stop, and `guard !isRestarting`, each checked after the right await; five review rounds kept
finding the await nobody checked. One gap stayed open by design: a Stop clicked while a restart
runs returns at `guard !isRestarting`, and the restart goes on to `container system start`.

This spec replaces those guards with one queue that runs one operation at a time and lets the
user's last instruction win by construction. What each operation does once it runs does not
change.

## 2. Requirements

- **[F-001] One at a time, including a superseded one still draining.** At most one operation
  executes steps; at most one more waits. A superseded operation keeps the queue until it
  reaches its next checkpoint, so its CLI step never overlaps the next operation's.
  *Acceptance:* a pure `RuntimeLifecycleQueue` test drives every request order and origin; a
  scenario test holds Restart inside `container system stop`, clicks Start, and asserts
  `system start` runs only after `system stop` has returned; a helper test (§3.6) covers the
  other direction.
- **[F-002] The user's last instruction wins, and the loser publishes nothing.** A user request
  while another operation runs supersedes it: the running one stops at its next checkpoint and
  writes no state after it, and a refresh it started discards its results. A newer user request
  replaces a pending one.
  *Acceptance:* scenario tests: (a) Restart running, Stop clicked during `container system
  stop`: `system start` and the bridge launch never run and the runtime ends stopped;
  (b) Restart superseded while its post-restart refresh is collecting health, and (c) while it
  is fetching inventory, including a fetch that fails: that refresh publishes nothing at all —
  no inventory, no state, no error message.
- **[F-003] Automatic work never undoes a user instruction.** An automatic request names the
  generation it observed and is dropped if the generation has moved (§3.2), if a user request
  is pending, or if what runs is a Stop or a Restart.
  *Acceptance:* scenario tests, each one of the interleavings Codex reproduced on #105 and
  this one: a probe that began during a Stop and asks for recovery after it is dropped.
- **[F-004] Recovery keeps working while the runtime starts.** Automatic recovery may
  supersede a running Start, as today's `shouldAttemptRestart` ignores `isStarting` on purpose:
  a start whose API server is gone cannot finish without a restart.
  *Acceptance:* scenario test: Start in its socket wait, the probe proves the API server
  absent, the restart runs and the start ends without publishing.
- **[F-005] Repeats are idempotent.** A user request equal to the running, not superseded
  operation, or to the pending one, is dropped.
  *Acceptance:* queue test; the Doctor's two-taps test still passes.
- **[F-006] Every request settles exactly once.** Dropped settles at once as `.dropped`; a
  pending request that is replaced settles at once as `.superseded`; a running one settles as
  `.completed(Bool)` or `.superseded`.
  *Acceptance:* scenario test: Start running, the Doctor's Restart pending, the sidebar's Stop
  replaces it: the Doctor's call returns `.superseded` and its `repairing` ends.
- **[F-007] Callers keep their contracts.** `restartRuntime() -> Bool` stays for the Doctor;
  only `.completed(true)` is true. Automatic callers get the outcome itself:
  `completeAutomaticRuntimeRecovery` cleans up only after `.completed(false)`, never after a
  restart that was dropped or superseded.
  *Acceptance:* scenario test: recovery dropped while Start runs leaves Start's state alone.
- **[F-008] Stop is never disabled by a restart.** The sidebar's Stop stays enabled while a
  Start or Restart runs; it is disabled only while a Stop runs or waits.

## 3. Design

### 3.1 The queue

A value type holds the decision logic and nothing else, so every rule above is tested without
a process or an await:

```swift
enum RuntimeOperation: Equatable { case start, stop(replacingSibling: Bool), restart(replacingSibling: Bool) }
/// Why an operation was asked for. The automatic reasons differ in what they may supersede, so
/// the queue needs the reason, not just "automatic".
enum RuntimeOperationOrigin { case user, recovery, staleBridge, launch }

struct RuntimeLifecycleQueue {
    private(set) var generation: Int
    mutating func request(_: RuntimeOperation, origin: RuntimeOperationOrigin, observed: Int?) -> Admission
    mutating func finish(_ token: Int) -> Promotion?      // the pending request, if any, to run next
    func isCurrent(_ token: Int) -> Bool
}
enum Admission { case runNow(token: Int), queued(id: Int), dropped }
```

Supersession is not an admission of its own: it invalidates the running token at once and
queues the request. The superseded operation still holds the queue until its next checkpoint,
where it sees its token gone, returns, and calls `finish`, which promotes the request (F-001).

| request | idle | Start runs | Stop or Restart runs | user request pending |
|---|---|---|---|---|
| `user`, any | run | supersede it, queue | supersede it, queue | replace it |
| `recovery` Restart | run | supersede it, queue (F-004) | drop | drop |
| `staleBridge` Restart, `launch` Start | run | drop | drop | drop |

A request equal to the running, not superseded operation or to the pending one is dropped
(F-005).

### 3.2 Generation

`generation` changes when an operation begins **and when it ends**. An observation — a probe,
a container or stack action — records it before its first await. An automatic request carrying
that value is admitted only if nothing began or ended since; a probe that began during a Stop
therefore loses to the Stop's end, as the Stop count does today. Actions keep #105's rule with
the generation in place of the Stop count.

### 3.3 Running an operation

The view model owns the queue (`@ObservationIgnored`) and one entry point,
`run(_:origin:observed:) async -> RuntimeOperationOutcome`:

- `.runNow` runs the operation in the caller's task.
- `.queued` suspends the caller until `finish` promotes it, then runs it in the caller's task;
  or settles it `.superseded` if a newer request replaced it first (F-006).
- `.dropped` settles at once.
- A request that supersedes the running operation also bumps `inventoryEpoch` at once, so a
  refresh in flight discards what it collected (§3.5).

Every await inside an operation body is followed by `guard isCurrent(token)` before it writes
state or takes the next step: after the ping, after the version check, after each restart step,
after each tick of a socket wait. `container system stop` itself is not interrupted; the
checkpoint after it is where a superseded restart ends.

### 3.4 Nested lifecycle work runs under the caller's token

An operation that needs another lifecycle step does it in its own body, under its own token,
never by requesting it: Start adopting a stale bridge (`adoptBridgeIfStale`) restarts inline.
Requesting from inside an operation would either be dropped by the rules above — and
`hasCheckedBridgeIdentity` is already spent, so nothing would retry — or wait on itself.
Only callers outside an operation (the sidebar, the Doctor, the probe, launch) request.

The probe's own adoption marks the check done before it asks for the restart, and that request is
dropped while a Start runs. The check is then unmarked again: left spent, Start's inline adoption
would skip it and the outdated bridge would serve for the rest of the session. A restart that was
admitted keeps it spent, failed or superseded, as today's "at most once per launch" intends.
*Acceptance:* scenario test: the probe adopts the socket while Start waits on its ping, its
restart is dropped, and Start's inline adoption restarts the outdated bridge.

### 3.5 State

A refresh captures `inventoryEpoch` once, as it begins, and every publication it makes checks
that value: health, each inventory list, and the error branches. Today each inventory fetch
captures its own epoch, so a supersede during the images fetch discarded images and let the
containers fetch after it publish under the new epoch. The fetches take the refresh's epoch
instead; a fetch called on its own still captures one.

`isStarting` and `isRestarting` stay stored and observed. Only the current operation writes
them, behind its checkpoints, with the phases they have today: Start clears `isStarting` as soon
as it adopts an answering socket. When an operation ends or is superseded with nothing to run
after it, `settle()` clears both and re-resolves `runtimeState` from what is known. The queue's
own bookkeeping is unobserved, so the Doctor's `isRestarting` watcher sees only real edges.

### 3.6 Launch and wait is one step

Launching the helper and waiting for its socket — recording the bridge identity and marking the
identity check done on success — becomes one step inside the operation, shared by Start and by
Restart's `.startBridge`. The detached waiter goes away. Restart keeps its own socket wait only
for the LaunchAgent path, which launches nothing itself.

Ending the helper ends what it runs. The helper spawns its own `container system start`
(`ContainerStackRuntime.swift:131`), and SIGTERM to the helper left that child running, where it
could overlap the next operation's `system stop`. The helper now handles SIGTERM by ending its
bounded children (`ProcessRunner.terminateBoundedChildren`) before it exits; its exit status is
unchanged (that is #56). The handler is a dispatch signal source, because the helper's main
thread sits in a blocking wait, and it does not wait on anything: socktainer's wait is unbounded
by design.

That only holds if a child cannot slip between being started and being registered.
`ProcessRunner` starts a bounded child and then registers it (`ProcessRunner.swift:175`, `:190`);
a shutdown between the two drains an empty registry and the child outlives it. Starting and
registering become one step under the registry's lock: once shutdown has begun the child is
refused, otherwise it is started and registered before shutdown can drain. This also closes the
same window for the app's own `terminateBoundedChildren` at quit.

*Acceptance:* a test runs the built helper against a fake `container`
(`CONTAINERSTACK_CONTAINER_PATH`) whose `system start` sleeps, sends SIGTERM, and asserts the fake
is gone; a `ProcessRunner` test races shutdown against bounded spawns and asserts no child
survives.

### 3.7 What it replaces

| today | after |
|---|---|
| `startAttempts`, `beginStartAttempt`, attempt checks | the operation's token |
| `stopRequests`, `finishStopRequest`, `stoppedSinceProbeBegan` | `generation` (§3.2) |
| `guard !isRestarting` in Stop and Restart | admission (§3.1) |
| the detached `waitForRuntime(on:launch:)` | launch-and-wait inside the operation (§3.6) |

### 3.8 Origins

| caller | origin |
|---|---|
| sidebar Start, Stop, Restart; Doctor's Restart Runtime | `user` |
| probe-triggered recovery | `recovery` |
| stale-bridge restart from the probe | `staleBridge` |
| launch-time start | `launch` |
| stale-bridge restart from within Start | none: inline (§3.4) |

## 4. Test infrastructure

The steps an operation takes — `RuntimeControlStep`s, ending the helper, launch-and-wait, the
ping, the version check, `system status` — go behind one injectable value, defaulting to
today's code. Tests substitute steps that suspend at an actor-held gate (never a blocking wait:
that hung CI on #104), so a scenario can hold an operation at any await and click something
else. Stop and Restart then run whole in a test for the first time, without signalling the
machine's bridge.

## 5. Non-goals

- Interrupting a CLI step already running; it ends on its own deadline (`ProcessRunner`).
- Changing what Start, Stop or Restart do once they run.
- LaunchAgent behaviour on Stop (#56) and `cstack runtime start` (#57).

## 6. Decided

- **Stop during Restart ends the restart at its next checkpoint**, rather than letting it
  finish and then stopping, which would bring the runtime up for seconds only to take it down.
  The Stop itself waits for that checkpoint: a CLI step already running (up to 120 s) is not
  cut short.
- **A light spec**, this file, rather than the brainstorm → spec → plan cycle Doctor had: the
  change is internal and its behaviour is pinned by the #105 tests.

## 7. Delivery

One PR, each commit green on its own:

1. The step seam (§4), no behaviour change.
2. `RuntimeLifecycleQueue` and its table tests (§3.1, §3.2).
3. Atomic spawn-and-register, then the helper ending its children on SIGTERM, as two commits
   (§3.6).
4. One epoch per refresh (§3.5).
5. Start, Stop, Restart and the automatic callers through the queue, with launch-and-wait as one
   step; the replaced guards and the detached waiter removed (§3.3–§3.7). Launch-and-wait moved
   here from 3: under the attempt numbers it would have needed transitional rules for a Start and
   a Restart launching at once, which the queue makes impossible.
6. Scenario tests for every acceptance above.
