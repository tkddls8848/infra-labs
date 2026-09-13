#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d /vagrant/manifests/rook-ceph ]]; then
  MANIFEST_DIR="${ROOK_MANIFEST_DIR:-/vagrant/manifests/rook-ceph}"
else
  MANIFEST_DIR="${ROOK_MANIFEST_DIR:-$(cd -- "$SCRIPT_DIR/../../../.." && pwd)/manifests/rook-ceph}"
fi

kubectl apply -f "$MANIFEST_DIR/filesystem/filesystem.yaml"
kubectl -n rook-ceph wait --for=condition=Ready cephfilesystem/myfs --timeout=10m
kubectl apply -f "$MANIFEST_DIR/filesystem/storageclass.yaml"
kubectl get storageclass rook-ceph-filesystem >/dev/null

if [[ "${RUN_DEMO_PODS:-false}" == "true" ]]; then
  kubectl apply -f "$MANIFEST_DIR/filesystem/demo.yaml"
fi
