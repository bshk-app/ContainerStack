# Spec: Kubernetes clusters, version 1

Version: 1.2, accepted for implementation. History: 0.1 to 0.4 and four design reviews
(`reviews/2026-11-23-kubernetes-review-1.md` to `-review-4.md`). 1.0 simplifies the bridge guard
(F-101), fixes the capability probe to the real help output (F-203), gives the restart step one
deadline (F-213, F-217) and checks the kubeconfig alias before any write (F-202). Precision past
this point is checked in the code review of each slice.
Date: 2026-11-23

Changes since 1.1 (the fork live check of 2026-11-23/24, report `report.md` and logs in the local
directory `k8s-fork`, cited as "k8s-fork"):

- §11: results of the fork live check; four items stay pending for the S4/S5 live tests.
- §2.5: every stop ends in a kill, with the disk unmounted; measured stop times. F-213: what the
  120 s deadline holds, and the result wording "stopped in order" (no clean shutdown).
- F-205, F-206, F-210, F-214: a reset or refused API check on a cluster whose nodes all run names
  the Local Network permission of the runtime as a likely cause.
- §2.5 limits: no StorageClass, a second start does not apply the control-plane network settings
  again, node IPs change at every start (F-208: nothing stores a node IP).
- F-001: the fork branch, its base and its three commits.
- F-209: the name must also end with a lowercase letter or digit (kubeadm endpoint). F-214: the
  Doctor rule for the Local Network line.
- §2.1: facts from the live list fixtures (absent keys, the port of a stopped control plane, an
  interrupted start that lists as running, one role per node).

Changes since 1.0 (the spec follows the code of slices S2, bridge `feat/cluster-node-guard` at
`0e06f99`, and S3, `feat/k8s-core-cstack` at `c6e5807`):

- F-101: no node check on create (the Runtime refuses the name) or on network connect and
  disconnect (they change no container); prune skips a
  candidate only when its new lookup shows a node; the first lookup of stop, kill, restart and
  start fails open; a new rule for the DNS sidecar name.
- F-101 (bridge `47d12b9`): an attach, HTTP or WebSocket, to a stopped node gets 409 in the lookup
  step; an attach to a running node is allowed. The start preparation refuses a node before it
  rebuilds a container. DNS sidecar removal looks the name up again before the stop and each
  delete, and treats only "not found" as absent.
- §12: network members are counted without nodes.
- F-201: the API endpoint rule. F-202: the alias check also at file creation; the home directory
  is the user's home, not `$HOME`. F-203: the usage line rule, a running runtime first, no cache of
  a failed call. F-205: two limits. F-206: the API check after `start` and `create`, `ls` columns,
  usage errors and exit codes.

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
inferred. **[P]** pending (until version 1.1): the fork live check of the branch `feat/cluster-start-stop` (report
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

- Live fixtures of a three-node cluster (`running`, `stopped`, `degraded`, and `running` after an
  interrupted start) [L k8s-fork `fixtures/`]:
  - A stopped node has no `addresses` key, and a worker has no `ports` key: the keys are absent,
    not `null` (the decoder treats an absent key and `null` the same).
  - A stopped control plane still lists its port `6445->6443`, so a stopped cluster has an API
    endpoint; only running clusters are probed (F-205).
  - The output after an interrupted start is identical to a normal running one except for the node
    IPs. Only the API-ready check (F-205) or the in-process "Start failed" state (F-210) can show
    the difference.
  - In a multi-node cluster each node has one role (`control-plane` or `worker`); a single-node
    cluster has both on one node (§2.1 example).
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
  The record and nodes stay, except for a cluster made with `--rm`: the runtime removes its nodes
  when they stop, and the record stays (`docs/cluster.md:228-250` in `983d408`).
- Every stop ends in a kill. systemd in the node does not finish its shutdown inside the grace time
  (it waits up to 1 min 30 s for the containerd scopes): after 30 s for `cluster stop`, after 5 s
  in the runtime restart (`system stop`), vminitd sends signal 9 and then unmounts the data disk.
  No boot showed a journal recovery or fsck. So a stop kills etcd and the pods, and the file system
  stays clean. Measured `cluster stop`: 32 s for one node; 39 to 68 s for three nodes (a control
  plane and two workers) [L k8s-fork `step4-cs-a-bootlog.txt`, `step6-bootlog-*.txt`, report §7].
- Limits: the node image has no StorageClass and no provisioner, so a PVC needs a static PV
  [L k8s-fork `step1-workload-no-storageclass.txt`]. A second `start` on a cluster whose control
  plane already runs does not apply the control-plane network settings (sysctls, iptables rules)
  again (`ClusterBootstrapper+Start.swift:92-103` in the fork branch; read in source, not shown
  live). Node IPs change at every start [L k8s-fork `step3-stop-start.txt`].
- Both commands print the name on success. A thrown error exits 1 and an argument error exits 64
  (ArgumentParser) [I]. The old plugin of `17bb57e` has no `start` and `stop`
  (`Sources/Plugins/Cluster/ClusterCommand.swift:48-53`); there, `container cluster start --help`
  exits 0 and prints the top-level help [review 3, run on the installed `1.7.1-bshk.1`].
- Documented limits (`docs/cluster.md` in the PR): a start that fails part way can leave the
  cluster `running`, and the recovery is `cluster stop` then `cluster start`; a cluster made before
  the stable endpoint cannot restart multi-node; a cluster made with `--rm` cannot start.
- Tests in the pull request thread report that `system stop`, `system start`, `cluster start` works
  on 1 node and on 1 + 1 workers with PVC data kept; 2 or more workers need fix 2543 [owner's
  summary]. The fork live check confirmed 1 node and 1 + 2 workers with fix 2543 (§11).
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
  and fix 2543 (`c308ec1`), unchanged, each as its own commit with the upstream reference in the
  message. When upstream merges them, the next fork release drops the patches. The fork branch
  `feat/cluster-start-stop` is built on tag `1.7.1-bshk.2` (`f11f9ad`, = `origin/bshk/1.7.1`),
  head `b9aee43`, with three commits: "Add container cluster start and stop (upstream pull request
  2485)", "Fix double close of stdio descriptors in cluster exec helpers (upstream pull request
  2543)", "Build cluster-shim for fork releases and require it in the package" [L k8s-fork report
  §1, §2].
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

  Rule: each route that can change a container resolves its target once at route entry. When the
  resolved container carries the label `com.apple.container.plugin=cluster`, the route answers 409
  before any fast return, bookkeeping or side effect. Body:
  `{"message":"<name> is a node of a Kubernetes cluster. Use 'container cluster' or ContainerStack to start, stop or delete it."}`.

  Routes at `6b3393b` and where the check goes [S Bridge `Sources/socktainer/Routes/Containers/`]:

  | Route | Check before | Node answer |
  |---|---|---|
  | `POST /containers/{id}/start` | the restart-state reset and the fast return for a running container (`ContainerStartRoute.swift:46-52`) | 409 |
  | `POST /containers/{id}/stop` | the 304 for a stopped container (`ContainerStopRoute.swift:26-36`) | 409 |
  | `POST /containers/{id}/kill` | the client call | 409 |
  | `POST /containers/{id}/restart` | the restart-state reset (`ContainerRestartRoute.swift:26-33`) | 409 |
  | `DELETE /containers/{id}` | the health-check stop and DNS alias removal (`ContainerDeleteRoute.swift:84-111`) | 409 |
  | `POST /containers/{id}/update` | the restart-policy store write (`ContainerUpdateRoute.swift:34-60`) | 409 |
  | `POST /containers/{id}/rename` | the same-name fast return and the delete and recreate (`ContainerRenameRoute.swift:100-110,183-229`). The source is checked; the target name is checked against nodes too, with the route's case-alias rule (`ContainerRenameRoute.swift:124-135`) | 409 when the source or the target name is a node |
  | `POST /containers/create` | no check. The Runtime refuses a name that a node holds, and the route answers the Docker name-conflict 409 (`ContainerCreateRoute.swift:798-799`). The create-option and volume writes before that refusal (`ContainerCreateRoute.swift:761-797`) change nothing that a node owns | 409 (name conflict) |
  | `PUT /containers/{id}/archive` | the file system write | 409 |
  | `POST /containers/{id}/attach`, `GET .../attach/ws` | the lookup step of both routes (`ContainerAttachRoute.swift:93-104`, `ContainerAttachWSRoute.swift:34-38`) | an attach (HTTP or WebSocket) to a stopped node gets 409 "You cannot attach to a stopped container, start it first" in the lookup step, before any start preparation, DNS sidecar, parked stdio or upgrade; an attach to a running node is allowed as before |
  | `POST /networks/{id}/connect`, `/disconnect` | no check: 200 as before; these routes change no container (`Routes/Networks/NetworkConnectRoute.swift:8-14`). A node check is needed when a route gets an effect on a container | 200 |
  | `POST /containers/prune` | each delete (`Clients/ClientContainerService.swift:850-852,915-938`) | a node is never a candidate, also with a label filter on the plugin label; a candidate is skipped only when its new lookup at its delete shows a node, and the prune continues; a failed lookup does not skip it; a skipped candidate is not in `ContainersDeleted` |

  Allowed for nodes: inspect, logs, stats, wait, export, archive GET and HEAD, exec, attach to a
  running node, resize. Unchanged: pause, unpause, top, changes, commit (not supported or
  not implemented).

  DNS sidecar name: the bridge uses, replaces or removes a container named
  `socktainer-dns-<network>` only when it has the labels `socktainer.role=dns` and
  `socktainer.network=<network>`. Any other container with that name is left alone
  (`DNS/NetworkDNSManager.swift`, `occupant`). Sidecar removal looks the name up again before the
  stop and before each delete, and treats only "not found" as absent.

  Start preparation: when the preparation would rebuild a stopped container, it looks the name up
  again and refuses a node before the rebuild (`Clients/ClientContainerService.swift:488-500`,
  `prepareRefreshed`).
- **Limit (replacement window).** The check and the native calls are separate steps: the routes
  resolve again in the client and act by native name (`ContainerStopRoute.swift:26-36`,
  `Clients/ClientContainerService.swift:583-590`), and `VMLifecycleAdmission` admits several
  requests at a time (`Utilities/VMLifecycleAdmission.swift:15-38`). A container that is replaced
  by a node between the check and a native call is not caught. That needs a `cluster create` with
  the same name inside that window. Serialization of bridge mutations per name is separate bridge
  work (§12). Inside the Runtime, a force delete also cleans up by name
  (`ContainersService.swift:498-507,850-890,1022-1030`); upstream issue 2453 moves cluster work into
  the daemon.
- **Limit (failed first lookup).** When the first lookup of stop, kill, restart or start fails, the
  route goes on without the check (fail open), as before the guard. Delete checks its second lookup
  too.

## 6. Requirements: ContainerStack

### 6.1 Core (`Sources/ContainerStackCore/`)

- **[F-201] Cluster model.** `KubernetesCluster` decodes one element of `cluster list --format
  json`. Required: `configuration.name`, `kubernetesVersion`, `remove`, `sharedImageStore`,
  `creationDate`, `nodes[].name`, `nodes[].roles`; `status.state` (`running` | `degraded` |
  `stopped`); `status.nodes[].name`, `status.nodes[].status`. Optional: `cni`, `fqdn`,
  `status.nodes[].addresses`, `ports`. Unknown keys are ignored; a missing required key or an
  unknown state is an error that names the key, shown in place of the list. The fixture is the
  array of §2.1. API endpoint: `https://<fqdn>:6443` when the record has an FQDN, else
  `https://127.0.0.1:<host>` with the published host port `<host>-><6443>`.
- **[F-202] Command wrapper.** `ClusterCommands` runs `<containerPath> cluster ...` with
  `containerPath` from `RuntimeProcessConfiguration.make` (`RuntimeProcessConfiguration.swift:62-99`),
  never `container` on `PATH`. The home directory is `FileManager.homeDirectoryForCurrentUser`,
  not `$HOME`. Every call sets `KUBECONFIG` to one absolute path, `<home>/.containerstack/kubeconfig`,
  and nothing else (no list of paths), except the explicit action of F-207. Precondition, before
  any initialization of the managed file and before any plugin call (F-207 included): follow both
  `<home>/.containerstack/kubeconfig` and `<home>/.kube/config` to their files; when both exist and
  have the same device and inode (symbolic link or hard link, from either side), refuse with
  "~/.containerstack/kubeconfig is the same file as ~/.kube/config; remove the link", write nothing
  and start no child process. After the precondition, the wrapper creates the managed file when it
  is missing (exclusive create), with mode 0600 and `apiVersion: v1`, `kind: Config` (the plugin
  keeps the mode of an existing file, §2.3). When the new file turns out to be the same file as
  `<home>/.kube/config` (a dangling link from `~/.kube/config` to the managed path), the wrapper
  removes it and refuses the same way. Process limits: `list` 20 s, `create` 15 min, `start` 10 min,
  `delete` 5 min, `write-config` 30 s; `stop` as F-213 gives it, else 2 min.
- **[F-203] Capability.** The Kubernetes section and `cstack cluster` work only when the runtime
  has the commands. First `container system status` must succeed (the plugin loader needs the API
  server, §2.4); else the result is "runtime not running" (`cstack` exit 69). Then `container
  cluster start --help` and `container cluster stop --help` each print a line that starts with
  `USAGE:` and whose command tokens end with `cluster start` (or `cluster stop`), so both `USAGE:
  cluster start` and `USAGE: container cluster start` pass; trailing options are allowed. The patched plugin prints `USAGE: cluster start [--name <name>]` and `USAGE: cluster
  stop [--name <name>] [--signal <signal>] [--time <time>]` [L `probe-help.txt`, plugin binary of
  `feat/cluster-start-stop` at `b9aee43`, run directly]; through `container`, the same plugin
  binary prints it [I; the live probe is in §11]. An exit status of 0 alone is not proof: the old
  plugin prints its top-level help with 0 (§2.5). The result is kept for the running build
  (`container --version` output); a help call that fails is not kept. Without it, the section says "This runtime has
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
- **Local Network permission.** The kubeconfig endpoint is `https://127.0.0.1:<port>` through the
  runtime's port forwarder. When `container-runtime-linux` has no macOS Local Network permission,
  every published port resets the connection, while `cluster create` and `cluster start` still exit
  0 and "API ready" fails [L k8s-fork report §5, `02-portprobe-official.txt`: the same with the
  official runtime]. ContainerStack does not detect the permission itself: no public API reports
  the Local Network permission of another process [I]. Rule: when the F-205 check fails with a
  connection reset or a refused connection (not a timeout, not a TLS or HTTP error), every node of
  the record runs, and the API cannot be starting, the result names the permission as the likely
  cause: "Likely cause: the runtime has no Local Network permission. Allow container-runtime-linux
  in System Settings > Privacy & Security > Local Network." "Cannot be starting" means: a `cluster
  create` or `cluster start` by this process exited 0 before the check (the plugin waits for the API
  server inside the node before it exits, `ClusterBootstrapper+Start.swift:93-103`), or the checks
  have failed this way for 30 s in a row (six checks 5 s apart) [I: a starting API server can also
  refuse for a short time]. The app row (F-210), `cstack` (F-206) and Doctor (F-214) use this rule.
  Doctor keeps its 20 s report limit (`DiagnosticRunner.swift:39`) and makes one F-205 check per
  running cluster. When the process has a prior observation (30 s of the same failure, or its own
  `create` or `start` that exited 0), Doctor shows the likely-cause line. With none (a fresh
  `cstack doctor`), it shows a warning that names both causes: "The API can still be starting if
  the cluster started in the last minute; else the runtime probably has no Local Network
  permission. Allow container-runtime-linux in System Settings > Privacy & Security > Local
  Network."
- **Limits of F-205.** The kubeconfig reader reads the shape that the plugin writes; a file of
  another shape reads as no context (API not ready). The request uses the system proxy settings, so
  a proxy that does not exempt `127.0.0.1` or the FQDN can make the check fail.

### 6.2 `cstack cluster` (`Sources/CStackCLI/`)

- **[F-206]** Subcommands; each is one Runtime command through F-202:

  | Command | Runs |
  |---|---|
  | `cstack cluster ls [--json]` | `cluster list --format json`. Table `NAME STATE API-READY VERSION NODES API`: API-READY is `yes` or `no` for a running cluster and `-` for any other; NODES is the count of nodes in the record. `--json` prints the runtime JSON unchanged. A failed list prints the runtime's error text. |
  | `cstack cluster create <name> [--cpus N] [--memory SIZE] [--workers ...]... [--node-image REF] [--cni PATH\|NONE] [--shared-image-store]` | `cluster create` |
  | `cstack cluster start <name>` / `stop <name>` / `rm <name>` | `cluster start` / `stop` / `delete` (no prompt) |
  | `cstack cluster kubeconfig <name>` | `cluster write-config`, then prints the two lines of F-207 |

  `cstack` uses `~/.containerstack/kubeconfig` and ignores the shell's `KUBECONFIG`. Progress on
  stderr unchanged. After `start` and `create` exit 0, `cstack` checks F-205: a probe every 5 s,
  each with a 3 s limit, for at most 30 s. When the API is not ready, it prints "To recover, run
  'cstack cluster stop <name>', then 'cstack cluster start <name>'." and exits 1; when the Local
  Network rule of F-205 matches, it prints the likely-cause line first. A cluster with no
  published API port and no FQDN skips the check, and `cstack` says so. An option written as
  `--opt=value` is a usage error. Exit codes: 0 done; 1 the Runtime command failed, the API is not
  ready, or the kubeconfig alias refusal (F-202); 64 usage; 69 the runtime does not run or has no
  cluster start (F-203).

### 6.3 App (`Sources/ContainerStackApp/`)

- **[F-207] Kubeconfig.** The F-202 precondition runs first, also for the action below. The
  inspector shows two lines with copy buttons:
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
  while the section shows. Node IPs change at every start (§2.5): the app and `cstack` show the IP
  from the latest list and store no node IP. Files: `KubernetesView.swift`, `RuntimeViewModel+Clusters.swift` (new),
  `DashboardView.swift`.
- **[F-209] Create form.** Name (lowercase letters, digits and `-`, 1 to 63 characters, the first
  a lowercase letter or digit as the Runtime requires, `ClusterResource.swift:46-54`, and the last a
  lowercase letter or digit too: without an FQDN the fork gives kubeadm `<name>:6443` as the
  control-plane endpoint, and kubeadm needs an RFC 1123 name,
  `Support/ClusterHelper+Networking.swift:30-36` in `feat/cluster-start-stop`; unique among
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
  | API not ready | state `running` and F-205 is not `ok`; when the Local Network rule of F-205 matches, the row adds its likely-cause line | Restart, Delete |
  | Running | state `running` and F-205 is `ok` | Stop, Delete |
  | Degraded: k of n nodes run | state `degraded` | Start, Stop, Delete |
  | Stopped | state `stopped` and every node of the record is present | Start, Delete |

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
  - One monotonic deadline, 120 s from the start of the step, covers the list, the F-217 probes and
    all stops. Process queueing, launch, termination and output drain are charged to it: each
    child process gets the time left as its limit, and the step does not start a child when less
    than 5 s are left. `cluster stop --name <n> --time <g>` gets `g` = the smaller of 30 s and one
    third of the time left, rounded down to whole seconds; when `g` is below 1 s, that stop is not
    started (`ClusterStop.swift:39-40` in `983d408`). Clusters: state `running` or `degraded`,
    oldest `creationDate` first.
  - At the deadline, or when the list fails, the step ends and the plan goes on to the recovery
    steps as today.
  - Result per cluster: "stopped in order"; "left to system stop" (not reached, or its stop failed
    or timed out); "nodes removed" only when a later list shows that its nodes are gone; when the
    list failed, one line "cluster inventory unknown".
  - Publication follows the lifecycle queue contract (`docs/specs/2026-10-07-runtime-lifecycle-queue.md`
    F-002 and §3.5). `cstack runtime restart` prints the result when the step settles, before the
    next step. The app checks its token after the list, after each probe and after each stop; it
    publishes the result in a banner when the plan ends, with success or failure, while its token
    is current; a superseded plan publishes nothing. The sidebar shows "Stopping cluster <name>…"
    while a stop runs (`RuntimeViewModel+Control.swift:145-153`).
  - After the restart, clusters whose nodes all exist show Stopped with Start (F-210); others show
    Node missing. Nothing starts them.
  - What the step gives: every stop ends in a kill (§2.5), so the value of the step is the ordered
    stop (workers, then the control plane) and the unmount of each node disk, not a clean process
    shutdown. A cluster "left to system stop" is killed after 5 s and its disk is unmounted too
    [L k8s-fork `step4-cs-a-bootlog.txt`]. With the measured times at the full 30 s grace (32 s
    for one node, up to 68 s for three nodes) and a short list, the 120 s deadline holds three
    one-node clusters, or one three-node and one one-node cluster [I: from the measured times].
    Later clusters get a shorter grace (one third of the time left), and while 5 s remain they
    still get the ordered stop; the rest are "left to system stop" in the result.
- **[F-217] Clusters that cannot come back.** Two kinds, among clusters with state `running` or
  `degraded`:
  - `configuration.remove` is `true` (made with `--rm`): the runtime removes its nodes when they
    stop, and it cannot start again (§2.5).
  - More than one node and the stable endpoint not proven. The list JSON has no field for it
    (`ClusterConfiguration.swift:64-101`). The probe: `container exec <cluster name> cat
    /etc/kubernetes/kubeadm-config.yaml`; it proves the endpoint only when the output has a
    non-empty YAML key `controlPlaneEndpoint` in the `ClusterConfiguration` document (the patched
    bootstrap writes it there, `Bootstrapper/ClusterBootstrapper+ControlPlane.swift:24-34,144-147`
    in `983d408`). Any other result, or no time left for the probe, is "unproven". The probe is
    evidence for the key only, nothing more. A single-node cluster can restart without it (§2.5).
  The app and `cstack` never create `--rm` clusters (F-209, F-206).
  - Manual Restart (sidebar, Doctor repair, `cstack runtime restart`): a preflight, with its own
    limit of 30 s for the list and the probes, runs before the question; the time that the user
    takes to answer is not charged to anything, and the F-213 deadline starts after the answer. The
    question names each kind: "Cluster <a> was created with --rm: its nodes will be removed.
    Cluster <b> has more than one node and may not start again. Clusters <c> stop and stay
    stopped." With no running cluster it asks nothing. When the preflight list fails, the question
    says "Cluster inventory unknown: running clusters may stop." `cstack runtime restart` asks
    `[y/N]` on a terminal; with no terminal it exits 1 with that text unless `--yes` is given.
  - `cstack runtime stop` and the app's "Stop Runtime" stop only the bridge and touch no cluster
    (§2.1), so they do not ask.
  - Automatic restarts (poll recovery, stale bridge) have no user to ask and exist to recover a hung
    runtime: the probes run inside the F-213 deadline, and the result names the clusters of these
    kinds with the F-213 wording.
  Files: `RuntimeControl.swift`, `RuntimeViewModel+Lifecycle.swift`, `RuntimeViewModel+Control.swift`,
  `CStackRuntimeControl.swift`, `SidebarRuntimePanel.swift`, `DoctorViewModel.swift`.

### 6.5 Doctor and docs

- **[F-214] Doctor check `clusters`,** in the CLI and UI sets (`DiagnosticReport.swift:5-19`):
  pass "N clusters, M running"; warning for Stopped ("start it in Kubernetes or with `cstack
  cluster start <name>`"; this names the clusters that a runtime restart left stopped), Degraded,
  API not ready (with the likely-cause line of the F-205 Local Network rule when it matches), Node
  missing, no context in the app kubeconfig;
  failure when the list does not decode or the runtime lacks F-203. Memory check: adds the limits
  of running nodes from the label-filtered list (`DiagnosticRunner+Memory.swift:6-35`).
- **[F-215] Docs.** `docs/kubernetes.md`: create; the app kubeconfig and the two lines; adding to
  `~/.kube/config` and its risk; NodePort and port-forward; no LoadBalancer or ingress; the shared
  image store warning; what each runtime action does to clusters ("Stop Runtime" stops only the
  bridge and clusters keep running; Restart and reboot stop them and they stay stopped; the nodes of
  a `--rm` cluster are removed); API not ready, Start failed and the recovery (Restart = stop then start);
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
| F-001 | Fork live check (done, §11): create 1 node and 1 + 2 workers, NodePort Service and a PVC, `system stop`, `system start`, `cluster start`: a new boot, NodePort answers, the PVC data is there. A start cut part way: state `running`; `stop` then `start` recovers. | live | Runtime |
| F-002 | The release payload check fails on a package without the shim; `make container BUILD_CONFIGURATION=release` without a shim exits non-zero. | CI | Runtime |
| F-101 | One route test per row of the table with a fake node: the answer, and no side effect happened (no restart-state reset, no 304, no health-check stop, no DNS alias removal, no restart-policy write, no delete or recreate); rename with the node as source, as target, and as a target that differs only in case; create with a node's name; HTTP and WebSocket attach to a stopped node with staged files run no preparation; exec runs, archive GET returns bytes; a node found by ID prefix and by retired ID is refused; prune with the plugin label filter deletes nothing; a candidate replaced by a node after the listing is not deleted, is not in `ContainersDeleted`, and the prune answers 200. | route | Bridge |
| F-201 | Decode the fixture; an extra key passes; a missing `status.state` or `state: "paused"` fails and names the key. | unit | App |
| F-202 | A fake `container` first on `PATH` is not run; with an inherited `KUBECONFIG` that lists several paths, every call (create, failed create with rollback, start, delete, write-config) has exactly the app file, and after each call `$HOME/.kube/config` and the other listed files are byte-equal to before; the file exists with mode 0600 before the first call. Alias: a symbolic link from the default path to the managed file, a symbolic link the other way, and a hard link: each refusal leaves both files byte-equal, creates no file, and starts no child process (the fake records no launch), also for the F-207 action. | unit | App |
| F-203 | Fixtures from `probe-help.txt`: `USAGE: cluster start [--name <name>]` and `USAGE: cluster stop ...` give capable; the old plugin's top-level help with exit 0 gives not capable; `start` present and `stop` missing gives not capable. | unit | App |
| F-204 | Two `start` requests in one process: the second begins after the first ends. | unit | App |
| F-205 | A local TLS server with the cluster's CA: `ok` is API ready; a 500, a timeout, another CA are API not ready. | unit | App |
| F-206 | Argument mapping for each subcommand; the shell's `KUBECONFIG` is not passed; exit codes. | unit | App |
| F-207 to F-212 | View model tests over fixtures for each row of F-210, including a running control plane with a missing worker (Node missing wins over Degraded), a start that failed followed by `/readyz` `ok` (Start failed stays, Restart offered), and `running` with `/readyz` failing (API not ready); "Add to ~/.kube/config" refuses for a same-name context, for a same-name cluster referenced by another context, and for a same-name user, and the file is byte-equal after; the cleanup commands contain `--kubeconfig "$HOME/.kube/config"`; the names `-dev` and `dev-` are refused. | unit | App |
| F-213 | Plan order: `stopClusters` before `stopContainers`. With a fake clock and fake children: a list that times out ends the step with "cluster inventory unknown"; a first stop whose child ignores SIGTERM while two clusters wait: the step ends by the deadline plus the child-termination limit charged to it, the plan goes on, and the result names the first "left to system stop" and the others not reached; several probes that time out leave the later clusters "unproven"; `--time` is whole seconds and no stop starts when it would be 0. Publication: a superseded app plan shows no banner; a plan that fails after the step shows the banner while its token is current; `cstack` prints the result before the next step. Live after S4: `cstack runtime restart --yes` with a running cluster: "stopped in order"; the cluster is Stopped; `cstack cluster start` then brings a new node boot, a NodePort answer from the host and a pod DNS lookup (not only `/readyz`). | unit, live | App |
| F-217 | Fixtures: `remove: true` gives "its nodes will be removed" in the question and "nodes removed" in the result only when the later list shows them gone; a probe output with `controlPlaneEndpoint: ""` or the key only in a comment is unproven; a non-empty key proves it; a preflight list failure gives "Cluster inventory unknown"; the time to answer the question is not charged; `cstack runtime restart` with no terminal and no `--yes` exits 1; an automatic restart asks nothing. | unit | App |
| F-214 | Doctor fixtures for each warning; the memory total includes a node found only through the label filter. | unit | App |
| F-216 | The staging check fails for each named file left out, one at a time, and for each named executable without its executable bit. | CI | App |

## 9. Order of work

| Slice | Requirements | Repository | Needs | Parallel with |
|---|---|---|---|---|
| S1 Fork release | F-001 to F-003 | Runtime | the fork live check (done, §11) | S2, S3 |
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

## 11. Results of the fork live check

The fork live check of 2026-11-23/24 ran the patched runtime (`b9aee43`, Developer ID build) on
alex-mac [L k8s-fork report]. Results:

1. Stop time: every stop ends in a kill; `cluster stop` takes 32 s for one node and 39 to 68 s for
   three nodes (§2.5). The 120 s deadline of F-213 holds one cluster of either size (F-213).
2. Restart recovery: after `cstack runtime restart` the cluster is `stopped`; `cluster start` takes
   46 s for one node and 71 s for three nodes, and node readiness, NodePort from the host, the
   ConfigMap and PVC markers, pod DNS and egress pass [L k8s-fork `step4-runtime-restart.txt`,
   `step6-runtime-restart.txt`] (F-001, F-213).
3. Multi-node with fix 2543: a control plane and two workers stop and start, and pod-to-pod traffic
   between the workers passes [L k8s-fork `step6-multinode.txt`] (F-001).
4. Shared image store: an image from `docker build` through the bridge runs in a pod with
   `imagePullPolicy: Never`, also after a runtime restart [L k8s-fork `step2-shared-store.txt`,
   `step5-shared-store-after-restart.txt`] (F-001, F-002).
5. Interrupted start: a late kill (all VMs up) leaves `running`; the next `start` is a no-op; pod
   DNS, egress and pod-to-pod fail; it healed in 180 s, or by `stop` and `start`. An early kill
   (only the control plane up) leaves `degraded`; the next `start` starts the rest
   [L k8s-fork `step7-interrupted-start.txt`, `step7-recovery.txt`, `step7-early-kill.txt`]
   (F-210).
6. List JSON: the shape of §2.1, with fixtures for `running`, `stopped`, `degraded` and `running`
   after an interrupted start; a stopped node has no `addresses`; no field for the control-plane
   endpoint or readiness [L k8s-fork `fixtures/`] (F-201, F-217).
7. Bridge: `docker ps -a` does not list the nodes, and `docker inspect` finds each one [L k8s-fork
   `step8-9-bridge-fixtures.txt`] (F-101).
8. Kubeconfig endpoint through the host: not reachable on alex-mac, because the runtime has no
   Local Network permission there (F-205 Local Network rule).

Pending: S4/S5 live test:

1. The usage line through `container cluster start --help` on a running daemon (F-203 accepts both
   forms).
2. The exit code of a failed `cluster start` (F-206).
3. The F-217 probe on a multi-node cluster made before the stable endpoint.
4. `container build` with the shared image store (not done: the builder image pull hung on
   alex-mac, not related to the cluster code).

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

Also later: network members are counted from a listing that hides plugin containers
(`Clients/ClientNetworkService.swift:22`), so a network that holds only nodes looks empty to the
startup network reaper and to `network prune`. Today nodes use the built-in `default` network,
which is exempt (`Utilities/OrphanedNetworkReaper.swift:17`).

Also later: serialization of bridge mutations per native name for the whole operation, which closes
the replacement window of F-101 (review 4, issues 1 and 2).

## 13. Open questions

None for the owner. Decisions D1 to D8 are the owner's of 2026-11-23.
