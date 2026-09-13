#!/usr/bin/env bash
set -euo pipefail

SYSTEM_ROOT="${SYSTEM_ROOT:-/vagrant}"
SOURCE_INVENTORY="${SOURCE_INVENTORY:-$SYSTEM_ROOT/inventory.ini}"
VENV_PATH="${VENV_PATH:-$HOME/.venv/kubespray}"

if [[ ! -f "$SOURCE_INVENTORY" ]]; then
  echo "Inventory not found: $SOURCE_INVENTORY" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$SYSTEM_ROOT/common/inventory.sh"

ROOK_VERSION="$(require_inventory_var "$SOURCE_INVENTORY" rook_version)"
ROOK_COMMIT="$(require_inventory_var "$SOURCE_INVENTORY" rook_git_commit)"
ROOK_CHECKOUT="${ROOK_CHECKOUT:-$HOME/.cache/rook-$ROOK_VERSION}"
MANIFEST_ROOT="$SYSTEM_ROOT/manifests/rook-$ROOK_VERSION"
UPSTREAM_MANIFESTS="$MANIFEST_ROOT/upstream"
RENDERED_MANIFESTS="$MANIFEST_ROOT/rendered"
PYTHON_BIN="$VENV_PATH/bin/python"
ANSIBLE_BIN="$VENV_PATH/bin/ansible"
ANSIBLE_INVENTORY_BIN="$VENV_PATH/bin/ansible-inventory"

for executable in kubectl "$PYTHON_BIN" "$ANSIBLE_BIN" "$ANSIBLE_INVENTORY_BIN"; do
  if ! command -v "$executable" >/dev/null 2>&1 && [[ ! -x "$executable" ]]; then
    echo "Required executable not found: $executable" >&2
    exit 1
  fi
done

ensure_pinned_checkout \
  "https://github.com/rook/rook.git" \
  "refs/tags/$ROOK_VERSION" \
  "$ROOK_COMMIT" \
  "$ROOK_CHECKOUT"

mkdir -p "$UPSTREAM_MANIFESTS" "$RENDERED_MANIFESTS"

# Vendor exact upstream files into the system's repo-local manifests directory.
install -m 0644 "$ROOK_CHECKOUT/deploy/examples/crds.yaml" "$UPSTREAM_MANIFESTS/crds.yaml"
install -m 0644 "$ROOK_CHECKOUT/deploy/examples/common.yaml" "$UPSTREAM_MANIFESTS/common.yaml"
install -m 0644 "$ROOK_CHECKOUT/deploy/examples/operator.yaml" "$UPSTREAM_MANIFESTS/operator.yaml"
install -m 0644 "$ROOK_CHECKOUT/deploy/examples/cluster.yaml" "$UPSTREAM_MANIFESTS/cluster.yaml"
install -m 0644 "$ROOK_CHECKOUT/deploy/examples/toolbox.yaml" "$UPSTREAM_MANIFESTS/toolbox.yaml"
install -m 0644 "$ROOK_CHECKOUT/deploy/examples/filesystem.yaml" "$UPSTREAM_MANIFESTS/filesystem.yaml"
install -m 0644 "$ROOK_CHECKOUT/deploy/examples/pool.yaml" "$UPSTREAM_MANIFESTS/pool.yaml"
install -m 0644 "$ROOK_CHECKOUT/deploy/examples/dashboard-loadbalancer.yaml" \
  "$UPSTREAM_MANIFESTS/dashboard-loadbalancer.yaml"
install -m 0644 "$ROOK_CHECKOUT/deploy/examples/csi/cephfs/storageclass.yaml" \
  "$UPSTREAM_MANIFESTS/cephfs-storageclass.yaml"
install -m 0644 "$ROOK_CHECKOUT/deploy/examples/csi/rbd/storageclass.yaml" \
  "$UPSTREAM_MANIFESTS/rbd-storageclass.yaml"
printf '%s\n' "$ROOK_COMMIT" >"$UPSTREAM_MANIFESTS/.source-commit"

inventory_json="$(mktemp)"
storage_nodes_file="$(mktemp)"
trap 'rm -f "$inventory_json" "$storage_nodes_file"' EXIT
"$ANSIBLE_INVENTORY_BIN" -i "$SOURCE_INVENTORY" --list >"$inventory_json"

# Check only inventory-declared OSD devices, through the Ansible inventory.
"$ANSIBLE_BIN" storage -i "$SOURCE_INVENTORY" --become \
  -m ansible.builtin.command -a 'cmd=/usr/bin/test -b {{ rook_device }}'

"$PYTHON_BIN" "$SYSTEM_ROOT/manifests/render_rook_cluster.py" \
  --inventory-json "$inventory_json" \
  --source "$UPSTREAM_MANIFESTS/cluster.yaml" \
  --output "$RENDERED_MANIFESTS/cluster.yaml" \
  --nodes-output "$storage_nodes_file"

while IFS= read -r storage_node; do
  [[ -n "$storage_node" ]] || continue
  kubectl label node "$storage_node" role=storage-node --overwrite
done <"$storage_nodes_file"

kubectl apply -f "$UPSTREAM_MANIFESTS/crds.yaml"
kubectl apply -f "$UPSTREAM_MANIFESTS/common.yaml"
kubectl apply -f "$UPSTREAM_MANIFESTS/operator.yaml"
kubectl rollout status deployment/rook-ceph-operator -n rook-ceph --timeout=5m

kubectl apply -f "$RENDERED_MANIFESTS/cluster.yaml"
kubectl wait --for=condition=Ready cephcluster/rook-ceph -n rook-ceph --timeout=20m

kubectl apply -f "$UPSTREAM_MANIFESTS/pool.yaml"
kubectl apply -f "$UPSTREAM_MANIFESTS/filesystem.yaml"
kubectl apply -f "$UPSTREAM_MANIFESTS/rbd-storageclass.yaml"
kubectl apply -f "$UPSTREAM_MANIFESTS/cephfs-storageclass.yaml"
kubectl apply -f "$UPSTREAM_MANIFESTS/toolbox.yaml"
kubectl apply -f "$UPSTREAM_MANIFESTS/dashboard-loadbalancer.yaml"
