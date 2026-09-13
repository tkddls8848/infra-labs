#!/bin/bash
# Stage 2: Ceph 사이클 완결
#   [1/2] Ceph 백엔드 (bootstrap → OSD → CephFS → RBD pool)
#   [2/2] Ceph CSI 설치 (ceph-rbd, ceph-cephfs StorageClass)
# 전제: start_1_infra_k3s.sh 완료 후 lab.env 존재
# 롤백: rollback_2_ceph.sh
set -e
CURRENT_STEP="init"
CURRENT_TARGET="local"
trap 'status=$?; command_name=${BASH_COMMAND%% *}; printf "[step=%s][target=%s][failed] reason=command exited %d: %s\\n" "$CURRENT_STEP" "$CURRENT_TARGET" "$status" "$command_name" >&2' ERR
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LAB_ENV="$LAB_ROOT/lab.env"

if [ ! -f "$LAB_ENV" ]; then
  echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET][failed] reason=$LAB_ENV 없음 — start_1_infra_k3s.sh 를 먼저 실행하세요." >&2
  exit 1
fi
set -a; source "$LAB_ENV"; set +a

SSH_KEY="${SSH_KEY_PATH:-${SSH_KEY:-$HOME/.ssh/storage-lab.pem}}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -i $SSH_KEY"

CURRENT_STEP="1/2"; CURRENT_TARGET="storage-cluster"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] Ceph 백엔드"
echo "       bootstrap → OSD → CephFS → RBD pool"
# bash -s < script 방식은 cephadm shell(podman)이 stdin을 소비해
# 스크립트 후반부가 실행되지 않는 문제가 있음 → scp 후 파일로 실행
scp -O $SSH_OPTS "$LAB_ROOT/scripts/system/02_ceph_backend.sh" \
  ec2-user@$BACKEND_IP:/tmp/02_ceph_backend.sh
ssh $SSH_OPTS ec2-user@$BACKEND_IP \
  "sudo CEPH_OSD_1_VOL='$CEPH_OSD_1_VOL' CEPH_OSD_2_VOL='$CEPH_OSD_2_VOL' bash /tmp/02_ceph_backend.sh"

# FSID / admin key 수집 → lab.env 저장
CEPH_FSID=$(ssh $SSH_OPTS ec2-user@$BACKEND_IP \
  "sudo cephadm shell -- ceph fsid 2>/dev/null" | tr -d '\r\n')
CEPH_ADMIN_KEY=$(ssh $SSH_OPTS ec2-user@$BACKEND_IP \
  "sudo cephadm shell -- ceph auth get-key client.admin 2>/dev/null" | tr -d '\r\n')

if [ -z "$CEPH_FSID" ] || [ -z "$CEPH_ADMIN_KEY" ]; then
  echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET][failed] reason=CEPH_FSID 또는 CEPH_ADMIN_KEY 수집 실패." >&2
  exit 1
fi

grep -v "^CEPH_FSID=\|^CEPH_ADMIN_KEY=" "$LAB_ENV" > "${LAB_ENV}.tmp" \
  && mv "${LAB_ENV}.tmp" "$LAB_ENV"
cat >> "$LAB_ENV" <<EOF
CEPH_FSID=${CEPH_FSID}
CEPH_ADMIN_KEY='${CEPH_ADMIN_KEY}'
EOF
echo "  CEPH_FSID / CEPH_ADMIN_KEY → $LAB_ENV 저장 완료 ✅"

CURRENT_STEP="2/2"; CURRENT_TARGET="storage-cluster"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] Ceph CSI 설치"
echo "       ceph-rbd, ceph-cephfs StorageClass → frontend"
scp -O $SSH_OPTS "$LAB_ROOT/scripts/system/04_csi_ceph.sh" ec2-user@$FRONTEND_IP:~/

ssh $SSH_OPTS ec2-user@$FRONTEND_IP \
  "sudo BACKEND_PRIVATE_IP='$BACKEND_PRIVATE_IP' \
   CEPH_FSID='$CEPH_FSID' \
   CEPH_ADMIN_KEY='$CEPH_ADMIN_KEY' \
   SCRIPT_DIR=/home/ec2-user \
   bash /home/ec2-user/04_csi_ceph.sh"

echo "Stage 2 완료 — Ceph 클러스터 + CSI 구성됨"
echo "  StorageClass: ceph-rbd, ceph-cephfs"
echo "  다음 단계: bash scripts/lifecycle/start_3_beegfs.sh"
