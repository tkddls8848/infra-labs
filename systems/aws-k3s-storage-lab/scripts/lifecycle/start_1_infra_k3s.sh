#!/bin/bash
# Stage 1: AWS 인프라 생성 + k3s 설치
# 완료 후 lab.env 에 상태 저장 — Stage 2/3이 이 파일을 source 함
# 롤백: rollback_1_infra.sh
set -e
CURRENT_STEP="init"
CURRENT_TARGET="local"
trap 'status=$?; command_name=${BASH_COMMAND%% *}; printf "[step=%s][target=%s][failed] reason=command exited %d: %s\\n" "$CURRENT_STEP" "$CURRENT_TARGET" "$status" "$command_name" >&2' ERR
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LAB_ENV="$LAB_ROOT/lab.env"
SSH_KEY="${SSH_KEY_PATH:-$HOME/.ssh/storage-lab.pem}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -i $SSH_KEY"

CURRENT_STEP="0/3"; CURRENT_TARGET="local"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] 사전 요구사항 확인"
MISSING=()
for cmd in tofu aws ssh scp; do
  command -v "$cmd" &>/dev/null || MISSING+=("$cmd")
done
[ -f "$SSH_KEY" ] || MISSING+=("ssh-key:$SSH_KEY")
if [ ${#MISSING[@]} -gt 0 ]; then
  echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET][failed] reason=누락된 항목: ${MISSING[*]}" >&2
  exit 1
fi
echo "모든 필수 항목 확인 완료"

CURRENT_STEP="1/3"; CURRENT_TARGET="aws:${REGION:-${AWS_REGION:-default}}"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] AWS 인프라 생성"
cd "$LAB_ROOT/opentofu"
tofu init
tofu apply -auto-approve

FRONTEND_IP=$(tofu output -raw frontend_public_ip)
BACKEND_IP=$(tofu output -raw backend_public_ip)
BACKEND_PRIVATE_IP=$(tofu output -raw backend_private_ip)
CEPH_OSD_1_VOL=$(tofu output -raw ceph_osd_1_volume_id)
CEPH_OSD_2_VOL=$(tofu output -raw ceph_osd_2_volume_id)
BEEGFS_STORAGE_1_VOL=$(tofu output -raw beegfs_storage_1_volume_id)
BEEGFS_STORAGE_2_VOL=$(tofu output -raw beegfs_storage_2_volume_id)

cat > "$LAB_ENV" <<EOF
SSH_KEY=${SSH_KEY}
FRONTEND_IP=${FRONTEND_IP}
BACKEND_IP=${BACKEND_IP}
BACKEND_PRIVATE_IP=${BACKEND_PRIVATE_IP}
CEPH_OSD_1_VOL=${CEPH_OSD_1_VOL}
CEPH_OSD_2_VOL=${CEPH_OSD_2_VOL}
BEEGFS_STORAGE_1_VOL=${BEEGFS_STORAGE_1_VOL}
BEEGFS_STORAGE_2_VOL=${BEEGFS_STORAGE_2_VOL}
EOF
echo "  상태 저장 완료: $LAB_ENV"
echo "  Frontend Public IP  : $FRONTEND_IP"
echo "  Backend Public IP   : $BACKEND_IP"
echo "  Ceph OSD volumes    : $CEPH_OSD_1_VOL, $CEPH_OSD_2_VOL"
echo "  BeeGFS volumes      : $BEEGFS_STORAGE_1_VOL, $BEEGFS_STORAGE_2_VOL"

CURRENT_STEP="2/3"; CURRENT_TARGET="local"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] SSH 연결 대기"
for IP in $FRONTEND_IP $BACKEND_IP; do
  echo -n "  $IP 대기 중..."
  until ssh $SSH_OPTS ec2-user@$IP "echo ok" &>/dev/null; do
    echo -n "."; sleep 5
  done
  echo " ready"
done

CURRENT_STEP="3/3"; CURRENT_TARGET="frontend:${FRONTEND_IP:-pending}"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] k3s Frontend 구성"
ssh $SSH_OPTS ec2-user@$FRONTEND_IP 'sudo bash -s' < "$LAB_ROOT/scripts/system/01_k3s_frontend.sh"
scp -O $SSH_OPTS -r "$LAB_ROOT/manifests" ec2-user@$FRONTEND_IP:~/

cat > "$LAB_ROOT/ADDRESS.md" <<EOF
# k3s-storage-lab 접속 정보

## Frontend (k3s server)
\`\`\`
ssh -i /home/psi/.ssh/storage-lab.pem -o StrictHostKeyChecking=no ec2-user@${FRONTEND_IP}
\`\`\`

## Backend (Ceph + BeeGFS)
\`\`\`
ssh -i /home/psi/.ssh/storage-lab.pem -o StrictHostKeyChecking=no ec2-user@${BACKEND_IP}
\`\`\`
EOF
echo "  접속 정보 저장 완료: $LAB_ROOT/ADDRESS.md"

echo "Stage 1 완료 — 인프라 + k3s 구성됨"
echo "  다음 단계: bash scripts/lifecycle/start_2_ceph.sh"
