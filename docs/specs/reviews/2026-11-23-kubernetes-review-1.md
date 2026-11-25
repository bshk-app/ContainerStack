# Review 1 of the Kubernetes spec

Spec: `docs/specs/2026-11-23-kubernetes.md`, version 0.1 (commit `e543640`). Result: version 0.2.

The review read Runtime `17bb57e` (`bshk/1.7.1`), Bridge `166bbd5` and `6b3393b`, and App
`d633708`. Each finding was checked again against the source at the named revision before it
was taken. Verdicts: **accepted** (the change of the finding, or the same effect), **changed**
(the finding is right; the fix differs), **rejected**.

Findings 1, 4, 5, 6, 10, 11, 12, 13 and 15 have one cause: cluster state had four writers and
four callers with no single point of admission. Version 0.2 fixes the cause, not each finding:
the Runtime's cluster service owns all cluster state and runs every lifecycle operation (spec §4),
under invariants I1 to I12 (spec §5).

| # | Finding | Verdict | Evidence checked | Requirements changed |
|---|---|---|---|---|
| 1 | Shutdown can cut through a create; nothing marks a finished create | changed: single owner, admission closed at shutdown, `createCompleted` | Runtime `Commands/ClusterCreate.swift:181-190` writes the record before provisioning; the record has no completion field (`ClusterConfiguration.swift:64-101`) | §4, I2, I3, F-007, F-011, F-012 |
| 2 | A cut between a config write and its reload makes the retry skip the reload | accepted | Spec 0.1 F-004 and F-005 restart only "when the value changed" | I8, F-004, F-005 |
| 3 | A failed certificate regeneration strands the node | accepted | Runtime `ClusterHelper.swift:135` (repair needs `apiserver.crt`), `:153-163` (delete, then regenerate, `exit 1` before the marker) | I9, I10, F-004 |
| 4 | A failed start looks like a successful one | changed: `lastStart` in the record, bound to node boots; "ready" computed from it | Runtime `ClusterService.swift:98-114` (state only from container status) | I7, F-003, F-006, F-012, F-209, §9.1 |
| 5 | Kubeconfig writers can lose each other's changes | accepted | Runtime `ClusterHelper+Kubeconfig.swift:141-175,178-204` (read, edit, write with no lock); `write-config` took no cluster lock in 0.1 | I1, I5, F-010, E8 |
| 6 | A cluster can overwrite or remove an entry it does not own | accepted, with the owner's decision: a refusal at create; ownership by an `extensions` item with the cluster identity, and the path and names in the record | Runtime `ClusterHelper+Kubeconfig.swift:163-169,195-201` (removal by name), `ClusterBootstrapper.swift:148-154` (rollback removes by name) | I4, F-010, F-207, F-208, §9.2 |
| 7 | The bridge guard can check one container and change another | accepted, with the owner's decision: check in the client layer on one snapshot, identity check before the native call, prune included; plus a Runtime-side refusal | Bridge `6b3393b` `Routes/Containers/ContainerStopRoute.swift:26-36` and `Clients/ClientContainerService.swift:583-590` resolve twice and call by native name; prune `:915-938` | I6, F-101, F-102, F-103, F-014 |
| 8 | Exec and archive PUT defeat the lifecycle guarantee | accepted, with the owner's decision: the guard is not a security boundary; exec, logs, inspect, attach, archive GET allowed as maintenance; archive PUT refused | Bridge `ExecRoutes.swift`, `ClientArchiveService.swift` (archive PUT writes the node file system) | F-101, §12 |
| 9 | The version pin cannot identify the build; the bundle keeps its old pin | accepted | Runtime `.github/workflows/bshk-release.yml:57` strips `-bshk.N`; App `scripts/prepare-container-runtime.sh:31-33` pins `bshk.2` and its SHA-256; `container --version` prints the commit [L] | F-218 (commit of client and daemon, both scripts, no "or later") |
| 10 | Autostart intent can be lost or applied out of order | changed: intent in the record, changed only by an admitted operation; autostart reads it again at each admission | Spec 0.1 F-204, F-205, F-214 (whole-file writes, intent set before the command) | I1, I12, D5, F-013, F-204, F-205 |
| 11 | Autostart is tied to bridge launches; `cstack` with no agent never runs it | changed: autostart runs in the cluster service, once per API server generation | App `CStackRuntimeControl.swift:137-146,162-177` starts socktainer itself; `ContainerStackRuntime.swift:148-183` | I12, F-013, F-214, §9.3 |
| 12 | The graceful-stop budget can be charged twice | changed: one shutdown in the Runtime with one deadline; the app adds no cluster step and its process limit covers budget and teardown | App `RuntimeControl.swift:157-163`, `ProcessRunner.swift:43` (120 s) | I2, F-011, F-213 |
| 13 | A missing node and a stopped node look the same | accepted | Runtime `ContainersService.swift:135-141` (a loaded stopped container has no networks), `ClusterService.swift:98-110` | I11, F-015 (`present`, identity label), F-209, F-215 |
| 14 | The port rule fails for FQDN clusters and a probe cannot reserve the port | accepted | Runtime `LinuxNodeProvisioner.swift:103-104` (no port with an FQDN), `RuntimeService.swift:310` (forwarder at bootstrap) | F-003 step 3 |
| 15 | Kubeconfig failure outcomes disagree; the copied command ignores the chosen file | accepted | Spec 0.1 F-010 against F-208, F-210 | F-010 (`kubeconfig.result`), F-208, F-210 |
| 16 | The create-conflict row depends on the bridge revision | accepted | Bridge `166bbd5` answers 500; `6b3393b` `ContainerCreateRoute.swift:798-799`, `Utilities/ContainerNameConflict.swift` answer 409 with the Docker text | F-105, §9.4 |
| 17 | The staging smoke test needs a live daemon | accepted | Runtime `DefaultCommand.swift:36-38,69-84` (plugin loader needs the API server) | F-218 (files checked directly; dispatch only live) |
| 18 | S3 needs E1 and E3, which need S3 | accepted | Spec 0.1 §9 | §11 (E1, E3 inside S3; E2 as S0) |
| T1 | Start tests inject failure only before worker work | accepted | Spec 0.1 §8 | §10.1 (fault seam after each write point, contention per invariant) |
| T2 | The kubeconfig round trip hides an overwrite | accepted | Spec 0.1 §8 F-010 row | §10.2 F-010 (intermediate document, collision, concurrent writers) |
| T3 | "Reaches the handler" misses side effects | accepted | Spec 0.1 §8 F-101, F-103 rows | §10.2 F-101 (disposition of exec, archive, attach; network routes with shared runtimes) |
| T4 | The restart live test passes when the node never stopped | accepted | Spec 0.1 §8 F-214 row | §10.2 F-003, F-013 (new boot asserted; no-agent path) |

No finding was rejected. D1 to D8 stay; D5 keeps its meaning and moves its storage into the
Runtime record.
