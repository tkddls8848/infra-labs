#!/bin/bash
set -e
CURRENT_STEP="init"
CURRENT_TARGET="local"
trap 'status=$?; command_name=${BASH_COMMAND%% *}; printf "[step=%s][target=%s][failed] reason=command exited %d: %s\\n" "$CURRENT_STEP" "$CURRENT_TARGET" "$status" "$command_name" >&2' ERR

AWS_REGION="${AWS_REGION:-ap-northeast-2}"
TAG_FILTER="Name=tag:Name,Values=k8s-storage-lab-*"

CURRENT_STEP="1/2"; CURRENT_TARGET="aws:${AWS_REGION}:ceph-osd"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] EBS 스냅샷 생성"
aws ec2 describe-volumes \
  --region $AWS_REGION \
  --filters "Name=tag:Name,Values=*ceph-osd*" \
  --query 'Volumes[].VolumeId' \
  --output text | tr '\t' '\n' | while read vol_id; do
    [ -z "$vol_id" ] && continue
    echo "  스냅샷: $vol_id"
    aws ec2 create-snapshot \
      --region $AWS_REGION \
      --volume-id $vol_id \
      --description "k8s-storage-lab-backup-$(date +%Y%m%d)" \
      --query 'SnapshotId' --output text
done

CURRENT_STEP="2/2"; CURRENT_TARGET="aws:${AWS_REGION}:k8s-storage-lab"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] EC2 중지"
INSTANCE_IDS=$(aws ec2 describe-instances \
  --region $AWS_REGION \
  --filters "$TAG_FILTER" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId' \
  --output text | tr '\t' ' ')

if [ -z "$INSTANCE_IDS" ]; then
  echo "  실행 중인 인스턴스가 없습니다."
  exit 0
fi

echo "  중지 대상: $INSTANCE_IDS"
aws ec2 stop-instances --region $AWS_REGION --instance-ids $INSTANCE_IDS > /dev/null

echo -n "  중지 대기 중..."
aws ec2 wait instance-stopped --region $AWS_REGION --instance-ids $INSTANCE_IDS
echo " ready"

echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] 스냅샷 생성 및 EC2 중지 완료 (재시작: bash scripts/lifecycle/resume.sh)"
