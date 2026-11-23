# Spec: Kubernetes clusters, version 1

Version: 0.3. History: 0.1 (one design review, `reviews/2026-11-23-kubernetes-review-1.md`);
0.2 (a Runtime-side owner of cluster state; second review, `reviews/2026-11-23-kubernetes-review-2.md`).
0.3 drops the fork-side design: upstream already builds cluster start and stop (§2.5), and the
owner decided on 2026-11-23 to carry that work. No code exists.
Date: 2026-11-23

Sources: the live check of 2026-11-23 (`report.md` and logs in the local directory `k8s-live`,
cited as "k8s-live"), a second live check (logs in the local directory `k8s-spec`, cited by file
name), and the source at these revisions:

| Name | Repository | Revision |
|---|---|---|
| **Runtime** | `container` fork, branch `bshk/1.7.1` | `17bb57e` (same cluster code as tag `1.7.1-bshk.2`) |
| **Upstream PR** | `apple/container` pull request 2485 | commit `983d408` ("Add container cluster start and stop"), in the fork clone |
| **Bridge** | `socktainer` fork | `6b3393b`, the app's `SOCKTAINER_REV` (`scripts/prepare-v1-runtime.sh:37`) |
| **App** | ContainerStack | `d633708` |

Markers: **[S]** read in source (revision, file:line), **[L]** verified live (log file), **[I]**
inferred. **[P]** pending: the fork live check of the branch `feat/cluster-start-stop` (report
`k8s-fork/report.md`, not written yet) decides it. A claim with no marker is a requirement or a
decision.

## 1. Overview

Apple Container 1.7 ships the `cluster` plugin: `container cluster create` makes a Ready
Kubernetes cluster of node VMs (`kindest/node`, one VM per node) in 30 to 60 s [L `create.txt`].
Upstream pull request 2485 adds `cluster start` and `cluster stop`. ContainerStack version 1
makes clusters a managed resource on top of that: create, list, start, stop, delete, a kubectl
context in a file of its own, clusters that come back after a runtime restart that ContainerStack
runs, and Doctor.

Version 1 adds no new shared state. The Runtime keeps the cluster record; ContainerStack keeps
only a kubeconfig file of its own and an in-process lock.

## 2. Facts

### 2.1 Behaviour of the Runtime at `17bb57e`

- `container cluster list --format json` returns the full record [L `create.txt`]:

  ```json
  [{"configuration":{"cni":null,"creationDate":"2026-11-23T17:23:33Z","fqdn":null,
    "kubernetesVersion":"v1.35.5","labels":{},"name":"cs-spec",
    "nodes":[{"kind":"linux","name":"cs-spec","roles":["control-plane","worker"]}],
    "remove":false,"sharedImageStore":false},
    "id":"cs-spec",
    "status":{"nodes":[{"addresses":["192.168.64.3"],"name":"cs-spec",
      "ports":["6445->6443"],"status":"running"}],"state":"running"}}]
  ```

- `status.state` is `running`, `degraded` or `stopped`, from the node containers only: `running`
  when all run, `stopped` when none runs. A node container that is gone counts as `stopped`, and a
  stopped container loaded at runtime start has no address, so the list cannot tell a missing node
  from a stopped one [S Runtime `Sources/ContainerResource/Cluster/ClusterStatus.swift:20-24`,
  `Sources/Services/ContainerClusterService/Server/ClusterService.swift:98-113`,
  `Sources/Services/ContainerAPIService/Server/Containers/ContainersService.swift:135-141`]. The
  state is not a health value: it said `running` while NodePort and pod DNS were broken
  [L `round1.txt`].
- The bridge hides nodes (label `com.apple.container.plugin=cluster`) from `GET /containers/json`
  and prune unless a `label` filter names that label; lookup by name or ID still finds them
  [S Bridge `Sources/socktainer/Clients/ClientContainerService.swift:238-273,850-852`]. The app
  list does not show nodes [L k8s-live `api-and-networks.txt`].
- The bridge does not guard nodes: `docker stop`, `rm -f`, `start` reach the native calls [S Bridge
  `ClientContainerService.swift:583-604,683-700`; L k8s-live `bridge-node-start.txt`]. A route
  resolves the reference, the client resolves it again, and the native call uses the native name
  [S Bridge `Routes/Containers/ContainerStopRoute.swift:26-36`, `ClientContainerService.swift:583-590`].
- A full runtime restart runs `container stop --all --time 5` (skips nodes), `system stop` (stops
  every container, nodes too, with a 5 s limit), `system start` [S App
  `Sources/ContainerStackCore/RuntimeControl.swift:146-165`; S Runtime
  `Sources/ContainerCommands/Container/ContainerStop.swift:63-65`,
  `Sources/ContainerCommands/System/SystemStop.swift:28,66-70`]. After it, the cluster is
  `stopped` [L k8s-live `lifecycle.txt`]. ContainerStack "Stop Runtime" stops only the bridge
  [S App `Sources/ContainerStackApp/RuntimeViewModel+Lifecycle.swift:210-218`].
- Full restarts come from the sidebar, the Doctor repair, the poll recovery, the stale-bridge check
  and `cstack runtime restart` [S App `SidebarRuntimePanel.swift:25,96`,
  `DoctorViewModel.swift:150,302`, `RuntimeViewModel.swift:281`,
  `RuntimeViewModel+Staleness.swift:20`, `CStackRuntimeControl.swift:68-70`]. None asks for a
  confirmation.
- An idle node VM with a 6 GB limit holds 2.2 GB of host memory [L k8s-live
  `memory-hypervisor-idle.txt`]. No LoadBalancer and no ingress controller [L k8s-live
  `recreate.txt`].

### 2.2 Why a plain node start was not enough

A node start through the bridge changes the VM IP (.3 to .4, .5, .6 in three rounds) [L
`round1.txt` to `round3.txt`]. The node boot script rewrites the old IP in files, but the
`kube-proxy` and `cluster-info` ConfigMaps keep it, so kube-proxy writes no rules: NodePort and pod
DNS fail [L `cause.txt`, `fix1.txt`]. Each node stop took about 90 s with every method tried
[L `round1.txt` to `round3.txt`].

### 2.3 Kubeconfig

- The plugin writes one file: `KUBECONFIG` if it names one path; with several, the first that
  exists, else the last; else `~/.kube/config` [S Runtime
  `Sources/ContainerCluster/Support/ClusterHelper+Kubeconfig.swift:127-139`].
- `create` sets the current context and exits 0 when the write fails [S Runtime
  `Bootstrapper/ClusterBootstrapper.swift:142-147`]. `write-config` does not set it [S Runtime
  `Commands/ClusterWriteConfig.swift:49`].
- A write decodes the whole file into a model with fixed keys and encodes it again
  [S Runtime `Sources/ContainerCluster/KubeConfig.swift:21-168`]. Keys outside the model are lost.
  On a copy of the owner's file it dropped three `exec.env: null` entries [L `kubeconfig-merge.txt`].
  Removal and rollback go by name [S Runtime `ClusterHelper+Kubeconfig.swift:163-169,195-201`,
  `ClusterBootstrapper.swift:148-154`]. No write takes a lock.
- A new file gets mode 0644; an existing 0600 file keeps 0600 [L `create.txt`, `kubeconfig-merge.txt`].
- The host entry is `https://127.0.0.1:<host port>`, or `https://<fqdn>:6443` when the system has
  a DNS domain [S Runtime `ClusterHelper+Kubeconfig.swift:73-85`].

### 2.4 Release

The fork release job does not build `cluster-shim`, and `make` only warns, so the release has no
shim and `--shared-image-store` fails [S Runtime `.github/workflows/bshk-release.yml:12-13,55-60`,
`Makefile:124-143,225-232`; L k8s-live `create.txt`]. `common.yml` builds it on Linux
(`.github/workflows/common.yml:23-50`). The release job strips `-bshk.N` from the version
(`bshk-release.yml:57`); `container --version` prints `1.7.1 (build: release, commit: 17bb57e)`
[L]. The app bundle script pins its own tag and checksum [S App
`scripts/prepare-container-runtime.sh:31-33`]. The plugin loader needs a running API server [S
Runtime `Sources/ContainerCommands/DefaultCommand.swift:36-38,69-84`].

### 2.5 Upstream pull request 2485 (`983d408`)

- New commands `container cluster start --name <n>` and `container cluster stop --name <n>
  [--signal S] [--time T]` [S Upstream PR `Sources/ContainerCluster/Commands/ClusterStart.swift`,
  `ClusterStop.swift`].
- Stable control-plane endpoint: kubeadm gets `controlPlaneEndpoint: <fqdn or cluster name>:6443`,
  and each node resolves the name through its `/etc/hosts`, so a new IP at start does not break
  kube-proxy [S Upstream PR `Bootstrapper/ClusterBootstrapper+ControlPlane.swift` diff,
  `Support/ClusterHelper+Networking.swift`].
- `start` on a cluster whose state is `running` prints the name and exits 0 with no change
  (`ClusterStart.swift:44-47`). Otherwise it boots the stopped nodes, restarts running workers
  when the control plane starts (no DNS domain), waits for the API, node leases, readiness, the
  `kubernetes` endpoint, CoreDNS and pod-network routes, then writes the kubeconfig **with the
  current context set** (`Bootstrapper/ClusterBootstrapper+Start.swift:66-163`). A missing node
  fails with "node container <n> not found; delete and re-create cluster <c>"
  (`Support/ClusterHelper+Lifecycle.swift:28-34`).
- `stop` stops the workers in parallel, then the control plane, with the image stop signal and
  30 s per node (`ClusterStop.swift:30-91`, `ClusterHelper.swift:53`).
  The record and nodes stay.
- Both commands exit 0 and print the name on success; an error exits non-zero with the message on
  stderr [S; the exact code is the CLI's error path, I].
- Documented limits (`docs/cluster.md` in the PR): a start that fails part way can leave the
  cluster `running`, and the recovery is `cluster stop` then `cluster start`; a cluster made before
  the stable endpoint cannot restart multi-node; a cluster made with `--rm` cannot start.
- Tests in the pull request thread report that `system stop`, `system start`, `cluster start` works
  on 1 node and on 1 + 1 workers with PVC data kept; 2 or more workers need fix 2543 [owner's
  summary; P].
- Upstream issue 2453 plans to move cluster bootstrap into the daemon. Upstream pull request 2557
  adds `--publish` to `cluster create`.

## 3. Decisions

- **D1. Carry upstream.** The fork release carries pull request 2485 and fix 2543 as patches. No
  own start, stop or cluster-service logic. *Alternative:* own fork design (spec 0.2). Cost: it
  duplicates and collides with upstream 2485 and 2453.
- **D2. A kubeconfig of ContainerStack's own.** The app and `cstack` run the plugin with
  `KUBECONFIG=~/.containerstack/kubeconfig` (mode 0600). `~/.kube/config` changes only through an
  explicit user action that states its risk (F-207). No fork change for kubeconfig.
  *Alternative:* write `~/.kube/config` by default. Cost: the plugin re-encodes the owner's file,
  which holds production contexts, and sets its current context (§2.3, §2.5).
- **D3. No LoadBalancer and no ingress in version 1.** The user gets NodePort on the node IP and
  `kubectl port-forward`. Upstream `--publish` (2557) is the likely way to host access later.
- **D4. No cluster in a shared or project VM.** Each node is its own VM.
- **D5. Clusters come back only inside a runtime restart that ContainerStack runs** (F-213). A stop
  with no start (Stop, logout, reboot, crash) leaves clusters stopped; the user starts them. No
  stored intent. *Alternative:* stored autostart. Cost: state shared between processes (spec 0.2,
  review 1 findings 10 and 11).
- **D6. The bridge refuses lifecycle calls on a node with 409.** It prevents accidents from Docker
  clients. It is not a security boundary.
- **D7. Clusters get their own sidebar section, "Kubernetes".**

## 4. Requirements: Runtime fork (`container`)

- **[F-001] Carry upstream.** The release branch gets the commits of pull request 2485 (`983d408`)
  and fix 2543, unchanged, each as its own commit with the upstream reference in the message. When
  upstream merges them, the next fork release drops the patches. Built and checked by the fork
  branch `feat/cluster-start-stop` [P].
- **[F-002] `cluster-shim` in the release.** `bshk-release.yml` gets a job on `ubuntu-24.04` with
  the steps of `common.yml:23-50`; the release job passes its artifact as `CLUSTER_SHIM_BINARY`.
  In `Makefile`, with `BUILD_CONFIGURATION=release`, a missing shim stops `build` and the install
  step with an error. The release job checks that the package payload has
  `libexec/container/plugins/cluster/resources/cluster-shim` as a static aarch64 ELF.
- **[F-003] Release `1.7.1-bshk.3`.** F-001 and F-002, on top of `1.7.1-bshk.2`.

## 5. Requirements: Bridge (`socktainer`)

- **[F-101] Node guard.** The guard prevents accidental lifecycle damage from Docker clients
  (`docker rm -f`, `docker container prune`). It is not a security boundary: a client with the
  socket already controls the runtime. Exec, logs, inspect, stats, wait, export, attach and
  archive GET stay allowed as maintenance access.

  The check is in the client layer, at the point of mutation. Each mutating method of
  `ClientContainerService` and `ClientArchiveService.putArchive` (which already takes a snapshot,
  `ClientArchiveService.swift:144`) resolves the reference once, checks the label on that snapshot,
  and passes the same snapshot on. Inside `VMLifecycleAdmission`, just before the native call, it
  reads the container again by native ID and compares `DockerContainerID.hexId` (native ID and
  creation date); on a difference it answers 409 "container <name> changed during the request" and
  changes nothing. Prune does the same for each candidate.

  | Route | Node answer |
  |---|---|
  | `POST /containers/{id}/start`, `/stop`, `/kill`, `/restart` | 409 |
  | `DELETE /containers/{id}` (with or without `force`) | 409 |
  | `POST /containers/{id}/rename`, `/update` | 409 |
  | `PUT /containers/{id}/archive` | 409 |
  | `POST /networks/{id}/connect`, `/disconnect` with a node | 409 (today a no-op 200, `Routes/Networks/NetworkConnectRoute.swift:8-14`) |
  | `POST /containers/prune` | the node is never a candidate, also with a label filter on the plugin label |
  | inspect, logs, stats, wait, export, archive GET and HEAD, exec, attach, resize | allowed |
  | pause, unpause, top, changes, commit | unchanged (not supported or not implemented) |
  | `POST /containers/create` with a node's name | unchanged: 409 with the Docker name-conflict text (pin `6b3393b` or later, `ContainerCreateRoute.swift:798-799`) |

  409 body: `{"message":"<name> is a node of a Kubernetes cluster. Use 'container cluster' or ContainerStack to start, stop or delete it."}`.
- **Limit (Runtime race).** The native calls act by name, and inside the Runtime a force delete
  reads state, waits for the stop, then cleans up by name [S Runtime
  `ContainersService.swift:498-507,850-890,1022-1030`]. A replacement of the container in that
  window is outside the bridge. The bridge closes its own window (re-read under admission); the
  rest waits for upstream (issue 2453 moves cluster work into the daemon).

## 6. Requirements: ContainerStack

### 6.1 Core (`Sources/ContainerStackCore/`)

- **[F-201] Cluster model.** `KubernetesCluster` decodes one element of `cluster list --format
  json`. Required: `configuration.name`, `kubernetesVersion`, `remove`, `sharedImageStore`,
  `creationDate`, `nodes[].name`, `nodes[].roles`; `status.state` (`running` | `degraded` |
  `stopped`); `status.nodes[].name`, `status.nodes[].status`. Optional: `cni`, `fqdn`,
  `status.nodes[].addresses`, `ports`. Unknown keys are ignored; a missing required key or an
  unknown state is an error that names the key, shown in place of the list. The fixture is the
  array of §2.1. API endpoint: `https://127.0.0.1:<host>` from the port `<host>-><6443>`, or
  `https://<fqdn>:6443`.
- **[F-202] Command wrapper.** `ClusterCommands` runs `<containerPath> cluster ...` with
  `containerPath` from `RuntimeProcessConfiguration.make` (`RuntimeProcessConfiguration.swift:62-99`),
  never `container` on `PATH`. Every call sets `KUBECONFIG=~/.containerstack/kubeconfig`, except the
  explicit action of F-207. Before the first call the wrapper creates that file with mode 0600 and
  `apiVersion: v1`, `kind: Config` (the plugin keeps the mode of an existing file, §2.3). Process
  limits: `list` 20 s, `create` 15 min, `start` 10 min, `stop` 2 min, `delete` 5 min,
  `write-config` 30 s.
- **[F-203] Capability.** The Kubernetes section and `cstack cluster` work only when the runtime
  has the commands: with the runtime running, `container cluster start --help` and `container
  cluster stop --help` exit 0 (the plugin loader needs the API server, §2.4). The result is kept for
  the running build (`container --version` commit). Without it, the section says "This runtime has
  no cluster start; update ContainerStack" and offers nothing else.
- **[F-204] One operation at a time per process.** `ClusterOperationLock` (an actor in Core) runs
  the cluster commands that change state (create, start, stop, delete, write-config) one at a time
  in a process, for all clusters, because they all write the one kubeconfig file. A second request
  waits in order. Across processes (app and `cstack`, or the bare CLI) there is no lock: see §7.
- **[F-205] Health check.** `ClusterHealth` sends `GET <API endpoint>/readyz` with a 3 s limit,
  trusting only the cluster's CA from `~/.containerstack/kubeconfig` (`certificate-authority-data`
  of the cluster entry), with no client credentials (kubeadm serves `/readyz` to anonymous callers,
  I). `ok` is healthy; anything else, or no context in the file, is "not ready". It runs after each
  start, create and restart-plan start, and every 5 s for running clusters while the Kubernetes
  section shows.

### 6.2 `cstack cluster` (`Sources/CStackCLI/`)

- **[F-206]** Subcommands; each is one Runtime command through F-202:

  | Command | Runs |
  |---|---|
  | `cstack cluster ls [--json]` | `cluster list --format json`. Table `NAME STATE HEALTH VERSION NODES API`. `--json` prints the runtime JSON unchanged. |
  | `cstack cluster create <name> [--cpus N] [--memory SIZE] [--workers ...]... [--node-image REF] [--cni PATH\|NONE] [--shared-image-store]` | `cluster create` |
  | `cstack cluster start <name>` / `stop <name>` / `rm <name>` | `cluster start` / `stop` / `delete` (no prompt) |
  | `cstack cluster kubeconfig <name>` | `cluster write-config`, then prints the two lines of F-207 |

  `cstack` uses `~/.containerstack/kubeconfig` and ignores the shell's `KUBECONFIG`. Progress on
  stderr unchanged. Exit codes: 0 done; 1 the Runtime command failed; 64 usage; 69 the runtime does
  not run or has no cluster start (F-203).

### 6.3 App (`Sources/ContainerStackApp/`)

- **[F-207] Kubeconfig.** The inspector shows two lines with copy buttons:
  `kubectl --kubeconfig ~/.containerstack/kubeconfig --context <name> get nodes` and
  `export KUBECONFIG=~/.containerstack/kubeconfig`. The action "Add to ~/.kube/config…" asks:
  "container rewrites the whole file ~/.kube/config. Keys it does not know are lost, and it changes
  the layout. Make a backup first. Add context <name>?" and then runs `cluster write-config` with
  `KUBECONFIG=~/.kube/config` (this command does not change the current context, §2.3). A cluster
  that the bare CLI created has no context in the app file; the row offers "Write Kubeconfig"
  (`write-config` into the app file).
- **[F-208] Kubernetes section** (D7). `DashboardDestination.kubernetes`, after Stacks, with an
  inspector (`DashboardView.swift:3-28`). One row per cluster: name, state, Kubernetes version,
  nodes, API endpoint. Inspector: nodes (name, roles, state, IP, CPUs, memory), the two lines of
  F-207, "Reach a NodePort Service at http://<node IP>:<node port>". The list refreshes every 5 s
  while the section shows. Files: `KubernetesView.swift`, `RuntimeViewModel+Clusters.swift` (new),
  `DashboardView.swift`.
- **[F-209] Create form.** Name (lowercase letters, digits and `-`, 1 to 63 characters, unique
  among clusters); CPUs and memory with the Runtime defaults (`ClusterHelper.swift:34-40`); worker
  groups (count, CPUs, memory; at most 1024 in total); node image (default kindest/node v1.35.5);
  network plugin (kindnet, a manifest file, none); "Share my local images with the cluster" with the
  three warning points of `docs/cluster.md:5-12` shown when on; a memory note (node limits against
  host memory, 2.2 GB idle per 6 GB node). No `--rm` option: such a cluster cannot start (§2.5).
- **[F-210] States and actions.** The first row that matches wins:

  | Shown | When | Actions |
  |---|---|---|
  | Creating, Starting, Stopping, Deleting | this process runs that command for the cluster | none |
  | Node missing: <names> | a node of the record is not in the bridge list filtered on the plugin label (`GET /containers/json?all=1&filters={"label":["com.apple.container.plugin=cluster"]}`) | Delete |
  | Not ready | state `running` and F-205 fails | Restart (runs `stop` then `start`, the upstream recovery), Delete |
  | Running | state `running` and F-205 is `ok` | Stop, Delete |
  | Degraded: k of n nodes run | state `degraded` | Start, Stop, Delete |
  | Stopped | state `stopped` | Start, Delete |

  A failed command shows its stderr on the row until the next command for that cluster. The app
  does not trust `running` alone after a start: a start that failed part way can leave `running`
  (§2.5), and F-205 tells it apart.
- **[F-211] Delete.** Confirmation: "Delete cluster <name>? Its nodes, Kubernetes objects and
  volumes are lost." When `~/.kube/config` has a context with this name and the cluster's API
  endpoint, the dialog adds: "~/.kube/config still has context <name>. Remove it with
  `kubectl config delete-context <name>`, `delete-cluster <name>` and `delete-user <name>`." The
  app does not edit `~/.kube/config`.
- **[F-212] Runtime down.** The section shows "The runtime is not running. Start it to manage
  clusters." and the last list, dimmed; no actions and no `cluster` commands.

### 6.4 Runtime lifecycle (D5)

- **[F-213] Clusters inside the restart plan.** `RuntimeRestartPlan.steps`
  (`RuntimeControl.swift:146-165`) gets two steps, both advisory like `stopContainers`
  (`RuntimeControl.swift:116-123`): a failure is logged, shown and does not stop the plan.
  1. `stopClusters`, first: list clusters; remember in the plan run (in memory) the names with
     state `running` or `degraded`; run `cluster stop` for each, one at a time.
  2. `startClusters`, last, after the bridge is back: `cluster start` for each remembered name, one
     at a time, then F-205.
  The sidebar shows "Stopping cluster <name>…" and "Starting cluster <name>…"
  (`RuntimeViewModel+Control.swift:145-153`). The app, `cstack runtime restart` and the automatic
  restarts (poll recovery, stale bridge) run this plan. Before a restart from the sidebar or the
  Doctor repair with a running cluster, the app asks: "Restart the runtime? Kubernetes clusters
  <names> stop and start again. Their pods restart. This can take several minutes." Files:
  `RuntimeControl.swift`, `RuntimeViewModel+Lifecycle.swift`, `CStackRuntimeControl.swift`,
  `SidebarRuntimePanel.swift`, `DoctorViewModel.swift`.
- This needs no state between processes: the plan runs in one process, and the list lives only in
  that run. When the process ends between the two steps (app quit, crash), the clusters stay
  stopped, as after a Stop. A bridge-only restart and "Stop Runtime" do not touch clusters (§2.1).

### 6.5 Doctor and docs

- **[F-214] Doctor check `clusters`,** in the CLI and UI sets (`DiagnosticReport.swift:5-19`):
  pass "N clusters, M running"; warning for Stopped ("start it in Kubernetes or with `cstack
  cluster start <name>`"), Degraded, Not ready, Node missing, no context in the app kubeconfig;
  failure when the list does not decode or the runtime lacks F-203. Memory check: adds the limits
  of running nodes from the label-filtered list (`DiagnosticRunner+Memory.swift:6-35`).
- **[F-215] Docs.** `docs/kubernetes.md`: create; the app kubeconfig and the two lines; adding to
  `~/.kube/config` and its risk; NodePort and port-forward; no LoadBalancer or ingress; the shared
  image store warning; what Stop, Restart and reboot do to clusters; Not ready and its recovery; the
  bridge guard is not a security boundary.
- **[F-216] Pins.** `scripts/prepare-v1-runtime.sh` and `scripts/prepare-container-runtime.sh`
  (tag and SHA-256) pin `1.7.1-bshk.3`, and the bridge pin carries F-101. The staging script checks
  the staged files directly: `libexec/container/plugins/cluster/bin/cluster`, its `config.toml` and
  `resources/cluster-shim` (static aarch64 ELF), `plugins/cluster-hoststore`,
  `plugins/container-core-clusters`. The capability (F-203) is checked live, not in staging.

## 7. Concurrency

ContainerStack adds no shared state. The rules:

- In one process, F-204 runs one changing cluster command at a time.
- Across processes there is no lock. The app and `cstack` both write `~/.containerstack/kubeconfig`
  through the plugin, which reads, edits and writes the whole file with no lock (§2.3). Two
  changing commands at the same time in two processes can lose one context. The user sees the
  cluster with "no context" (F-207, F-214) and fixes it with "Write Kubeconfig".
- A change by another process (bare CLI, a second `cstack`) shows at the next list refresh (5 s).
  A command of the app that meets a state changed under it reports the Runtime's error on the row.
- Limits inside the upstream plugin, with no fix in ContainerStack: two `cluster` commands on one
  cluster are not serialized; `create` writes the record before it provisions nodes, so an
  interrupted create leaves a record that `start` cannot use (delete it) [S Runtime
  `Commands/ClusterCreate.swift:181-190`]; the native calls act by name (§5). Upstream issue 2453
  moves this work into the daemon.

## 8. Tests

Live tests use their own `KUBECONFIG` and check at the end that `~/.kube/config` has the same
SHA-256 as before.

| Req. | Test that fails without it | Kind | Repository |
|---|---|---|---|
| F-001 | [P] fork live check: create 1 node and 1 + 2 workers, NodePort Service and a PVC, `system stop`, `system start`, `cluster start`: a new boot, NodePort answers, the PVC data is there. A start cut part way: state `running`; `stop` then `start` recovers. | live | Runtime |
| F-002 | The release payload check fails on a package without the shim; `make container BUILD_CONFIGURATION=release` without a shim exits non-zero. | CI | Runtime |
| F-101 | Route tests with a fake node: each 409 row answers 409 with the body and the fake records no mutation; exec runs, archive GET returns bytes, archive PUT writes nothing; a node found by ID prefix and by retired ID is refused; a container replaced by a node after the first resolve (fake hook before the re-read) is not changed; prune with the plugin label filter deletes nothing; network connect and disconnect with and without `--shared-runtimes`. | route | Bridge |
| F-201 | Decode the fixture; an extra key passes; a missing `status.state` or `state: "paused"` fails and names the key. | unit | App |
| F-202 | A fake `container` first on `PATH` is not run; every call has `KUBECONFIG` set to the app file; the file exists with mode 0600 before the first call. | unit | App |
| F-203 | A fake `container` whose `cluster start --help` exits 1 disables the section and `cstack cluster`. | unit | App |
| F-204 | Two `start` requests in one process: the second begins after the first ends. | unit | App |
| F-205 | A local TLS server with the cluster's CA: `ok` is healthy; a 500, a timeout, another CA are not ready. | unit | App |
| F-206 | Argument mapping for each subcommand; the shell's `KUBECONFIG` is not passed; exit codes. | unit | App |
| F-207 to F-212 | View model tests over fixtures for each row of F-210, including a running control plane with a missing worker (Node missing wins over Degraded) and `running` with a failing health check (Not ready); the copied lines; the `~/.kube/config` warning text; delete text with and without a matching context. | unit | App |
| F-213 | Plan order: `stopClusters` before `stopContainers`, `startClusters` after the bridge step; only the remembered names start; a failing cluster step does not stop the plan. Live after S4: `cstack runtime restart` with a running cluster: a new node boot and F-205 `ok`. | unit, live | App |
| F-214 | Doctor fixtures for each warning; the memory total includes a node found only through the label filter. | unit | App |
| F-216 | The staging check fails on a bundle without each named file. | CI | App |

## 9. Order of work

| Slice | Requirements | Repository | Needs | Parallel with |
|---|---|---|---|---|
| S1 Fork release | F-001 to F-003 | Runtime | the fork live check [P] | S2, S3 |
| S2 Node guard | F-101 | Bridge | — | S1, S3 |
| S3 Core and `cstack` | F-201 to F-206 | App | the JSON of §2.1 (unchanged by 2485) | S1, S2 |
| S4 Pins | F-216 | App | S1, S2 | S5 |
| S5 App section and lifecycle | F-207 to F-214 | App | S3; live tests after S4 | S4 |
| S6 Docs | F-215 | App | S5 | — |

## 10. Non-goals

- A Kubernetes object browser in the app.
- LoadBalancer, ingress and host port publishing (D3; upstream 2557 later).
- A cluster in a shared or project VM (D4).
- Clusters that start by themselves after a Stop, logout, reboot or crash (D5).
- `--rm` clusters in the app (they cannot start, §2.5).
- Changes to `~/.kube/config` other than the explicit action of F-207.
- A security boundary between Docker clients and nodes (D6).

## 11. Pending: fork live check

The fork worker checks these on `feat/cluster-start-stop`; the results go into F-001 and F-213
limits, not to the owner: node stop time with the upstream 30 s limit (it was about 90 s, §2.2);
1 + 2 workers with fix 2543; the shared image store after a runtime restart; the failed-start gap
(state `running` after a cut start, and `stop` then `start` as recovery); the exit code of a
failed `cluster start`.

## 12. Open questions

None for the owner. Decisions D1 to D7 are the owner's of 2026-11-23.
