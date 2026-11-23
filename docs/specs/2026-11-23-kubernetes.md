# Spec: Kubernetes clusters, version 1

Version: 0.4. History: 0.1 (review 1, `reviews/2026-11-23-kubernetes-review-1.md`); 0.2 (a
Runtime-side owner of cluster state; review 2, `reviews/2026-11-23-kubernetes-review-2.md`); 0.3
(carry upstream cluster start and stop, §2.5; review 3, `reviews/2026-11-23-kubernetes-review-3.md`).
0.4 removes the automatic start of clusters after a runtime restart (now in §12 "Later") and
tightens the bridge guard. No code exists.
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
context in a file of its own, an orderly cluster stop before a runtime restart, and Doctor.

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
- Stable control-plane endpoint: kubeadm gets `controlPlaneEndpoint: <fqdn or cluster name>:6443`
  [S Upstream PR `Bootstrapper/ClusterBootstrapper.swift:107-125`]. Without an FQDN, the
  control-plane address goes into the `/etc/hosts` of the workers; start updates it only on the
  workers that it boots or restarts (`Bootstrapper/ClusterBootstrapper+Start.swift:105-120`).
- `start` on a cluster whose state is `running` prints the name and exits 0 with no change
  (`ClusterStart.swift:44-47`). Otherwise it boots the stopped nodes, restarts running workers
  when the control plane starts (no FQDN), and waits for the API server and node leases and
  readiness. With a CNI it also waits for the `kubernetes` endpoint and CoreDNS; with the default
  CNI on more than one node, also for pod-network routes; with `--cni NONE`, for none of these
  (`ClusterBootstrapper+Start.swift:131-152`). Then it writes the kubeconfig **with the current
  context set**; a failure of that write is a warning and the command still exits 0
  (`ClusterBootstrapper+Start.swift:155-163`). A missing node fails with "node container <n> not
  found; delete and re-create cluster <c>" (`Support/ClusterHelper+Lifecycle.swift:28-34`).
- `stop` stops only the running nodes of the record and skips missing ones: first the workers in
  parallel, then the control plane. `--time` (default 30 s) is the grace period that the Runtime
  gives each node before it kills it, so one cluster can take up to two grace periods
  (`ClusterStop.swift:36-89`, `Support/ClusterHelper+Lifecycle.swift:43-54`, `ClusterHelper.swift:53`).
  The record and nodes stay.
- Both commands print the name on success. A thrown error exits 1 and an argument error exits 64
  (ArgumentParser) [I]. The old plugin of `17bb57e` has no `start` and `stop`
  (`Sources/Plugins/Cluster/ClusterCommand.swift:48-53`); there, `container cluster start --help`
  exits 0 and prints the top-level help [review 3, run on the installed `1.7.1-bshk.1`].
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
- **D5. No automatic start of clusters in version 1.** A runtime restart stops the running
  clusters in order (F-213); after it they are Stopped, and the user starts them. *Alternative:*
  start them again inside the restart plan (spec 0.3). Cost: review 3 findings 1, 2, 3 and 6
  showed that this needs a cluster identity, one restart plan at a time across processes, one
  finalization path and one time budget (§12).
- **D6. The bridge refuses lifecycle calls on a node with 409.** It prevents accidents from Docker
  clients. It is not a security boundary.
- **D8. When a choice is between new shared state and a stated limit with a visible result,
  version 1 takes the limit.**
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

  One rule: every route that can change a node first takes the checked snapshot (native ID,
  creation date, node label, Docker ID) and decides on it, before any fast return or side effect.
  All bridge mutations of one native name run one at a time for the whole operation, through a new
  per-name lock in the client layer (`ContainerMutationLock`, keyed by native name; it also covers
  create and rename, which take or reuse a name). `VMLifecycleAdmission` stays as the global limit
  (it admits several requests, `Utilities/VMLifecycleAdmission.swift:15-38`, so it cannot be this
  lock). Under the lock, just before each native call of the operation (also the later calls of a
  compound operation, such as stop then delete), the client reads the container again and compares
  native ID, creation date and node label with the snapshot; on a difference it answers 409
  "container <name> changed during the request" and changes nothing more. The Docker ID alone is
  not enough: it can be a stored ID kept across a rebuild (`Utilities/DockerContainerID.swift:11-19,39-47`).

  Routes that can change a container, at `6b3393b`, and where the snapshot is taken:

  | Route | Change before today's client call | Node answer |
  |---|---|---|
  | `POST /containers/{id}/start` | resets restart state; returns success at once for a running container (`Routes/Containers/ContainerStartRoute.swift:46-52`) | 409, decided before both |
  | `POST /containers/{id}/stop` | returns 304 for a stopped container (`ContainerStopRoute.swift:26-36`) | 409, decided before the 304 |
  | `POST /containers/{id}/kill`, `/restart` | — | 409 |
  | `DELETE /containers/{id}` | stops health checks, removes DNS aliases (`ContainerDeleteRoute.swift:84-111`) | 409, decided before both |
  | `POST /containers/{id}/update` | writes the restart-policy store in the route (`ContainerUpdateRoute.swift:34-60`) | 409 |
  | `POST /containers/{id}/rename` | recreates the container (`Clients/ClientContainerService.swift:107,425`) | 409 |
  | `PUT /containers/{id}/archive` | writes the node file system (`Clients/ClientArchiveService.swift:144`) | 409 |
  | `POST /containers/{id}/attach`, `GET .../attach/ws` | prepares the container, which can delete and recreate a stopped one (`ContainerAttachRoute.swift:93-102`, `ContainerAttachWSRoute.swift:28-35`, `ClientContainerService.swift:472-501`) | allowed, but for a node the preparation is skipped |
  | `POST /networks/{id}/connect`, `/disconnect` with a node | a no-op 200 today (`Routes/Networks/NetworkConnectRoute.swift:8-14`) | 409 |
  | `POST /containers/prune` | lists, then deletes each by name (`ClientContainerService.swift:850-852,915-938`) | a node is never a candidate, also with a label filter on the plugin label; each delete takes the lock and re-reads |
  | `POST /containers/create`, rename target | take or reuse a name | take the per-name lock; a node's name gives the Docker name-conflict 409 (`ContainerCreateRoute.swift:798-799`) |

  Allowed for nodes as maintenance access: inspect, logs, stats, wait, export, archive GET and
  HEAD, exec, attach (without preparation), resize. Unchanged: pause, unpause, top, changes,
  commit (not supported or not implemented).

  409 body: `{"message":"<name> is a node of a Kubernetes cluster. Use 'container cluster' or ContainerStack to start, stop or delete it."}`.
- **Limit (Runtime race).** The native calls act by name, and inside the Runtime a force delete
  reads state, waits for the stop, then cleans up by name [S Runtime
  `ContainersService.swift:498-507,850-890,1022-1030`]. A replacement of the container in that
  window is outside the bridge, and so is any change by the `container` CLI. The bridge closes its
  own window (per-name lock and re-read); the rest waits for upstream (issue 2453 moves cluster work
  into the daemon).

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
  never `container` on `PATH`. Every call sets `KUBECONFIG` to one expanded absolute path,
  `$HOME/.containerstack/kubeconfig`, and nothing else (no list of paths), except the explicit
  action of F-207. Before the first call the wrapper creates that file with mode 0600 and
  `apiVersion: v1`, `kind: Config` (the plugin keeps the mode of an existing file, §2.3). It
  refuses to run when that path and `$HOME/.kube/config` resolve to the same file (symbolic link
  or hard link: same device and inode), with "~/.containerstack/kubeconfig is the same file as
  ~/.kube/config; remove the link". Process limits: `list` 20 s, `create` 15 min, `start` 10 min,
  `delete` 5 min, `write-config` 30 s; `stop` as F-213 gives it, else 2 min.
- **[F-203] Capability.** The Kubernetes section and `cstack cluster` work only when the runtime
  has the commands: with the runtime running (the plugin loader needs the API server, §2.4),
  `container cluster start --help` and `container cluster stop --help` each print a usage line
  that names that subcommand (`USAGE: container cluster start`, `... stop`). An exit status of 0
  alone is not proof: the old plugin prints its top-level help with 0 (§2.5). The result is kept
  for the running build (`container --version` commit). Without it, the section says "This runtime has
  no cluster start; update ContainerStack" and offers nothing else.
- **[F-204] One operation at a time per process.** `ClusterOperationLock` (an actor in Core) runs
  the cluster commands that change state (create, start, stop, delete, write-config) one at a time
  in a process, for all clusters, because they all write the one kubeconfig file. A second request
  waits in order. Across processes (app and `cstack`, or the bare CLI) there is no lock: see §7.
- **[F-205] API ready.** `ClusterAPIReady` sends `GET <API endpoint>/readyz` with a 3 s limit,
  trusting only the cluster's CA from `~/.containerstack/kubeconfig` (`certificate-authority-data`
  of the cluster entry), with no client credentials (kubeadm serves `/readyz` to anonymous callers,
  I). `ok` is "API ready"; anything else, or no context in the file, is "API not ready". It checks
  the API server only: a start can fail after the API is ready, on leases, node readiness, DNS or
  routes (§2.5). It runs after each create and start, and every 5 s for running clusters while the
  Kubernetes section shows.

### 6.2 `cstack cluster` (`Sources/CStackCLI/`)

- **[F-206]** Subcommands; each is one Runtime command through F-202:

  | Command | Runs |
  |---|---|
  | `cstack cluster ls [--json]` | `cluster list --format json`. Table `NAME STATE API-READY VERSION NODES API`. `--json` prints the runtime JSON unchanged. |
  | `cstack cluster create <name> [--cpus N] [--memory SIZE] [--workers ...]... [--node-image REF] [--cni PATH\|NONE] [--shared-image-store]` | `cluster create` |
  | `cstack cluster start <name>` / `stop <name>` / `rm <name>` | `cluster start` / `stop` / `delete` (no prompt) |
  | `cstack cluster kubeconfig <name>` | `cluster write-config`, then prints the two lines of F-207 |

  `cstack` uses `~/.containerstack/kubeconfig` and ignores the shell's `KUBECONFIG`. Progress on
  stderr unchanged. Exit codes: 0 done; 1 the Runtime command failed; 64 usage; 69 the runtime does
  not run or has no cluster start (F-203).

### 6.3 App (`Sources/ContainerStackApp/`)

- **[F-207] Kubeconfig.** The inspector shows two lines with copy buttons:
  `kubectl --kubeconfig ~/.containerstack/kubeconfig --context <name> get nodes` and
  `export KUBECONFIG=~/.containerstack/kubeconfig`. The action "Add to ~/.kube/config…" first
  reads `$HOME/.kube/config` (read only). When a cluster, context or user named <name> exists
  there, it refuses: "~/.kube/config already has a cluster, context or user named <name>. container
  would replace it. Remove it first or use the ContainerStack kubeconfig." There is no replace
  option in version 1. Else it asks: "container rewrites the whole file ~/.kube/config. Keys it does
  not know are lost, and it changes the layout. Make a backup first. Add context <name>?" and then
  runs `cluster write-config` with `KUBECONFIG=$HOME/.kube/config` (this command does not change the
  current context, §2.3). The plugin replaces entries of the same name
  (`Support/ClusterHelper+Kubeconfig.swift:163-175`); a change of the file between the check and the
  write is a limit. A cluster
  that the bare CLI created has no context in the app file; the row offers "Write Kubeconfig"
  (`write-config` into the app file).
- **[F-208] Kubernetes section** (D7). `DashboardDestination.kubernetes`, after Stacks, with an
  inspector (`DashboardView.swift:3-28`). One row per cluster: name, state, Kubernetes version,
  nodes, API endpoint. Inspector: nodes (name, roles, state, IP, CPUs, memory), the two lines of
  F-207, "Reach a NodePort Service at http://<node IP>:<node port>". The list refreshes every 5 s
  while the section shows. Files: `KubernetesView.swift`, `RuntimeViewModel+Clusters.swift` (new),
  `DashboardView.swift`.
- **[F-209] Create form.** Name (lowercase letters, digits and `-`, 1 to 63 characters, the first
  a lowercase letter or digit as the Runtime requires, `ClusterResource.swift:46-54`; unique among
  clusters); CPUs and memory with the Runtime defaults (`ClusterHelper.swift:34-40`); worker
  groups (count, CPUs, memory; at most 1024 in total); node image (default kindest/node v1.35.5);
  network plugin (kindnet, a manifest file, none); "Share my local images with the cluster" with the
  three warning points of `docs/cluster.md:5-12` shown when on; a memory note (node limits against
  host memory, 2.2 GB idle per 6 GB node). No `--rm` option: such a cluster cannot start (§2.5).
- **[F-210] States and actions.** The first row that matches wins:

  | Shown | When | Actions |
  |---|---|---|
  | Creating, Starting, Stopping, Deleting | this process runs that command for the cluster | none |
  | Node missing: <names> | a node of the record is not in the bridge list filtered on the plugin label (`GET /containers/json?all=1&filters={"label":["com.apple.container.plugin=cluster"]}`) | Delete |
  | Start failed: <stderr> | a create, start or Restart that this process ran for the cluster failed, and no later start or stop by this process succeeded | Restart, Stop, Delete |
  | API not ready | state `running` and F-205 is not `ok` | Restart, Delete |
  | Running | state `running` and F-205 is `ok` | Stop, Delete |
  | Degraded: k of n nodes run | state `degraded` | Start, Stop, Delete |
  | Stopped | state `stopped` | Start, Delete |

  Restart runs `stop` then `start`, the upstream recovery (§2.5). "Start failed" is in-memory state
  of one process: another process (a second app copy, `cstack`) sees `running` and API ready for a
  cluster whose start failed after the API was up, and an app restart forgets it. This is a limit
  (D8); Doctor's CLI check (F-214) and the user page say how to recover. Other failed commands
  show their stderr on the row until the next command for that cluster.
- **[F-211] Delete.** Confirmation: "Delete cluster <name>? Its nodes, Kubernetes objects and
  volumes are lost." When `~/.kube/config` has a context with this name and the cluster's API
  endpoint, the dialog adds: "~/.kube/config still has context <name>. Remove it with
  `kubectl --kubeconfig "$HOME/.kube/config" config delete-context <name>`, `... delete-cluster
  <name>` and `... delete-user <name>`." Each command names the file, so the shell's `KUBECONFIG`
  does not select another one. The app does not edit `~/.kube/config`.
- **[F-212] Runtime down.** The section shows "The runtime is not running. Start it to manage
  clusters." and the last list, dimmed; no actions and no `cluster` commands.

### 6.4 Runtime lifecycle (D5)

- **[F-213] Stop clusters before `system stop`.** `RuntimeRestartPlan.steps`
  (`RuntimeControl.swift:146-165`) gets a first step `stopClusters`, advisory like
  `stopContainers` (`RuntimeControl.swift:116-123`): it never stops the plan.
  - One budget of 120 s for the list and all stops. The list gets at most 20 s of it. Then, for
    each cluster with state `running` or `degraded`, oldest `creationDate` first, `cluster stop
    --name <n> --time <g>` runs with a process limit equal to the time left, where `g` is the
    smaller of 30 s and one third of the time left (a cluster can take two grace periods, §2.5).
  - When the budget ends, or the list fails or times out, the step ends and the plan goes on to the
    recovery steps as today.
  - The step's result names each cluster as "stopped cleanly", "left to system stop" (not reached,
    or its stop failed or timed out), or, when the list failed, "unknown". The app shows it in a
    banner after the restart, `cstack runtime restart` prints it, and the sidebar shows "Stopping
    cluster <name>…" while it runs (`RuntimeViewModel+Control.swift:145-153`).
  - After the restart the clusters are Stopped (F-210 offers Start). Nothing starts them.
- **[F-217] Clusters that cannot come back.** Before the first stop, the app knows two kinds from
  the list and one check:
  - `configuration.remove` is `true`: made with `--rm`; its nodes are deleted when they stop, and
    it cannot start again (§2.5).
  - More than one node and a stable endpoint not proven: the list JSON has no field for the stable
    endpoint (`ClusterConfiguration.swift:64-101`). The rule: for a running control plane, `container
    exec <cluster name> grep -q controlPlaneEndpoint /etc/kubernetes/kubeadm-config.yaml` (5 s
    limit; the plugin writes that file at create, `Bootstrapper/ClusterBootstrapper+ControlPlane.swift`
    in `983d408`). Exit 0 means stable endpoint; any other result means "may not start again". A
    single-node cluster can restart without it (§2.5). A stopped cluster is not affected by a
    restart and needs no check.
  The app and `cstack` never create `--rm` clusters (F-209, F-206). For the clusters of these kinds
  that run (made with the bare CLI):
  - A Restart from the sidebar or the Doctor repair asks, also when no other cluster runs:
    "Restart the runtime? Cluster <a> was created with --rm and will be deleted. Cluster <b> may not
    start again. Clusters <c> stop and stay stopped." Buttons "Restart" and "Cancel". With running
    clusters of no such kind, the text has only the last sentence.
  - `cstack runtime restart` prints the same text. On a terminal it asks `[y/N]`; with no terminal
    it exits 1 with that text unless `--yes` is given. `cstack runtime stop` and the app's "Stop
    Runtime" stop only the bridge and touch no cluster (§2.1), so they do not ask.
  - The automatic restarts (poll recovery, stale bridge) have no user to ask and exist to recover a
    hung runtime, so they go on; the result banner names each cluster that was deleted or may not
    start.
  Files: `RuntimeControl.swift`, `RuntimeViewModel+Lifecycle.swift`, `RuntimeViewModel+Control.swift`,
  `CStackRuntimeControl.swift`, `SidebarRuntimePanel.swift`, `DoctorViewModel.swift`.

### 6.5 Doctor and docs

- **[F-214] Doctor check `clusters`,** in the CLI and UI sets (`DiagnosticReport.swift:5-19`):
  pass "N clusters, M running"; warning for Stopped ("start it in Kubernetes or with `cstack
  cluster start <name>`"; this names the clusters that a runtime restart left stopped), Degraded,
  API not ready, Node missing, no context in the app kubeconfig;
  failure when the list does not decode or the runtime lacks F-203. Memory check: adds the limits
  of running nodes from the label-filtered list (`DiagnosticRunner+Memory.swift:6-35`).
- **[F-215] Docs.** `docs/kubernetes.md`: create; the app kubeconfig and the two lines; adding to
  `~/.kube/config` and its risk; NodePort and port-forward; no LoadBalancer or ingress; the shared
  image store warning; what Stop, Restart and reboot do to clusters (they stay stopped; `--rm`
  clusters are deleted); API not ready, Start failed and the recovery (Restart = stop then start);
  the bridge guard is not a security boundary.
- **[F-216] Pins.** `scripts/prepare-v1-runtime.sh` and `scripts/prepare-container-runtime.sh`
  (tag and SHA-256) pin `1.7.1-bshk.3`, and the bridge pin carries F-101. The staging script checks
  these exact files under `libexec/container/plugins/` (the set that `Makefile:219-234` installs):
  `cluster/bin/cluster` (executable), `cluster/config.toml`, `cluster/resources/kindnet.yaml`
  (default CNI; create fails without it, `ClusterBootstrapper+ControlPlane.swift:102-117` in
  `983d408`), `cluster/resources/cluster-shim` (executable, static aarch64 ELF),
  `cluster-hoststore/bin/cluster-hoststore` (executable), `cluster-hoststore/config.toml`,
  `container-core-clusters/bin/container-core-clusters` (executable),
  `container-core-clusters/config.toml`. The capability (F-203) is checked live, not in staging.

## 7. Concurrency

ContainerStack adds no shared state. The rules:

- In one process, F-204 runs one changing cluster command at a time.
- Across processes there is no lock. The app and `cstack` both write `~/.containerstack/kubeconfig`
  through the plugin, which reads, edits and writes the whole file with no lock (§2.3). Two
  changing commands at the same time in two processes can lose one context. The user sees the
  cluster with "no context" (F-207, F-214) and fixes it with "Write Kubeconfig".
- A change by another process (bare CLI, a second `cstack`) shows at the next list refresh (5 s).
  A command of the app that meets a state changed under it reports the Runtime's error on the row.
- Two restart plans (app and `cstack`) can run at the same time. Each only stops clusters
  (F-213), and `cluster stop` of a stopped cluster does nothing, so the overlap costs time, not
  data. The second plan's result can say "left to system stop" for a cluster that the first plan
  stopped.
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
| F-101 | Route tests with a fake node: each 409 row answers 409 and the fake records no mutation and no side effect (restart state, 304, health check, DNS aliases, restart-policy store); `/start` of a running node and `/stop` of a stopped node answer 409; HTTP and WebSocket attach to a stopped node with staged files run no preparation; exec runs, archive GET returns bytes, archive PUT writes nothing; a node found by ID prefix and by retired ID is refused; prune with the plugin label filter deletes nothing; network connect and disconnect with and without `--shared-runtimes`. Race: a second bridge mutation of the same name sent after the first request's final read waits for the first to end; a container replaced (new native ID or creation date, or the node label added) between two native calls of one delete stops the delete with 409. | route | Bridge |
| F-201 | Decode the fixture; an extra key passes; a missing `status.state` or `state: "paused"` fails and names the key. | unit | App |
| F-202 | A fake `container` first on `PATH` is not run; with an inherited `KUBECONFIG` that lists several paths, every call (create, failed create with rollback, start, delete, write-config) has exactly the app file, and after each call `$HOME/.kube/config` and the other listed files are byte-equal to before; the file exists with mode 0600 before the first call; a symbolic link from the app path to `~/.kube/config` makes the wrapper refuse. | unit | App |
| F-203 | Fixtures: `cluster start --help` exits 0 with the top-level help (the old plugin): not capable; `start` present and `stop` missing: not capable; both usage lines: capable. | unit | App |
| F-204 | Two `start` requests in one process: the second begins after the first ends. | unit | App |
| F-205 | A local TLS server with the cluster's CA: `ok` is API ready; a 500, a timeout, another CA are API not ready. | unit | App |
| F-206 | Argument mapping for each subcommand; the shell's `KUBECONFIG` is not passed; exit codes. | unit | App |
| F-207 to F-212 | View model tests over fixtures for each row of F-210, including a running control plane with a missing worker (Node missing wins over Degraded), a start that failed followed by `/readyz` `ok` (Start failed stays, Restart offered), and `running` with `/readyz` failing (API not ready); "Add to ~/.kube/config" refuses for a same-name context, for a same-name cluster referenced by another context, and for a same-name user, and the file is byte-equal after; the cleanup commands contain `--kubeconfig "$HOME/.kube/config"`; a name `-dev` is refused. | unit | App |
| F-213 | Plan order: `stopClusters` before `stopContainers`; a list that times out ends the step at 20 s with result "unknown"; a first stop that hangs while two clusters wait: the step ends at 120 s, the plan goes on, and the result names the first as "left to system stop" and the others as not reached; each call gets the time left. Live after S4: `cstack runtime restart --yes` with a running cluster: the result says "stopped cleanly"; the cluster is Stopped; `cstack cluster start` then brings a new node boot, a NodePort answer from the host and a pod DNS lookup (not only `/readyz`). | unit, live | App |
| F-217 | Fixtures: `remove: true` and a multi-node cluster whose exec check fails are named in the Restart text; `cstack runtime restart` with no terminal and no `--yes` exits 1; an automatic restart goes on and its result names them. | unit | App |
| F-214 | Doctor fixtures for each warning; the memory total includes a node found only through the label filter. | unit | App |
| F-216 | The staging check fails for each named file left out, one at a time, and for each named executable without its executable bit. | CI | App |

## 9. Order of work

| Slice | Requirements | Repository | Needs | Parallel with |
|---|---|---|---|---|
| S1 Fork release | F-001 to F-003 | Runtime | the fork live check [P] | S2, S3 |
| S2 Node guard | F-101 | Bridge | — | S1, S3 |
| S3 Core and `cstack` | F-201 to F-206 | App | the JSON of §2.1 (unchanged by 2485) | S1, S2 |
| S4 Pins | F-216 | App | S1, S2 | S5 |
| S5 App section and lifecycle | F-207 to F-214, F-217 | App | S3; live tests after S4 | S4 |
| S6 Docs | F-215 | App | S5 | — |

## 10. Non-goals

- A Kubernetes object browser in the app.
- LoadBalancer, ingress and host port publishing (D3; upstream 2557 later).
- A cluster in a shared or project VM (D4).
- Clusters that start by themselves, after a runtime restart or otherwise (D5, §12).
- `--rm` clusters in the app (they cannot start, §2.5).
- Changes to `~/.kube/config` other than the explicit action of F-207.
- A security boundary between Docker clients and nodes (D6).

## 11. Pending: fork live check

The fork worker checks these on `feat/cluster-start-stop`; the results go into F-001 and F-213
limits, not to the owner: node stop time with the upstream 30 s grace (it was about 90 s, §2.2),
which decides whether the 120 s budget of F-213 is enough for one cluster; 1 + 2 workers with fix
2543; the shared image store after a runtime restart; the failed-start gap (state `running` and
`/readyz` `ok` after a start cut after the API was up, and `stop` then `start` as recovery); the
exit code of a failed `cluster start`; the F-217 exec check on a cluster made before 2485.

## 12. Later: start clusters again after a runtime restart

Not in version 1 (D5). A later version that restarts the stopped clusters needs, from review 3:

1. A cluster identity `(name, creationDate)`, checked before the stop and before the start, so a
   deleted and re-created cluster of the same name is not started (finding 2).
2. One restart plan at a time across the app and `cstack` (finding 2).
3. One finalization path in both executors: after any failed step, superseded plan or failed bridge
   launch, try the start when the Runtime API answers, wait for real bridge readiness, and report
   every cluster left stopped or unknown (finding 3).
4. One time budget for the stop side and the start side (finding 6), and the `--rm` and
   pre-stable-endpoint rules of F-217 (finding 1).

## 13. Open questions

None for the owner. Decisions D1 to D8 are the owner's of 2026-11-23.
