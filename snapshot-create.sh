#!/usr/bin/env bash

set -Eeuo pipefail

namespace="${NAMESPACE:-default}"
source_selector="${SOURCE_SELECTOR:-snapshot-sync.katacontainers.io/source=true}"
replace=false
dry_run=false

usage() {
    cat <<'EOF'
Usage: ./snapshot-create.sh [options] POD_NAME [NODE_NAME]

Create /run/vc/vm/snapshots/POD_NAME from the Pod's Ready Kata sandbox.
When NODE_NAME is omitted, use the single node labeled
snapshot-sync.katacontainers.io/source=true.

Options:
  -n, --namespace NAME  Namespace containing the Pod (default: default).
  --replace             Remove an existing snapshot at the destination first.
  --dry-run             Resolve and print the sandbox without creating a snapshot.
  -h, --help            Show this help.

Environment overrides:
  NAMESPACE, SOURCE_SELECTOR
EOF
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

positionals=()
while (($# > 0)); do
    case "$1" in
        -n|--namespace)
            (($# >= 2)) || die "$1 requires a namespace"
            namespace="$2"
            shift 2
            ;;
        --replace)
            replace=true
            shift
            ;;
        --dry-run)
            dry_run=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            positionals+=("$@")
            break
            ;;
        -*)
            die "unknown option: $1"
            ;;
        *)
            positionals+=("$1")
            shift
            ;;
    esac
done

((${#positionals[@]} >= 1)) || die "POD_NAME is required"
((${#positionals[@]} <= 2)) || die "expected POD_NAME and optional NODE_NAME"

pod_name="${positionals[0]}"
node_name="${positionals[1]:-}"
snapshot_path="/run/vc/vm/snapshots/$pod_name"

command -v kubectl >/dev/null 2>&1 || die "required command not found: kubectl"
command -v kubectl-node_shell >/dev/null 2>&1 ||
    die "required kubectl node-shell plugin not found (kubectl-node_shell)"

if [[ -z "$node_name" ]]; then
    mapfile -t source_nodes < <(
        kubectl get nodes -l "$source_selector" \
            -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
    )

    if ((${#source_nodes[@]} != 1)); then
        die "expected exactly one source node matching '$source_selector'; found ${#source_nodes[@]}"
    fi
    node_name="${source_nodes[0]}"
fi

pod_jsonpath='{.metadata.uid}{"\t"}{.spec.nodeName}{"\t"}{.status.phase}{"\t"}{.spec.runtimeClassName}{"\n"}'
IFS=$'\t' read -r pod_uid pod_node pod_phase runtime_class < <(
    kubectl get pod -n "$namespace" "$pod_name" -o "jsonpath=$pod_jsonpath"
)

[[ -n "$pod_uid" ]] || die "could not resolve UID for Pod $namespace/$pod_name"
[[ "$pod_phase" == "Running" ]] ||
    die "Pod $namespace/$pod_name is $pod_phase; expected Running"
[[ "$pod_node" == "$node_name" ]] ||
    die "Pod $namespace/$pod_name runs on '$pod_node', not selected node '$node_name'"

node_ready="$(
    kubectl get node "$node_name" \
        -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}'
)"
[[ "$node_ready" == "True" ]] || die "node '$node_name' is not Ready"

printf 'Pod:           %s/%s\n' "$namespace" "$pod_name"
printf 'Node:          %s\n' "$node_name"
printf 'RuntimeClass:  %s\n' "${runtime_class:-<none>}"
printf 'Snapshot path: %s\n' "$snapshot_path"

# shellcheck disable=SC2016  # Expanded in the source node's namespaces.
kubectl node-shell "$node_name" -- \
    env POD_UID="$pod_uid" POD_NAME="$pod_name" \
        SNAPSHOT_PATH="$snapshot_path" REPLACE="$replace" DRY_RUN="$dry_run" \
    sh -ec '
        command -v crictl >/dev/null
        command -v kata-runtime >/dev/null

        sandbox_ids="$(
            crictl pods --state Ready \
                --label "io.kubernetes.pod.uid=${POD_UID}" \
                --no-trunc --quiet
        )"

        set -- $sandbox_ids
        if [ "$#" -ne 1 ]; then
            printf "Expected one Ready sandbox for Pod %s; found %d.\n" \
                "$POD_NAME" "$#" >&2
            exit 1
        fi
        sandbox_id="$1"

        printf "Sandbox ID:    %s\n" "$sandbox_id"

        if [ "$DRY_RUN" = true ]; then
            printf "Dry run: kata-runtime snapshot create --sandbox-id %s --path %s\n" \
                "$sandbox_id" "$SNAPSHOT_PATH"
            exit 0
        fi

        mkdir -p /run/vc/vm/snapshots
        if [ -e "$SNAPSHOT_PATH" ]; then
            if [ "$REPLACE" != true ]; then
                printf "Snapshot path already exists: %s\n" "$SNAPSHOT_PATH" >&2
                printf "Rerun with --replace to recreate it.\n" >&2
                exit 1
            fi
            rm -rf -- "$SNAPSHOT_PATH"
        fi

        kata-runtime snapshot create \
            --sandbox-id "$sandbox_id" \
            --path "$SNAPSHOT_PATH"

        test -d "$SNAPSHOT_PATH"
        printf "Snapshot created at %s.\n" "$SNAPSHOT_PATH"
        du -sh "$SNAPSHOT_PATH"
    '