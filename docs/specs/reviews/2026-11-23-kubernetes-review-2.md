# Review 2 of the Kubernetes spec

Spec: `docs/specs/2026-11-23-kubernetes.md`, version 0.2 (commit `d7d847e`). Result: version 0.3.

Between the review and version 0.3 the plan changed: upstream pull request 2485 (`983d408`)
already adds `cluster start` and `cluster stop` with a stable control-plane endpoint, and the
owner decided to carry it in the fork release (spec D1). Version 0.3 removes the Runtime-side
design of 0.2: the cluster service as owner of cluster state, its record schema, shutdown
protocol, autostart in the Runtime, the Runtime node guard (F-014 of 0.2) and the address repair.

Verdicts:

- **gone**: gone with the removed design.
- **limit**: a limit of the upstream code that the app must not rely on; the named requirement
  handles it.
- **ours**: still ours; the named requirement changed.

| # | Finding (short) | Verdict | Requirement in 0.3 |
|---|---|---|---|
| 1 | A service restart does not change the generation; an operation stays busy | gone | — |
| 2 | XPC request lifetime cannot carry the shutdown barrier | gone | — |
| 3 | Shutdown can reopen admission; fallback stop refuses nodes | gone | — |
| 4 | Loading the service is not an API-readiness barrier or a generation signal | gone | — |
| 5 | Moving the plugin into the service breaks resource lookup | gone | — |
| 6 | Record store and recovery can lose the cleanup record | limit: an interrupted `create` leaves a record that `start` cannot use | §7 (delete is the recovery), F-210 (Node missing offers Delete) |
| 7 | The bridge checks one container and mutates another; archive PUT has its own write path; the Runtime force delete cleans up by name | ours (bridge part); limit (Runtime part) | F-101 (one snapshot, re-read and identity compare under admission, `putArchive` and prune included); §5 "Limit (Runtime race)" |
| 8 | Certificate repair can install a mismatched pair | gone | — |
| 9 | The failed legacy entrypoint cannot reach the repair | gone | — |
| 10 | Migration both needs and forbids the first boot | gone | — |
| 11 | The ownership record can lose track of a written kubeconfig file | ours | F-202 (one fixed app file, `~/.containerstack/kubeconfig`), F-207 (`~/.kube/config` only by explicit action), F-211 (the app never removes entries from `~/.kube/config`) |
| 12 | A shared lock with `kubectl` does not hold | limit: the plugin writes with no lock | §7 (no cross-process lock; a lost context shows as "no context" and "Write Kubeconfig" restores it), F-204 (one writer per process) |
| 13 | The list cannot compute Ready; create records no successful boot | limit: `running` is not health, and a failed start can stay `running` | F-205 (health through `/readyz`), F-210 (Not ready, with Restart = stop then start) |
| 14 | File timestamps and the current subnet do not prove the repair | gone | — |
| 15 | The operation contract has no result after completion | gone | — |
| 16 | The state table masks a missing node | ours | F-210 (Node missing before Degraded and Not ready; presence from the label-filtered bridge list); §8 fixture with a running control plane and a missing worker |
| 17 | Acceptance tests depend on later slices | ours | §9 (live tests of S5 after S4; the fork live check belongs to S1) |
