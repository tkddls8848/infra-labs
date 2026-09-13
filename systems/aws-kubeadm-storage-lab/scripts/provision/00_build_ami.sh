#!/bin/bash
# 00_build_ami.sh — Packer 사전 조건 점검 + bastion/master/worker AMI 빌드
# 실행: bash scripts/provision/00_build_ami.sh [REGION] [KEY_NAME] [PEM_FILE]
set -euo pipefail
CURRENT_STEP="init"
CURRENT_TARGET="local"
trap 'status=$?; command_name=${BASH_COMMAND%% *}; printf "[step=%s][target=%s][failed] reason=command exited %d: %s\\n" "$CURRENT_STEP" "$CURRENT_TARGET" "$status" "$command_name" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PACKER_DIR="$LAB_DIR/packer"

REGION="${1:-ap-northeast-2}"
KEY_NAME="${2:-storage-lab}"
KEY_FILE="${3:-${SSH_KEY_PATH:-$HOME/.ssh/storage-lab.pem}}"
EXPANDED_KEY="${KEY_FILE/#\~/$HOME}"

# Packer 임시 보안 그룹 정리 (빌드 성공/실패 모두 실행)
cleanup_packer_sgs() {
  CURRENT_STEP="cleanup"; CURRENT_TARGET="packer-local"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] Packer 임시 보안 그룹 정리"
  local sgs
  sgs=$(aws ec2 describe-security-groups --region "$REGION" \
    --filters "Name=group-name,Values=packer_*" \
    --query 'SecurityGroups[*].GroupId' --output text 2>/dev/null)
  if [ -z "$sgs" ] || [ "$sgs" = "None" ]; then
    echo "  잔여 보안 그룹 없음"
    return
  fi
  for sg in $sgs; do
    if aws ec2 delete-security-group --region "$REGION" --group-id "$sg" 2>/dev/null; then
      echo "  삭제: $sg"
    else
      echo "  건너뜀 (사용 중): $sg"
    fi
  done
}
trap cleanup_packer_sgs EXIT

PASS="[PASS]"
FAIL="[FAIL]"
WARN="[WARN]"
ERRORS=0

# ══════════════════════════════════════════════════════════════════
#  [1/4] 사전 조건 점검
# ══════════════════════════════════════════════════════════════════
CURRENT_STEP="1/4"; CURRENT_TARGET="packer-local"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] Packer 사전 조건 점검"
echo " Region : $REGION"
echo " Key    : $KEY_NAME"
echo " PEM    : $EXPANDED_KEY"

# ── 로컬 CLI 도구 ─────────────────────────────────────────────────
CURRENT_STEP="0"; CURRENT_TARGET="local"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] 로컬 CLI 도구"
for cmd in packer aws; do
  if command -v "$cmd" &>/dev/null; then
    echo "  $PASS $cmd ($(command -v "$cmd"))"
  else
    echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET][failed] reason=$cmd 없음 — 설치 후 재실행하세요" >&2
    (( ERRORS++ ))
  fi
done

# ── 1. Default VPC ────────────────────────────────────────────────
CURRENT_STEP="1"; CURRENT_TARGET="aws:${REGION:-${AWS_REGION:-default}}"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] Default VPC"
VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" \
  --filters "Name=isDefault,Values=true" \
  --query 'Vpcs[0].VpcId' --output text 2>/dev/null)

if [ "$VPC_ID" = "None" ] || [ -z "$VPC_ID" ]; then
  echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET][failed] reason=Default VPC 없음" >&2
  echo "       복구: aws ec2 create-default-vpc --region $REGION"
  VPC_ID=""
  (( ERRORS++ ))
else
  echo "  $PASS $VPC_ID"
fi

# ── 2. Subnets ────────────────────────────────────────────────────
CURRENT_STEP="2"; CURRENT_TARGET="aws:${REGION:-${AWS_REGION:-default}}"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] Subnets (Default VPC)"
if [ -z "$VPC_ID" ]; then
  echo "  $WARN VPC 없으므로 서브넷 검사 생략"
else
  SUBNETS=$(aws ec2 describe-subnets --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'Subnets[*].{ID:SubnetId,AZ:AvailabilityZone}' \
    --output text 2>/dev/null)
  if [ -z "$SUBNETS" ]; then
    echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET][failed] reason=서브넷 없음" >&2
    echo "       복구 예시:"
    echo "         aws ec2 create-default-subnet --availability-zone ${REGION}a --region $REGION"
    echo "         aws ec2 create-default-subnet --availability-zone ${REGION}b --region $REGION"
    echo "         aws ec2 create-default-subnet --availability-zone ${REGION}c --region $REGION"
    (( ERRORS++ ))
  else
    while IFS= read -r line; do
      echo "  $PASS $line"
    done <<< "$SUBNETS"
  fi
fi

# ── 3. Internet Gateway ───────────────────────────────────────────
CURRENT_STEP="3"; CURRENT_TARGET="aws:${REGION}"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] Internet Gateway"
if [ -z "$VPC_ID" ]; then
  echo "  $WARN VPC 없으므로 IGW 검사 생략"
else
  IGW=$(aws ec2 describe-internet-gateways --region "$REGION" \
    --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
    --query 'InternetGateways[0].InternetGatewayId' --output text 2>/dev/null)
  if [ "$IGW" = "None" ] || [ -z "$IGW" ]; then
    echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET][failed] reason=IGW 없음" >&2
    echo "       복구:"
    echo "         IGW_ID=\$(aws ec2 create-internet-gateway --region $REGION --query 'InternetGateway.InternetGatewayId' --output text)"
    echo "         aws ec2 attach-internet-gateway --region $REGION --internet-gateway-id \$IGW_ID --vpc-id $VPC_ID"
    (( ERRORS++ ))
  else
    echo "  $PASS $IGW"
  fi
fi

# ── 4. Route Table ────────────────────────────────────────────────
CURRENT_STEP="4"; CURRENT_TARGET="aws:${REGION}"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] Route Table (0.0.0.0/0 → IGW)"
if [ -z "$VPC_ID" ]; then
  echo "  $WARN VPC 없으므로 라우팅 검사 생략"
else
  RT_ID=$(aws ec2 describe-route-tables --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=association.main,Values=true" \
    --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null)
  DEFAULT_ROUTE=$(aws ec2 describe-route-tables --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query "RouteTables[*].Routes[?DestinationCidrBlock=='0.0.0.0/0'].GatewayId" \
    --output text 2>/dev/null)

  if ! echo "$DEFAULT_ROUTE" | grep -q "igw-"; then
    echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET][failed] reason=기본 경로(0.0.0.0/0) 없음" >&2
    echo "       복구: aws ec2 create-route --region $REGION --route-table-id $RT_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW"
    (( ERRORS++ ))
  elif [ "$DEFAULT_ROUTE" != "$IGW" ]; then
    echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET][failed] reason=라우팅 IGW($DEFAULT_ROUTE) ≠ 부착된 IGW($IGW)" >&2
    echo "       복구:"
    echo "         aws ec2 delete-route --region $REGION --route-table-id $RT_ID --destination-cidr-block 0.0.0.0/0"
    echo "         aws ec2 create-route --region $REGION --route-table-id $RT_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW"
    (( ERRORS++ ))
  else
    echo "  $PASS 0.0.0.0/0 → $DEFAULT_ROUTE"
  fi
fi

# ── 5. SSH Key Pair (AWS) ─────────────────────────────────────────
CURRENT_STEP="5"; CURRENT_TARGET="aws:${REGION:-${AWS_REGION:-default}}"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] SSH Key Pair (AWS EC2)"
KEY_EXISTS=$(aws ec2 describe-key-pairs --region "$REGION" \
  --key-names "$KEY_NAME" \
  --query 'KeyPairs[0].KeyName' --output text 2>/dev/null)
if [ "$KEY_EXISTS" = "$KEY_NAME" ]; then
  echo "  $PASS $KEY_NAME"
else
  echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET][failed] reason=Key Pair '$KEY_NAME' 가 AWS에 없음" >&2
  echo "       EC2 콘솔 또는 CLI로 키 페어를 생성/등록하세요"
  (( ERRORS++ ))
fi

# ── 6. PEM 파일 (로컬) ────────────────────────────────────────────
CURRENT_STEP="6"; CURRENT_TARGET="local"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] PEM 파일 (로컬)"
if [ -f "$EXPANDED_KEY" ]; then
  PERMS=$(stat -c "%a" "$EXPANDED_KEY" 2>/dev/null)
  if [ "$PERMS" = "400" ] || [ "$PERMS" = "600" ]; then
    echo "  $PASS $EXPANDED_KEY (권한: $PERMS)"
  else
    echo "  $WARN $EXPANDED_KEY 존재하지만 권한이 $PERMS (400 권장)"
    echo "       복구: chmod 400 $EXPANDED_KEY"
  fi
else
  echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET][failed] reason=$EXPANDED_KEY 없음" >&2
  echo "       AWS에서 키 페어 다운로드 후 ~/.ssh/ 에 배치하세요"
  (( ERRORS++ ))
fi

if [ "$ERRORS" -gt 0 ]; then
  echo " ❌ 사전 조건 점검 실패 ($ERRORS 건) — AMI 빌드를 중단합니다"
  exit 1
fi
echo " 사전 조건 점검 완료 — AMI 빌드를 시작합니다"

cd "$PACKER_DIR"
packer init .

# ══════════════════════════════════════════════════════════════════
#  [2/4] Bastion AMI 빌드
#         ansible-core + boto3 + collections 사전 설치
# ══════════════════════════════════════════════════════════════════
CURRENT_STEP="2/4"; CURRENT_TARGET="packer:bastion"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] Bastion AMI 빌드"
echo "       (ansible-core + boto3 + collections)"
packer build \
  -only=amazon-ebs.bastion \
  -var "aws_region=$REGION" \
  -var "key_name=$KEY_NAME" \
  -var "ssh_private_key_file=$EXPANDED_KEY" \
  -var-file=variables.pkrvars.hcl \
  . 2>&1 | tee /tmp/packer-bastion.log

BASTION_AMI=$(grep -oE 'ami-[a-f0-9]+' /tmp/packer-bastion.log | tail -1)
echo "  Bastion AMI: $BASTION_AMI"

# ══════════════════════════════════════════════════════════════════
#  [3/4] Master AMI 빌드
#         containerd + kubeadm/kubelet/kubectl 사전 설치
# ══════════════════════════════════════════════════════════════════
CURRENT_STEP="3/4"; CURRENT_TARGET="packer:master"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] Master AMI 빌드"
echo "       (containerd + kubeadm/kubelet/kubectl 1.31)"
packer build \
  -only=amazon-ebs.master \
  -var "aws_region=$REGION" \
  -var "key_name=$KEY_NAME" \
  -var "ssh_private_key_file=$EXPANDED_KEY" \
  -var-file=variables.pkrvars.hcl \
  . 2>&1 | tee /tmp/packer-master.log

MASTER_AMI=$(grep -oE 'ami-[a-f0-9]+' /tmp/packer-master.log | tail -1)
echo "  Master AMI: $MASTER_AMI"

# ══════════════════════════════════════════════════════════════════
#  [4/4] Worker AMI 빌드
#         containerd + kubeadm/kubelet/kubectl + 커널 6.8 + BeeGFS 7.4.6 모듈
# ══════════════════════════════════════════════════════════════════
CURRENT_STEP="4/4"; CURRENT_TARGET="packer:worker"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] Worker AMI 빌드"
echo "       (containerd + kubeadm + kernel 6.8 + BeeGFS 7.4.6 module)"
packer build \
  -only=amazon-ebs.worker \
  -var "aws_region=$REGION" \
  -var "key_name=$KEY_NAME" \
  -var "ssh_private_key_file=$EXPANDED_KEY" \
  -var-file=variables.pkrvars.hcl \
  . 2>&1 | tee /tmp/packer-worker.log

WORKER_AMI=$(grep -oE 'ami-[a-f0-9]+' /tmp/packer-worker.log | tail -1)
echo "  Worker AMI: $WORKER_AMI"

# ══════════════════════════════════════════════════════════════════
#  결과 요약
# ══════════════════════════════════════════════════════════════════
echo " AMI 빌드 완료"
echo "  Bastion AMI : $BASTION_AMI"
echo "  Master AMI  : $MASTER_AMI"
echo "  Worker AMI  : $WORKER_AMI"
echo "  opentofu/terraform.tfvars 에 AMI ID 를 반영하세요:"
echo "    ami_bastion = \"$BASTION_AMI\""
echo "    ami_master  = \"$MASTER_AMI\""
echo "    ami_worker  = \"$WORKER_AMI\""
echo "  이후 start_k8s.sh 실행 시 Packer AMI를 사용하려면:"
echo "    USE_PACKER_AMI=true bash scripts/lifecycle/start_k8s.sh"
