#!/bin/bash
set -e
CURRENT_STEP="init"
CURRENT_TARGET="local"
trap 'status=$?; command_name=${BASH_COMMAND%% *}; printf "[step=%s][target=%s][failed] reason=command exited %d: %s\\n" "$CURRENT_STEP" "$CURRENT_TARGET" "$status" "$command_name" >&2' ERR
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SSH_KEY="${SSH_KEY_PATH:-$HOME/.ssh/storage-lab.pem}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -i $SSH_KEY"
AWS_REGION="${AWS_REGION:-ap-northeast-2}"
TAG_FILTER="Name=tag:Name,Values=k8s-storage-lab-*"

CURRENT_STEP="1/4"; CURRENT_TARGET="aws:${AWS_REGION}:k8s-storage-lab"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] EC2 시작"
INSTANCE_IDS=$(aws ec2 describe-instances \
  --region $AWS_REGION \
  --filters "$TAG_FILTER" "Name=instance-state-name,Values=stopped" \
  --query 'Reservations[].Instances[].InstanceId' \
  --output text | tr '\t' ' ')

if [ -z "$INSTANCE_IDS" ]; then
  echo "  중지된 인스턴스가 없습니다."
  aws ec2 describe-instances \
    --region $AWS_REGION \
    --filters "$TAG_FILTER" \
    --query 'Reservations[].Instances[].[Tags[?Key==`Name`].Value|[0],State.Name,PublicIpAddress,PrivateIpAddress]' \
    --output table
  exit 0
fi

echo "  시작 대상: $INSTANCE_IDS"
aws ec2 start-instances --region $AWS_REGION --instance-ids $INSTANCE_IDS > /dev/null

echo -n "  실행 대기 중..."
aws ec2 wait instance-running --region $AWS_REGION --instance-ids $INSTANCE_IDS
echo " ready"

sleep 10  # IP 할당 안정화 대기

CURRENT_STEP="2/4"; CURRENT_TARGET="bastion"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] IP 갱신"
BASTION_IP=$(tofu -chdir="$LAB_ROOT/opentofu" output -raw bastion_public_ip)
BASTION_PRIVATE_IP=$(tofu -chdir="$LAB_ROOT/opentofu" output -raw bastion_private_ip)
echo "  Bastion Public  : $BASTION_IP"
echo "  Bastion Private : $BASTION_PRIVATE_IP"

CURRENT_STEP="3/4"; CURRENT_TARGET="bastion:${BASTION_IP}"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] SSH 대기"
echo -n "  연결 대기 중..."
until ssh $SSH_OPTS ubuntu@$BASTION_IP "echo ok" &>/dev/null; do
  echo -n "."; sleep 5
done
echo " ready"

CURRENT_STEP="4/4"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] Playbook 재전송 (최신 상태 반영)"
ssh $SSH_OPTS ubuntu@$BASTION_IP "rm -rf ~/ansible ~/manifests"
scp -O $SSH_OPTS -r "$LAB_ROOT/ansible"   ubuntu@$BASTION_IP:~/
scp -O $SSH_OPTS -r "$LAB_ROOT/manifests" ubuntu@$BASTION_IP:~/

echo " 현재 노드 상태"
aws ec2 describe-instances \
  --region $AWS_REGION \
  --filters "$TAG_FILTER" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].[Tags[?Key==`Name`].Value|[0],PrivateIpAddress,State.Name]' \
  --output table

echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] 재시작 완료"
echo "   Bastion : ssh -i $SSH_KEY ubuntu@$BASTION_IP"
echo "   K8s 플레이북 재실행 필요 시 (bastion에서):"
echo "   cd ~/ansible && /home/ubuntu/.local/bin/ansible-playbook \\"
echo "     -i inventory/aws_ec2.yml playbooks/k8s.yml \\"
echo "     --extra-vars \"control_plane_endpoint=$BASTION_PRIVATE_IP\""
