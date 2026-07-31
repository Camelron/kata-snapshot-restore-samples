# BusyBox restore scale demo

This demo starts one restored Kata pod, scales the Deployment to a configurable number of replicas, and measures the time until all replicas are Ready. The readiness elapsed time is the observable restore signal for this demo.

## Prerequisites

- The `kata-preview` RuntimeClass is installed and usable.
- The snapshot exists at `/run/vc/vm/snapshots/busybox-kata` on every node that can run these pods.
- `docker.io/library/busybox:latest` is already present on every eligible node because the manifest uses `imagePullPolicy: Never`.
- The cluster has enough unallocated capacity for the selected replica target.
- `kubectl` is configured for the target cluster and namespace.

Run all commands from this directory. To use another namespace, add the same `--namespace <namespace>` option to every `kubectl` command.

## 1. Start with one restored replica

```sh
kubectl apply -f busy-restore-deployment.yaml
kubectl rollout status deployment/busybox-kata-restore --timeout=2m
kubectl get deployment busybox-kata-restore
```

The Deployment should report `1/1` Ready before the timed scale-up.

## 2. Watch the scale-up

In a separate terminal, watch the Deployment and its pods:

```sh
kubectl get deployment busybox-kata-restore --watch
```

For pod-level detail, use:

```sh
kubectl get pods -l app=busybox-kata-restore --watch
```

## 3. Scale from 1 to the target and measure readiness

Set the target for the run. Change this value while experimenting; if it is unset, the timing block defaults to 100 replicas.

```sh
export TARGET_REPLICAS=50
```

Run this Bash block in the main terminal:

```bash
target_replicas="${TARGET_REPLICAS:-100}"

if [[ ! "$target_replicas" =~ ^[1-9][0-9]*$ ]]; then
    printf 'TARGET_REPLICAS must be a positive integer; got %s.\n' "$target_replicas" >&2
elif start_ns=$(date +%s%N) &&
    kubectl scale deployment/busybox-kata-restore --replicas="$target_replicas" &&
    kubectl wait deployment/busybox-kata-restore \
        --for="jsonpath={.status.readyReplicas}=${target_replicas}" \
        --timeout=10m; then
    end_ns=$(date +%s%N)
    elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
    printf '%d/%d replicas became Ready in %d ms (%d.%03d s)\n' \
        "$target_replicas" "$target_replicas" "$elapsed_ms" \
        "$((elapsed_ms / 1000))" "$((elapsed_ms % 1000))"
else
    printf 'Scale-up did not reach %d Ready replicas within the timeout.\n' \
        "$target_replicas" >&2
fi
```

For comparison with stock kata:

```bash
target_replicas="${TARGET_REPLICAS:-100}"

if [[ ! "$target_replicas" =~ ^[1-9][0-9]*$ ]]; then
    printf 'TARGET_REPLICAS must be a positive integer; got %s.\n' "$target_replicas" >&2
elif start_ns=$(date +%s%N) &&
    kubectl scale deployment/busybox-kata --replicas="$target_replicas" &&
    kubectl wait deployment/busybox-kata \
        --for="jsonpath={.status.readyReplicas}=${target_replicas}" \
        --timeout=10m; then
    end_ns=$(date +%s%N)
    elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
    printf '%d/%d replicas became Ready in %d ms (%d.%03d s)\n' \
        "$target_replicas" "$target_replicas" "$elapsed_ms" \
        "$((elapsed_ms / 1000))" "$((elapsed_ms % 1000))"
else
    printf 'Scale-up did not reach %d Ready replicas within the timeout.\n' \
        "$target_replicas" >&2
fi
```

A successful run ends with `deployment.apps/busybox-kata-restore condition met` and prints the total elapsed readiness time. Record that elapsed time as the demo result.

## 4. Capture the final state

```sh
kubectl get deployment busybox-kata-restore
kubectl get pods -l app=busybox-kata-restore -o wide
```

The final Deployment state should show the selected target as both desired and Ready, with no pods in `Pending`, `Error`, or `CrashLoopBackOff`.

## Repeat the demo

Scale back to one replica and wait for the old replicas to terminate:

```sh
kubectl scale deployment/busybox-kata-restore --replicas=1
kubectl wait deployment/busybox-kata-restore \
    --for=jsonpath='{.status.readyReplicas}'=1 \
    --timeout=5m
kubectl get pods -l app=busybox-kata-restore
```

Then repeat steps 2 through 4. For comparisons between runs, keep the cluster capacity, node set, image cache, and snapshot placement unchanged.

## Cleanup

```sh
kubectl delete -f busy-restore-deployment.yaml
```
