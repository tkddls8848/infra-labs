#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d /vagrant/manifests/rook-ceph ]]; then
  MANIFEST_DIR="${ROOK_MANIFEST_DIR:-/vagrant/manifests/rook-ceph}"
else
  MANIFEST_DIR="${ROOK_MANIFEST_DIR:-$(cd -- "$SCRIPT_DIR/../../../.." && pwd)/manifests/rook-ceph}"
fi

kubectl apply -f "$MANIFEST_DIR/storageclass.yaml"
kubectl get storageclass rook-ceph-block >/dev/null

## test ceph block storage by wordpress app
if [[ "${RUN_DEMO_APP:-false}" == "true" ]]; then
  kubectl apply -f "$MANIFEST_DIR/block/mysql.yaml"
  kubectl apply -f "$MANIFEST_DIR/block/wordpress.yaml"
fi
