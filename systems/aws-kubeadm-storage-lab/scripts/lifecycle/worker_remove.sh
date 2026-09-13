#!/bin/bash
# HCI Worker 노드 1대 제거 (마지막 노드 drain → delete → tofu)
# 사용법: bash scripts/lifecycle/worker_remove.sh
set -e
CURRENT_STEP="init"
CURRENT_TARGET="local"
trap 'status=$?; command_name=${BASH_COMMAND%% *}; printf "[step=%s][target=%s][failed] reason=command exited %d: %s\\n" "$CURRENT_STEP" "$CURRENT_TARGET" "$status" "$command_name" >&2' ERR
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SSH_KEY="${SSH_KEY_PATH:-$HOME/.ssh/storage-lab.pem}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -i $SSH_KEY"
KUBECONFIG_PATH="~/.kube/config-k8s-storage-lab"

CURRENT_STEP="0/5"; CURRENT_TARGET="local"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] 사전 요구사항 확인"
for cmd in tofu jq ssh; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET][failed] reason=$cmd 가 없습니다." >&2; exit 1
  fi
done

cd "$LAB_ROOT/opentofu"
CURRENT=$(tofu output -json worker_private_ips | jq 'length')

if [ "$CURRENT" -le 1 ]; then
  echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET][failed] reason=Worker가 1대 이하입니다. 최소 1대 유지 필요." >&2; exit 1
fi

NEW_COUNT=$((CURRENT - 1))
TARGET_IP=$(tofu output -json worker_private_ips | jq -r ".[$NEW_COUNT]")
TARGET_NAME="worker-$CURRENT"
BASTION_IP=$(tofu output -raw bastion_public_ip)

echo "  제거 대상: $TARGET_NAME ($TARGET_IP)"
echo "  제거 후 Worker 수: $NEW_COUNT"
read -p "  계속하시겠습니까? [y/N] " confirm
[ "$confirm" != "y" ] && echo "취소됨" && exit 0

CURRENT_STEP="1/5"; CURRENT_TARGET="k8s-storage-cluster"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] BeeGFS storaged 컨테이너 확인"
ssh $SSH_OPTS ubuntu@$BASTION_IP \
  "export KUBECONFIG=$KUBECONFIG_PATH && \
   kubectl -n beegfs-system get pods -o wide | grep $TARGET_IP || true"

CURRENT_STEP="2/5"; CURRENT_TARGET="workers"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] K8s 노드 drain"
ssh $SSH_OPTS ubuntu@$BASTION_IP \
  "export KUBECONFIG=$KUBECONFIG_PATH && \
   kubectl drain $TARGET_NAME \
     --ignore-daemonsets \
     --delete-emptydir-data \
     --force \
     --timeout=120s"

CURRENT_STEP="3/5"; CURRENT_TARGET="k8s-storage-cluster"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] Ceph OSD 안전 제거"
ssh $SSH_OPTS ubuntu@$BASTION_IP "
export KUBECONFIG=$KUBECONFIG_PATH

# 해당 worker의 OSD ID 찾기
OSD_IDS=\$(kubectl -n rook-ceph get pods -o wide | grep $TARGET_IP | grep osd | awk '{print \$1}' | grep -oP 'osd-\K[0-9]+' || echo '')

if [ -n \"\$OSD_IDS\" ]; then
  for OSD_ID in \$OSD_IDS; do
    echo \"  OSD \$OSD_ID 제거 중...\"
    # out → down → purge
    kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd out \$OSD_ID
    sleep 5
    kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd down \$OSD_ID
    kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd purge \$OSD_ID --yes-i-really-mean-it
    echo \"  OSD \$OSD_ID 제거 완료\"
  done
  echo \"  Ceph rebalancing 대기 (60s)...\"
  sleep 60
  kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph status
else
  echo \"  OSD 없음 - 건너뜀\"
fi
"

CURRENT_STEP="4/5"; CURRENT_TARGET="workers"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] K8s 노드 삭제"
ssh $SSH_OPTS ubuntu@$BASTION_IP \
  "export KUBECONFIG=$KUBECONFIG_PATH && \
   kubectl delete node $TARGET_NAME"

# known_hosts 정리
ssh-keygen -R "$TARGET_IP" 2>/dev/null || true

CURRENT_STEP="5/5"; CURRENT_TARGET="aws:${REGION:-${AWS_REGION:-default}}"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] 인프라 축소 (tofu apply)"
tofu apply -auto-approve -var="worker_count=$NEW_COUNT"

echo "Worker 제거 완료!"
echo "   제거된 노드: $TARGET_NAME ($TARGET_IP)"
echo "   현재 Worker 수: $NEW_COUNT"
echo "   kubectl get nodes"
