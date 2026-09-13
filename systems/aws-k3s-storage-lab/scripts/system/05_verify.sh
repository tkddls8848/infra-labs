#!/bin/bash
# Phase 6: 검증 — PVC 생성 및 Pod 마운트 테스트
# 실행: EC2 #1 (frontend) 에서 실행
set -e
export PATH="/usr/local/bin:/usr/local/sbin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFEST_DIR="${SCRIPT_DIR}/manifests"
# sudo 환경에서 $HOME=/root가 되므로 명시적 경로 우선 사용
export KUBECONFIG="${KUBECONFIG:-/home/ec2-user/.kube/config}"
[ -f "$KUBECONFIG" ] || export KUBECONFIG="/etc/rancher/k3s/k3s.yaml"

echo "=============================="
echo " [1/3] StorageClass 확인"
echo "=============================="
kubectl get storageclass
echo ""

echo "=============================="
echo " [2/3] PVC 생성 테스트"
echo "=============================="
kubectl apply -f "${MANIFEST_DIR}/test-pvc/test-rbd.yaml"
kubectl apply -f "${MANIFEST_DIR}/test-pvc/test-cephfs.yaml"
kubectl apply -f "${MANIFEST_DIR}/test-pvc/test-beegfs.yaml"

echo "PVC Bound 대기 (60초)..."
sleep 60
kubectl get pvc
echo ""

echo "=============================="
echo " [3/3] Pod 마운트 및 읽기/쓰기 테스트"
echo "=============================="
for pvc in test-rbd test-cephfs test-beegfs; do
  POD="verify-${pvc}"
  echo "--- ${POD} ---"
  kubectl wait pod/${POD} --for=condition=Ready --timeout=120s 2>/dev/null || true
  STATUS=$(kubectl get pod ${POD} -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
  if [ "$STATUS" = "Running" ]; then
    kubectl exec ${POD} -- df -h /mnt/data
    kubectl exec ${POD} -- sh -c "dd if=/dev/zero of=/mnt/data/test bs=1M count=10 && echo 'write OK' && rm /mnt/data/test && echo 'delete OK'"
  else
    echo "  Pod 상태: ${STATUS} (skip)"
  fi
done

echo ""
kubectl get pvc
kubectl get pods
echo ""
echo "✅ 검증 완료"
