#!/bin/bash
# k3s-storage-lab EC2 인스턴스 재시작
# - 서비스(k3s, ceph, beegfs)는 systemd에 등록되어 자동 기동
# - Public IP가 변경되므로 새 IP를 출력
set -e
CURRENT_STEP="init"
CURRENT_TARGET="local"
trap 'status=$?; command_name=${BASH_COMMAND%% *}; printf "[step=%s][target=%s][failed] reason=command exited %d: %s\\n" "$CURRENT_STEP" "$CURRENT_TARGET" "$status" "$command_name" >&2' ERR
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROJECT_NAME="k3s-storage-lab"
REGION=$(grep aws_region "$LAB_ROOT/opentofu/terraform.tfvars" | awk -F'"' '{print $2}')
SSH_KEY="${SSH_KEY_PATH:-$HOME/.ssh/storage-lab.pem}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -i $SSH_KEY"

CURRENT_STEP="1/3"; CURRENT_TARGET="aws:${REGION}"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] EC2 인스턴스 시작"

INSTANCE_IDS=$(aws ec2 describe-instances \
  --region "$REGION" \
  --filters \
    "Name=tag:Name,Values=${PROJECT_NAME}-frontend,${PROJECT_NAME}-backend" \
    "Name=instance-state-name,Values=stopped" \
  --query "Reservations[].Instances[].InstanceId" \
  --output text)

if [ -z "$INSTANCE_IDS" ]; then
  echo "중지된 인스턴스가 없습니다. (이미 실행 중이거나 존재하지 않음)"
  exit 0
fi

echo "  시작 대상: $INSTANCE_IDS"
aws ec2 start-instances --region "$REGION" --instance-ids $INSTANCE_IDS > /dev/null

CURRENT_STEP="2/3"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] 인스턴스 running 대기"
aws ec2 wait instance-running --region "$REGION" --instance-ids $INSTANCE_IDS

# 새 Public IP 조회
FRONTEND_IP=$(aws ec2 describe-instances \
  --region "$REGION" \
  --filters \
    "Name=tag:Name,Values=${PROJECT_NAME}-frontend" \
    "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].PublicIpAddress" \
  --output text)

BACKEND_IP=$(aws ec2 describe-instances \
  --region "$REGION" \
  --filters \
    "Name=tag:Name,Values=${PROJECT_NAME}-backend" \
    "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].PublicIpAddress" \
  --output text)

echo "  Frontend: $FRONTEND_IP"
echo "  Backend : $BACKEND_IP"

CURRENT_STEP="3/3"; CURRENT_TARGET="frontend/backend"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] SSH 연결 대기"
for IP in $FRONTEND_IP $BACKEND_IP; do
  echo -n "  $IP 대기 중..."
  until ssh $SSH_OPTS ec2-user@$IP "echo ok" &>/dev/null; do
    echo -n "."; sleep 5
  done
  echo " ready"
done

echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] 인스턴스 재시작 완료"
echo "  Frontend : ssh -i $SSH_KEY ec2-user@$FRONTEND_IP"
echo "  Backend  : ssh -i $SSH_KEY ec2-user@$BACKEND_IP"
echo "  서비스 상태 확인:"
echo "    ssh -i $SSH_KEY ec2-user@$FRONTEND_IP 'kubectl get nodes'"
