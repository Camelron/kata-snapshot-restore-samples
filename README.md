# Kata snapshot and restore demo files

This directory contains small Kubernetes manifests and helper tools for testing
a custom Kata Containers snapshot/restore path. The central behavior is the
`io.katacontainers.restore-from` Pod annotation: its value points to a snapshot
directory on the node, and the custom Kata runtime restores the sandbox from
that directory instead of cold-starting it.

The main workflow is:

1. Prepare the Kata-capable nodes and label exactly one as the snapshot source.
2. Cache the BusyBox image on every Kata-capable node.
3. Start the `busybox-kata` source Pod on the snapshot source node.
4. Create a snapshot on that node with `snapshot-create.sh`.
5. Distribute that node-local snapshot to the other Kata nodes.
6. Run either the single-Pod smoke test or the normal-versus-restore scale demo.

`snapshot-create.sh` automates the host-side snapshot command for an existing
source Pod. The restore manifests expect the resulting snapshot to exist under
`/run/vc/vm/snapshots` on every node where a restored Pod may be scheduled.

## Prerequisites and conventions

- The cluster has the custom `kata-preview` runtime handler that supports
  `io.katacontainers.restore-from`.
- The `kubectl node-shell` plugin is installed locally; `snapshot-create.sh`
   uses it to run `crictl` and `kata-runtime` in the selected node's namespaces.
- Every eligible node is labeled
  `katacontainers.io/kata-runtime=true`.
- Exactly one authoritative snapshot node is labeled
   `snapshot-sync.katacontainers.io/source=true` before applying `busy.yaml`.
- The BusyBox image is cached on every eligible node. Restore and benchmark
  manifests use `imagePullPolicy: Never` so image pulls do not affect timing.
- Snapshot creation, synchronization, and restore operations do not overlap.
- The Pod/container definition used for restore remains compatible with the
  definition captured in the snapshot.

The primary snapshot names are:

| Workload | Host snapshot directory |
| --- | --- |
| Single-container BusyBox | `/run/vc/vm/snapshots/busybox-kata` |
| Three-container BusyBox | `/run/vc/vm/snapshots/busybox-kata-multi` |

## File catalog

### Cluster and node preparation

#### [`runtimeClass-kata-preview-azl3.yaml`](runtimeClass-kata-preview-azl3.yaml)

Defines the cluster-scoped `kata-preview` RuntimeClass. It selects nodes labeled
`katacontainers.io/kata-runtime=true`, uses the `kata-preview` runtime handler,
and declares 32 MiB of fixed Pod memory overhead.

Apply this only when the cluster does not already provide the RuntimeClass:

```sh
kubectl apply -f runtimeClass-kata-preview-azl3.yaml
```

#### [`busy-daemonset.yaml`](busy-daemonset.yaml)

A temporary DaemonSet that pulls `docker.io/library/busybox:latest` onto every
node labeled `katacontainers.io/kata-runtime=true`. It uses
`imagePullPolicy: IfNotPresent`, so each node pulls the image only when it is
missing. Wait for every DaemonSet Pod to become Ready before deleting it:

```sh
kubectl apply -f busy-daemonset.yaml
kubectl rollout status daemonset/busybox-cache --timeout=5m
kubectl get pods -l app=busybox-cache -o wide
kubectl delete -f busy-daemonset.yaml
```

Deleting the DaemonSet removes its Pods but leaves the image in each node's
containerd cache. The later source, restore, and benchmark workloads can
therefore use `imagePullPolicy: Never` without including image pulls in their
startup times.

#### [`busy.yaml`](busy.yaml)

A long-running source Pod named `busybox-kata`. The `kata-preview` RuntimeClass
selects `katacontainers.io/kata-runtime=true` nodes, and the Pod additionally
selects `snapshot-sync.katacontainers.io/source=true`, so it runs only on the
selected snapshot source node. It uses `imagePullPolicy: Never`, so complete the
cache DaemonSet step first. Label exactly one source node before creating it:

```sh
kubectl label node <source-node> \
   snapshot-sync.katacontainers.io/source=true

kubectl apply -f busy.yaml
kubectl wait --for=condition=Ready pod/busybox-kata --timeout=2m
kubectl get pod busybox-kata -o wide
```

Leave the Pod running until `snapshot-create.sh` has created its snapshot. The
image must remain cached on every node that will later run a restore or benchmark
workload.

### Snapshot creation

#### [`snapshot-create.sh`](snapshot-create.sh)

Creates a snapshot from a running Pod's Ready CRI sandbox. It looks up the
sandbox by the Kubernetes Pod UID, avoiding ambiguous matches when Pod names
share a prefix or an older failed sandbox attempt remains on the node. The
snapshot is written to `/run/vc/vm/snapshots/<pod-name>`, so the source Pod name
must match the snapshot directory referenced by the restore manifest. For the
primary demo, that name is `busybox-kata`.

Pass the Pod name and, optionally, its node name:

```sh
./snapshot-create.sh busybox-kata
./snapshot-create.sh busybox-kata <node-name>
```

When the node is omitted, the script requires exactly one node labeled
`snapshot-sync.katacontainers.io/source=true`. It verifies that the Pod is
Running on the selected node before invoking:

```sh
kata-runtime snapshot create \
   --sandbox-id <sandbox-id> \
   --path /run/vc/vm/snapshots/<pod-name>
```

The script refuses to overwrite an existing snapshot by default. Validate the
lookup without creating anything, or explicitly replace an existing snapshot:

```sh
./snapshot-create.sh --dry-run busybox-kata
./snapshot-create.sh --replace busybox-kata
./snapshot-create.sh --namespace <namespace> <pod-name> [node-name]
```

### Snapshot distribution

#### [`snapshot-sync.sh`](snapshot-sync.sh)

The preferred one-shot synchronization tool. It discovers all Ready nodes
labeled `katacontainers.io/kata-runtime=true` and uses the one node labeled
`snapshot-sync.katacontainers.io/source=true` as the source of truth.

The script:

1. Starts a temporary, node-pinned helper Pod on each target node.
2. Uses GNU tar to create a sparse-aware `snapshots.tar.gz` on the source node.
3. Uses `kubectl cp` to download only that compressed archive to a local
   `mktemp` directory.
4. Copies the archive to every other Ready Kata node and verifies SHA-256 at
   each transfer boundary.
5. Sparse-extracts into a new host directory and swaps it into place only after
   extraction succeeds.
6. Deletes the helper Pods and local temporary files when the run finishes.

The destination becomes an exact copy of the source snapshot tree. Files that
exist only on a destination are removed by the directory replacement.

The source selected before applying `busy.yaml` is also the synchronization
source. Confirm the label and run the sync:

```sh
kubectl get nodes -l snapshot-sync.katacontainers.io/source=true
./snapshot-sync.sh
```

Useful alternatives:

```sh
./snapshot-sync.sh --source <source-node>
./snapshot-sync.sh --keep-local-copy
NAMESPACE=<namespace> ./snapshot-sync.sh
```

The helper image defaults to `ubuntu:24.04` because BusyBox tar does not encode
GNU sparse metadata. An image supplied through `HELPER_IMAGE` must include GNU
tar with `--sparse`, gzip, and `sha256sum`.

### Single-Pod restore tests

#### [`busy-restore.yaml`](busy-restore.yaml)

The smallest restore smoke test. It creates `busybox-kata-restored` with:

```yaml
io.katacontainers.restore-from: "/run/vc/vm/snapshots/busybox-kata"
```

Use a watcher in one terminal:

```sh
kubectl get pod busybox-kata-restored --watch -o wide
```

Create a fresh restored Pod in another terminal:

```sh
kubectl delete pod busybox-kata-restored --ignore-not-found --wait=true
kubectl apply -f busy-restore.yaml
kubectl wait --for=condition=Ready pod/busybox-kata-restored --timeout=60s
```

Deleting the previous Pod matters: applying an unchanged existing Pod does not
exercise a new restore.

#### [`busy2-restore.yaml`](busy2-restore.yaml)

Personal scratch space for restore experiments. The current version creates a
second restored Pod and pins it to a specific AKS hostname. Treat the contents
as temporary and cluster-specific, not as part of the repeatable demo.

### Scale and comparison demo

#### [`busy-deployment.yaml`](busy-deployment.yaml)

The non-restore baseline Deployment. Its Pods cold-start through normal Kata,
use `imagePullPolicy: Never`, and sleep indefinitely so readiness can be timed.
The strict hostname topology spread constraint balances replicas across two
nodes with at most one Pod of skew.

#### [`busy-restore-deployment.yaml`](busy-restore-deployment.yaml)

The restore-enabled counterpart to `busy-deployment.yaml`. The restore
annotation is on the Deployment's Pod template, so every replica restores from
`/run/vc/vm/snapshots/busybox-kata`. It uses the same long-running container and
two-node spread policy as the baseline, making readiness timing comparable.

Both Deployment spread constraints use `minDomains: 2` and
`whenUnsatisfiable: DoNotSchedule`. If only one eligible node is available,
Kubernetes leaves excess replicas Pending rather than concentrating the full
test on that node.

#### [`busy-restore-demo.md`](busy-restore-demo.md)

The scale-test runbook. It starts at one replica, accepts a configurable
`TARGET_REPLICAS`, scales the restore Deployment, and reports elapsed time until
the requested number of replicas is Ready. It also contains a matching timing
block for the non-restore baseline Deployment.

Prepare both comparison Deployments before following the runbook:

```sh
kubectl apply -f busy-deployment.yaml
kubectl apply -f busy-restore-deployment.yaml
```

### Multi-container variant

#### [`busy-multi.yaml`](busy-multi.yaml)

A source Pod with three long-running BusyBox containers in one Kata sandbox.
It is used to exercise snapshot behavior beyond the single-container case and
expects all image layers to already be cached.

#### [`busy-multi-restore.yaml`](busy-multi-restore.yaml)

The matching three-container restore Pod. It restores from
`/run/vc/vm/snapshots/busybox-kata-multi`; its container names and commands
mirror `busy-multi.yaml`.

### Independent runtime reproducer

#### [`emptydir.yaml`](emptydir.yaml)

A standalone reproducer for a Go-runtime plus block-rootfs failure involving a
disk-backed `emptyDir` with the default `emptydir_mode=shared-fs`. It is not
part of the snapshot/restore demo. The comments in the manifest document the
expected read-only-filesystem failure and the in-memory `emptyDir` control case.

## Suggested two-node workflow

1. Verify the RuntimeClass and Kata node labels, then select one snapshot source:

   ```sh
   kubectl get runtimeclass kata-preview
   kubectl get nodes -L katacontainers.io/kata-runtime
   kubectl label node <source-node> \
     snapshot-sync.katacontainers.io/source=true
   ```

2. Apply `busy-daemonset.yaml`, wait for `daemonset/busybox-cache` to finish its
   rollout, confirm that one cache Pod ran on each Kata node, and delete the
   DaemonSet. The cached image remains on the nodes.
3. Apply `busy.yaml` and wait for the `busybox-kata` Pod to become Ready on the
   labeled source node.
4. Run `./snapshot-create.sh busybox-kata` to create the snapshot, then remove
   the source Pod with `kubectl delete -f busy.yaml`. Add `--replace` when
   deliberately refreshing an existing path.
5. Run `./snapshot-sync.sh` from the already-labeled source node.
6. Run `busy-restore.yaml` for a one-Pod smoke test.
7. Apply both Deployment manifests and follow `busy-restore-demo.md` for the
   normal-versus-restore scale comparison.

For repeatable measurements, keep the node set, image cache, snapshot contents,
cluster load, and target replica count consistent between baseline and restore
runs.