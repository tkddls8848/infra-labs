#!/bin/bash
# HCI Worker 노드 1대 추가 (K8s + Ceph OSD + BeeGFS storaged)
# 사용법: bash scripts/lifecycle/worker_add.sh
set -e
CURRENT_STEP="init"
CURRENT_TARGET="local"
trap 'status=$?; command_name=${BASH_COMMAND%% *}; printf "[step=%s][target=%s][failed] reason=command exited %d: %s\\n" "$CURRENT_STEP" "$CURRENT_TARGET" "$status" "$command_name" >&2' ERR
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SSH_KEY="${SSH_KEY_PATH:-$HOME/.ssh/storage-lab.pem}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -i $SSH_KEY"

CURRENT_STEP="0/4"; CURRENT_TARGET="local"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] 사전 요구사항 확인"
for cmd in tofu jq ssh; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET][failed] reason=$cmd 가 없습니다." >&2; exit 1
  fi
done
if [ ! -f "$SSH_KEY" ]; then
  echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET][failed] reason=SSH 키가 없습니다: $SSH_KEY" >&2; exit 1
fi

cd "$LAB_ROOT/opentofu"

# 현재 worker_count 읽기
CURRENT=$(tofu output -json worker_private_ips | jq 'length')
NEW_COUNT=$((CURRENT + 1))
echo "  현재 Worker 수: $CURRENT → 추가 후: $NEW_COUNT"

CURRENT_STEP="1/4"; CURRENT_TARGET="aws:${REGION:-${AWS_REGION:-default}}"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] 인프라 확장 (tofu apply)"
tofu apply -auto-approve -var="worker_count=$NEW_COUNT"

BASTION_IP=$(tofu output -raw bastion_public_ip)
BASTION_PRIVATE_IP=$(tofu output -raw bastion_private_ip)

# 새 worker의 private IP (마지막 항목)
NEW_WORKER_IP=$(tofu output -json worker_private_ips | jq -r ".[$CURRENT]")
echo "  새 Worker IP: $NEW_WORKER_IP"

CURRENT_STEP="2/4"; CURRENT_TARGET="workers"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] 새 Worker 부팅 대기"
echo -n "  $NEW_WORKER_IP 대기 중..."
until ssh $SSH_OPTS -o "ProxyCommand=ssh $SSH_OPTS -W %h:%p ubuntu@$BASTION_IP" \
  ubuntu@$NEW_WORKER_IP "echo ok" &>/dev/null; do
  echo -n "."; sleep 5
done
echo " ready"

CURRENT_STEP="3/4"; CURRENT_TARGET="workers"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] Ansible: 새 Worker 설정 + K8s/BeeGFS join"
# ansible + manifests 재전송 (최신 상태 반영)
scp -O $SSH_OPTS -r "$LAB_ROOT/ansible"   ubuntu@$BASTION_IP:~/
scp -O $SSH_OPTS -r "$LAB_ROOT/manifests" ubuntu@$BASTION_IP:~/

ssh $SSH_OPTS ubuntu@$BASTION_IP \
  "cd ~/ansible && /home/ubuntu/.local/bin/ansible-playbook \
     -i inventory/aws_ec2.yml playbooks/k8s.yml \
     --extra-vars \"control_plane_endpoint=$BASTION_PRIVATE_IP\" \
     --limit \"$NEW_WORKER_IP\" \
     --tags common,hci_node,cluster_setup,k8s_common,worker"

CURRENT_STEP="4/4"; CURRENT_TARGET="k8s-storage-cluster"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] BeeGFS storaged join"
ssh $SSH_OPTS ubuntu@$BASTION_IP \
  "cd ~/ansible && /home/ubuntu/.local/bin/ansible-playbook \
     -i inventory/aws_ec2.yml playbooks/beegfs.yml \
     --limit \"$NEW_WORKER_IP\""

echo "Worker 추가 완료!"
echo "   새 노드: $NEW_WORKER_IP (worker-$NEW_COUNT)"
echo "   Ceph OSD는 rook-ceph operator가 자동으로 새 디스크를 감지합니다."
echo "   kubectl get nodes"
echo "   kubectl -n rook-ceph get pods -o wide"
