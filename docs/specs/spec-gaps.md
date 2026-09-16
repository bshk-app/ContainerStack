# Spec gaps: Doctor diagnostics

Date: 2026-09-11
Spec: docs/specs/current.md (v1.1)
Panel: 4 reviewers — requirements (Wiegers), architecture (Fowler), testing
(Crispin), operations (Nygard)

Every finding below was checked against the code before being accepted or
rejected. Reviewer claims that did not survive that check are listed too, with
the evidence, so nobody re-litigates them later.

**Ready to plan? YES** — but only after OQ-2 was closed. The first draft of this
file said YES while OQ-2 was still open, which was wrong: `dockerContext` is a
**mandatory** member of the UI check set (F-002), and its only existing entry
point repairs as a side effect of polling. A plan written against that would
have had to invent a seam or make the diagnostic mutate. OQ-2 is now decision 8
below; all five remaining open questions are genuinely optional.

---

## Accepted — folded into the spec

| # | Finding | Severity | Landed as |
|---|---|---|---|
| G-01 | `NFR-002` claimed 10s bounded the section. False: `health()` is three retried calls (`DockerAPIClient.swift:313,321,322`), `.timedOut` **is** retryable (`DockerRetryPolicy.swift:31-32`) at 3 attempts × 5s, and four probes at 10s run sequentially. Worst case ≈117s. | blocker | NFR-002 rewritten as a 20s **total** budget with concurrent probes, `requestRetryingImmediateFailures`, and unfinished checks → `.indeterminate` |
| G-02 | `F-007` promised cancellation. `ProcessRunner.run` is synchronous on a `DispatchSemaphore` (`:198`); `Task.cancel()` cannot interrupt a probe. | blocker | F-007 rewritten: single-flight + coalescing; leaving discards the *result*; generation counter only decides publication |
| G-03 | A wedged runtime is indistinguishable from a stopped one at the socket, so `F-010`'s "zero `.failure`" rendered an unusable system as all-grey. | blocker | `Verdict.indeterminate` added (amber, never grey); F-010 split into stopped → `.skipped`, wedged → `.indeterminate` |
| G-04 | `F-003`'s golden test had nowhere to live: `Package.swift` declares only `ContainerStackCoreTests` and `ContainerStackAppTests`; `doctor` prints; `dup2` capture is unsafe under swift-testing's in-process parallelism. | blocker | F-012: `DoctorTextRenderer.render(_:) -> String` in Core; CLI becomes `print(render(report))` |
| G-05 | `StubDockerTransport` cannot fail (`TestSupport.swift:19-25` always returns `responses.removeFirst()`) and **traps** on an exhausted queue, so F-009/F-010 and §5's transport-error row were unwritable. | blocker | New §7a: transport takes `[Result<Data, Error>]`, throws when exhausted, keyed by path |
| G-06 | `F-006` claimed `CaseIterable` + `sidebarHiddenItems` were enough. The sidebar iterates explicit `dockerItems` / `generalItems` lists, and **only `dockerItems` is filtered by `hidden`** (`AppChrome.swift:95-99, 117, 122`). Doctor next to Overview would not have been hideable. | blocker | F-006 names `dockerItems` membership as the mechanism |
| G-07 | Precedence was duplicated: `RuntimeState.resolve` already encodes `foreignBridge → detached → socket`, and F-004 restated it in the runner with no test failing when only one side changes. | major | F-004: resolve is called **once** and projected onto verdicts |
| G-08 | Acceptance criteria that pass while the requirement is violated: F-002 ("no `inspectContainer`" passes for a wrong set), F-009/F-010 (single-probe fixtures), NFR-001 (invariance without exact counts), NFR-002/004/005 (no acceptance clause at all). | major | Exact set equality, matrix tests, exact counts, explicit predicates |
| G-09 | Repair buttons had no guardrails: `restartRuntime()` returns `false` silently and runs to `lifecycleTimeout` (120s) with nothing said about the 2 minutes; `repairStaleContextRecordIfNeeded()` is `private` with an empty `catch` (`RuntimeViewModel+DockerContext.swift:186-188`). | major | F-008 binds to `canRestartRuntime`, shows in-progress, suppresses auto-rerun; OQ-7 resolved (see below) |
| G-10 | Automatic run had no throttle. `DiagnosticCadence` exists in this codebase precisely because spawning `container system status` per tick was a measured problem (~1200 spawns/hour). | major | F-011: 30s cadence + explicit "Check again" |

## Rejected — with the evidence

| Claim | Source | Why rejected |
|---|---|---|
| "CLI check set should be `allChecks`" | requirements review | `cstack doctor` has no bridge-ownership check and no context check (`context` is a separate subcommand, `CStackCommands.swift:279`). Passing `allChecks` would emit new lines and break F-003. The reviewer read the spec before commit `4e9843e`. The *underlying* point — assert exact set equality — was accepted. |
| "Choose between logic drift and an F-003 regression" | advisory note | A false dilemma in two ways. `RuntimeState.resolve` takes `foreignBridge` as a parameter, so passing `nil` for the CLI would keep one rule and one output — but that injects "unmeasured looks healthy" into the precedence computation, the same defect `.indeterminate` was added to prevent. The chosen option avoids both: the CLI genuinely measures bridge ownership now. |
| "`SystemProbe` should be split for interface segregation" | architecture review | Deferred, not rejected: it is one implementation with one lifetime, and four methods on it is not yet a burden. Recorded in `docs/plans/backlog.md` if it starts hurting. |
| "`Remedy` in Core leaks UI concerns" | considered, found fine | `Remedy` names capabilities (`restartRuntime`), not UI verbs; the CLI renders the same values as text. |

## Decisions taken (gated implementation)

1. **Precedence** — project a single `RuntimeState.resolve` call, and add
   `foreignBridge` to the CLI set. The CLI gains a real bridge warning; F-003
   sanctions that one diff.
2. **Cadence** — 30s throttle plus an explicit "Check again" button.
3. **Verdicts** — add `.indeterminate`, distinct from `.skipped`.
4. **Placement** — `.doctor` joins `DashboardDestination.dockerItems`.
5. **`MemoryCommitment.exceeding` → `.warning`** with a `.manual` remedy. Over-
   commitment is a risk, not a broken state; red on a working system devalues
   red. (Closes OQ-4.)
6. **"Host memory unknown" and failed `inspectContainer` → `.indeterminate`.**
   Both are measurement failures; the CLI text is unchanged, only the internal
   label. (Closes OQ-4's second half.)
7. **`repairDockerContextRecord() async -> Bool`** extracted from the private
   method. Polling keeps ignoring the result; Doctor renders failure. (Closes
   OQ-7.)
8. **Read-only docker-context check.** Doctor builds its own from
   `DockerCLI.recordedSocketPath(for:)` (`DockerCLI.swift:152`; injectable
   `using:` variant at `:156`) and the pure
   `DockerContext.shouldRepairStaleRecord(...)` (`DockerContext.swift:63-75`).
   It must not call `repairStaleContextRecordIfNeeded()` — a diagnostic that
   repairs while reporting is not a diagnostic. Costs the fifth spawn
   (`docker context ls`), so NFR-001 is now four spawns for the CLI set and
   five for the UI set. (Closes OQ-2.)

## Still open — do not guess during implementation

- **OQ-1** aggregate verdict / sidebar badge — deferred; a badge implies
  background runs, which are a non-goal.
- *(OQ-2 closed — see decision 8.)*
- **OQ-3** v2: memory commitment behind its own button in the UI.
- **OQ-5** `CheckID` granularity for "versions" (today one printed block).
- **OQ-6** presentation while a repair runs.
- **OQ-8** whether the 20s budget applies to the CLI, which has no section to
  block and a human waiting at a prompt.

## Note on process

The architecture reviewer wrote `docs/specs/reviews/review-architecture.md`
despite being told not to modify files. The content was kept; the instruction
breach is recorded here rather than silently accepted.
