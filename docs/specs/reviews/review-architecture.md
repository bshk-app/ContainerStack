# Architecture Review (Fowler lens)

## Critical issues

*(None.)*

## Major issues

- **`DiagnosticRunner` re-implements the precedence rule that already lives in `RuntimeState.resolve`.** The spec at F-004 says "Precedence follows `RuntimeState.resolve` … `foreignBridge` first, then `appRoot`, then the socket-dependent checks." `RuntimeState.resolve` (`RuntimeState.swift:47-48`) already encodes exactly that ordering, from exactly the same inputs (`socketResponds`, `missingAppRoot`, `foreignBridge`, `unroutableNetworks`). The spec then has the runner branch on those primitives a second time. That is two implementations of one law, with only a golden-text test and F-004's own fixtures pinning them together — nothing in the acceptance suite fails when *only* `RuntimeState.resolve` changes. First real edit to either side (say, a fourth precedence branch, or reordering `.starting` vs. `.offline`) drifts them silently, and the sidebar quietly lies. — **Recommended refactor:** the runner should not re-derive the branch; it should call `RuntimeState.resolve` once and *project* the resulting state into per-check verdicts. Rough shape:
  ```swift
  extension DiagnosticRunner {
      func project(
          _ state: RuntimeState,
          checks: Set<CheckID>,
          probes: ProbeInputs
      ) -> [DiagnosticCheck]
  }
  // .foreignBridge   -> foreignBridge=.failure, all socket-dependent=.skipped(reason)
  // .detached        -> appRoot=.failure(.restartRuntime), downstream=.skipped
  // .running/.degraded -> run downstream probes and API checks
  // .offline/.starting -> all downstream=.skipped(reason)
  ```
  `RuntimeState` becomes the single source of the ordering rule; `DiagnosticRunner` becomes a projection layer. The v1 CLI-vs-UI parity is preserved because both surfaces read from the same projected list. This is the change I'd insist on before merging.

## Minor issues

- **`SystemProbe` bundles two unrelated probes behind one protocol.** `runtimeStatus()` and `routingTable()` share nothing but a process spawn. Interface segregation is cheap here — a UI check set that skips routes still has to satisfy both members. **Refactor:** `protocol RuntimeStatusProbe { func run() async -> ProbeResult }` and `protocol RoutingTableProbe { func run() async -> ProbeResult }`, injected independently. Small win, but honest.

- **`Set<CheckID>` is more freedom than either caller needs.** Two callers, one difference (`.memoryCommitment`). An arbitrary set encourages nonsense combinations (`.socket` without `.foreignBridge`, `.routes` without `.socket`) that the runner has to defend against forever. **Refactor:** `enum DiagnosticProfile { case cli, ui }` on the public API, `Set<CheckID>` on an internal seam. Preset names document intent; the projection function above stays testable via the internal API. The `Set` is fine, but a profile is honest.

- **`Remedy.manual(String)` doing double duty.** It carries user-facing display copy (spec §4 says CLI text must stay byte-identical, so the string *must* originate in Core — that part is fine), but it also functions as the "no button" sentinel. **Refactor:** either name it `.instructions(String)` and add an explicit `.none` for "no action available", or drop `.manual` entirely and let `remedy: Remedy?` carry `nil` when there is nothing to do. The current `.manual("Run: cstack runtime restart")` reads as executable but isn't.

## This is fine

- **`Remedy` as a Core enum.** `.restartRuntime` and `.repairDockerContext` are capability tags, not view code; the CLI already prints matching prose. Data, not UI.
- **`CommandShell` duplication.** The current doctor calls `CommandShell.output` (`CStackCommands.swift:13, 58`), which launders failure to `""` — the exact bug the brainstorm names (lines 118-120). The Core probe wrapping `ProcessRunner.run` directly is the fix, not a smell; the two runners exist because they encode different failure contracts. CLI's `runtimeControl` still legitimately needs `CommandShell` for `.inherit` output and lifecycle timeouts. Accept the duplication.
- **`DiagnosticRunner` depth.** Hides precedence, error-per-check isolation (§4 "one failing check never aborts the others"), skip-vs-failure discipline, and the `""`-laundering fix. Deep enough; not a pass-through.
- **v2 memory-commitment absorption.** Adding `.memoryCommitment` to the UI profile is a `Set` mutation; the runner already handles it for the CLI. Open question #4 (`MemoryCommitment.approaching → Verdict`) must be resolved for §F-003 byte-identity anyway, so v2 inherits a decided mapping. No rework.

## Architecture quality score: 7/10
## Evolvability score: 7/10

## Consensus statement

The single biggest architectural risk is the duplicated precedence rule. `RuntimeState.resolve` and `DiagnosticRunner` both encode "foreignBridge > appRoot > socket-dependent" from the same primitive inputs, with no test that fails when only one side changes. Making the runner a projection of `RuntimeState` — not a parallel resolver — collapses the two into one law and turns any future divergence into a compile-time or unit-test failure. Everything else is polish; this is the one to fix before implementation.
