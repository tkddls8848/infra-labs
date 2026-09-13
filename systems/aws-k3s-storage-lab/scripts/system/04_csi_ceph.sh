#!/bin/bash
# Ceph CSI 설치 — Helm (ceph-csi-rbd, ceph-csi-cephfs)
# 실행 위치: EC2 #1 (frontend)
# 필수 환경변수: BACKEND_PRIVATE_IP, CEPH_FSID, CEPH_ADMIN_KEY
set -e
export PATH="/usr/local/bin:/usr/local/sbin:$PATH"
export KUBECONFIG="${KUBECONFIG:-/home/ec2-user/.kube/config}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFEST_DIR="${SCRIPT_DIR}/manifests"

: "${BACKEND_PRIVATE_IP:?필수: BACKEND_PRIVATE_IP}"
: "${CEPH_FSID:?필수: CEPH_FSID}"
: "${CEPH_ADMIN_KEY:?필수: CEPH_ADMIN_KEY}"

echo "=============================="
echo " [1/3] Helm 설치 확인"
echo "=============================="
# helm은 Packer AMI에 사전 설치됨 — 없을 경우 fallback 설치
if ! command -v helm &>/dev/null; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi
helm version --short

echo "=============================="
echo " [2/3] Ceph CSI 설치"
echo "=============================="
kubectl create namespace ceph-csi-rbd    --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace ceph-csi-cephfs --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: csi-rbd-secret
  namespace: ceph-csi-rbd
stringData:
  userID: admin
  userKey: ${CEPH_ADMIN_KEY}
EOF

kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: csi-cephfs-secret
  namespace: ceph-csi-cephfs
stringData:
  adminID: admin
  adminKey: ${CEPH_ADMIN_KEY}
EOF

cat > "${MANIFEST_DIR}/ceph-csi/storageclass-rbd.yaml" <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ceph-rbd
provisioner: rbd.csi.ceph.com
parameters:
  clusterID: ${CEPH_FSID}
  pool: kubernetes
  imageFeatures: layering
  csi.storage.k8s.io/provisioner-secret-name: csi-rbd-secret
  csi.storage.k8s.io/provisioner-secret-namespace: ceph-csi-rbd
  csi.storage.k8s.io/controller-expand-secret-name: csi-rbd-secret
  csi.storage.k8s.io/controller-expand-secret-namespace: ceph-csi-rbd
  csi.storage.k8s.io/node-stage-secret-name: csi-rbd-secret
  csi.storage.k8s.io/node-stage-secret-namespace: ceph-csi-rbd
reclaimPolicy: Delete
allowVolumeExpansion: true
volumeBindingMode: Immediate
EOF

cat > "${MANIFEST_DIR}/ceph-csi/storageclass-cephfs.yaml" <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ceph-cephfs
provisioner: cephfs.csi.ceph.com
parameters:
  clusterID: ${CEPH_FSID}
  fsName: cephfs
  csi.storage.k8s.io/provisioner-secret-name: csi-cephfs-secret
  csi.storage.k8s.io/provisioner-secret-namespace: ceph-csi-cephfs
  csi.storage.k8s.io/controller-expand-secret-name: csi-cephfs-secret
  csi.storage.k8s.io/controller-expand-secret-namespace: ceph-csi-cephfs
  csi.storage.k8s.io/node-stage-secret-name: csi-cephfs-secret
  csi.storage.k8s.io/node-stage-secret-namespace: ceph-csi-cephfs
reclaimPolicy: Delete
allowVolumeExpansion: true
volumeBindingMode: Immediate
EOF

helm repo add ceph-csi https://ceph.github.io/csi-charts 2>/dev/null || helm repo update

helm upgrade --install ceph-csi-rbd ceph-csi/ceph-csi-rbd \
  -n ceph-csi-rbd \
  --set provisioner.replicaCount=1 \
  --set-json "csiConfig=[{\"clusterID\":\"${CEPH_FSID}\",\"monitors\":[\"${BACKEND_PRIVATE_IP}:6789\"]}]"

helm upgrade --install ceph-csi-cephfs ceph-csi/ceph-csi-cephfs \
  -n ceph-csi-cephfs \
  --set provisioner.replicaCount=1 \
  --set-json "csiConfig=[{\"clusterID\":\"${CEPH_FSID}\",\"monitors\":[\"${BACKEND_PRIVATE_IP}:6789\"]}]"

kubectl delete storageclass ceph-rbd    --ignore-not-found
kubectl delete storageclass ceph-cephfs --ignore-not-found
kubectl apply -f "${MANIFEST_DIR}/ceph-csi/storageclass-rbd.yaml"
kubectl apply -f "${MANIFEST_DIR}/ceph-csi/storageclass-cephfs.yaml"

echo "  Ceph CSI 롤아웃 대기 (이미지 풀 포함 최대 5분)..."
kubectl rollout status deployment/ceph-csi-rbd-provisioner    -n ceph-csi-rbd    --timeout=300s
kubectl rollout status deployment/ceph-csi-cephfs-provisioner -n ceph-csi-cephfs --timeout=300s

echo "=============================="
echo " [3/3] 결과 확인"
echo "=============================="
kubectl get storageclass | grep -E "NAME|ceph"
echo ""
echo "✅ Ceph CSI 설치 완료 — StorageClass: ceph-rbd, ceph-cephfs"
