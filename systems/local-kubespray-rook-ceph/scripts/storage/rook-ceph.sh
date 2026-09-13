#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d /vagrant/manifests/rook-ceph ]]; then
  SYSTEM_ROOT="${SYSTEM_ROOT:-/vagrant}"
else
  SYSTEM_ROOT="${SYSTEM_ROOT:-$(cd -- "$SCRIPT_DIR/../.." && pwd)}"
fi
MANIFEST_DIR="${ROOK_MANIFEST_DIR:-$SYSTEM_ROOT/manifests/rook-ceph}"
INVENTORY_FILE="${INVENTORY_FILE:-$SYSTEM_ROOT/inventory/inventory.ini}"

inventory_var() {
  local key="$1"
  awk -F= -v key="$key" '
    /^\[all:vars\][[:space:]]*$/ { in_all_vars = 1; next }
    /^\[/ { in_all_vars = 0 }
    in_all_vars {
      name = $1
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
      if (name == key) {
        value = substr($0, index($0, "=") + 1)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        print value
        exit
      }
    }
  ' "$INVENTORY_FILE"
}

require_manifest() {
  local manifest="$1"
  if [[ ! -f "$MANIFEST_DIR/$manifest" ]]; then
    echo "[rook] missing vendored manifest: $MANIFEST_DIR/$manifest" >&2
    exit 1
  fi
}

ROOK_VERSION="$(inventory_var rook_version)"
if [[ -z "$ROOK_VERSION" ]]; then
  echo "[rook] missing rook_version in $INVENTORY_FILE [all:vars]" >&2
  exit 1
fi

if ! command -v kubectl >/dev/null 2>&1; then
  echo "[rook] kubectl is not available. Run kubespray.sh first." >&2
  exit 1
fi

for manifest in crds.yaml common.yaml csi-operator.yaml operator.yaml cluster.yaml toolbox.yaml storageclass.yaml dashboard-loadbalancer.yaml; do
  require_manifest "$manifest"
done
if ! grep -Fq "docker.io/rook/ceph:$ROOK_VERSION" "$MANIFEST_DIR/operator.yaml"; then
  echo "[rook] operator manifest does not match inventory rook_version=$ROOK_VERSION" >&2
  exit 1
fi

echo "[rook] installing $ROOK_VERSION from $MANIFEST_DIR"
kubectl apply -f "$MANIFEST_DIR/crds.yaml"
kubectl wait --for=condition=Established --timeout=180s crd/cephclusters.ceph.rook.io
kubectl apply \
  -f "$MANIFEST_DIR/common.yaml" \
  -f "$MANIFEST_DIR/csi-operator.yaml" \
  -f "$MANIFEST_DIR/operator.yaml"
kubectl -n rook-ceph rollout status deploy/rook-ceph-operator --timeout=5m

echo "[rook] creating Ceph cluster"
kubectl apply -f "$MANIFEST_DIR/cluster.yaml" -f "$MANIFEST_DIR/toolbox.yaml"
kubectl -n rook-ceph wait --for=condition=Ready cephcluster/rook-ceph --timeout=30m
kubectl -n rook-ceph rollout status deploy/rook-ceph-tools --timeout=5m

echo "[rook] waiting for Ceph health"
health=""
for _ in {1..60}; do
  health="$(kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph health 2>/dev/null || true)"
  if [[ "$health" == "HEALTH_OK" ]]; then
    break
  fi
  sleep 10
done
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph status
if [[ "$health" != "HEALTH_OK" ]]; then
  echo "[rook] Ceph did not reach HEALTH_OK: $health" >&2
  exit 1
fi

echo "[rook] installing RBD storage class"
kubectl apply -f "$MANIFEST_DIR/storageclass.yaml"
kubectl get storageclass rook-ceph-block >/dev/null

echo "[rook] exposing dashboard through MetalLB"
kubectl apply -f "$MANIFEST_DIR/dashboard-loadbalancer.yaml"
