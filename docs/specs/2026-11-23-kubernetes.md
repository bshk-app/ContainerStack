# Spec: Kubernetes clusters, version 1

Version: 0.2 (0.1: one design review, 18 findings and 4 weak tests, see
`docs/specs/reviews/2026-11-23-kubernetes-review-1.md`; 0.2 moves all cluster state into the
Runtime's cluster service, §4, and adds invariants, §5. No code exists.)
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
   Delete and create loses all data. (§3, §4, F-002 to F-008, F-011, F-013)
2. The bridge lets `docker stop`, `docker rm -f`, `docker start` and other calls change a node.
   (F-101, F-102, F-014)
3. The release has no `cluster-shim`, so `--shared-image-store` fails. (F-001)
4. `cluster create` sets the current kubectl context, and the kubeconfig merge rewrites the
   whole file through a model with a fixed set of keys. The owner's `~/.kube/config` holds
   production contexts. (F-009, F-010)
5. A runtime restart kills node VMs with no orderly shutdown. (F-002, F-011, F-213)

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

All three stops took about 90 s. The cause is not known (§13, E2).

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
| Worker `kubelet.conf`, `server:` = control-plane IP | **no** | the gate needs `apiserver.crt`, which a worker does not have, and the worker's own IP is not the one that changed | [S Runtime `ClusterBootstrapper.swift:115`, `ClusterHelper.swift:135`; I, §13 E1] |
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

### 2.6 Facts added by the review check

- `cluster create` writes the record before it provisions any node, and removes the record only
  in its own error path [S Runtime `Commands/ClusterCreate.swift:181-190`]. A create that is
  killed leaves a record whose nodes may be missing, half made or not joined. Nothing in the
  record says whether the create finished [S Runtime `Sources/ContainerResource/Cluster/ClusterConfiguration.swift:64-101`].
- The record store is an actor with a filesystem store in the cluster service
  [S Runtime `Sources/Services/ContainerClusterService/Server/ClusterService.swift:20-28`]. A
  create replaces a record only when none of its node containers exists, stopped or running
  (`ClusterService.swift:55-67`).
- The boot script deletes the API server certificate and key, then regenerates them; on failure
  it exits 1 before it writes the IP marker [S Runtime `ClusterHelper.swift:153-163`]. The next
  boot skips the repair, because its condition needs `apiserver.crt` (`ClusterHelper.swift:135`).
  The node then runs with no API server certificate, and with files that name the IP of the failed
  boot, which the marker does not name [I].
- A stopped container that the runtime loads at its start has no network attachments
  [S Runtime `Sources/Services/ContainerAPIService/Server/Containers/ContainersService.swift:135-141`].
  The cluster status shows it with no address, the same as a node that is gone
  (`ClusterService.swift:98-110`).
- The API port forwarder binds at bootstrap, after the VM exists
  [S Runtime `Sources/Services/RuntimeLinux/Server/RuntimeService.swift:310`]. A probe before the
  start cannot reserve the port. A cluster with an FQDN publishes no port
  (`LinuxNodeProvisioner.swift:103-104`).
- The plugin loader needs a running API server, and it searches that server's install root
  [S Runtime `Sources/ContainerCommands/DefaultCommand.swift:36-38,69-84`].
- `container --version` prints `container CLI version 1.7.1 (build: release, commit: 17bb57e)`
  [L, run on the keg]. The release job strips `-bshk.N` from the version
  [S Runtime `.github/workflows/bshk-release.yml:57`]. The commit, not the version, names the
  build. The app bundle script pins its own tag and checksum
  [S App `scripts/prepare-container-runtime.sh:31-33`].
- `cstack runtime start` with no registered agent starts socktainer itself, not through the
  helper [S App `Sources/CStackCLI/CStackRuntimeControl.swift:137-146,162-177`].
- In the bridge, a route resolves the reference, then the client resolves it again, and the
  native call uses the native name [S Bridge `Routes/Containers/ContainerStopRoute.swift:26-36`,
  `Clients/ClientContainerService.swift:583-590`]. Prune lists, then deletes each by native name
  (`ClientContainerService.swift:915-938`). A name can name another container between the two.
- The create route maps a native name conflict to 409 with the Docker conflict text since
  `6b3393b` [S Bridge `Routes/Containers/ContainerCreateRoute.swift:798-799`,
  `Utilities/ContainerNameConflict.swift`]. The bridge `166bbd5` of the first live check answers
  500.

## 3. Decisions

The owner can change each one. The rest of the spec follows the choice in bold. The review kept
all eight; D5 keeps its meaning and moves its storage into the Runtime (§4).

- **D1. Restart recovery is fixed in the Runtime fork.** A stopped cluster starts again with
  its data and works fully on a new IP (F-002 to F-008). *Alternative:* the app deletes and
  creates the cluster. Cost: all Kubernetes objects and volumes are lost at each runtime restart
  [L k8s-live `recreate.txt`]. *Alternative:* a fixed node address. Cost: the network service
  must store requested addresses across restarts, and a start fails when another container got
  the address. Worker `kubelet.conf` and the ConfigMaps still need the repair after a create on a
  different subnet. *Cost of the choice:* the fork carries start, stop and repair code until
  upstream takes it.
- **D2. Kubeconfig: write the context to `~/.kube/config`, honour `KUBECONFIG`, do not change
  the current context unless the user asks** (F-009, F-010). *Alternative:* a separate file that
  the user adds to `KUBECONFIG`. Cost: tools that read only `~/.kube/config` do not see the
  cluster. *Cost of the choice:* the Runtime writes a file that holds production credentials, so
  a write must keep every key it does not own and must never take a name it does not own (F-010).
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
- **D5. Start with the runtime.** Each cluster has an autostart value in its record, `true` by
  default and for a record made before this change. An admitted user start sets it to `true`, an
  admitted user stop sets it to `false`. A stop by a runtime shutdown does not change it (F-013).
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
  a login shell. Cost: it depends on shell startup files and can hang. This is an app
  preference, not cluster state: the path a cluster wrote is in its record (F-010).

## 4. Ownership of cluster state

Version 0.1 had four writers of cluster state (the plugin record, `~/.containerstack/clusters.json`,
`~/.containerstack/cluster-status.json`, the kubeconfig file) and four callers (app, `cstack`,
runtime helper, the bare `container` CLI) with no single point of admission. Most review findings
(1, 4, 5, 6, 10, 11, 12, 13, 15) come from this.

**Choice: the cluster service of the Runtime (`ContainerClusterService`) owns all cluster state
and runs every lifecycle operation.** The two files under `~/.containerstack` go away. App,
`cstack` and the bare CLI are clients of the service; the helper has no cluster role.

- The record gets a lifecycle part (§9.1): a creation identity, `createCompleted`, autostart,
  the operation in progress with its step, the outcome of the last start bound to the node boots,
  and the kubeconfig file and entries this cluster wrote.
- The service admits one lifecycle operation per cluster (create, start, stop, delete,
  write-config, autostart change) and runs it in its own process. The plugin commands send the
  request and follow the operation in the record until it ends. A killed client does not stop or
  corrupt the operation.
- A shutdown request closes admission, then drains and stops clusters inside one time budget.
- Autostart runs in the service, once for each start of the Runtime API server (generation,
  F-013). It works for every start path: the app helper, `cstack runtime start` with no agent,
  and `container system start` in a terminal.

Why the service: it already owns the record and lists node containers
(`ClusterService.swift:20-67`); it is an actor, so admission and record writes are serialized
in one place; it lives as long as the Runtime, so it can run autostart and a shutdown drain that
no client process can promise. A file outside the Runtime cannot know about a create or a stop
that a terminal user runs.

Why not the helper: the helper runs only when ContainerStack started the Runtime through its
agent, and it exits with the bridge (§2.6). Why not a file lock in the plugin: a lock admits, but
it does not record what happened when the holder dies, and it cannot run at system start.

Cost: the create, start, stop, delete and write-config logic (today in the plugin process,
`Sources/ContainerCluster`, about 2,900 lines with tests) moves into the service, which links the
`ContainerCluster` library. New XPC routes, a record schema with migration, and a shutdown route.
The fork difference grows by about 1,500 to 2,500 lines [I]. Upstream chance: medium. Upstream
moved the records into this service on 2026-11-04 (`07dee3d`), so a service that also runs the
lifecycle is in the same direction; autostart is a policy that upstream may not want, so it is a
separate commit.

The one value outside the Runtime: the app's kubeconfig path preference (D8). Its one writer is
the app (`UserDefaults`); it needs no lock. It is not cluster state: the path in use for a
cluster is in the record.

## 5. Invariants

These rules hold in every state and under every interleaving of callers. Each requirement names
the invariants it keeps. §10.1 tests each one.

- **I1. One admitted operation per cluster.** The service admits at most one lifecycle
  operation for a cluster name at a time. A second request gets "busy" (exit 75) and changes
  nothing, not even autostart.
- **I2. Closed admission.** After a shutdown request, the service admits no operation until the
  next generation. All draining and graceful stops share one deadline; after it, only bounded
  forced teardown runs.
- **I3. Incomplete create.** A record without `createCompleted` is never started, by a user or
  by autostart. The only operation it admits is delete, which cleans up what exists.
- **I4. Kubeconfig ownership.** A kubeconfig entry is written or removed only by the cluster
  whose creation identity it carries (F-010). A name that exists and does not carry this identity
  is never overwritten and never removed.
- **I5. Kubeconfig file lock.** Every write of a kubeconfig file holds that file's lock across
  read, edit and rename.
- **I6. Same instance.** A guard decision and the mutation it allows act on the same container
  instance (same native ID and same creation date). Otherwise the mutation does not run.
- **I7. Start outcome.** `lastStart.outcome = succeeded` is true only for the node boots it
  names. A node boot that is not in it makes the cluster "needs start", whatever the container
  states say.
- **I8. Write and reload.** A configuration write and the reload that makes it effective are one
  step. The step is done only when the running component shows the value; a retry checks the
  running component, not only the file.
- **I9. Repair by key.** Address repair sets each value to the current address. It never depends
  on a remembered earlier address.
- **I10. Certificate pair.** The API server certificate and key are replaced only as a pair, by
  rename, after the new pair exists. A missing certificate or key is repaired, not a reason to
  skip the repair.
- **I11. Node identity.** A lifecycle operation acts on a node only when the container has the
  cluster label, this cluster's identity label, the expected role and the expected name.
- **I12. Autostart once.** Autostart runs at most once for each API server generation, and checks
  the autostart value and I3 again when it admits each cluster.

## 6. Requirements: Runtime fork (`container`, branch `bshk/1.7.1`)

Release `1.7.1-bshk.3` carries F-001 to F-015.

- **[F-001] The release contains `cluster-shim`.** `bshk-release.yml` gets a job `cluster-shim`
  on `ubuntu-24.04` with the steps of `common.yml:23-50`. The release job needs it, downloads the
  artifact and passes `CLUSTER_SHIM_BINARY` to `make`. In `Makefile`, when
  `BUILD_CONFIGURATION=release`, `build` and the install step stop with an error if the shim file
  does not exist, in place of the two warnings. There is no override. Before it signs the
  package, the release job checks that the payload has
  `libexec/container/plugins/cluster/resources/cluster-shim` and that `file` reports a static
  ELF for aarch64. Files: `.github/workflows/bshk-release.yml`, `Makefile`.
- **[F-007] The cluster service runs every lifecycle operation** (I1, I2, I3). New XPC routes:
  `start`, `stop`, `delete` (now runs the delete, not only the record removal), `writeConfig`,
  `setAutostart`, `operation` (get the operation in progress), `shutdown`. `create` takes the
  whole create request. The service admits a request only when: admission is open (I2), no
  operation runs for the name (I1), and the record state allows it (I3: an incomplete record
  admits delete only). It writes the operation (kind, step, start time, generation) to the record
  before the first side effect, and clears it when the operation ends. The plugin commands
  (`ClusterCreate`, `ClusterStart`, `ClusterStop`, `ClusterDelete`, `ClusterWriteConfig`) send the
  request, print each new step from the record to stderr, and exit with the result: 0 done, 1
  failed, 75 busy or admission closed. On SIGINT a command stops following and says that the
  operation goes on in the service. An operation whose generation is older than the current one
  was cut by a service exit: the service marks it `interrupted` at load. Files:
  `Sources/Services/ContainerClusterService/Server/ClusterService.swift`,
  `ClusterServiceHarness.swift`, `Client/ClusterClient.swift`, `Client/ClusterServiceXPCRoutes.swift`,
  `ClusterServiceXPCKeys.swift`, the commands under `Sources/ContainerCluster/Commands/`,
  `Sources/Plugins/CoreClusters/config.toml` (`runAtLoad = true`).
- **[F-012] Record schema 2** (I3, I4, I7, I11). `ClusterConfiguration` gets a `lifecycle` part
  (§9.1). Create writes `createCompleted: true` as its last step, after the kubeconfig step. A
  record without `lifecycle` (made by 1.7.0 to 1.7.1-bshk.2) is migrated at load:
  `clusterID` new, `createCompleted` true only when every node container exists and the
  control-plane node has `/etc/kubernetes/admin.conf` at the first admitted start (checked by
  exec; else the start fails with "create of <name> did not finish; delete the cluster"),
  autostart true, no kubeconfig ownership (F-010 then treats its entries as not owned).
  Files: `Sources/ContainerResource/Cluster/ClusterConfiguration.swift`, `ClusterStatus.swift`,
  `ClusterService.swift`.
- **[F-015] Node identity** (I11). Create adds the label
  `com.apple.container.cluster.id=<clusterID>` to each node (`LinuxNodeProvisioner.swift:118-121`).
  Start, stop and delete find nodes by name, then check the plugin label, the role and this label.
  A node of a migrated record has no identity label: its check uses the plugin label, role and
  name, and its creation date must equal the one the service stored at migration. The list gets
  `status.nodes[].present` (bool), so a missing node and a stopped node differ (§2.6). Files:
  `LinuxNodeProvisioner.swift`, `ClusterService.swift`, `ClusterStatus.swift`.
- **[F-002] Stop** (I1, I2, I11). The service stops the workers in descending index order, then
  the control plane. For each running node it asks systemd in the node for an orderly power-off,
  waits for the node container to stop, and at the stop limit stops it by force. The way to ask and
  the stop limit come from E2 (§13); until E2, the limit is 120 s per node. A node that is stopped
  or gone is not an error. The record and the node containers stay. A user stop sets autostart
  false at admission (D5). For a cluster made with `--rm`, the command warns that the runtime
  removes the nodes when they stop (`docs/cluster.md:222-228`). Files: `Commands/ClusterStop.swift`
  (new), `Plugins/Cluster/ClusterCommand.swift`, `Provisioners/NodeProvisioner.swift`,
  `LinuxNodeProvisioner.swift`, `ClusterService.swift`.
- **[F-003] Start** (I1, I3, I7, I8, I9, I10, I11). A user start sets autostart true at
  admission. Then, in order:
  1. Refuse a record without `createCompleted` (I3). Get each node with the I11 check; if one
     is gone, fail and name it (for `remove: true` add "nodes of a cluster created with --rm are
     removed when they stop").
  2. With `sharedImageStore`: the shim and host-store socket checks of
     `LinuxNodeProvisioner.provision` (lines 87-95), before any node starts.
  3. If the control plane does not run: bootstrap and start it (`LinuxNodeProvisioner.swift:184-188`),
     then `waitForNodeBooted`. When the record has a published API port and the bootstrap fails
     because the port is taken (the forwarder binds at bootstrap, §2.6), stop the node, keep the
     record and the port, and fail with "port <port> on the host is in use; free it and start
     cluster <name> again". Do not pick another port: the kubeconfig holds this one. A cluster
     with an FQDN has no published port and no such check. (E3 gives the runtime's error text.)
  4. Node preparation on the control plane (F-005).
  5. Control-plane repair (F-004, first part), then wait for the API server
     (`ClusterHelper.waitForAPIServer`).
  6. In-cluster repair (F-004, second part).
  7. For each worker in index order: start it if it does not run, wait for boot, node
     preparation, worker repair (F-004, third part), then `waitForReady` (or `waitForRegistered`
     with `--cni NONE`).
  8. Wait for the cluster: `waitForReady` (or `waitForAPIServer` with `--cni NONE`); then wait
     until the kube-proxy DaemonSet has all pods Ready (120 s).
  9. Write `lastStart` (§9.1): generation, `succeeded`, and the boot identity of each node
     (container creation date and `startedDate`). Only now (I7).

  The operation does not write the kubeconfig: the host entry goes through the published port, or
  through the FQDN when the system has a DNS domain [S Runtime `ClusterHelper+Kubeconfig.swift:73-85`].
  A start of a cluster whose `lastStart` is `succeeded` for the current node boots does nothing
  and succeeds. Files: `Commands/ClusterStart.swift` (new), `ClusterCommand.swift`,
  `NodeProvisioner.swift`, `LinuxNodeProvisioner.swift`, `ClusterHelper.swift`,
  `Support/ClusterHelper+Readiness.swift`, `ClusterService.swift`.
- **[F-004] Address repair** (I8, I9, I10). It sets values by key to the current control-plane
  IP (`LinuxNodeProvisioner.address`), from the subnet of the node's attachment. It does not
  search for a remembered IP.
  1. Control-plane files, by exec in the node, before the API wait: in `kubeadm-config.yaml`
     (`localAPIEndpoint.advertiseAddress`), in the etcd and API server manifests, and in
     `admin.conf`, `super-admin.conf`, `kubelet.conf`, `controller-manager.conf`,
     `scheduler.conf` and `/root/.kube/config`, each IPv4 address in the node subnet becomes the
     current IP. In these files of a control-plane node, each address of the node subnet names the
     control plane itself [S Runtime `ClusterBootstrapper+ControlPlane.swift:120-153`; L
     `baseline.txt`: the files list]. Each file is written to a temporary file and renamed. When
     `apiserver.crt` or `apiserver.key` is missing, or the certificate SAN does not have the
     current IP, make a new pair with `kubeadm init phase certs apiserver --cert-dir <temp>`, then
     rename key and certificate into place (I10). When a manifest changed, the kubelet restarts
     the static pod by itself [I]; when only the certificate changed, restart the API server pod
     (`crictl` stop of its container).
  2. In-cluster objects, through `kubectl` in the node with `/etc/kubernetes/admin.conf`:
     `server:` in the ConfigMaps `kube-system/kube-proxy` (key `kubeconfig.conf`) and
     `kube-public/cluster-info` (key `kubeconfig`). Then, when any node booted since the last
     `succeeded` start, or the value changed, delete the kube-proxy pod on the control-plane node
     and wait until its new pod is Ready (120 s). The reload is bound to the start, not to the
     change, so a retry after a cut between write and reload still reloads (I8). Do not wait for
     the whole DaemonSet here: the workers start later (F-003 step 8 waits for all).
  3. Each worker: `clusters[0].cluster.server` in `/etc/kubernetes/kubelet.conf` to
     `https://<control-plane IP>:6443`. Restart the kubelet when the value changed or when the
     kubelet's start time (`systemctl show kubelet -p ActiveEnterTimestamp`) is older than the
     file (I8).
  The node entrypoint of new clusters follows I9 and I10 too: it applies the subnet rule of
  step 1 and never deletes the pair before a new pair exists. Old nodes keep their stored
  entrypoint; step 1 repairs what it leaves (§2.6). Files: `ClusterHelper.swift`,
  `Support/ClusterHelper+Networking.swift`, `LinuxNodeProvisioner.swift`.
- **[F-005] Node preparation at each start** (I8). The preparation of create runs again at each
  start on each node, written so that a second run changes nothing: `sysctl -w` for the three
  values; each `TCPMSS` rule added only when `iptables -C` does not find it; the containerd file
  only when it differs; `systemctl restart containerd` when the file changed or when containerd
  started before the file's modification time (I8). It installs and enables
  `container-cluster-shutdown.service`. Its `ExecStop` writes
  `/var/lib/container-cluster/stopped-cleanly`; its `ExecStart` moves that file to the verdict
  `/var/lib/container-cluster/last-shutdown` (`clean`), or writes `unclean` when it is missing.
  Start reads the verdict and, on `unclean`, warns "the previous shutdown of node <node> was not
  clean" and continues. The start that first installs the unit gives no verdict. Create uses the
  same script. Files: `LinuxNodeProvisioner.swift`.
- **[F-006] A start that fails part way** (I7, I8). Start never stops or deletes a node on
  failure, except the node of a failed bootstrap (F-003 step 3). It writes `lastStart` with
  `failed`, the step, the node and the cause, and the command exits 1 with "start of cluster
  <name> failed at <step> on node <node>: <cause>". Each step checks the running state first, so
  a second start continues. Each wait has a limit: boot 120 s, API 180 s, node Ready 360 s,
  kube-proxy 120 s.
- **[F-008] Older clusters** (I3). A record from 1.7.0 or later is migrated (F-012). Node
  containers with the cluster label and no record: start fails, "cluster <name> was created by an
  earlier version of container; delete it with `container cluster delete --name <name>` and
  create it again". Delete of such nodes works as today (`ClusterDelete.swift:40-60`).
- **[F-009] The current context and the target file.** `create` gets `--current-context` /
  `--no-current-context` (default `--current-context`, as today) and `--kubeconfig <path>`
  (default: today's rule, `ClusterHelper+Kubeconfig.swift:127-139`, applied in the client and
  sent as an absolute path). `write-config` gets `--set-current-context` (default off).
  ContainerStack passes `--no-current-context` and `--kubeconfig`. Files:
  `Commands/ClusterCreate.swift`, `Commands/ClusterWriteConfig.swift`, `ClusterBootstrapper.swift`.
- **[F-010] Kubeconfig writes** (I4, I5).
  - Ownership: each `clusters`, `contexts` and `users` entry that the Runtime writes carries an
    `extensions` item `{name: "container.apple.com/cluster", extension: {id: <clusterID>}}`
    (kubeconfig entries take `extensions`). The record keeps the path and the three names
    (§9.1).
  - Create checks the target file before it provisions anything: it must parse, and none of the
    three names may exist without this cluster's identity. Else create fails at once and makes
    nothing: "kubeconfig <path> already has a context, cluster or user named <name> that container
    did not write for this cluster; remove it or choose another cluster name".
  - Write-config writes only entries that are absent or carry this cluster's identity; else it
    fails with the same text.
  - Delete removes only entries that carry this cluster's identity, from the path in the record.
    Entries without it stay, and the result names them.
  - Each write: take the lock `<path>.lock` (created with `O_EXCL`; the same lock file that
    `kubectl` uses [I]), wait for it at most 10 s, read, edit the YAML node tree, write a
    temporary file in the same directory, rename, remove the lock. Only the three owned entries
    and `current-context` (when asked) change; other keys, values and order stay; comments may be
    lost. The file is written only when its content changes. A new file gets mode 0600; an
    existing file keeps its mode and owner.
  - Rollback of a failed create removes only what that create wrote (I4); it does not call
    today's name-based removal (`ClusterBootstrapper.swift:148-154`).
  - Outcome: the record keeps `kubeconfig.result` (`written`, `failed` with the cause,
    `removed`, `kept` with the names that were not removed). Create fails before provisioning
    on a check failure; a write failure after provisioning leaves the cluster created with
    `failed` (the command exits 0 and prints the cause). Delete always finishes the delete and
    prints the kubeconfig result.
  Files: `KubeConfig.swift`, `Support/ClusterHelper+Kubeconfig.swift`, `ClusterBootstrapper.swift`.
- **[F-011] Shutdown with one budget** (I2). `container system stop` gets
  `--cluster-timeout <seconds>` (default 300). Before it stops containers
  (`SystemStop.swift:66`), it sends `shutdown(deadline)` to the cluster service. The service
  closes admission; cancels the autostart queue; asks a running operation to stop at its next step
  (a create in progress tears down the nodes it made and deletes its record; a start stops between
  steps; its `lastStart` becomes `interrupted`); then stops all running clusters in parallel with
  F-002, each node limit cut to the time left. At the deadline the service stops waiting and
  answers. `system stop` then stops the remaining containers with its existing 5 s rule and stops
  the services. A shutdown stop does not change autostart. When the cluster plugin is not
  installed, the request is skipped. Files: `Sources/ContainerCommands/System/SystemStop.swift`,
  `ClusterService.swift`.
- **[F-013] Autostart in the Runtime** (I3, I12). The API server writes a new generation UUID to
  `<app root>/apiserver-generation` at each start, before it loads plugins. The cluster service
  (now `runAtLoad = true`) reads it at load. When it differs from the generation of its last
  autostart run (kept in the service's own store), it runs autostart: for each record with
  `createCompleted`, autostart true and not "ready" (§9.1), oldest `creationDate` first, one at a
  time, it admits a start like a user start but without changing autostart. It reads autostart
  and I3 again at each admission. A busy cluster is retried 3 times, 10 s apart. A `remove: true`
  cluster whose nodes are gone gets `lastStart = skipped`. The run ends at a shutdown request.
  `container cluster autostart --name <name> on|off` sets the value through `setAutostart` (I1).
  Files: `Sources/APIServer/` (generation file), `ClusterService.swift`,
  `Commands/ClusterAutostart.swift` (new), `Sources/Plugins/CoreClusters/config.toml`.
- **[F-014] Node guard in the Runtime API** (I6). `ContainersService.bootstrap`, `kill`, `stop`
  and `delete` (`ContainersService.swift:363,543,578,831`) refuse a container with
  `com.apple.container.plugin=cluster` unless the request carries the option
  `managedBy: "cluster"`. The check runs in the container service, on the container it is about to
  change, so the decision and the change act on one instance. The cluster service sets the option;
  the `container` commands already hide nodes; the bridge never sets it. This is not a security
  boundary (see F-101). Files: `ContainersService.swift`, `ContainerStopOptions.swift`,
  `ContainerClient.swift`.

Upstream (`apple/container`), later: F-002 to F-005, F-007, F-009, F-010, F-012, F-014, F-015 and
the `Makefile` part of F-001 apply as they are. F-011 and F-013 are separate commits (policy).
The `bshk-release.yml` part of F-001 is fork-only.

## 7. Requirements: Bridge (`socktainer`)

- **[F-101] Node guard** (I6). The guard prevents accidental lifecycle damage from Docker
  clients, such as `docker rm -f` or `docker container prune`. It is not a security boundary: a
  client with the socket already controls the runtime. Exec, logs, inspect, attach and archive GET
  stay allowed as stated maintenance access.

  The check is in the client layer at the point of mutation, not in a route interceptor. Each
  mutating method of `ClientContainerService` (`start`, `stop`, `kill`, `restart`, `delete`,
  `rename`, `update`, archive PUT, prune) resolves the reference once, checks the label on that
  snapshot, and passes the same snapshot to the native call. Inside `VMLifecycleAdmission`, just
  before the native call, it reads the container again by native ID and compares
  `DockerContainerID.hexId` (native ID and creation date); a difference answers 409 "container
  <name> changed during the request" and changes nothing. The remaining gap between that read and
  the native call is closed by the Runtime (F-014): the bridge never sets `managedBy`, so the
  Runtime refuses a node whatever the bridge decided. Files: `Clients/ClientContainerService.swift`,
  `Clients/ClientArchiveService.swift`, the network connect and disconnect routes.

  All routes that take a container reference [S Bridge, at the lines given]:

  | Route | Registered at | Node answer | Why |
  |---|---|---|---|
  | `POST /containers/{id}/start` | `Routes/Containers/ContainerStartRoute.swift:10` | 409 | Starts the VM with no repair (§2.3); `container cluster start` does it right. |
  | `POST /containers/{id}/stop` | `ContainerStopRoute.swift:6` | 409 | SIGTERM with 5 s, then kill (`ClientContainerService.swift:603-604`). |
  | `POST /containers/{id}/kill` | `ContainerKillRoute.swift:12` | 409 | Lifecycle. |
  | `POST /containers/{id}/restart` | `ContainerRestartRoute.swift:6` | 409 | Stop and start. |
  | `DELETE /containers/{id}` (with or without `force`, `v`) | `ContainerDeleteRoute.swift:8` | 409 | Leaves a record that cannot start. |
  | `POST /containers/{id}/rename` | `ContainerRenameRoute.swift:55` | 409 | Recreates the container under a new name (`ClientContainerService.swift:107,425`). |
  | `POST /containers/{id}/update` | `ContainerUpdateRoute.swift:26` | 409 | Sets a restart policy (`ContainerUpdateRoute.swift:56-60`). |
  | `PUT /containers/{id}/archive` | `ContainerArchiveRoute.swift:33` | 409 | Can change the file system of a stopped node, which exec cannot. |
  | `POST /networks/{id}/connect`, `/disconnect` with a node in `Container` | `Routes/Networks/NetworkConnectRoute.swift:5`, `NetworkDisconnectRoute.swift:5` | 409 | Today a no-op that answers 200 (`NetworkConnectRoute.swift:8-14`). The handler resolves the body's container through the client. |
  | `POST /containers/{id}/pause`, `/unpause` | `ContainerPauseRoute.swift:5`, `ContainerUnpauseRoute.swift:5` | unchanged (not supported) | |
  | `GET /containers/{id}/json`, `/logs`, `/stats`; `POST .../wait` | `ContainerInspectRoute.swift:9`, `ContainerLogsRoute.swift:9`, `ContainerStatsRoute.swift:27`, `ContainerWaitRoute.swift:19` | allowed | Read only. |
  | `GET /containers/{id}/export`; `GET`, `HEAD .../archive` | `ContainerExportRoute.swift:13`, `ContainerArchiveRoute.swift:28,38` | allowed | Read only. |
  | `POST /containers/{id}/exec`; `/exec/{id}/start`, `/json`, `/resize` | `ExecRoutes.swift:104-107` | allowed (maintenance) | As `container exec` on a node (`docs/cluster.md:90`). |
  | `POST /containers/{id}/attach`, `GET .../attach/ws`; `POST .../resize` | `ContainerAttachRoute.swift:22`, `ContainerAttachWSRoute.swift:21`, `ContainerResizeRoute.swift:7` | allowed (maintenance) | A signal through attach uses `kill`, which is refused. |
  | `GET /containers/{id}/top`, `/changes`; `POST /commit` | `ContainerTopRoute.swift:5`, `ContainerChangesRoute.swift:5`, `Routes/Images/CommitRoute.swift:5` | unchanged (not implemented) | |
  | `POST /containers/create` with the name of a node | `ContainerCreateRoute.swift:26` | unchanged: 409 with the Docker name-conflict text (F-105) | Not a node answer. |

  The node answer is 409 with the body of §9.4.
- **[F-102] Prune never removes a node** (I6). `pruneCandidates` drops every container with
  `com.apple.container.plugin=cluster`, also when a `label` filter names the plugin label
  (`ClientContainerService.swift:850-852`). The delete of each candidate uses the F-101 path: same
  snapshot, identity check, then the native call.
- **[F-103] Shared runtimes unchanged.** The shared-runtimes interceptor stays as it is
  (`RegexRouter.swift:27,73`). A session is not a node, and a node is not a session, so the two
  checks do not meet; the node check is in the client, below both.
- **[F-104] No new API.** The app reads clusters from `container cluster list --format json`, and
  node memory limits from `GET /containers/json?all=1&filters={"label":["com.apple.container.plugin=cluster"]}`
  and the existing inspect.
- **[F-105] Prerequisite.** The bridge pin is `6b3393b` or later, for the 409 on a create-name
  conflict (§2.6). §9.4 does not apply to that answer.

Upstream (`socktainer/socktainer`), later: F-101, F-102.

## 8. Requirements: ContainerStack

### 8.1 Core (`Sources/ContainerStackCore/`)

- **[F-201] Cluster model.** `KubernetesCluster` decodes one element of the list (§9.1),
  including `lifecycle` and `status.nodes[].present`. The API endpoint is
  `https://127.0.0.1:<host port>` from the control-plane port `<host>-><6443>`, or
  `https://<fqdn>:6443` when `fqdn` is set. File: `KubernetesCluster.swift` (new).
- **[F-202] Command wrapper.** `ClusterCommands` runs `<containerPath> cluster ...` where
  `containerPath` comes from `RuntimeProcessConfiguration.make` (`RuntimeProcessConfiguration.swift:62-99`).
  It never looks up `container` on `PATH`. It passes `--kubeconfig <path>` from the app setting
  (D8) to `create` and `write-config`. Limits for the client process: `list` 20 s, `create`
  15 min, `start` 15 min, `stop` 2 min plus 2 min per node, `delete` 5 min, `write-config` 30 s.
  When a limit ends the client, the operation goes on in the service; the app follows it in the
  list. Exit 75 is `busy`. Files: `ClusterCommands.swift` (new), `ProcessRunner.swift`.
- **[F-203] Contract changes.** The decoder ignores unknown keys. A missing or renamed required
  key, or an unknown enum value, is an error that names the key and the runtime build; the app
  shows it in place of the list, and Doctor fails (F-215). It never shows a partial list. The app
  enables the feature only for the pinned build (F-218), so a new runtime arrives only with an app
  update that passed the fixture test.
- **[F-204] No cluster state in ContainerStack** (I1, I12). The app, `cstack` and the helper
  write no cluster state. `~/.containerstack/clusters.json` and `cluster-status.json` of version
  0.1 do not exist.

### 8.2 `cstack cluster` (`Sources/CStackCLI/`)

- **[F-205]** Subcommands (file `CStackClusterCommands.swift`, new; dispatch in `CStackCLI.swift`).
  Each is a plain call of the Runtime command; `cstack` keeps no state.

  | Command | Runs |
  |---|---|
  | `cstack cluster ls [--json]` | `cluster list --format json`. Table: `NAME STATE VERSION NODES API CONTEXT AUTOSTART`. `--json` prints the runtime's JSON unchanged. |
  | `cstack cluster create <name> [--cpus N] [--memory SIZE] [--workers ...]... [--node-image REF] [--cni PATH\|NONE] [--shared-image-store] [--rm] [--set-current-context]` | `cluster create --no-current-context` plus the options; `--set-current-context` drops `--no-current-context`. |
  | `cstack cluster start <name>` / `stop <name>` | `cluster start` / `cluster stop`. |
  | `cstack cluster rm <name>` | `cluster delete`. No prompt. |
  | `cstack cluster kubeconfig <name> [--set-current-context]` | `cluster write-config`. |
  | `cstack cluster autostart <name> on\|off` | `cluster autostart`. |

  Progress on stderr unchanged. Exit codes: 0 done; 1 failed; 64 usage; 69 the runtime does not
  run, or the plugin is missing; 75 busy or the runtime is stopping. `KUBECONFIG` of the shell
  reaches the Runtime command.

### 8.3 App (`Sources/ContainerStackApp/`)

- **[F-206] Kubernetes section.** `DashboardDestination.kubernetes`, title "Kubernetes", after
  Stacks, with an inspector (`DashboardView.swift:3-28`). One row per cluster: name, state (F-209),
  Kubernetes version, node count, API endpoint. The inspector: nodes (name, roles, state, present,
  IP, CPUs, memory from the node containers), the kubeconfig file, names and result from the
  record, autostart, the operation in progress with its step, the last start outcome, and "Reach a
  NodePort Service at http://<node IP>:<node port>". The list refreshes every 5 s while the
  section shows, and on demand (F-211). Settings > Kubernetes holds the kubeconfig path (D8).
  Files: `KubernetesView.swift`, `RuntimeViewModel+Clusters.swift`, `KubernetesSettingsPane.swift`
  (new), `DashboardView.swift`, `SettingsNavigation.swift`.
- **[F-207] Create form.** A sheet:
  - Name: lowercase letters, digits and `-`, 1 to 63 characters, starting with a letter or digit
    (stricter than the Runtime's rule, `ClusterResource.swift:46-55`, §13 E5); unique among
    clusters. The form also reads the kubeconfig file and says when the name exists there
    without this cluster's identity; Create is then off (the Runtime refuses it too, F-010).
  - CPUs and memory of the control plane: default as the Runtime (`ClusterHelper.swift:34-40`).
  - Workers: none by default; "Add worker group" adds a row with count, CPUs, memory. Total at
    most 1024 (`ClusterConfiguration.swift:66`).
  - Node image: default "kindest/node v1.35.5 (default)"; a field for another reference.
  - Network plugin: kindnet (default), a manifest file, or none.
  - "Share my local images with the cluster" (`--shared-image-store`), off. When on, the form
    shows the three points of the warning in `docs/cluster.md:5-12` as they are written there.
  - "Delete when stopped" (`--rm`), off. When on, the form says that a runtime restart deletes
    the nodes.
  - "Make this the current kubectl context", off.
  - A memory note: the sum of node memory limits against host memory, with the measured 2.2 GB
    of an idle 6 GB node.
  Create shows the operation's steps. File: `KubernetesCreateSheet.swift` (new).
- **[F-208] Delete.** A confirmation: "Delete cluster <name>? Its nodes, Kubernetes objects and
  volumes are lost. Its context, cluster and user entries in <path from the record> are removed
  if container wrote them." Buttons "Delete" and "Cancel". After delete, the app shows the
  kubeconfig result when it is not `removed`.
- **[F-209] States.** All from the list (§9.1); the app keeps none. The first row that matches
  wins:

  | Shown | When |
  |---|---|
  | Creating, Starting, Stopping, Deleting (with the step) | `lifecycle.operation` is set |
  | Create did not finish | `createCompleted` false and no operation; action Delete only |
  | Failed: <cause> | `lastStart.outcome` is `failed` or `interrupted` and the nodes run or are degraded; actions Start, Stop, Delete |
  | Running | "ready" (§9.1) |
  | Needs start | all nodes run but not "ready" (a boot that no start finished, I7); action Start |
  | Degraded: k of n nodes run | some nodes run; action Start |
  | Node missing: <names> | a node has `present: false`; action Delete |
  | Stopped | no node runs |

  Actions of a cluster with an operation are off. The row does not probe Kubernetes health
  (Doctor does, F-215).
- **[F-210] Context.** Actions "Copy Context Name", "Copy kubectl Command" (`kubectl
  --kubeconfig <path from the record> --context <name> get nodes`; without `--kubeconfig` when
  the path is `~/.kube/config`), "Make Current Context" (`write-config --set-current-context`),
  "Write Kubeconfig Again". The row shows `kubeconfig.result` when it is `failed`, with "Write
  Kubeconfig Again".
- **[F-211] Runtime Restart confirmation.** Before a full restart from the sidebar or the Doctor
  repair, the app lists clusters. When one or more run, it asks: "Restart the runtime? Kubernetes
  clusters <names> stop and start again. Their pods restart. This can take several minutes."
  Buttons "Restart" and "Cancel". With no running cluster it asks nothing. "Stop Runtime" stops
  only the bridge (§2.1) and does not ask. Automatic restarts (poll recovery, stale bridge) do not
  ask. Files: `SidebarRuntimePanel.swift`, `DoctorViewModel.swift`.
- **[F-212] Runtime down.** The section shows "The runtime is not running. Start it to manage
  clusters." and the last list, dimmed. All actions are off. The app runs no `cluster` command
  until the runtime is ready.

### 8.4 Runtime lifecycle

- **[F-213] The restart plan uses the Runtime's shutdown** (I2). The app adds no cluster step.
  `RuntimeRestartPlan.steps` runs `system stop --cluster-timeout 300`, and the process limit of
  that step becomes 300 s plus 120 s for the forced teardown and the service stop (today 120 s,
  `ProcessRunner.swift:43`). The sidebar shows "Stopping Kubernetes clusters…" when a cluster ran
  before the step (`RuntimeViewModel+Control.swift:145-153`). The app, `cstack runtime restart` and
  the automatic restarts use this plan. Files: `RuntimeControl.swift`, `RuntimeViewModel+Control.swift`,
  `CStackRuntimeControl.swift`.
- **[F-214] No autostart in ContainerStack** (I12). Autostart is F-013 in the Runtime. It runs on
  every Runtime start: the helper's `system start`, `cstack runtime start` with no agent, and a
  terminal. A bridge-only restart does not touch it. The app shows its progress and result from
  the list (F-209).

### 8.5 Doctor and memory

- **[F-215] Check `clusters`,** in `CheckID.cliSet` and `CheckID.uiSet`
  (`DiagnosticReport.swift:5-19`). One `cluster list` (3 s limit).
  - Pass: "Kubernetes: N clusters, M running", or "no clusters".
  - Warning: a cluster is degraded, needs start, has a failed or interrupted or skipped last
    start (cause), has `kubeconfig.result` `failed`, or a node has `present: false`; a create
    that did not finish.
  - Failure: the list does not decode (F-203); the plugin is missing.
  - `cstack doctor` only: for each running cluster, `container exec <control plane> kubectl
    --kubeconfig /etc/kubernetes/admin.conf get --raw=/readyz` with a 5 s limit; a failure is a
    warning with the output.
  Files: `DiagnosticRunner+Clusters.swift` (new), `DiagnosticReport.swift`, `DoctorTextRenderer.swift`.
- **[F-216] Memory check counts nodes.** `memoryMeasurement` (`DiagnosticRunner+Memory.swift:6-35`)
  adds the memory limits of running nodes, listed with the cluster label filter (F-104). The
  report says "including K cluster nodes".

### 8.6 Docs and version

- **[F-217] Docs.** `docs/kubernetes.md`: create; contexts, the kubeconfig file, ownership of
  entries and name refusals; reach a Service (NodePort on the node IP, `kubectl port-forward`); no
  LoadBalancer, no ingress; the shared image store and its warning; what a runtime restart does;
  autostart; delete; the bridge refuses lifecycle calls on nodes and is not a security boundary.
  ROADMAP M8 names this spec.
- **[F-218] Pins and build identity.** Both runtime scripts pin `1.7.1-bshk.3`:
  `scripts/prepare-v1-runtime.sh` (tag) and `scripts/prepare-container-runtime.sh` (tag and the
  package SHA-256). `RuntimeProcessConfiguration` gets the pinned commit. The app enables the
  Kubernetes section only when `container --version` reports the pinned commit and `container
  system status` reports the same `server.commit` (the daemon that supplies the plugin). No "or
  later" rule. The staging script checks the staged files directly:
  `libexec/container/plugins/cluster/bin/cluster`, its `config.toml` and
  `resources/cluster-shim` (static ELF aarch64), `plugins/cluster-hoststore`,
  `plugins/container-core-clusters`. Files: the two scripts, `RuntimeProcessConfiguration.swift`,
  `ContainerVersionCheck.swift`, `scripts/stage-containerstack-app.sh`.

## 9. Frozen contracts

### 9.1 Cluster list (Runtime → app), schema 2

`container cluster list --format json`: a JSON array. The app reads these keys and ignores
others.

Required: `configuration.name`, `configuration.kubernetesVersion`, `configuration.remove`,
`configuration.sharedImageStore`, `configuration.creationDate` (ISO 8601),
`configuration.nodes[].name`, `configuration.nodes[].roles`, `status.state` (`running` \|
`degraded` \| `stopped`), `status.nodes[].name`, `status.nodes[].status` (`unknown` \| `stopped`
\| `running` \| `stopping`), `status.nodes[].present` (bool), and:

```json
"lifecycle": {
  "clusterID": "3f0c…",
  "createCompleted": true,
  "autostart": true,
  "operation": { "kind": "start", "step": "Repairing kube-proxy", "started": "…", "generation": "…" },
  "lastStart": { "outcome": "succeeded", "generation": "…", "finished": "…",
                 "step": null, "node": null, "message": null,
                 "nodeBoots": [ { "name": "dev", "created": "…", "started": "…" } ] },
  "kubeconfig": { "path": "/Users/u/.kube/config", "names": { "cluster": "dev", "context": "dev", "user": "dev" },
                  "result": "written", "message": null }
}
```

`operation` and `lastStart` may be null. `operation.kind`: `create`, `start`, `stop`, `delete`,
`writeConfig`. `lastStart.outcome`: `succeeded`, `failed`, `interrupted`, `skipped`.
`kubeconfig.result`: `written`, `failed`, `removed`, `kept`; `kubeconfig` may be null (a migrated
record). Optional: `configuration.cni`, `configuration.fqdn`, `status.nodes[].addresses`,
`status.nodes[].ports`.

"Ready" means: `createCompleted`, no `operation`, `lastStart.outcome` is `succeeded`, every node
runs, and `lastStart.nodeBoots` equals the current created and started dates of the nodes. The
service computes nothing else; the app and Doctor compute "ready" from these fields with one
shared function in `KubernetesCluster`.

The fixture `Tests/ContainerStackCoreTests/Fixtures/cluster-list.v2.json` comes from the first
live run of S3; until then a hand-written file in this shape.

### 9.2 Kubeconfig entry ownership (Runtime → user file)

Each owned `clusters`, `contexts` and `users` entry has:

```yaml
extensions:
- name: container.apple.com/cluster
  extension:
    id: 3f0c…
```

### 9.3 Shutdown and generation

`container system stop [--cluster-timeout <s>]`: one deadline for drain and graceful stops
(F-011). `<app root>/apiserver-generation`: one UUID, written by the API server at start
(F-013).

### 9.4 Bridge answer for a node

HTTP 409, body `{"message":"<name> is a node of a Kubernetes cluster. Use 'container cluster' or ContainerStack to start, stop or delete it."}`.
An identity change answers 409 `{"message":"container <name> changed during the request"}`.

### 9.5 Runtime commands

`container cluster start|stop|delete|autostart --name <name>`, `create --no-current-context
--kubeconfig <path>`, `write-config --set-current-context`. Exit codes: 0 done, 1 failed,
75 busy or admission closed. Output: the name on stdout, steps and warnings on stderr.

## 10. Tests

Every live test uses its own `KUBECONFIG` file in a temporary directory and checks at the end
that `~/.kube/config` has the same SHA-256 as before.

### 10.1 Invariant tests

The service gets a debug-build fault seam: `CLUSTER_FAULT_AFTER=<write point>` makes the service
process exit with SIGKILL right after the named persistent write. Write points: record
`operation` set; each `step` update; each node file write of F-004 and F-005; each ConfigMap
write; kubeconfig rename; `createCompleted`; `lastStart`; `autostart`; generation of the autostart
run. For each invariant, one test runs the operation once for each write point it passes, lets
launchd load the service again, and checks the invariant; and one contention test runs two
callers at the same time.

| Inv. | Failure injection (after each write point) | Contention |
|---|---|---|
| I1 | The operation is `interrupted` at load; a new request is admitted; never two operations. | `start` and `delete` from two clients at once: one is admitted, the other exits 75 and its autostart change is not made. Also `create` against `start`, `stop`, `write-config`. |
| I2 | Cut during shutdown: the next generation opens admission; no operation of the old one continues. | `start` sent while `shutdown` drains: exits 75. Total time of `system stop` with two clusters stays under the budget plus the teardown limit. |
| I3 | Cut at each create write point: the record is not completed; `start` and autostart refuse it; `delete` cleans every node and kubeconfig entry it made. | Autostart and a user `delete` of an incomplete record. |
| I4 | Cut after the kubeconfig rename and before `createCompleted`: delete removes the entries; an entry with another identity stays. | Two clusters with names `a`, `b` in one file, created at once: both entries exist; a pre-existing `a` without identity is refused and kept byte-equal. |
| I5 | Cut between temporary write and rename: the file is the old one or the new one, never partial; no stale lock blocks the next write for more than 10 s (the lock file names its PID; a lock of a dead PID is removed). | `write-config` of cluster `a` and `delete` of cluster `b` on one file at once: both changes are in the result. `kubectl config set` during a Runtime write: both changes kept. |
| I6 | Not a persistent write. | Bridge: replace a non-node container by a node of the same name between resolve and mutation (fake client hook): no mutation, 409. Runtime: `stop` without `managedBy` on a node: refused. |
| I7 | Cut at each start write point: no `succeeded` for a boot that the start did not finish. | A node is booted by the Runtime test hook during a start: the outcome does not name that boot. |
| I8 | Cut between each ConfigMap or kubelet.conf write and its reload: the next start reloads (kube-proxy pod newer than the write; kubelet `ActiveEnterTimestamp` newer than the file; containerd newer than its file). | Not applicable beyond I1. |
| I9 | Unit: ConfigMap holds an IP two boots old (round 3): repaired. Files hold the IP of a failed boot that the marker does not name: repaired. | — |
| I10 | Cut after the temporary pair and before rename; a node with key but no certificate; with neither: the API server serves with the current IP SAN after start. Old entrypoint with a forced `kubeadm` failure: the start repairs it. | — |
| I11 | — | A container with the node's name but another identity label: start refuses it. |
| I12 | Cut during the autostart run: the next load of the same generation does not run it again; a new generation does. | User `stop` while autostart waits in the queue: the cluster stays stopped. |

### 10.2 Requirement tests

| Req. | Test that fails without it | Kind | Repository |
|---|---|---|---|
| F-001 | The release job's payload check fails on a package built without the shim. `make container BUILD_CONFIGURATION=release` with no shim and no container services exits non-zero. | CI | Runtime |
| F-002 | A fake provisioner records the stop order (workers descending, then control plane) and the force stop at the limit. Live: `cluster stop` leaves the record and nodes, state `stopped`; the next start reads verdict `clean`. | unit, live | Runtime |
| F-003, F-004 | Live: create, a NodePort Service, `cluster stop`, take the node IP with another container, `cluster start`. Asserted: a new node boot (`startedDate` changed and the IP differs), NodePort answers from the host, a pod resolves `kubernetes.default` and fetches an HTTP page, a ConfigMap made before the stop is there, `lastStart` names the new boots. The same with `--workers 1` (E1). Unit: with a stopped worker, step 6 waits only for the control-plane kube-proxy pod. | live, unit | Runtime |
| F-003 step 3 | Live (E3): hold the API port on the host, start: fails with the port text, node stopped, record and port kept; free the port, start: succeeds. FQDN cluster: no port check. | live | Runtime |
| F-005 | Live: after a start, both TCPMSS rules exist once; a second start adds none. | live | Runtime |
| F-007 | Unit: a killed client process does not end the operation; the command prints steps from the record. | unit | Runtime |
| F-010 | Unit over a fixture with `preferences`, `extensions` on all levels, `exec` with `env: null` and non-empty `env`, unknown keys. After merge: the intermediate document has the three owned entries with the identity and is otherwise equal; after remove: equal to the input. Collision: a pre-existing context of the same name stops create before any provisioning (the fake provisioner is never called). Mode 0600 of a new file; an existing 0640 file stays 0640; a delete with nothing owned does not change the modification time. | unit | Runtime |
| F-011 | Live: with a running cluster, `container system stop` returns inside `--cluster-timeout` plus 120 s; the next start reads verdict `clean` (after E2). | live | Runtime |
| F-012 | Unit: a schema-1 record loads as migrated, autostart true, no kubeconfig ownership; a schema-1 record whose control plane has no `admin.conf` is not started. | unit | Runtime |
| F-013 | Unit with a fake clock and store: one run per generation, oldest first, autostart false skipped. Live: `cstack runtime start` with no registered agent after `system stop`: the cluster runs again with a new boot. | unit, live | Runtime, App |
| F-014 | Unit: `stop`, `kill`, `delete`, `bootstrap` of a labelled container without `managedBy` are refused; with it, done. | unit | Runtime |
| F-101 | Route tests with a fake node for each row: each 409 row answers 409 with the body and the fake records no mutation; exec on a node runs the process (fake records the exec); archive GET returns the bytes; archive PUT is refused and writes nothing; attach streams. Network connect and disconnect with a node, with and without `--shared-runtimes`: 409. A reference by ID prefix and by retired ID resolves to the node and is refused. | route | Bridge |
| F-102 | `docker container prune --filter label=com.apple.container.plugin=cluster` on a fake with a stopped node deletes nothing; a candidate replaced by a node before its delete is not deleted. | unit | Bridge |
| F-103 | With `--shared-runtimes`, a node stop gets 409 and a session stop still works. | route | Bridge |
| F-104 | No bridge test: F-216's test reads node limits through the label filter and inspect. | — | — |
| F-105 | Route test: create with a node's name answers 409 with the Docker conflict text. | route | Bridge |
| F-201, F-203 | Decode the fixture; decode with an extra key; fail with a missing `status.state`, with `state: "paused"`, with a missing `lifecycle`; the error names the key. "Ready" is false when one `nodeBoots` date differs. | unit | App |
| F-202 | With a fake `container` first on `PATH` and a configuration path to a recording script, the wrapper runs the script; `create` gets `--kubeconfig` with the setting. | unit | App |
| F-204 | The app and `cstack` write no file under `~/.containerstack` for clusters (a test run with a temporary home lists the files). | unit | App |
| F-205 | Argument mapping for each subcommand; exit 75 maps to 75; `create` passes `--no-current-context` unless `--set-current-context`. | unit | App |
| F-206 to F-210, F-212 | View model tests over list fixtures: each row of F-209; actions on and off; create arguments from the form, the warning only with sharing on; the name collision turns Create off; delete text names the record's path; the copied command has `--kubeconfig` for a non-default path. | unit | App |
| F-211 | With one running cluster, "Restart" shows the confirmation with its name; with none, no confirmation; automatic recovery shows none. | unit | App |
| F-213 | `RuntimeRestartPlan.steps` passes `--cluster-timeout 300` and the step limit is 420 s. | unit | App |
| F-215, F-216 | Doctor fixtures: degraded, needs start, failed start, node missing give warnings; unreadable list gives a failure; memory total includes a node found only through the label filter. | unit | App |
| F-217 | Review only. | review | App |
| F-218 | Version check: a build with another commit, or a daemon with another `server.commit`, hides the section. The staging check fails on a bundle without each named file. Dispatch through `container cluster --help` runs only in a live test against the daemon of the staged bundle, after `system status` shows its install root. | unit, CI, live | App |

## 11. Order of work

Each slice is one pull request, reviewed alone.

| Slice | Requirements | Repository | Needs | Parallel with |
|---|---|---|---|---|
| S0 Experiment E2 | — | Runtime (no code) | — | all |
| S1 Release has the shim | F-001 | Runtime | — | S2 to S4, S6 |
| S2 Service owns state | F-007, F-012, F-015, F-014, F-010, F-009, fault seam | Runtime | — | S1, S4, S6 |
| S3 Start, stop, shutdown, autostart | F-002 to F-006, F-008, F-011, F-013 | Runtime | S2; S0 for F-002's stop method. E1 and E3 are acceptance tests of S3, run when a first start works. | S1, S4, S6 |
| S4 Node guard | F-101 to F-105 | Bridge | F-014 for the I6 contention test (fake until S2 lands) | S1 to S3, S6 |
| S5 Pins | F-218, release `1.7.1-bshk.3` | Runtime, App | S1 to S4 | S7 to S10 (until their live tests) |
| S6 Core | F-201 to F-204 | App | the contract of §9 only (hand-written fixture, fake runner) | S1 to S4 |
| S7 `cstack cluster` | F-205 | App | S6 | S8 to S10 |
| S8 Lifecycle | F-213, F-214 | App | S6; the live test needs S5 | S7, S9, S10 |
| S9 App UI | F-206 to F-212 | App | S6 | S7, S8, S10 |
| S10 Doctor | F-215, F-216 | App | S6 | S7 to S9 |
| S11 Docs and E4 | F-217 | App | S5, S7 to S10 | — |

## 12. Non-goals

- A Kubernetes object browser (pods, Services, logs) in the app. Users use `kubectl` or other
  tools with the context.
- LoadBalancer and ingress (D3).
- A cluster in a shared or project VM (D4).
- A change of CPUs, memory, workers, node image or sharing after create. The Runtime has no
  command for it; sharing is fixed at create [S Runtime `docs/cluster.md:168`]. The user deletes
  and creates the cluster.
- An upgrade of Kubernetes in place.
- Loading a local image into a cluster without the shared image store.
- A security boundary between Docker clients and cluster nodes (F-101).

## 13. Open questions

Live experiments that this spec did not run:

- **E1. Multi-node start.** Part of S3's acceptance (§10.2). If the worker becomes Ready only
  after the worker repair of F-004, the design is confirmed. If it becomes Ready without it, keep
  the step: it is a no-op when the value is right. If it does not become Ready with it, the worker
  holds the IP in another place: grep the worker for the old control-plane IP and add the item to
  F-004.
- **E2. Stop takes 90 s.** Three stop methods each took about 90 s (§2.2). Run, with a limit of
  300 s: (a) `kill` with signal 37 (SIGRTMIN+3, systemd halt), (b) signal 38 (SIGRTMIN+4,
  poweroff), (c) exec `systemctl poweroff`. Record the time to `stopped` and the F-005 verdict at
  the next boot (install the unit by hand for this). If a method gives `clean` in less than 90 s,
  F-002 uses it with a limit of twice the time. If all give `clean` at about 90 s, a unit hits
  systemd's default stop timeout of 90 s [I]; find it with a persistent journal and add a drop-in
  with a short stop timeout for it to F-005. If none gives `clean`, the signal does not reach
  systemd, and the in-node `systemctl` needs the system bus that the exec did not find.
- **E3. API port taken at start.** Part of S3's acceptance. The output fixes the error text of
  F-003 step 3.
- **E4. Shared image store after a restart.** Needs a release with the shim (F-001). Check that
  the host-store socket exists before autostart (`Sources/Plugins/ClusterHostStore/config.toml`:
  `loadAtBoot`, `runAtLoad`), and that a pod with a local image and `imagePullPolicy: Never`
  starts after a runtime restart.
- **E5. Upper-case cluster names.** The Runtime accepts upper-case letters, `_` and `.` in a
  cluster name. A Kubernetes node name must be lower case [I]. Create a cluster named `Dev`. If
  kubeadm fails, the Runtime's name check needs the Kubernetes rule; the app form already has it.
- **E6. TCPMSS.** A 500 KB HTTPS download worked without the clamp [L `fix1.txt`]. F-005 restores
  it anyway. A network with a smaller MTU (a VPN on the host) can show whether the clamp is
  needed; this does not change the design.
- **E7. Host logout and shutdown.** launchd ends the Runtime's agents at logout and shutdown, with
  its own exit timeout [I]. `system stop` does not run then, so F-011 does not run. Log out with a
  running cluster, log in, and read the F-005 verdict at autostart. If it is `unclean`, nodes die
  hard at logout; the data survived three hard stops in this check (§2.2), and E2's fix shortens
  the stop. The result goes to the user page.
- **E8. Lock file of `kubectl`.** F-010 assumes that `kubectl` locks `<path>.lock` while it writes
  [I]. Run `kubectl config set` in a loop against the Runtime's writer. If both changes are not
  always kept, F-010 needs another lock.

Decisions for the owner: D1 to D4 confirm the earlier recommendations; D5 to D8 are new. §4
(the cluster service owns all cluster state and runs the lifecycle) is the structural choice of
this version and grows the fork difference; the alternative is a file lock in the plugin plus
the helper, which the review showed cannot record outcomes or cover every start path.
