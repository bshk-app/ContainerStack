# Spec: Kubernetes clusters, version 1

Version: 0.1 (for design review; no code exists)
Date: 2026-11-23
Source: the live check of 2026-11-23 (`report.md` and its logs in the local directory
`k8s-live`, cited as "k8s-live"), a second live check for this spec (logs in the local directory
`k8s-spec`, cited by file name only), and the source of three repositories at these revisions:

| Name in this spec | Repository | Revision |
|---|---|---|
| **Runtime** | `container` fork, branch `bshk/1.7.1` | `17bb57e`. Tag `1.7.1-bshk.2` (`f11f9ad`), which the app pins, has no other change in the cluster paths (`git diff 1.7.1-bshk.2 bshk/1.7.1` over `Sources/Plugins`, `Sources/ContainerCluster`, `Sources/ContainerResource/Cluster`, `Sources/Services/ContainerClusterService`, `Sources/ContainerCommands`, `Makefile`, `.github`, `cluster-shim`, `docs/cluster.md` touches only `.github/bshk-release-notes.md`). The installed keg is `1.7.1-bshk.1`, server commit `17bb57e` (`preflight.txt`). The app bundle copies the whole package payload, plugins included [S App `scripts/prepare-container-runtime.sh:93-104`, `scripts/stage-containerstack-app.sh:154`]. |
| **Bridge** | `socktainer` fork | `6b3393b`, the `SOCKTAINER_REV` of `scripts/prepare-v1-runtime.sh:37`. The first live check ran bridge `166bbd5`. |
| **App** | ContainerStack | `d633708` |

Markers: **[S]** read in source (repository, file:line), **[L]** verified live (log file),
**[I]** inferred. A claim with no marker is a requirement or a decision of this spec.

## 1. Overview

Apple Container 1.7 ships the `cluster` plugin. `container cluster create` makes a Ready
Kubernetes cluster of one or more node VMs in 30 to 60 s [L `create.txt`]. Each node is a
container with the label `com.apple.container.plugin=cluster` and runs the `kindest/node`
image with systemd. The plugin keeps a record of each cluster in the `container-core-clusters`
service [S Runtime `Sources/Plugins/CoreClusters/config.toml`].

ContainerStack version 1 makes these clusters a managed resource: create, list, start, stop,
delete, kubectl context, recovery after a runtime restart, Doctor. The live checks found five
defects that block this. Each one has requirements here:

1. A runtime restart stops every cluster, and the plugin has no command to start one again.
   A start through the bridge brings the API back, but NodePort and pod DNS stay broken.
   Delete and create loses all data. (§3, F-002 to F-008, F-213, F-214)
2. The bridge lets `docker stop`, `docker rm -f`, `docker start` and other calls change a node.
   (F-101 to F-104)
3. The release has no `cluster-shim`, so `--shared-image-store` fails. (F-001)
4. `cluster create` sets the current kubectl context, and the kubeconfig merge rewrites the
   whole file through a model with a fixed set of keys. The owner's `~/.kube/config` holds
   production contexts. (F-009, F-010)
5. A runtime restart kills node VMs with no orderly shutdown. (F-002, F-213)

## 2. Facts

### 2.1 Behaviour

- Create, NodePort from the host on the node IP, `kubectl port-forward`, pod DNS and egress
  work on a new cluster [L k8s-live `workload.txt`, `port-forward.txt`; L `baseline.txt`].
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

  The record has no CPUs, memory or node image. `--nodes` reads them from the node containers,
  for the table only [S Runtime `Sources/ContainerCluster/Commands/ClusterList.swift:50-67`].
- `status.state` is `running`, `degraded` or `stopped`
  [S Runtime `Sources/ContainerResource/Cluster/ClusterStatus.swift:20-24`]. It comes only from
  the node containers: `running` when all run, `stopped` when none runs, else `degraded`. A
  node container that is gone counts as `stopped`
  [S Runtime `Sources/Services/ContainerClusterService/Server/ClusterService.swift:98-113`].
  The record said `running` while NodePort and pod DNS were broken [L `round1.txt`]. The state
  is not a health value.
- The cluster service has four XPC routes: create, get, list, delete. There is no start and no
  stop [S Runtime `Sources/Services/ContainerClusterService/Client/ClusterServiceXPCRoutes.swift:22-25`].
- `container start`, `stop`, `kill`, `delete` report a node as not found; `stop --all` skips
  nodes [S Runtime `Sources/ContainerCommands/Container/ContainerStart.swift:59-61`,
  `ContainerStop.swift:63-69`; `docs/cluster.md:85-90`].
- The bridge hides nodes from `GET /containers/json` and from prune unless a `label` filter
  names `com.apple.container.plugin`. Lookup by name or ID still finds them
  [S Bridge `Sources/socktainer/Clients/ClientContainerService.swift:238-273,850-852`]. The app
  list does not show nodes [S App `Sources/ContainerStackApp/RuntimeViewModel+Containers.swift:84`,
  `Sources/ContainerStackCore/DockerAPIClient.swift:334-339`; L k8s-live `api-and-networks.txt`].
- A bridge restart keeps the cluster Ready [L k8s-live `lifecycle.txt`]. ContainerStack "Stop
  Runtime" stops only the bridge [S App `Sources/ContainerStackApp/RuntimeViewModel+Lifecycle.swift:210-218`,
  `Sources/ContainerStackCore/RuntimeControl.swift:182-192`].
- A full runtime restart runs `container stop --all --time 5`, `system stop`, `system start`
  [S App `Sources/ContainerStackCore/RuntimeControl.swift:146-165`]. `stop --all` skips nodes
  [S Runtime `ContainerStop.swift:63-65`]. `system stop` stops every container, nodes too, with
  the default signal and a 5 s limit [S Runtime `Sources/ContainerCommands/System/SystemStop.swift:28,66-70`].
  A node needs about 90 s to stop (§2.2), so `system stop` kills it [I]. After the restart the
  cluster is `stopped` and `container start <node>` says not found [L k8s-live `lifecycle.txt`].
  The app runs `system stop` with a 120 s limit [S App `Sources/ContainerStackCore/ProcessRunner.swift:43`].
- Full restarts come from: the sidebar (`SidebarRuntimePanel.swift:25,96`), the Doctor repair
  (`DoctorViewModel.swift:150,302`), the poll recovery (`RuntimeViewModel.swift:281`), the
  stale-bridge check (`RuntimeViewModel+Staleness.swift:20`) and `cstack runtime restart`
  (`CStackRuntimeControl.swift:68-70`) [S App]. No path asks for a confirmation today
  [S App `SidebarRuntimePanel.swift:24-36,95-103`].
- An idle node VM with a 6 GB limit holds 2.2 GB of host memory [L k8s-live
  `memory-hypervisor-idle.txt`].
- No LoadBalancer implementation and no ingress controller: a LoadBalancer Service stayed
  `<pending>` for 4m41s [L k8s-live `recreate.txt`, `repeated-workload.txt`].

### 2.2 Stop and start of a node (second live check)

The test stopped and started one single-node cluster (`cs-spec`, 4 CPUs, 6 GB) three times
through the bridge, with no runtime restart. The VM IP changed at each start:
192.168.64.3, .4, .5, .6 [L `baseline.txt`, `round1.txt`, `round2.txt`, `round3.txt`]. The
runtime allocates addresses per hostname in memory only, and an attachment has no field for a
requested address [S Runtime `Sources/Services/Network/Server/AttachmentAllocator.swift:43,97-103`,
`Sources/ContainerResource/Network/AttachmentConfiguration.swift:34-46`]. A node cannot ask
for its old address.

| Round | Stop | Stop time | After start |
|---|---|---|---|
| 1 | `docker stop -s SIGRTMIN+3 -t 90` | 92 s | API ready in 8 s. NodePort refused, CoreDNS 0/1, pod DNS "no servers could be reached". |
| 2 | `docker stop -s 37 -t 90` | 90 s | API ready in 7 s. ConfigMap made before the stop is still there. NodePort refused. |
| 3 | `container exec <node> systemctl poweroff --no-block` | 91 s, with no external limit | API ready in 7 s. The exec printed "Failed to connect to system scope bus", but the node stopped by itself. |

All three stops took about 90 s. The cause is not known (§11, E2).

### 2.3 What holds the node address (root cause)

The node entrypoint is a script of the plugin, not the image entrypoint
[S Runtime `Sources/ContainerCluster/Provisioners/LinuxNodeProvisioner.swift:114,159`]. At each
boot it compares the current IP with `/etc/.container-cluster-last-ip`. When they differ and
`/etc/kubernetes/pki/apiserver.crt` exists, it replaces the old IP in a fixed list of files and
makes a new API server certificate [S Runtime `Sources/ContainerCluster/ClusterHelper.swift:121-163`].
kubeadm gets the IP as `advertiseAddress`, with no `controlPlaneEndpoint`
[S Runtime `Bootstrapper/ClusterBootstrapper.swift:103-111`, `Bootstrapper/ClusterBootstrapper+ControlPlane.swift:120-153`].

| Item that holds the IP | Rewritten at boot | Effect when stale | Evidence |
|---|---|---|---|
| Static pod manifests of etcd and the API server; `kubeadm-config.yaml`; `admin.conf`, `kubelet.conf`, `controller-manager.conf`, `scheduler.conf`, `/root/.kube/config` | yes | none: the API is ready in 7-8 s | [L `cause.txt`, `round1.txt`] |
| API server certificate SAN | regenerated | none: SAN has the new IP | [L `cause.txt`] |
| `/etc/kubernetes/super-admin.conf` | **no**, not in the list | the break-glass admin file points to the create-time IP | [L `cause.txt`, `round3.txt`] |
| ConfigMap `kube-system/kube-proxy`, key `kubeconfig.conf`, `server:` | **no**, it is in etcd | kube-proxy cannot reach the API ("dial tcp 192.168.64.3:6443: connect: no route"), writes no rules (0 lines in chain `KUBE-SERVICES`). NodePort is refused. CoreDNS stays 0/1 and pod DNS fails. Service IPs do not work, so CoreDNS cannot reach `10.96.0.1` [I: the CoreDNS log had no matching line]. The repair of this one item restored all of it [L `fix1.txt`]. | [L `cause.txt`, `round1.txt`] |
| ConfigMap `kube-public/cluster-info`, `server:` | **no** | `kubeadm join` discovery uses the old IP [I] | [L `cause.txt`] |
| ConfigMap `kube-system/kubeadm-config` | n/a | has no IP | [L `round3.txt`] |
| EndpointSlice `kubernetes`, Node `InternalIP` | n/a | the API server and the kubelet update them | [L `cause.txt`] |
| Kubelet node IP | n/a | the kubelet finds it at each start: `/var/lib/kubelet/kubeadm-flags.env` has no IP | [L `baseline.txt`: not in the list of files with the IP] |
| kindnet | n/a | its manifest has no address: it reads the host IP and pod IP from the pod status and reaches the API through the Service IP | [S Runtime `Sources/Plugins/Cluster/Resources/kindnet.yaml:86-99`; L `cause.txt`: "connected to apiserver: https://10.96.0.1:443"] |
| Worker `kubelet.conf`, `server:` = control-plane IP | **no** | the gate needs `apiserver.crt`, which a worker does not have, and the worker's own IP is not the one that changed | [S Runtime `ClusterBootstrapper.swift:115`, `ClusterHelper.swift:135`; I, §11 E1] |
| `sysctl` values and two `TCPMSS` rules from the node preparation | **no**: the preparation runs once, by exec, at create | after boot: `ip_forward` and `bridge-nf-call-iptables` are 1 again (something else sets them), the TCPMSS rules are gone. A 500 KB HTTPS download from a pod worked without them. | [S Runtime `LinuxNodeProvisioner.swift:191,309-324,349-364`; L `baseline.txt`, `round1.txt`, `fix1.txt`] |
| Host kubeconfig `server: https://127.0.0.1:<port>` | n/a | none: it goes through the published port | [S Runtime `Support/ClusterHelper+Kubeconfig.swift:73-85`; L k8s-live `bridge-node-verified.txt`] |

Repair test [L `fix1.txt`, `round3.txt`]: set `server:` in the `kube-proxy` and `cluster-info`
ConfigMaps to the current IP, then delete the kube-proxy pod. The rules came back in 2 s.
NodePort, pod DNS, egress and the 500 KB download worked again. In round 3 the ConfigMap held
the IP of two boots before (.4), not the previous boot (.5). The repair must set the value by
key, not replace "the old IP".

The entrypoint is stored in each node's container configuration at create. A change to it
reaches only new clusters [S Runtime `LinuxNodeProvisioner.swift:156-168`]. The boot rewrite
has existed since `aa8d76b` ("rename to container cluster", tag 1.6.1), and records since
`07dee3d` (tag 1.7.0) [S Runtime git log]. A cluster made before 1.7.0 has no record and
`cluster list` does not show it [S Runtime `docs/cluster.md:66`].

### 2.4 Kubeconfig

- The plugin merges into one file: `KUBECONFIG` if it names one path; with several, the first
  that exists, else the last; else `~/.kube/config`
  [S Runtime `Support/ClusterHelper+Kubeconfig.swift:127-139`].
- `create` sets the current context [S Runtime `ClusterBootstrapper.swift:143`] and exits 0 when
  the write fails, with a warning only [S Runtime `ClusterBootstrapper.swift:142-147`].
  `write-config` does not set the current context [S Runtime `Commands/ClusterWriteConfig.swift:49`].
- The merge decodes the whole file into a model with fixed keys, then encodes it again
  [S Runtime `Sources/ContainerCluster/KubeConfig.swift:21-168`, `Support/ClusterHelper+Kubeconfig.swift:141-176`].
  Keys outside the model are lost (for example `preferences`, `extensions`). A test on a copy
  of the owner's file lost only three `exec.env: null` entries. Mode 0600 was kept, and a
  second identical write gave identical bytes [L `kubeconfig-merge.txt`].
- A new kubeconfig file gets mode 0644, and it holds the admin client key [L `create.txt`].
- `delete` removes the entries and writes the file even when it removed nothing
  [S Runtime `Support/ClusterHelper+Kubeconfig.swift:178-205`].

### 2.5 Release and shared image store

- The fork release job runs on `macos-26` and calls `make container` with no
  `CLUSTER_SHIM_BINARY` [S Runtime `.github/workflows/bshk-release.yml:12-13,55-60`]. With no
  running container services, `make` skips the shim with a warning, and packaging warns again
  [S Runtime `Makefile:124-143,225-232`]. `common.yml` builds the shim on `ubuntu-24.04` and
  passes it in [S Runtime `.github/workflows/common.yml:23-50,64-65,103-107`]. The installed keg
  has no shim [L `preflight.txt`; L k8s-live `create.txt`].
- Shared create checks the shim and the host-store socket before it pulls the node image
  [S Runtime `LinuxNodeProvisioner.swift:87-95`, `ClusterHelper.swift:69-79`].
- Without sharing, a pod cannot use an image from `docker build` (`ErrImageNeverPull`)
  [L k8s-live `image-probe.txt`].

## 3. Decisions

The owner can change each one. The rest of the spec follows the choice in bold.

- **D1. Restart recovery is fixed in the Runtime fork.** A stopped cluster starts again with
  its data and works fully on a new IP (F-002 to F-008). *Alternative:* the app deletes and
  creates the cluster. Cost: all Kubernetes objects and volumes are lost at each runtime restart
  [L k8s-live `recreate.txt`]. *Alternative:* a fixed node address. Cost: the network service
  must store requested addresses across restarts, and a start fails when another container got
  the address. Worker `kubelet.conf` and the ConfigMaps still need the repair after a create on a
  different subnet. *Cost of the choice:* the fork carries start, stop and repair code until
  upstream takes it.
- **D2. Kubeconfig: write the context to `~/.kube/config`, honour `KUBECONFIG`, do not change
  the current context unless the user asks** (F-009, F-010, F-210). *Alternative:* a separate
  file that the user adds to `KUBECONFIG`. Cost: tools that read only `~/.kube/config` do not
  see the cluster. *Cost of the choice:* the plugin writes a file that holds production
  credentials, so the merge must keep every key it does not own (F-010).
- **D3. No LoadBalancer and no ingress controller in version 1.** The user gets NodePort on the
  node IP from the host, and `kubectl port-forward`. A LoadBalancer Service stays `<pending>`;
  the user page says so. A later version needs a controller that gives a Service an address the
  host can reach. The runtime allocates every address of the node network, so a controller that
  takes addresses from that subnet conflicts with the allocator [I]. Publishing a host port for
  each Service needs a way to add a published port to a running node; the Runtime has none [I].
  Ingress needs a controller and one of these two. *Alternative:* ship MetalLB or
  cloud-provider-kind and ingress-nginx in version 1. Cost: the address question above must be
  solved in the Runtime first, and each cluster runs more pods. *Cost of the choice:* manifests
  with `type: LoadBalancer` or an Ingress do not work unchanged; the user changes them to
  NodePort or uses port-forward.
- **D4. Version 1 does not run a cluster in a shared or project VM.** Each node is its own VM,
  as the plugin makes it. *Alternative:* run the nodes in a shared or project VM. Cost: the
  plugin creates and boots each node as its own container VM
  [S Runtime `LinuxNodeProvisioner.swift:156-188`], so this needs a new node provisioner in the
  Runtime and a shared-runtime kind that the shared-runtimes spec reserves for later
  (`kind: "pod"`, `docs/specs/2026-11-15-shared-runtimes.md` §3.1). *Cost of the choice:* each
  node holds its own VM memory, about 2.2 GB idle.
- **D5. Start with the runtime.** Each cluster has an autostart value, `true` by default and
  for a cluster that ContainerStack did not create. A user Start sets it to `true`, a user Stop
  sets it to `false`. A stop by a runtime restart does not change it (F-204, F-214).
  *Alternative:* no autostart. Cost: after each runtime restart, reboot or update, every cluster
  is down until the user starts it.
- **D6. The bridge refuses lifecycle calls on a node with 409** (F-101). *Alternative:* answer
  404, as `container start` does. Cost: `docker inspect`, `logs` and `exec` on a node stop
  working, and they are useful for debugging. *Alternative:* no guard. Cost: one `docker rm -f`
  destroys a node and leaves a record that cannot start.
- **D7. Clusters get their own sidebar section, "Kubernetes"** (F-206). Nodes stay out of
  Containers. *Alternative:* nodes in Containers. Cost: each row action there needs the cluster
  rules of F-101 again.
- **D8. The app's kubeconfig file is a setting** (Settings > Kubernetes, default
  `~/.kube/config`). An app started by launchd has no shell environment, so it cannot see the
  user's `KUBECONFIG`. `cstack` uses its own `KUBECONFIG`. *Alternative:* read `KUBECONFIG` from
  a login shell. Cost: it depends on shell startup files and can hang.

## 4. Requirements: Runtime fork (`container`, branch `bshk/1.7.1`)

Release `1.7.1-bshk.3` carries F-001 to F-011.

- **[F-001] The release contains `cluster-shim`.** `bshk-release.yml` gets a job `cluster-shim`
  on `ubuntu-24.04` with the steps of `common.yml:23-50`. The release job needs it, downloads the
  artifact and passes `CLUSTER_SHIM_BINARY` to `make`. In `Makefile`, when
  `BUILD_CONFIGURATION=release`, `build` and the install step stop with an error if the shim file
  does not exist, in place of the two warnings. There is no override. Before it signs the
  package, the release job checks that the payload has
  `libexec/container/plugins/cluster/resources/cluster-shim` and that `file` reports a static
  ELF for aarch64. Files: `.github/workflows/bshk-release.yml`, `Makefile`.
- **[F-002] `container cluster stop --name <name>`.** It stops the workers in descending index
  order, then the control plane. For each running node it asks systemd in the node for an orderly
  power-off, waits for the node container to stop, and at the stop limit stops it by force. The
  way to ask and the stop limit come from experiment E2 (§11); until E2, the limit is 120 s per
  node. A node that is stopped or gone is not an error. The record and the node containers stay.
  Exit 0 when every node is stopped. For a cluster made with `--rm`, the help text and a warning
  say that the runtime removes the nodes when they stop (`docs/cluster.md:222-228`). Files:
  `Sources/ContainerCluster/Commands/ClusterStop.swift` (new),
  `Sources/Plugins/Cluster/ClusterCommand.swift`, `Sources/ContainerCluster/Provisioners/NodeProvisioner.swift`,
  `LinuxNodeProvisioner.swift`.
- **[F-003] `container cluster start --name <name>`.** It runs these steps in order:
  1. Take the cluster lock (F-007).
  2. Read the record. If there is none and node containers with the cluster label and this
     name exist: fail, "cluster <name> was created by an earlier version of container; delete it
     with `container cluster delete --name <name>` and create it again". If there is no record and
     no node: fail with not found.
  3. Get each node container that the record names. If one is gone: fail and name it; when the
     record has `remove: true`, add "nodes of a cluster created with --rm are removed when they
     stop".
  4. With `sharedImageStore`: the shim and host-store socket checks of
     `LinuxNodeProvisioner.provision` (lines 87-95), before any node starts.
  5. The control-plane node publishes the API port that `create` chose. If a process on the host
     holds that port, fail before the node starts and name the port. Do not pick another port: the
     kubeconfig holds this one. (E3 gives the runtime's own error text.)
  6. If the control plane does not run: bootstrap and start it with the calls of
     `LinuxNodeProvisioner.provision` (lines 184-188), then `waitForNodeBooted`. The node
     entrypoint does the file rewrite of §2.3.
  7. Node preparation on the control plane (F-005).
  8. Wait for the API server (`ClusterHelper.waitForAPIServer`).
  9. Address repair on the control plane (F-004).
  10. For each worker in index order: start it if it does not run, wait for boot, node
      preparation, worker repair (F-004), then `waitForReady` (or `waitForRegistered` with
      `--cni NONE`).
  11. Wait for the cluster: `waitForReady`, or `waitForAPIServer` with `--cni NONE`; then wait
      until the kube-proxy DaemonSet has all pods Ready (120 s).
  12. Print the name. Exit 0.

  The command does not write the kubeconfig: the host entry goes through the published port, or
  through the FQDN when the system has a DNS domain [S Runtime `ClusterHelper+Kubeconfig.swift:73-85`].
  Files: `Commands/ClusterStart.swift` (new), `ClusterCommand.swift`, `NodeProvisioner.swift`,
  `LinuxNodeProvisioner.swift`, `ClusterHelper.swift`, `Support/ClusterHelper+Readiness.swift`.
- **[F-004] Address repair.** It sets values by key to the current control-plane IP
  (`LinuxNodeProvisioner.address`). It does not search for an old IP.
  - Control plane: `server:` in the ConfigMaps `kube-system/kube-proxy` (key `kubeconfig.conf`)
    and `kube-public/cluster-info` (key `kubeconfig`), through `kubectl` in the node with
    `/etc/kubernetes/admin.conf`. `clusters[0].cluster.server` in `/etc/kubernetes/super-admin.conf`.
    When the kube-proxy value changed: delete the pods with `k8s-app=kube-proxy`, then wait until
    the kube-proxy pod on the control-plane node is Ready (bounded, 120 s). Do not wait for the
    whole DaemonSet here: the workers start later (F-003 step 10), and their kube-proxy pods
    cannot be Ready before that. Step 11 waits for every node.
  - Each worker: `clusters[0].cluster.server` in `/etc/kubernetes/kubelet.conf` to
    `https://<control-plane IP>:6443`; when it changed, `systemctl restart kubelet`.
  - A value that is already right is not written. A second start changes nothing.
  - The node entrypoint gets `/etc/kubernetes/super-admin.conf` in its file list, for new
    clusters. Old clusters get the same result from this step.
  Files: `ClusterHelper.swift`, `Support/ClusterHelper+Networking.swift`, `LinuxNodeProvisioner.swift`.
- **[F-005] Node preparation at each start.** The preparation of create runs again at each start
  on each node, written so that a second run changes nothing: `sysctl -w` for the three values,
  each `TCPMSS` rule added only when `iptables -C` does not find it, the containerd file only when
  it differs, `systemctl restart containerd` only when the file changed. It also installs and
  enables a unit `container-cluster-shutdown.service`. Its `ExecStop` writes
  `/var/lib/container-cluster/stopped-cleanly`. Its `ExecStart` moves that file to the verdict
  `/var/lib/container-cluster/last-shutdown` (`clean`), or writes `unclean` when the file is
  missing. Start reads the verdict. On `unclean` it writes the warning "the previous shutdown of
  node <node> was not clean" to stderr and continues. The start that installs the unit for the
  first time (an older cluster) gives no verdict. Create uses the same script. Files:
  `LinuxNodeProvisioner.swift`.
- **[F-006] A start that fails part way.** Start never stops or deletes a node on failure. It
  exits 1 with "start of cluster <name> failed at <step> on node <node>: <cause>". Each step
  checks the state first (node runs, value already right), so a second `start` continues from
  where the first one stopped. Each wait has a limit: boot 120 s, API 180 s, node Ready 360 s,
  kube-proxy 120 s.
- **[F-007] Cluster lock.** `create`, `start`, `stop` and `delete` take an exclusive `flock` on
  `<plugin state root>/clusters/<name>.lock`, with no wait. When another command holds it: exit
  with code 75 and "cluster <name> is busy: another create, start, stop or delete runs". This makes
  the app, the runtime helper and a terminal safe to use at the same time. Files: `ClusterHelper.swift`,
  each command.
- **[F-008] Older clusters.** A cluster with a record (made by 1.7.0 or later) starts with F-003;
  F-004 and F-005 do not depend on files that create wrote. A cluster with no record: see F-003
  step 2. No conversion of old clusters.
- **[F-009] The current context.** `create` gets the flag `--current-context` /
  `--no-current-context` (default `--current-context`, as today). `write-config` gets
  `--set-current-context` (default off, as today). ContainerStack passes `--no-current-context`.
  Files: `Commands/ClusterCreate.swift`, `Bootstrapper/ClusterBootstrapper.swift`,
  `Commands/ClusterWriteConfig.swift`.
- **[F-010] Kubeconfig writes keep the user's file.**
  - The merge and the removal edit the YAML node tree. They change only the `clusters`,
    `contexts` and `users` entries named after the cluster, and `current-context` when asked.
    Every other key, value and order stays. Comments may be lost (Yams); the user page says so.
  - The file is written only when its content changes (also for `delete`).
  - A new file gets mode 0600. An existing file keeps its mode and owner.
  - The write goes to a temporary file in the same directory, then a rename.
  - A file that does not parse is not written; the command fails with the parse error
    (`delete` warns and continues, as today).
  Files: `KubeConfig.swift`, `Support/ClusterHelper+Kubeconfig.swift`.
- **[F-011] `container system stop` stops clusters first.** Before it stops containers
  (`SystemStop.swift:66`), `system stop` lists the cluster records (`ClusterClient.list`) and runs
  the plugin, `container cluster stop --name <name>` (F-002), for each cluster that is running or
  degraded, one at a time. The stop code stays in the plugin. When the plugin is not installed,
  this step does nothing. A failure is logged, and the system stop continues. This covers a user who runs `container system stop` in a terminal. The
  ContainerStack restart does not depend on it: F-213 stops clusters before it calls `system
  stop`, inside its own time limit, so `system stop` finds no running node. Files:
  `Sources/ContainerCommands/System/SystemStop.swift`.

Upstream (`apple/container`), later: F-002 to F-010 and the `Makefile` part of F-001 apply to
upstream as they are. The `bshk-release.yml` part of F-001 is fork-only.

## 5. Requirements: Bridge (`socktainer`)

- **[F-101] Node guard.** A request that names a container by name, Docker ID, ID prefix or
  retired ID (all resolve through `ClientContainerService.getContainer`,
  [S Bridge `Clients/ClientContainerService.swift:398-433`]) and resolves to a container with
  the label `com.apple.container.plugin=cluster` gets the answer of this table. Files:
  `Sources/socktainer/ClusterNodes/ClusterNodeGuard.swift` (new), `Utilities/RegexRouter.swift`,
  `configure.swift`.

  These are all routes that take a container reference [S Bridge, registrations at the lines
  given]:

  | Route | Registered at | Node answer | Why |
  |---|---|---|---|
  | `POST /containers/{id}/start` | `Routes/Containers/ContainerStartRoute.swift:10` | 409 | Starts the VM with no address repair (§2.3); `container cluster start` does it right. |
  | `POST /containers/{id}/stop` | `ContainerStopRoute.swift:6` | 409 | Sends SIGTERM with 5 s, then kills (`ClientContainerService.swift:603-604`); the cluster record cannot follow. |
  | `POST /containers/{id}/kill` | `ContainerKillRoute.swift:12` | 409 | Lifecycle. |
  | `POST /containers/{id}/restart` | `ContainerRestartRoute.swift:6` | 409 | Stop and start, both refused. |
  | `DELETE /containers/{id}` (with or without `force`, `v`) | `ContainerDeleteRoute.swift:8` | 409 | Leaves a record that cannot start. |
  | `POST /containers/{id}/rename` | `ContainerRenameRoute.swift:55` | 409 | Recreates the container under a new name (`ClientContainerService.swift:107,425`); the record names nodes by name. |
  | `POST /containers/{id}/update` | `ContainerUpdateRoute.swift:26` | 409 | Sets a restart policy (`ContainerUpdateRoute.swift:56-60`); the bridge would then start the node. |
  | `POST /containers/{id}/pause`, `/unpause` | `ContainerPauseRoute.swift:5`, `ContainerUnpauseRoute.swift:5` | unchanged (not supported) | No change of state is possible. |
  | `POST /networks/{id}/connect`, `/disconnect` with a node in `Container` | `Routes/Networks/NetworkConnectRoute.swift:5`, `NetworkDisconnectRoute.swift:5` | 409 | Today a no-op that answers 200 (`NetworkConnectRoute.swift:8-14`); for a node it would claim a change that did not occur. |
  | `GET /containers/{id}/json` | `ContainerInspectRoute.swift:9` | allowed | Read only. |
  | `GET /containers/{id}/logs` | `ContainerLogsRoute.swift:9` | allowed | Read only. |
  | `GET /containers/{id}/stats` | `ContainerStatsRoute.swift:27` | allowed | Read only. |
  | `POST /containers/{id}/wait` | `ContainerWaitRoute.swift:19` | allowed | Read only. |
  | `GET /containers/{id}/export` | `ContainerExportRoute.swift:13` | allowed | Read only. |
  | `GET`, `HEAD /containers/{id}/archive` | `ContainerArchiveRoute.swift:28,38` | allowed | Read only. |
  | `PUT /containers/{id}/archive` | `ContainerArchiveRoute.swift:33` | allowed | Same power as `exec`, which the Runtime allows on a node (`docs/cluster.md:90`). |
  | `POST /containers/{id}/exec`; `/exec/{id}/start`, `/json`, `/resize` | `ExecRoutes.swift:104-107` | allowed | As `container exec` on a node. |
  | `POST /containers/{id}/attach`, `GET .../attach/ws` | `ContainerAttachRoute.swift:22`, `ContainerAttachWSRoute.swift:21` | allowed | A signal through attach uses `kill`, which is refused. |
  | `POST /containers/{id}/resize` | `ContainerResizeRoute.swift:7` | allowed | No change of state. |
  | `GET /containers/{id}/top`, `/changes`; `POST /commit` | `ContainerTopRoute.swift:5`, `ContainerChangesRoute.swift:5`, `Routes/Images/CommitRoute.swift:5` | unchanged (not implemented) | |
  | `POST /containers/create` with the name of a node | `ContainerCreateRoute.swift:26` | unchanged: 409 from the runtime's name conflict [I] | Test only. |

  The 409 body is the Docker error shape: `{"message":"<name> is a node of a Kubernetes cluster. Use 'container cluster' or ContainerStack to start, stop or delete it."}`.
  The guard runs before the route handler and before the shared-runtimes interceptor.
- **[F-102] Prune never removes a node.** `pruneCandidates` drops every container with
  `com.apple.container.plugin=cluster`, also when a `label` filter names the plugin label
  [S Bridge `ClientContainerService.swift:850-852` keeps them today with such a filter]. File:
  `Clients/ClientContainerService.swift`.
- **[F-103] One interceptor chain.** `RegexRouter.interceptor` is one slot today, set by shared
  runtimes [S Bridge `Utilities/RegexRouter.swift:27,73`, `SharedRuntimes/SharedRuntimeService.swift:62-64`].
  It becomes an ordered list: the node guard, then shared runtimes when on. The first non-nil
  answer wins. The node guard is always on.
- **[F-104] No new API.** The app reads clusters from `container cluster list --format json`, and
  node memory limits from `GET /containers/json?all=1&filters={"label":["com.apple.container.plugin=cluster"]}`
  and the existing inspect. Both exist.

Upstream (`socktainer/socktainer`), later: F-101 to F-103.

## 6. Requirements: ContainerStack

### 6.1 Core (`Sources/ContainerStackCore/`)

- **[F-201] Cluster model.** `KubernetesCluster` decodes one element of the list (§7.1):
  name, Kubernetes version, CNI, FQDN, `remove`, `sharedImageStore`, creation date, nodes (name,
  roles), status state, node status (name, status, addresses, ports). The API endpoint is
  `https://127.0.0.1:<host port>` from the control-plane port `<host>-><6443>`, or
  `https://<fqdn>:6443` when `fqdn` is set. File: `KubernetesCluster.swift` (new).
- **[F-202] Command wrapper.** `ClusterCommands` runs `<containerPath> cluster ...` where
  `containerPath` comes from `RuntimeProcessConfiguration.make`, the resolution the runtime
  helper uses (`RuntimeProcessConfiguration.swift:62-99`). It never looks up `container` on
  `PATH`. It sets `KUBECONFIG` to the configured file (D8). Limits: `list` 20 s, `create` 15 min
  (node image pull), `start` 15 min, `stop` 2 min plus 2 min per node, `delete` 5 min,
  `write-config` 30 s. It maps exit 75 to `busy`. It reports "cluster plugin missing" when
  `container cluster --help` fails. Files: `ClusterCommands.swift` (new), `ProcessRunner.swift`.
- **[F-203] Contract changes.** The decoder ignores unknown keys. A missing or renamed required
  key, or an unknown `state` or node `status`, is an error that names the key and the runtime
  version; the app shows it in place of the list, and Doctor fails (F-215). It never shows a
  partial list. The app pins the runtime version (F-218), so a newer runtime arrives only with an
  app update that has passed the fixture test.
- **[F-204] Autostart file.** `~/.containerstack/clusters.json` (§7.2). The app and `cstack`
  write it; the runtime helper reads it. An entry is removed when its cluster is deleted.
  File: `ClusterAutostart.swift` (new).

### 6.2 `cstack cluster` (`Sources/CStackCLI/`)

- **[F-205]** Subcommands (file: `CStackClusterCommands.swift`, new; `CStackCLI.swift` dispatch):

  | Command | Does |
  |---|---|
  | `cstack cluster ls [--json]` | Table: `NAME STATE VERSION NODES API CONTEXT AUTOSTART`. `--json` prints the runtime's JSON unchanged. |
  | `cstack cluster create <name> [--cpus N] [--memory SIZE] [--workers N \| --workers count=N,cpus=N,memory=SIZE]... [--node-image REF] [--cni PATH\|NONE] [--shared-image-store] [--rm] [--set-current-context]` | Runs `container cluster create --no-current-context` plus the options; `--set-current-context` drops `--no-current-context`. Sets autostart `true` (`false` with `--rm`). Prints the name. |
  | `cstack cluster start <name>` | Sets autostart `true`, then `container cluster start`. |
  | `cstack cluster stop <name>` | Sets autostart `false`, then `container cluster stop`. |
  | `cstack cluster rm <name>` | `container cluster delete`; removes the autostart entry. No prompt (scripts use it); the app asks. |
  | `cstack cluster kubeconfig <name> [--set-current-context]` | `container cluster write-config`. |
  | `cstack cluster autostart <name> on\|off` | Sets the value only. |

  The runtime's progress goes to stderr unchanged. Exit codes: 0 done; 1 the operation failed
  (cause on stderr); 64 usage; 69 the runtime does not run, or the cluster plugin is missing; 75
  the cluster is busy. `KUBECONFIG` of the shell is passed through.

### 6.3 App (`Sources/ContainerStackApp/`)

- **[F-206] Kubernetes section.** `DashboardDestination.kubernetes`, title "Kubernetes", after
  Stacks, with an inspector (`DashboardView.swift:3-28`). One row per cluster: name, state (F-209),
  Kubernetes version, node count, API endpoint. The inspector shows nodes (name, roles, state, IP,
  CPUs, memory from the node containers), the kubeconfig file and context, autostart, and "Reach a
  NodePort Service at http://<node IP>:<node port>". The list refreshes every 5 s while the
  section shows, and on demand (F-211). Files: `KubernetesView.swift`, `RuntimeViewModel+Clusters.swift`
  (new), `DashboardView.swift`.
- **[F-207] Create form.** A sheet:
  - Name: lowercase letters, digits and `-`, 1 to 63 characters, starting with a letter or digit
    (stricter than the Runtime's rule, `ClusterResource.swift:46-55`, see §11 E5); unique among
    clusters.
  - CPUs and memory of the control plane: default as the Runtime (`ClusterHelper.swift:34-40`).
  - Workers: none by default; "Add worker group" adds a row with count, CPUs, memory. Total at
    most 1024 (`ClusterConfiguration.swift:66`).
  - Node image: default "kindest/node v1.35.5 (default)"; a field for another reference.
  - Network plugin: kindnet (default), a manifest file, or none.
  - "Share my local images with the cluster" (`--shared-image-store`), off. When on, the form
    shows the three points of the warning in `docs/cluster.md:5-12` as they are written there.
  - "Delete when stopped" (`--rm`), off. When on, the form says that a runtime restart deletes
    the nodes, and autostart is off.
  - "Make this the current kubectl context", off.
  - A memory note: the sum of node memory limits against host memory, with the measured 2.2 GB
    of an idle 6 GB node.
  Create shows the Runtime's progress lines. Files: `KubernetesCreateSheet.swift` (new).
- **[F-208] Delete.** A confirmation: "Delete cluster <name>? Its nodes, Kubernetes objects and
  volumes are lost, and its context is removed from <kubeconfig file>." Buttons "Delete" and
  "Cancel".
- **[F-209] States.** The row shows one of:

  | Shown | When |
  |---|---|
  | Creating, Starting, Stopping, Deleting | the app runs that command for this cluster, or the helper's status file (§7.3) says `starting` |
  | Failed | the last command of the app or the helper for this cluster failed; the cause is shown; actions Start (retry) and Delete |
  | Running | record `running`, and no Failed |
  | Degraded: k of n nodes run | record `degraded`; action Start (it repairs) |
  | Stopped | record `stopped` |

  The first row that matches wins. Failed stays until a later command succeeds. Running means
  "started by `create` or by F-003": the bridge (F-101) and the Runtime CLI
  (`ContainerStart.swift:59-61`) do not start a node another way.
  The row does not probe Kubernetes health (Doctor does, F-215). Actions: Start (Stopped,
  Degraded, Failed), Stop (Running, Degraded), Delete (all but Creating and Deleting). The
  buttons of a busy cluster are off.
- **[F-210] Context.** Actions "Copy Context Name", "Copy kubectl Command" (`kubectl --context
  <name> get nodes`), "Make Current Context" (`write-config --set-current-context`), "Write
  Kubeconfig Again". After create, the app checks that the context is in the file; if not, the
  row shows "Kubeconfig not written: <stderr of create>" with "Write Kubeconfig Again"
  (§2.4: create exits 0 when this write fails).
- **[F-211] Runtime Restart confirmation.** Before a full restart from the sidebar or the Doctor
  repair, the app lists clusters. When one or more run, it asks: "Restart the runtime? Kubernetes
  clusters <names> stop and start again. Their pods restart. This can take several minutes."
  Buttons "Restart" and "Cancel". With no running cluster it asks nothing, as today. "Stop
  Runtime" stops only the bridge (§2.1) and does not ask. The automatic restarts (poll recovery,
  stale bridge) do not ask; they run F-213, and the clusters come back by F-214. Files:
  `SidebarRuntimePanel.swift`, `DoctorViewModel.swift`.
- **[F-212] Runtime down.** The section shows "The runtime is not running. Start it to manage
  clusters." and the last list, dimmed. All actions are off. The app does not run `cluster`
  commands until the runtime is ready.
- **Settings > Kubernetes** (part of F-206): the kubeconfig file (D8), with "Choose…" and
  "Reset to ~/.kube/config". File: `SettingsNavigation.swift`, `KubernetesSettingsPane.swift` (new).

### 6.4 Runtime lifecycle

- **[F-213] Stop clusters before `system stop`.** `RuntimeRestartPlan.steps` gets a step
  `stopClusters(executablePath:)` before `stopContainers`. It lists clusters and runs `cluster
  stop` for each running or degraded one, one at a time, with the limit of F-202 (2 min plus
  2 min per node). The whole step has a limit of 5 min: the plan exists to recover a runtime
  that hangs, and a hung `cluster stop` must not hold the recovery longer. When the limit ends
  the step, the clusters that are left are killed by `system stop`, as today. When `cluster
  list` fails or times out (a hung runtime), the step is skipped. Like `stopContainers`, it is
  advisory: a failure or a timeout is logged and the restart continues
  (`RuntimeControl.swift:116-123`). It does not change autostart (D5).
  The sidebar shows "Stopping cluster <name>…" while it runs (`RuntimeViewModel+Control.swift:145-153`
  names each step today). The app, `cstack runtime
  restart` and the automatic restarts use this plan. Files: `RuntimeControl.swift`,
  `RuntimeViewModel+Lifecycle.swift`, `CStackRuntimeControl.swift`.
- **[F-214] Start clusters after the runtime starts.** The runtime helper
  (`ContainerStackRuntime.swift:148-208`), after `waitForContainerSystem` and before it starts the
  bridge, starts a detached task. The bridge does not wait for it: `cluster start` uses the
  Runtime's XPC API, not the bridge [S Runtime `LinuxNodeProvisioner.swift:172-188`]. The task:
  1. Reads `clusters.json` and `container cluster list --format json`.
  2. Takes each cluster that is not `running` and has autostart `true`, oldest `creationDate`
     first, and runs `cluster start` for one cluster at a time (memory: each node holds about
     2.2 GB idle).
  3. Writes each phase to `~/.containerstack/cluster-status.json` (§7.3) and to the helper log.
  4. A cluster with `remove: true` whose nodes are gone gets `skipped` with "nodes were removed
     when the cluster stopped".
  5. Exit 75 (busy) is retried 3 times, 10 s apart, then `failed`.
  `cluster start` does not write the kubeconfig (F-003), so the helper needs no `KUBECONFIG`.
  The helper can exit while a start runs: it exits when the bridge exits, and returns at once
  when another bridge holds the socket (`ContainerStackRuntime.swift:173-183`). The status file
  records the helper's PID (§7.3). When the app reads `waiting` or `starting` and that PID does
  not run, it shows Failed with "the start was interrupted; Start runs it again". The Runtime's
  start is safe to run again (F-006).
  The user sees Starting on the row, then Running or Failed with the cause (F-209), and Doctor
  reports a failure (F-215). Files: `ContainerStackRuntime.swift`, `ClusterAutostart.swift`.

### 6.5 Doctor and memory

- **[F-215] Check `clusters`,** in `CheckID.cliSet` and `CheckID.uiSet`
  (`DiagnosticReport.swift:5-19`). It uses one `cluster list` (3 s limit) and the two files.
  - Pass: "Kubernetes: N clusters, M running", or "no clusters".
  - Warning: a cluster is degraded; autostart failed or was skipped in the last runtime start
    (cause); a running cluster has no context in the kubeconfig file; a node that the record names
    is gone.
  - Failure: the list does not decode (F-203); the plugin is missing.
  - `cstack doctor` only: for each running cluster, `container exec <control plane> kubectl
    --kubeconfig /etc/kubernetes/admin.conf get --raw=/readyz` with a 5 s limit; a failure is a
    warning with the output.
  Files: `DiagnosticRunner+Clusters.swift` (new), `DiagnosticReport.swift`, `DoctorTextRenderer.swift`.
- **[F-216] Memory check counts nodes.** `memoryMeasurement` (`DiagnosticRunner+Memory.swift:6-35`)
  adds the memory limits of running nodes, listed with the cluster label filter (F-104), because
  the plain list hides them. The report says "including K cluster nodes".

### 6.6 Docs and version

- **[F-217] Docs.** `docs/kubernetes.md`: create; contexts and the kubeconfig file (comments in
  the file can be lost on a write); reach a Service (NodePort on the node IP, `kubectl
  port-forward`); no LoadBalancer, no ingress; the shared image store and its warning; what a
  runtime restart does; autostart; delete; the bridge refuses lifecycle calls on nodes. ROADMAP M8
  names this spec.
- **[F-218] Pins.** `scripts/prepare-v1-runtime.sh` pins `1.7.1-bshk.3` and the socktainer
  revision with F-101 to F-103. The app enables the Kubernetes section only when the runtime
  version is that pin or later (`ContainerVersionCheck.swift`). The staging script fails when the
  staged runtime lacks the cluster plugin, its `cluster-shim`, `cluster-hoststore` or
  `container-core-clusters`.

## 7. Frozen contracts

### 7.1 Cluster list (Runtime → app)

`container cluster list --format json`: a JSON array. The app reads these keys and ignores
others. Required: `configuration.name` (string), `configuration.kubernetesVersion` (string),
`configuration.remove` (bool), `configuration.sharedImageStore` (bool),
`configuration.creationDate` (ISO 8601 string), `configuration.nodes[].name` (string),
`configuration.nodes[].roles` (strings), `status.state` (`running` \| `degraded` \| `stopped`),
`status.nodes[].name`, `status.nodes[].status` (`unknown` \| `stopped` \| `running` \|
`stopping`). Optional (absent or null is allowed): `configuration.cni`, `configuration.fqdn`,
`status.nodes[].addresses`, `status.nodes[].ports` (strings `"<host>-><container>"`). The fixture
is the array in §2.1, as `Tests/ContainerStackCoreTests/Fixtures/cluster-list.v1.json`.

### 7.2 `~/.containerstack/clusters.json` (app, `cstack` → helper)

```json
{ "version": 1, "clusters": { "dev": { "autostart": true } } }
```

A cluster with no entry has autostart `true`. A missing file is no entries. A file that does not
parse, or has another `version`, is not used: autostart starts nothing, and Doctor warns. Unknown
keys are ignored. Writes are atomic.

### 7.3 `~/.containerstack/cluster-status.json` (helper → app, Doctor)

```json
{ "version": 1, "runStarted": "2026-11-23T17:40:00Z", "helperPID": 41210,
  "clusters": { "dev": { "phase": "failed", "message": "start of cluster dev failed at ...",
                         "updated": "2026-11-23T17:41:10Z" } } }
```

`phase`: `waiting`, `starting`, `started`, `failed`, `skipped`. The helper writes the whole file
atomically at each change and starts a new one at each runtime start.

### 7.4 Bridge answer for a node

HTTP 409, body `{"message": "..."}` with the text of F-101.

### 7.5 New Runtime commands

`container cluster start --name <name>`, `container cluster stop --name <name>`; `create
--no-current-context`; `write-config --set-current-context`. Exit codes: 0 done, 1 failed,
75 busy. Output: the name on stdout, progress and warnings on stderr.

## 8. Tests

Every live test uses its own `KUBECONFIG` file in a temporary directory and checks at the end
that `~/.kube/config` has the same SHA-256 as before.

| Req. | Test that fails without it | Kind | Repository |
|---|---|---|---|
| F-001 | The release job's payload check fails on a package built without the shim. `make container BUILD_CONFIGURATION=release` with no shim and no container services exits non-zero. | CI | Runtime |
| F-002 | A fake provisioner records the stop order (workers descending, then control plane) and the force stop at the limit. Live: `cluster stop` leaves the record and nodes, state `stopped`; the clean-shutdown file exists at the next start. | unit, live | Runtime |
| F-003 | Live: create, workload with a NodePort Service, `cluster stop`, take the node IP with another container, `cluster start`. The IP differs; NodePort answers from the host; a pod resolves `kubernetes.default` and fetches an HTTP page; a ConfigMap made before the stop is there. Unit: each failure of steps 2-5 gives its message. | live, unit | Runtime |
| F-004 | Unit: the repair sets `server:` by key when the ConfigMap holds an IP from two starts before (round 3 case), and writes nothing when the value is right. Unit: with a stopped worker, step 9 waits only for the control-plane kube-proxy pod and does not time out. Live: as F-003 with `--workers 1` (E1), the worker is Ready and a pod on it answers through NodePort. | unit, live | Runtime |
| F-005 | Live: after a start, both TCPMSS rules exist once; a second start adds none. | live | Runtime |
| F-006 | Unit: a fake that fails at worker 1 leaves the control plane running; a second start skips the done steps. | unit | Runtime |
| F-007 | Unit: a second `start` while the lock is held exits 75 at once. | unit | Runtime |
| F-008 | Unit: node containers with the label and no record give the "earlier version" message. | unit | Runtime |
| F-009 | Live: `create --no-current-context` leaves `current-context` as it was. | live | Runtime |
| F-011 | Live: with a running cluster, `container system stop` returns after the cluster stop; the clean-shutdown file exists at the next start. | live | Runtime |
| F-010 | Unit over a fixture with `preferences`, `extensions` on all levels, `exec` with `env: null` and non-empty `env`, and unknown keys: merge then remove gives the same parsed document. Mode 0600 of a new file; an existing 0640 file stays 0640; a delete of an absent cluster does not change the file's modification time. | unit | Runtime |
| F-101 | A route test for each row of the table, with a fake container with the label: each 409 row answers 409 with the body; each allowed row reaches the handler. A test by ID prefix and by retired ID. | route | Bridge |
| F-102 | `docker container prune --filter label=com.apple.container.plugin=cluster` on a fake with a stopped node deletes nothing. | unit | Bridge |
| F-103 | With `--shared-runtimes`, a node stop gets 409 and a session stop still works. | route | Bridge |
| F-104 | No bridge test: F-216's test reads node limits through the existing label filter and inspect, and the F-101 route tests keep inspect allowed. | — | — |
| F-201, F-203 | Decode the fixture; decode with an extra key; fail with a missing `status.state`, with `state: "paused"`; the error names the key. | unit | App |
| F-202 | With a fake `container` first on `PATH` and a configuration path to a recording script, the wrapper runs the script. A command that sleeps past its limit is ended. | unit | App |
| F-204 | Read and write of §7.2; unknown version is not used. | unit | App |
| F-205 | Argument mapping for each subcommand; exit 75 maps to 75; `create` passes `--no-current-context` unless `--set-current-context`. | unit | App |
| F-206 to F-210, F-212 | View model tests: state mapping of F-209 for each row; actions on and off per state; create arguments from the form, including the warning shown only with sharing on; delete confirmation text names the kubeconfig file. | unit | App |
| F-211 | With one running cluster, "Restart" shows the confirmation with its name; with none, no confirmation; automatic recovery shows none. | unit | App |
| F-213 | `RuntimeRestartPlan.steps` has `stopClusters` before `stopContainers`; a failing `stopClusters` does not stop the plan; a `cluster stop` that never returns ends the step at 5 min; a `cluster list` that fails skips it; autostart is unchanged. | unit | App |
| F-214 | A fake runner: two clusters with autostart `true` start one at a time, oldest first; one with `false` stays; a busy result is retried; the status file has each phase and the helper PID. A status file with `starting` and a PID that does not run maps to Failed "interrupted". Live: `cstack runtime restart` with a running cluster: the cluster is `running` again and NodePort answers, with no user action. | unit, live | App |
| F-215, F-216 | Doctor fixtures: degraded cluster gives a warning; unreadable list gives a failure; memory total includes a node found only through the label filter. | unit | App |
| F-217 | Review only: the user page covers each item of F-217; no code test. | review | App |
| F-218 | Version check: an older runtime hides the section. The release staging check (`scripts/stage-containerstack-app.sh`) fails when the staged bundle lacks `libexec/container/plugins/cluster/resources/cluster-shim`, `plugins/cluster-hoststore` or `plugins/container-core-clusters`, and runs `<bundle>/Contents/Resources/container/bin/container cluster --help`. | unit, CI | App |

## 9. Order of work

Each slice is one pull request, reviewed alone.

| Slice | Requirements | Repository | Needs | Parallel with |
|---|---|---|---|---|
| S1 Release has the shim | F-001 | Runtime | — | S2, S3, S4, S6 |
| S2 Kubeconfig writes | F-009, F-010 | Runtime | — | S1, S3, S4, S6 |
| S3 Start and stop | F-002 to F-008, F-011 | Runtime | E1, E2, E3 run first; the live test of F-003 is part of the slice | S1, S2, S4, S6 |
| S4 Node guard | F-101 to F-104 | Bridge | — | S1, S2, S3, S6 |
| S5 Pins | F-218, release `1.7.1-bshk.3` | Runtime, App | S1, S2, S3, S4 | S7 to S10 (until their live tests) |
| S6 Core | F-201 to F-204 | App | the contract of §7 only (fixture from §2.1, fake runner) | S1 to S4 |
| S7 `cstack cluster` | F-205 | App | S6 | S8, S9, S10 |
| S8 Lifecycle | F-213, F-214 | App | S6; its live test needs S5 | S7, S9, S10 |
| S9 App UI | F-206 to F-212 | App | S6; the status display needs S8's file format (§7.3, frozen) | S7, S8, S10 |
| S10 Doctor | F-215, F-216 | App | S6 | S7, S8, S9 |
| S11 Docs and E4 | F-217 | App | S5, S7 to S10 | — |

## 10. Non-goals

- A Kubernetes object browser (pods, Services, logs) in the app. Users use `kubectl` or other
  tools with the context.
- LoadBalancer and ingress (D3).
- A cluster in a shared or project VM (D4).
- A change of CPUs, memory, workers, node image or sharing after create. The Runtime has no
  command for it; sharing is fixed at create [S Runtime `docs/cluster.md:168`]. The user deletes
  and creates the cluster.
- An upgrade of Kubernetes in place.
- Loading a local image into a cluster without the shared image store.

## 11. Open questions

Live experiments that this spec did not run:

- **E1. Multi-node start.** The safety rules of this check allowed one single-node cluster.
  Run F-003's live test with `--workers 1`. If the worker becomes Ready only after the worker
  repair of F-004, the design is confirmed. If it becomes Ready without it, keep the step: it
  is a no-op when the value is right. If it does not become Ready with it, the worker holds the
  IP in another place: grep the worker for the old control-plane IP, and add that item to F-004.
- **E2. Stop takes 90 s.** Three stop methods each took about 90 s (§2.2). Run, with a limit of
  300 s: (a) `kill` with signal 37 (SIGRTMIN+3, systemd halt), (b) signal 38 (SIGRTMIN+4,
  poweroff), (c) exec `systemctl poweroff`. Record the time to `stopped` and whether F-005's
  clean-shutdown file exists at the next boot. If a method gives the file in less than 90 s, F-002
  uses it with a limit of twice the time. If all give the file at about 90 s, a unit hits
  systemd's default stop timeout of 90 s [I]; find it with a persistent journal, and add a
  drop-in with a short stop timeout for it to F-005. If none gives the file, the signal does not
  reach systemd, and the in-node `systemctl` needs the system bus that the exec did not find.
- **E3. API port taken at start.** Hold the port with `nc -l 127.0.0.1 <port>` and run `cluster
  start`. The output fixes the error text of F-003 step 5.
- **E4. Shared image store after a restart.** Needs a release with the shim (F-001). Check that
  the host-store socket exists before the helper starts clusters
  (`Sources/Plugins/ClusterHostStore/config.toml`: `loadAtBoot`, `runAtLoad`), and that a pod with
  a local image and `imagePullPolicy: Never` starts after a runtime restart.
- **E5. Upper-case cluster names.** The Runtime accepts upper-case letters, `_` and `.` in a
  cluster name. A Kubernetes node name must be lower case [I]. Create a cluster named `Dev`. If
  kubeadm fails, the Runtime's name check needs the Kubernetes rule; the app form already has it.
- **E6. TCPMSS.** A 500 KB HTTPS download worked without the clamp [L `fix1.txt`]. F-005
  restores it anyway. A network with a smaller MTU (a VPN on the host) can show whether the clamp
  is needed; this does not change the design.
- **E7. Host logout and shutdown.** launchd ends the runtime's agents at logout and shutdown,
  with its own exit timeout [I]. A node needs about 90 s to stop (§2.2). Log out with a running
  cluster, log in, and read the clean-shutdown warning of F-005 at the autostart. If the warning
  shows, nodes die hard at logout; the data survived three hard stops in this check (§2.2, round
  2 and 3), and E2's fix shortens the stop. The result goes to the user page.

Decisions for the owner (each with the recommendation in §3): D1 to D4 confirm the
supervisor's recommendations; D5 (autostart on by default), D6 (409), D7 (own section), D8
(kubeconfig path as a setting) are new.
