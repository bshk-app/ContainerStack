# Review 4 of the Kubernetes spec (confirmation)

Spec: `docs/specs/2026-11-23-kubernetes.md`, version 0.4 (commit `2fa6c57`). Result: version 1.0,
accepted for implementation.

The review confirmed 5 findings of review 3 as closed (2, 5, 10, 12, 13), 8 as partly closed
(1, 3, 4, 6, 7, 8, 9, 11), and raised 8 issues in the 0.4 changes. Each item was checked against
the source at the named revision. Verdicts: **accepted**, **changed** (right; the fix differs),
**rejected**. None was rejected.

### Partly closed findings of review 3

| # | Verdict | Evidence checked | Requirements changed |
|---|---|---|---|
| 1 | accepted | Upstream `983d408` `docs/cluster.md:228-250` (`--rm` keeps the record, removes nodes); `ClusterHelper+Lifecycle.swift:28-34` | F-213 and F-217 wording by outcome; F-210 Stopped only with all nodes present |
| 3 | accepted | App `RuntimeViewModel+Lifecycle.swift:259-275`; `docs/specs/2026-10-07-runtime-lifecycle-queue.md` F-002, §3.5 | F-213 publication |
| 4 | changed: per-name lock removed from version 1 (rule D8); the replacement window is a stated limit and serialization goes to §12 | Bridge `6b3393b` `ContainerDeleteRoute.swift:72-111`, `ContainerRenameRoute.swift:100-110,183-229`, `Utilities/VMLifecycleAdmission.swift:15-38` | F-101, §12 |
| 6 | accepted | App `ProcessRunner.swift:196-223` (timer starts after launch); Upstream `ClusterStop.swift:39-40` | F-213 (one monotonic deadline, whole-second `--time`), F-217 (probes inside it) |
| 7 | accepted | Bridge `ContainerRenameRoute.swift:100-135,183-229`, `ContainerRestartRoute.swift:26-33`, `ContainerCreateRoute.swift:761-799` | F-101 route table |
| 8 | changed: the real help prints `USAGE:` in capitals, not `Usage:` | `probe-help.txt`: the plugin binary of `feat/cluster-start-stop` at `b9aee43` prints `USAGE: cluster start [--name <name>]` | F-203, §8, §11 item 7 |
| 9 | accepted | Spec 0.4 F-202, F-207 | F-202 precondition, F-207 |
| 11 | accepted | Upstream `docs/cluster.md:228-250` | §2.5 |

### Issues in the 0.4 changes

| # | Issue | Verdict | Requirements changed |
|---|---|---|---|
| 1 | The route must own the lock across the whole mutation | changed: no lock in version 1; check at route entry; limit stated | F-101, §12 |
| 2 | The original snapshot cannot be the expected state before every native call | changed: the per-call comparison is removed with the lock | F-101 |
| 3 | The probe example rejects the capable build | changed: `USAGE:` from the real output | F-203 |
| 4 | The 120 s test is stricter than the waits | accepted | F-213, F-217, §8 |
| 5 | Warning and result describe different outcomes | accepted | F-213, F-217, F-210, F-215 |
| 6 | Result publication must keep the lifecycle queue contract | accepted | F-213 |
| 7 | The alias refusal must come before initialization and F-207 | accepted | F-202, F-207, §8 |
| 8 | Prune's conflict answer is ambiguous | accepted: a changed candidate is skipped; the prune continues | F-101, §8 |
