# Review 3 of the Kubernetes spec

Spec: `docs/specs/2026-11-23-kubernetes.md`, version 0.3 (commit `225a596`). Result: version 0.4.

Each finding was checked against the source at the named revision before it was taken. Verdicts:
**accepted**, **changed** (the finding is right; the fix differs), **rejected**. No finding was
rejected.

Findings 1, 2, 3 and 6 all come from the automatic start of clusters after a runtime restart
(F-213 of 0.3). Version 0.4 removes that start (D5): the plan only stops clusters, inside one time
budget. The four findings become the entry requirements of spec §12 "Later".

| # | Finding (short) | Verdict | Evidence checked | Requirements changed |
|---|---|---|---|---|
| 1 | A restart can destroy a `--rm` cluster; old multi-node clusters cannot restart | changed: no automatic start; the confirmation names such clusters; automatic restarts go on and report | Upstream `983d408` `docs/cluster.md` (`--rm` and pre-stable-endpoint limits); Runtime `SystemStop.swift:64-79`; the list has no stable-endpoint field (`ClusterConfiguration.swift:64-101`) | D5, F-217 (new), F-213, §12 |
| 2 | Overlapping plans lose the restore list or start a replacement cluster | changed: no restore list in version 1 | Upstream `ClusterService.swift:40-48,70-84` (records by name); App `CStackRuntimeControl.swift` and the app plan run separately | D5, F-213, §7, §12 |
| 3 | A live process can abandon stopped clusters | changed: nothing to finalize in version 1; the result names every cluster | App `RuntimeViewModel+Lifecycle.swift:259-290` (early return), `CStackRuntimeControl.swift:108-110,137-177` | F-213, §12 |
| 4 | The admission semaphore leaves a race inside the bridge | accepted | Bridge `6b3393b` `Utilities/VMLifecycleAdmission.swift:15-38` (several slots); `ContainerDeleteRoute.swift:108-114` (stop, then delete); `Utilities/DockerContainerID.swift:11-19,39-47` (stored ID kept across a rebuild) | F-101 (per-name lock for the whole operation; compare native ID, creation date, label) |
| 5 | `/readyz` can be `ok` after a failed start | accepted | Upstream `Support/ClusterHelper+Readiness.swift:63-85`, `ClusterBootstrapper+Start.swift:98-102,131-152` | F-205 (named "API ready"), F-210 ("Start failed" row, in-memory limit), §8 (live test checks NodePort and pod DNS) |
| 6 | A hung cluster stop delays recovery by two minutes per cluster | accepted | App `RuntimeViewModel+Control.swift:165-175`, `CStackRuntimeControl.swift:111-120`; Upstream `ClusterStop.swift:36-40,55-86` | F-213 (one 120 s budget, time left passed on, result per cluster) |
| 7 | A client-layer guard misses route mutations and fast paths | accepted | Bridge `ContainerUpdateRoute.swift:34-60`, `ContainerStartRoute.swift:46-52`, `ContainerStopRoute.swift:26-36`, `ContainerDeleteRoute.swift:84-111`, `ContainerAttachRoute.swift:93-102`, `ContainerAttachWSRoute.swift:28-35` | F-101 (snapshot before any fast return or side effect; route table; no preparation on attach to a node) |
| 8 | Exit status alone does not detect the new commands | accepted | Runtime `17bb57e` `Sources/Plugins/Cluster/ClusterCommand.swift:48-53` (no `start`, `stop`) | F-203 (usage line must name the subcommand), §8 |
| 9 | Kubeconfig isolation by path name only; cleanup commands follow the shell | accepted | Upstream `ClusterHelper+Kubeconfig.swift:127-142,174-204` | F-202 (one absolute path; refuse a link to `~/.kube/config`), F-211 (`--kubeconfig "$HOME/.kube/config"`), §8 (file compare after each write path) |
| 10 | "Add context" can replace a production entry | accepted, with the owner's decision: refuse, no replace option | Upstream `ClusterHelper+Kubeconfig.swift:163-175` | F-207, §8 |
| 11 | §2.5 overstates upstream start and stop | accepted | Upstream `ClusterBootstrapper.swift:107-125`, `ClusterBootstrapper+Start.swift:105-120,131-164`, `ClusterHelper+Lifecycle.swift:43-54`, `ClusterStop.swift:46-89`; exit codes 1 and 64 from ArgumentParser are marked inferred | §2.5 |
| 12 | The form admits `-dev` | accepted | Upstream `ClusterResource.swift:46-54` | F-209, §8 |
| 13 | Staging can pass with incomplete plugins | accepted | Runtime `Makefile:219-234`; Upstream `ClusterBootstrapper+ControlPlane.swift:102-117` | F-216, §8 |
