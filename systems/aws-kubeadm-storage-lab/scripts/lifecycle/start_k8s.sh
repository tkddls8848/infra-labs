#!/bin/bash
# USE_PACKER_AMI=true: Packer 사전 빌드 AMI 사용 (패키지 설치 단계 스킵 --skip-tags ami_base)
set -e
CURRENT_STEP="init"
CURRENT_TARGET="local"
trap 'status=$?; command_name=${BASH_COMMAND%% *}; printf "[step=%s][target=%s][failed] reason=command exited %d: %s\\n" "$CURRENT_STEP" "$CURRENT_TARGET" "$status" "$command_name" >&2' ERR
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SSH_KEY="${SSH_KEY_PATH:-$HOME/.ssh/storage-lab.pem}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -i $SSH_KEY"
USE_PACKER_AMI=${USE_PACKER_AMI:-false}

CURRENT_STEP="0/5"; CURRENT_TARGET="local"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] 사전 요구사항 확인"
MISSING=()
for cmd in tofu aws ssh scp; do
  if ! command -v "$cmd" &>/dev/null; then
    MISSING+=("$cmd")
  fi
done
if [ ! -f "$SSH_KEY" ]; then
  MISSING+=("ssh-key:$SSH_KEY")
fi

if [ ${#MISSING[@]} -gt 0 ]; then
  echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET][failed] reason=누락된 항목: ${MISSING[*]}" >&2
  for item in "${MISSING[@]}"; do
    case "$item" in
      tofu)      echo "  tofu    : https://opentofu.org/docs/intro/install/" ;;
      aws)       echo "  awscli  : pip3 install awscli --break-system-packages" ;;
      ssh|scp)   echo "  ssh/scp : sudo apt-get install -y openssh-client" ;;
      ssh-key:*) echo "  ssh key : ${item#ssh-key:} 파일이 없습니다" ;;
    esac
  done
  exit 1
fi
echo "모든 필수 항목 확인 완료"

CURRENT_STEP="1/5"; CURRENT_TARGET="aws:${REGION:-${AWS_REGION:-default}}"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] AWS 인프라 생성"
cd "$LAB_ROOT/opentofu"
tofu init
tofu apply -auto-approve

BASTION_IP=$(tofu output -raw bastion_public_ip)
BASTION_PRIVATE_IP=$(tofu output -raw bastion_private_ip)
echo "  Bastion Public IP  : $BASTION_IP"
echo "  Bastion Private IP : $BASTION_PRIVATE_IP (HAProxy endpoint)"

CURRENT_STEP="2/5"; CURRENT_TARGET="bastion:${BASTION_IP:-pending}"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] Bastion SSH 대기"
echo -n "  연결 대기 중..."
until ssh $SSH_OPTS ubuntu@$BASTION_IP "echo ok" &>/dev/null; do
  echo -n "."; sleep 5
done
echo " ready"

CURRENT_STEP="3/5"; CURRENT_TARGET="local"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] SSH 키 + Playbook 전송"
ssh $SSH_OPTS ubuntu@$BASTION_IP "mkdir -p ~/.ssh && chmod 700 ~/.ssh && rm -f ~/.ssh/storage-lab.pem"
scp $SSH_OPTS "$SSH_KEY" ubuntu@$BASTION_IP:~/.ssh/storage-lab.pem
ssh $SSH_OPTS ubuntu@$BASTION_IP "chmod 400 ~/.ssh/storage-lab.pem && rm -rf ~/ansible ~/manifests"
scp -O $SSH_OPTS -r "$LAB_ROOT/ansible"    ubuntu@$BASTION_IP:~/
scp -O $SSH_OPTS -r "$LAB_ROOT/manifests"  ubuntu@$BASTION_IP:~/

CURRENT_STEP="4/5"; CURRENT_TARGET="workers"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] 나머지 노드 부팅 대기"
NODE_IPS=$(
  tofu output -json master_private_ips | jq -r '.[]'
  tofu output -json worker_private_ips | jq -r '.[]'
)
for IP in $NODE_IPS; do
  echo -n "  $IP 대기 중..."
  until ssh $SSH_OPTS -o "ProxyCommand=ssh $SSH_OPTS -W %h:%p ubuntu@$BASTION_IP" ubuntu@$IP "echo ok" &>/dev/null; do
    echo -n "."; sleep 5
  done
  echo " ready"
done

CURRENT_STEP="5/5"; CURRENT_TARGET="bastion:${BASTION_IP:-pending}"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] Ansible Playbook 실행 (Bastion)"
LOCK_FILE="/tmp/k8s-setup.lock"
if [ "$USE_PACKER_AMI" = "true" ]; then
  ANSIBLE_EXTRA_ARGS="--skip-tags ami_base"
  echo "  [Packer AMI] --skip-tags ami_base 적용 (패키지 설치 단계 스킵)"
else
  ANSIBLE_EXTRA_ARGS=""
fi
ssh $SSH_OPTS ubuntu@$BASTION_IP \
  "while [ ! -f /tmp/ansible-ready ]; do echo 'Waiting for ansible install...'; sleep 10; done && \
   if [ -f $LOCK_FILE ]; then \
     echo '❌ 이미 다른 프로세스가 실행 중입니다 (lock: $LOCK_FILE)'; \
     exit 1; \
   fi && \
   touch $LOCK_FILE && \
   trap 'rm -f $LOCK_FILE' EXIT && \
   cd ~/ansible && /home/ubuntu/.local/bin/ansible-playbook \
     -i inventory/aws_ec2.yml playbooks/k8s.yml \
     --extra-vars \"control_plane_endpoint=$BASTION_PRIVATE_IP\" \
     $ANSIBLE_EXTRA_ARGS && \
   touch /tmp/ansible-k8s-complete && \
   rm -f $LOCK_FILE"

echo "완료"
echo "   Bastion     : ssh -i $SSH_KEY ubuntu@$BASTION_IP"
echo "   HAProxy     : http://$BASTION_IP:9000/stats  (admin/admin)"
echo "   kubeconfig  : ~/.kube/config-k8s-storage-lab (배스천)"
echo "   다음 단계:"
echo "   1. bash scripts/lifecycle/start_ceph.sh    # Ceph(rook) 설치"
echo "   2. bash scripts/lifecycle/start_beegfs.sh  # BeeGFS 설치"
