#!/bin/bash
# Stage 3: BeeGFS 사이클 완결
#   [1/2] BeeGFS 백엔드 (디스크 준비 → LVM 스트라이프 → XFS → 서비스 기동)
#   [2/2] BeeGFS CSI 설치 (커널 모듈 빌드 → beegfs-scratch StorageClass)
# 전제: start_2_ceph.sh 완료 후 lab.env 에 CEPH_FSID / CEPH_ADMIN_KEY 존재
# 롤백: rollback_3_beegfs.sh
set -e
CURRENT_STEP="init"
CURRENT_TARGET="local"
trap 'status=$?; command_name=${BASH_COMMAND%% *}; printf "[step=%s][target=%s][failed] reason=command exited %d: %s\\n" "$CURRENT_STEP" "$CURRENT_TARGET" "$status" "$command_name" >&2' ERR
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LAB_ENV="$LAB_ROOT/lab.env"

if [ ! -f "$LAB_ENV" ]; then
  echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET][failed] reason=$LAB_ENV 없음 — start_1_infra_k3s.sh, start_2_ceph.sh 를 먼저 실행하세요." >&2
  exit 1
fi
set -a; source "$LAB_ENV"; set +a

: "${CEPH_FSID:?lab.env 에 CEPH_FSID 없음 — start_2_ceph.sh 를 먼저 실행하세요}"

SSH_KEY="${SSH_KEY_PATH:-${SSH_KEY:-$HOME/.ssh/storage-lab.pem}}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -i $SSH_KEY"

CURRENT_STEP="1/2"; CURRENT_TARGET="storage-cluster"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] BeeGFS 백엔드"
echo "       디스크 준비 → LVM 스트라이프 → XFS → 서비스 기동"
ssh $SSH_OPTS ec2-user@$BACKEND_IP \
  "sudo BEEGFS_STORAGE_1_VOL='$BEEGFS_STORAGE_1_VOL' BEEGFS_STORAGE_2_VOL='$BEEGFS_STORAGE_2_VOL' bash -s" \
  < "$LAB_ROOT/scripts/system/03_beegfs_backend.sh"

CURRENT_STEP="2/2"; CURRENT_TARGET="storage-cluster"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] BeeGFS CSI 설치"
echo "       커널 모듈 빌드 → beegfs-scratch StorageClass → frontend"
scp -O $SSH_OPTS "$LAB_ROOT/scripts/system/04_csi_beegfs.sh" ec2-user@$FRONTEND_IP:~/
scp -O $SSH_OPTS "$LAB_ROOT/scripts/system/05_verify.sh"     ec2-user@$FRONTEND_IP:~/

ssh $SSH_OPTS ec2-user@$FRONTEND_IP \
  "sudo BACKEND_PRIVATE_IP='$BACKEND_PRIVATE_IP' \
   SCRIPT_DIR=/home/ec2-user \
   bash /home/ec2-user/04_csi_beegfs.sh"

echo "Stage 3 완료 — BeeGFS + CSI 구성됨"
echo "  StorageClass: beegfs-scratch"
echo "  전체 StorageClass 확인:"
ssh $SSH_OPTS ec2-user@$FRONTEND_IP \
  "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml && kubectl get storageclass"
echo "  Frontend : ssh -i $SSH_KEY ec2-user@$FRONTEND_IP"
echo "  Backend  : ssh -i $SSH_KEY ec2-user@$BACKEND_IP"
echo "  검증     : ssh -i $SSH_KEY ec2-user@$FRONTEND_IP 'bash ~/05_verify.sh'"
