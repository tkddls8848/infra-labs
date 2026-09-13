#!/bin/bash
# k3s-storage-lab EC2 인스턴스 중지 (EBS 데이터 유지)
set -e
CURRENT_STEP="init"
CURRENT_TARGET="local"
trap 'status=$?; command_name=${BASH_COMMAND%% *}; printf "[step=%s][target=%s][failed] reason=command exited %d: %s\\n" "$CURRENT_STEP" "$CURRENT_TARGET" "$status" "$command_name" >&2' ERR
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROJECT_NAME="k3s-storage-lab"
REGION=$(grep aws_region "$LAB_ROOT/opentofu/terraform.tfvars" | awk -F'"' '{print $2}')

CURRENT_STEP="1/2"; CURRENT_TARGET="aws:${REGION}"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] EC2 인스턴스 중지"

INSTANCE_IDS=$(aws ec2 describe-instances \
  --region "$REGION" \
  --filters \
    "Name=tag:Name,Values=${PROJECT_NAME}-frontend,${PROJECT_NAME}-backend" \
    "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].InstanceId" \
  --output text)

if [ -z "$INSTANCE_IDS" ]; then
  echo "실행 중인 인스턴스가 없습니다."
  exit 0
fi

echo "  중지 대상: $INSTANCE_IDS"
aws ec2 stop-instances --region "$REGION" --instance-ids $INSTANCE_IDS > /dev/null

CURRENT_STEP="2/2"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] 인스턴스 stopped 대기"
aws ec2 wait instance-stopped --region "$REGION" --instance-ids $INSTANCE_IDS

echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] 인스턴스 중지 완료 (EBS 데이터 유지)"
echo "   재시작: bash scripts/lifecycle/restart.sh"
