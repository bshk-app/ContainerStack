# Kubernetes clusters

A cluster runs Kubernetes on your Mac. Each node is a VM that the Apple Container
cluster plugin creates. Clusters need Apple Container runtime `1.7.1-bshk.3` or later
with the `container cluster start` and `container cluster stop` commands.

## Create and manage a cluster

1. Open **Kubernetes** in the sidebar and click **Create Cluster…**.
2. Enter a **Name**. Use 1 to 63 lowercase letters, digits, or hyphens. Start and end
   with a letter or digit.
3. Set **CPUs** and **Memory** for the control plane, or leave them blank for the defaults.
   To add workers, click **Add Group** under **Worker groups** and set **Count**.
4. Click **Create**. When the row shows **Running**, select it to see **Nodes** and
   **Kubeconfig** in the inspector.

An idle node with a 6 GB limit uses about 2.2 GB of host memory. Keep the total node
limits within your Mac's memory.

Use the row's **Start**, **Stop**, or **Delete** action to manage the cluster. **Stop**
keeps the nodes and their data. **Delete** asks for confirmation and removes the nodes,
Kubernetes objects, and volumes.

In a terminal, these commands create a cluster named `dev`, list clusters, and stop or
start `dev`:

```sh
cstack cluster create dev
cstack cluster ls
cstack cluster stop dev
cstack cluster start dev
```

`cstack cluster ls --json` prints the runtime's cluster list as JSON.
`cstack cluster rm dev` deletes the cluster and its data without a prompt.
The Docker bridge blocks Docker lifecycle actions on cluster nodes to prevent accidents.
This guard has no security isolation.

## Use kubectl

The app and `cstack` write cluster contexts to `~/.containerstack/kubeconfig`.
Select the cluster and use the copy buttons in **Kubeconfig**. For a cluster named `dev`,
the two lines are:

```sh
kubectl --kubeconfig ~/.containerstack/kubeconfig --context dev get nodes
export KUBECONFIG=~/.containerstack/kubeconfig
```

The first line checks the nodes. The second tells `kubectl` to use the app file in
the current shell. `cstack cluster kubeconfig dev` writes the context and prints both
lines. If the row shows **No kubeconfig context**, click **Write Kubeconfig** when the
button is available. It needs a running control plane and all nodes present.

To use your default kubeconfig, click **Add to ~/.kube/config…** in the inspector.
Back up the file before you confirm with **Add Context**. Apple Container rewrites
the whole file, removes keys it does not recognize, and changes the layout. The app
refuses if the file has a cluster, context, or user with the same name, if it cannot
read or parse the file, or if a symbolic link or hard link makes it the same file as
the app kubeconfig. If the delete dialog shows commands to remove entries from
`~/.kube/config`, run them to remove those entries.

## Reach a service

For a NodePort Service, select the cluster and read **IP** under **Nodes**. Connect to the
node IP and the Service's NodePort. The node IP changes at each start. Check it again
after you start the cluster.

For local access through the Kubernetes API, forward a port. This example forwards
port 8080 on your Mac to port 80 of a Service named `web`:

```sh
kubectl --kubeconfig ~/.containerstack/kubeconfig --context dev port-forward service/web 8080:80
```

Open `http://localhost:8080` while the command runs. Clusters have no LoadBalancer
support and no ingress controller. They also come without a StorageClass or a storage
provisioner. Use a static PersistentVolume for a claim.

## Use local images

When you create a cluster, turn on **Share my local images with the cluster**, or
use `cstack cluster create dev --shared-image-store`. Pods can use images you build
with `docker build` through the ContainerStack Docker bridge. A pod can use a local
image with `imagePullPolicy: Never`.

Root on a node can read every local image, including private images. This includes
privileged pods and pods with a `hostPath` mount. Local images take priority over
registry images of the same name for every pull policy, even without pod pull secrets.
Nodes cannot add, change, or delete local images.

## Restart the runtime

**Stop Runtime** and `cstack runtime stop` stop only the Docker bridge. Clusters keep
running. **Restart Runtime** and `cstack runtime restart` try to stop clusters oldest
first, with workers before the control plane. A cluster marked `left to system stop`
is left for the runtime to stop. A Mac reboot also stops clusters.

After a restart or reboot, clusters stay stopped. Start them again from **Kubernetes**
or with `cstack cluster start dev`. Normal clusters keep their Kubernetes objects
and volume data. There are two exceptions to plan for before a stop:

- A cluster created with the native `container cluster create --rm` loses its nodes
  and their data when it stops. Delete the remaining cluster record and create a new
  cluster.
- An old multi-node cluster without a stable control-plane endpoint can lose the
  ability to start after a stop. Back up its data before stopping it. If it cannot
  start, create a new cluster and restore the data from the backup.

## Row states and Doctor

| Row state | What to do |
| --- | --- |
| **Running** | The API is ready. Use `kubectl`, or click **Stop** when you finish. |
| **Stopped** | Click **Start** to use the cluster again. |
| **Degraded: 1 of 2 nodes running** | Some nodes are stopped. Click **Start** to bring them up. |
| **Node missing: dev** | A node is gone. Click **Delete** and create a new cluster. |
| **API not ready** | Wait if the cluster just started. If you see the Local Network message, follow it. Use **Restart** if the API still does not respond. |
| **Start failed** | Read the error on the row. Click **Restart** to stop and then start the cluster. |
| **Creating…**, **Starting…**, **Stopping…**, **Deleting…**, **Writing Kubeconfig…** | Wait for the operation to finish. |

The Local Network message reads:

> Likely cause: the runtime has no Local Network permission. Allow container-runtime-linux
> in System Settings > Privacy & Security > Local Network.

In the terminal, use `cstack cluster stop dev` followed by `cstack cluster start dev`
to do the same as the row's **Restart** action.

Open **Doctor** or run `cstack doctor` to check the cluster count and see warnings
for stopped or degraded clusters, missing nodes, API readiness, or missing kubeconfig
contexts. The memory check includes the limits of running nodes.

Run one cluster change at a time. The app and separate terminal commands can write the
same kubeconfig at the same time and lose a context. Wait for each change to finish
before starting the next one.
