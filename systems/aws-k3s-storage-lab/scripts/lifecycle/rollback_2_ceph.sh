#!/bin/bash
# Rollback Stage 2: Ceph CSI 제거 → Ceph 클러스터 제거
# 실행 순서: rollback_3_beegfs.sh → rollback_2_ceph.sh → rollback_1_infra.sh
set -e
CURRENT_STEP="init"
CURRENT_TARGET="local"
trap 'status=$?; command_name=${BASH_COMMAND%% *}; printf "[step=%s][target=%s][failed] reason=command exited %d: %s\\n" "$CURRENT_STEP" "$CURRENT_TARGET" "$status" "$command_name" >&2' ERR
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LAB_ENV="$LAB_ROOT/lab.env"

if [ ! -f "$LAB_ENV" ]; then
  echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET][failed] reason=$LAB_ENV 없음 — 롤백할 상태가 없습니다." >&2
  exit 1
fi
set -a; source "$LAB_ENV"; set +a

if [ -z "$CEPH_FSID" ]; then
  echo "[warning] lab.env 에 CEPH_FSID 없음 — Ceph 가 설치되지 않았거나 이미 제거됨."
  exit 0
fi

SSH_KEY="${SSH_KEY_PATH:-${SSH_KEY:-$HOME/.ssh/storage-lab.pem}}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -i $SSH_KEY"

CURRENT_STEP="1/2"; CURRENT_TARGET="frontend:${FRONTEND_IP:-pending}"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] Ceph CSI 제거 (Frontend)"
ssh $SSH_OPTS ec2-user@$FRONTEND_IP 'sudo bash -s' <<'EOF'
export PATH="/usr/local/bin:/usr/local/sbin:$PATH"
export KUBECONFIG="/etc/rancher/k3s/k3s.yaml"

if command -v helm &>/dev/null; then
  helm uninstall ceph-csi-rbd    -n ceph-csi-rbd    2>/dev/null || true
  helm uninstall ceph-csi-cephfs -n ceph-csi-cephfs 2>/dev/null || true
fi
kubectl delete namespace ceph-csi-rbd ceph-csi-cephfs --ignore-not-found
kubectl delete storageclass ceph-rbd ceph-cephfs --ignore-not-found
echo "Ceph CSI 제거 완료"
EOF

CURRENT_STEP="2/2"; CURRENT_TARGET="backend:${BACKEND_IP:-pending}"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] Ceph 클러스터 제거 (Backend)"
echo "       fsid: $CEPH_FSID"
ssh $SSH_OPTS ec2-user@$BACKEND_IP \
  "sudo cephadm rm-cluster --force --zap-osds --fsid '$CEPH_FSID'"

grep -v "^CEPH_FSID=\|^CEPH_ADMIN_KEY=" "$LAB_ENV" > "${LAB_ENV}.tmp" \
  && mv "${LAB_ENV}.tmp" "$LAB_ENV"
echo "  CEPH_FSID / CEPH_ADMIN_KEY → lab.env 에서 제거 완료"

echo "Stage 2 롤백 완료"
echo "  다음 단계 (필요 시): bash scripts/lifecycle/rollback_1_infra.sh"
