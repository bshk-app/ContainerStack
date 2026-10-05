# Doctor diagnostics — execution progress

Branch: `feat/doctor-diagnostics`, worktree `/Volumes/DATA/cs-doctor`.
Baseline: `9834af8`. Loop: one worker per task, reviewer green-loop after each.

## Done

| Task | Worker | Reviewer | Rounds |
|---|---|---|---|
| T-001 stub transport can fail | `6d1c6ad` | `eabf880` | 4 |
| T-002 responses keyed by path | `d180b63` | `d568372` | 2 |
| T-003 report value types | `44933a0` | `5e7fce7` | 4 |
| T-004 SystemProbe + fakes | `51e18ec` | `9f66fbc` | 1 |
| T-005 production probe | `55064dd` | `a9872c7` | 2 |
| T-006 runner skeleton | `7dcf9a9` | `390e66a` | 2 |
| T-007 named check sets | `2efc759` | — (no findings) | 1 |
| T-008 precedence projection | `2504561` | `aa610b0` | 2 |
| T-009 app-root payload | `9a2a04c` | `0097c75` | 1 |
| T-010 probe failure ≠ healthy | `1f09424` | — (no findings) | 2 |
| T-011 socket + versions | `e95622c` | `5f06041` | 1 |
| T-012 routes | `c06bd74` | `5890add` | **5 — budget exhausted** |

Tests: 335 → **402** Core, 48 App, 0 failures, 1 known issue.
Gates green throughout. `RuntimeViewModel.swift` untouched (NFR-003).

## Stopped here

The T-012 reviewer exhausted its 5-round budget and handed off. Per the
subagent-driven protocol the loop stops rather than spending more rounds.

## Open, needing a decision rather than a patch

1. **F-003 is not achievable as written.** It promises byte-identical `cstack
   doctor` output with exactly one sanctioned difference. But today's CLI
   *aborts* whenever a measurement fails — `try await client.health()`
   (`CStackCommands.swift:31`) and `listNetworks()` (`:51`) throw out of the
   command. Every state where the Doctor reports "could not measure" therefore
   has no CLI counterpart to match. Four invented lines exist so far:
   app-root UNKNOWN, socket UNKNOWN, API-version UNKNOWN, routes UNKNOWN.
   F-003 was amended once (T-011) to sanction the first pair; the pattern will
   repeat in T-014.

2. **The `unroutableNetworks` wiring is unpinnable.** Mutating it to `[]` leaves
   all 450 tests green: `.running` and `.degraded` project identically, and
   `DiagnosticReport` exposes only `checks`/`ranAt`. Testing it needs an
   aggregate verdict on the report — which is spec open question 1.

3. **NFR-001's path list is stale.** It names `/containers/json?all=0`;
   `listContainers(all: false)` actually emits `/containers/json`.

4. **Two commits are unsigned** (`c06bd74`, `5890add`) — the 1Password agent
   re-locked mid-run. Re-sign with a rebase once unlocked.

5. **Information loss in the routes check.** When a network is unroutable *and*
   another publisher has no subnet, the CLI's separate "cannot check … no
   subnet reported" line disappears. No failure is hidden; fidelity is reduced.

## Not started

T-013 foreign bridge · T-014 memory commitment · T-015 20s budget ·
T-016 renderer + goldens · T-017 CLI as formatter · T-018 docker context ·
T-018a shared test-support target · T-019 repair extraction · T-020 view model ·
T-021 sidebar · T-022 view.
