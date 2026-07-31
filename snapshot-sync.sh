#!/usr/bin/env bash

set -Eeuo pipefail

namespace="${NAMESPACE:-default}"
source_node="${SOURCE_NODE:-}"
source_selector="${SOURCE_SELECTOR:-snapshot-sync.katacontainers.io/source=true}"
target_selector="${TARGET_SELECTOR:-katacontainers.io/kata-runtime=true}"
helper_image="${HELPER_IMAGE:-docker.io/library/ubuntu:24.04}"
pod_ready_timeout="${POD_READY_TIMEOUT:-2m}"
copy_retries="${COPY_RETRIES:-3}"
keep_local_copy="${KEEP_LOCAL_COPY:-false}"

usage() {
    cat <<'EOF'
Usage: ./snapshot-sync.sh [options]

Create a sparse-aware snapshots.tar.gz on one source node, copy that archive
through a local temporary directory, then replace the snapshot directory on
every other Ready Kata node.

Options:
  --source NODE       Use NODE as the source instead of discovering the node
                      labeled snapshot-sync.katacontainers.io/source=true.
  --namespace NAME    Namespace for temporary helper pods (default: default).
  --keep-local-copy   Keep the local temporary directory after the run.
  -h, --help          Show this help.

Environment overrides:
  SOURCE_NODE, SOURCE_SELECTOR, TARGET_SELECTOR, HELPER_IMAGE, NAMESPACE,
  POD_READY_TIMEOUT, COPY_RETRIES, KEEP_LOCAL_COPY, TMPDIR

Do not create snapshots or start restores while this script is running.
EOF
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

while (($# > 0)); do
    case "$1" in
        --source)
            (($# >= 2)) || die "--source requires a node name"
            source_node="$2"
            shift 2
            ;;
        --namespace)
            (($# >= 2)) || die "--namespace requires a value"
            namespace="$2"
            shift 2
            ;;
        --keep-local-copy)
            keep_local_copy=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
done

for command_name in kubectl sha256sum mktemp awk; do
    command -v "$command_name" >/dev/null 2>&1 ||
        die "required command not found: $command_name"
done

case "$copy_retries" in
    ''|*[!0-9]*) die "COPY_RETRIES must be a non-negative integer" ;;
esac

run_id="$(date -u +%Y%m%d%H%M%S)-$$"
run_label="${run_id//[^a-zA-Z0-9_.-]/-}"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/kata-snapshot-sync.XXXXXXXX")"
archive="$work_dir/snapshots.tar.gz"

cleanup() {
    local status=$?
    trap - EXIT HUP INT TERM

    kubectl delete pods -n "$namespace" \
        -l "snapshot-sync.katacontainers.io/run-id=$run_label" \
        --ignore-not-found --wait=false >/dev/null 2>&1 || true

    if [[ "$keep_local_copy" == "true" ]]; then
        printf 'Local copy retained at %s\n' "$work_dir"
    else
        rm -rf "$work_dir"
    fi

    exit "$status"
}
trap cleanup EXIT HUP INT TERM

mapfile -t candidate_nodes < <(
    kubectl get nodes -l "$target_selector" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
)

((${#candidate_nodes[@]} > 0)) ||
    die "no nodes match target selector: $target_selector"

target_nodes=()
for node in "${candidate_nodes[@]}"; do
    ready_status="$(
        kubectl get node "$node" \
            -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}'
    )"
    if [[ "$ready_status" == "True" ]]; then
        target_nodes+=("$node")
    else
        printf 'Skipping non-Ready node %s.\n' "$node" >&2
    fi
done

((${#target_nodes[@]} > 1)) ||
    die "snapshot sync requires at least two Ready target nodes"

if [[ -z "$source_node" ]]; then
    mapfile -t source_nodes < <(
        kubectl get nodes -l "$source_selector" \
            -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
    )

    if ((${#source_nodes[@]} != 1)); then
        die "expected exactly one source node matching '$source_selector'; found ${#source_nodes[@]}"
    fi
    source_node="${source_nodes[0]}"
fi

source_is_target=false
for node in "${target_nodes[@]}"; do
    if [[ "$node" == "$source_node" ]]; then
        source_is_target=true
        break
    fi
done

[[ "$source_is_target" == "true" ]] ||
    die "source node '$source_node' is not a Ready node matching '$target_selector'"

declare -A helper_pods=()

create_helper_pod() {
    local node="$1"
    local index="$2"
    local pod_name="kata-snapshot-sync-${run_label}-${index}"

    helper_pods["$node"]="$pod_name"

    kubectl create -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${pod_name}
  namespace: ${namespace}
  labels:
    app.kubernetes.io/name: kata-snapshot-sync-helper
    snapshot-sync.katacontainers.io/run-id: ${run_label}
spec:
  nodeName: ${node}
  restartPolicy: Never
  automountServiceAccountToken: false
  containers:
  - name: helper
    image: ${helper_image}
    imagePullPolicy: IfNotPresent
    command: ["sh", "-c", "trap : TERM INT; sleep 3600 & wait"]
    securityContext:
      runAsUser: 0
    volumeMounts:
    - name: host-vm
      mountPath: /host-vm
  volumes:
  - name: host-vm
    hostPath:
      path: /run/vc/vm
      type: Directory
EOF

    kubectl wait -n "$namespace" --for=condition=Ready \
        "pod/$pod_name" --timeout="$pod_ready_timeout" >/dev/null

    kubectl exec -n "$namespace" "$pod_name" -c helper -- sh -ec '
        tar --version | grep -q "GNU tar"
        tar --help | grep -q -- "--sparse"
        command -v gzip >/dev/null
        command -v sha256sum >/dev/null
    '
}

printf 'Source node: %s\n' "$source_node"
printf 'Ready target nodes (%d):\n' "${#target_nodes[@]}"
printf '  %s\n' "${target_nodes[@]}"
printf 'Local staging directory: %s\n' "$work_dir"

for index in "${!target_nodes[@]}"; do
    node="${target_nodes[$index]}"
    printf 'Starting helper pod on %s...\n' "$node"
    create_helper_pod "$node" "$index"
done

source_pod="${helper_pods[$source_node]}"
source_archive="/tmp/kata-snapshots-${run_label}.tar.gz"

printf 'Creating sparse compressed archive on %s...\n' "$source_node"
source_archive_sha256="$(
    # shellcheck disable=SC2016  # Expanded by the helper pod, not this shell.
    kubectl exec -n "$namespace" "$source_pod" -c helper -- \
        env SOURCE_ARCHIVE="$source_archive" sh -ec '
            test -d /host-vm/snapshots
            test -n "$(find /host-vm/snapshots -mindepth 1 -maxdepth 1 -print -quit)"
            rm -f "$SOURCE_ARCHIVE"
            tar --sparse -C /host-vm/snapshots -czf "$SOURCE_ARCHIVE" .
            sha256sum "$SOURCE_ARCHIVE" | awk "{print \$1}"
        '
)"

[[ "$source_archive_sha256" =~ ^[0-9a-f]{64}$ ]] ||
    die "source helper returned an invalid SHA-256: $source_archive_sha256"

printf 'Copying %s from %s to %s...\n' \
    "$(basename "$archive")" "$source_node" "$archive"
kubectl cp --retries="$copy_retries" -c helper \
    "$namespace/$source_pod:$source_archive" "$archive"

archive_sha256="$(sha256sum "$archive" | awk '{print $1}')"
[[ "$archive_sha256" == "$source_archive_sha256" ]] ||
    die "source-to-local checksum mismatch: expected $source_archive_sha256, got $archive_sha256"
printf 'Local archive checksum: %s\n' "$archive_sha256"

for target_node in "${target_nodes[@]}"; do
    if [[ "$target_node" == "$source_node" ]]; then
        continue
    fi

    target_pod="${helper_pods[$target_node]}"
    remote_archive="/tmp/kata-snapshots-${run_label}.tar.gz"

    printf 'Copying snapshots to %s...\n' "$target_node"
    kubectl cp --retries="$copy_retries" -c helper \
        "$archive" "$namespace/$target_pod:$remote_archive"

    # shellcheck disable=SC2016  # Expanded by the helper pod, not this shell.
    kubectl exec -n "$namespace" "$target_pod" -c helper -- \
        env EXPECTED_SHA256="$archive_sha256" \
            REMOTE_ARCHIVE="$remote_archive" RUN_ID="$run_label" \
        sh -ec '
            snapshots=/host-vm/snapshots
            incoming="/host-vm/snapshots.sync-new-${RUN_ID}"
            previous="/host-vm/snapshots.sync-old-${RUN_ID}"
            lock=/host-vm/snapshots.sync-lock

            actual_sha256="$(sha256sum "$REMOTE_ARCHIVE" | awk "{print \$1}")"
            if [ "$actual_sha256" != "$EXPECTED_SHA256" ]; then
                printf "Checksum mismatch: expected %s, got %s.\n" \
                    "$EXPECTED_SHA256" "$actual_sha256" >&2
                exit 1
            fi

            if ! mkdir "$lock" 2>/dev/null; then
                printf "Another snapshot sync appears to be active: %s\n" \
                    "$lock" >&2
                exit 1
            fi

            rollback() {
                status=$?
                trap - EXIT HUP INT TERM
                if [ ! -e "$snapshots" ] && [ -e "$previous" ]; then
                    mv "$previous" "$snapshots" || true
                fi
                rm -rf "$incoming" "$lock"
                exit "$status"
            }
            trap rollback EXIT HUP INT TERM

            test ! -e "$incoming"
            test ! -e "$previous"
            mkdir "$incoming"
            tar --sparse -C "$incoming" -xzf "$REMOTE_ARCHIVE"
            test -n "$(find "$incoming" -mindepth 1 -maxdepth 1 -print -quit)"

            if [ -e "$snapshots" ]; then
                mv "$snapshots" "$previous"
            fi
            mv "$incoming" "$snapshots"

            trap - EXIT HUP INT TERM
            rm -rf "$previous" "$lock" "$REMOTE_ARCHIVE"
        '

    printf 'Synchronized %s from %s.\n' "$target_node" "$source_node"
done

printf 'Snapshot sync completed successfully.\n'