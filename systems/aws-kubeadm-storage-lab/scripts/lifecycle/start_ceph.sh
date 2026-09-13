#!/bin/bash
set -e
CURRENT_STEP="init"
CURRENT_TARGET="local"
trap 'status=$?; command_name=${BASH_COMMAND%% *}; printf "[step=%s][target=%s][failed] reason=command exited %d: %s\\n" "$CURRENT_STEP" "$CURRENT_TARGET" "$status" "$command_name" >&2' ERR
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SSH_KEY="${SSH_KEY_PATH:-$HOME/.ssh/storage-lab.pem}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -i $SSH_KEY"

CURRENT_STEP="0/4"; CURRENT_TARGET="local"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] 사전 요구사항 확인"
MISSING=()
for cmd in tofu jq ssh scp; do
  if ! command -v "$cmd" &>/dev/null; then
    MISSING+=("$cmd")
  fi
done
if [ ! -f "$SSH_KEY" ]; then
  MISSING+=("ssh-key:$SSH_KEY")
fi
if [ ${#MISSING[@]} -gt 0 ]; then
  echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET][failed] reason=누락된 항목: ${MISSING[*]}" >&2
  exit 1
fi
echo "모든 필수 항목 확인 완료"

CURRENT_STEP="1/4"; CURRENT_TARGET="aws:${REGION:-${AWS_REGION:-default}}"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] 인프라 정보 수집"
cd "$LAB_ROOT/opentofu"
BASTION_IP=$(tofu output -raw bastion_public_ip)
MASTER_IP=$(tofu output -json master_private_ips | jq -r '.[0]')
WORKER_IPS=($(tofu output -json worker_private_ips | jq -r '.[]'))
cd "$LAB_ROOT"

echo "  Bastion : $BASTION_IP"
echo "  Master  : $MASTER_IP"
echo "  Workers : ${WORKER_IPS[*]}"

CURRENT_STEP="2/4"; CURRENT_TARGET="bastion:${BASTION_IP:-pending}"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] Bastion 환경 준비"
ssh $SSH_OPTS ubuntu@$BASTION_IP "rm -rf ~/scripts && mkdir -p ~/scripts"
scp -O $SSH_OPTS -r "$SCRIPT_DIR/scripts" ubuntu@$BASTION_IP:~/

# .env 생성 (배스천에서 scripts/ceph_install.sh가 참조)
printf "SSH_KEY=\$HOME/.ssh/storage-lab.pem
M1_PUB=%s
M1_PRIV=%s
WORKER_PUBS=(%s)
WORKER_PRIVS=(%s)
" \
  "$MASTER_IP" "$MASTER_IP" \
  "${WORKER_IPS[*]}" "${WORKER_IPS[*]}" \
  | ssh $SSH_OPTS ubuntu@$BASTION_IP "cat > ~/scripts/.env"

# kubectl 설치 (배스천에 없는 경우)
ssh $SSH_OPTS ubuntu@$BASTION_IP "
  if ! command -v kubectl &>/dev/null; then
    echo '  kubectl 설치 중...'
    curl -sLO https://dl.k8s.io/release/v1.31.0/bin/linux/amd64/kubectl
    sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
    rm -f kubectl
    echo '  kubectl 설치 완료'
  else
    echo '  kubectl 이미 설치됨'
  fi
"

CURRENT_STEP="3/4"; CURRENT_TARGET="bastion:${BASTION_IP:-pending}"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] Ceph 클러스터 구성 (Bastion에서 실행)"
ssh $SSH_OPTS ubuntu@$BASTION_IP \
  "export KUBECONFIG=~/.kube/config-k8s-storage-lab && cd ~ && bash scripts/ceph_install.sh"

CURRENT_STEP="4/4"; CURRENT_TARGET="local"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] 안내"
echo "인프라, K8s, Ceph(rook) 구성 완료!"
echo "   StorageClass: ceph-rbd, ceph-cephfs"
echo "   kubeconfig  : ~/.kube/config-k8s-storage-lab (배스천)"
echo "[warning] BeeGFS 설치는 별도 실행 필요:"
echo "   1. bash scripts/lifecycle/start_beegfs.sh"
echo "   2. kubectl apply -f manifests/examples/test-pvc-beegfs.yaml"
echo "   rook-ceph만 재설치 필요 시:"
echo "   bash scripts/lifecycle/destroy_ceph.sh && bash scripts/lifecycle/start_ceph.sh"
