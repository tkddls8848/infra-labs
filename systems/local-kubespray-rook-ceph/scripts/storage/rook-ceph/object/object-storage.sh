#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d /vagrant/manifests/rook-ceph ]]; then
  MANIFEST_DIR="${ROOK_MANIFEST_DIR:-/vagrant/manifests/rook-ceph}"
else
  MANIFEST_DIR="${ROOK_MANIFEST_DIR:-$(cd -- "$SCRIPT_DIR/../../../.." && pwd)/manifests/rook-ceph}"
fi
WORKDIR="${WORKDIR:-$HOME/k8s-install-manifests}"

kubectl apply -f "$MANIFEST_DIR/object/object.yaml"
kubectl apply -f "$MANIFEST_DIR/object/object-user.yaml"
kubectl -n rook-ceph wait --for=condition=Ready cephobjectstore/my-store --timeout=10m

if [[ "${RUN_SMOKE_TEST:-false}" != "true" ]]; then
  exit 0
fi

ACCESS_KEY="$(kubectl -n rook-ceph get secret rook-ceph-object-user-my-store-my-user -o jsonpath='{.data.AccessKey}' | base64 --decode)"
SECRET_KEY="$(kubectl -n rook-ceph get secret rook-ceph-object-user-my-store-my-user -o jsonpath='{.data.SecretKey}' | base64 --decode)"

sudo apt-get update
sudo apt-get install -y awscli

endpoint_ip="$(kubectl -n rook-ceph get svc rook-ceph-rgw-my-store -o jsonpath='{.spec.clusterIP}')"
endpoint_port="$(kubectl -n rook-ceph get svc rook-ceph-rgw-my-store -o jsonpath='{.spec.ports[0].port}')"
install -m 0755 -d "$WORKDIR"
echo "rook object storage smoke test" > "$WORKDIR/myfile.txt"
export AWS_ACCESS_KEY_ID="$ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET_KEY"
export AWS_DEFAULT_REGION=us-east-1
aws --endpoint-url="http://$endpoint_ip:$endpoint_port/" s3 mb s3://my-test-bucket || true
aws --endpoint-url="http://$endpoint_ip:$endpoint_port/" s3 cp "$WORKDIR/myfile.txt" s3://my-test-bucket
aws --endpoint-url="http://$endpoint_ip:$endpoint_port/" s3 ls s3://my-test-bucket
