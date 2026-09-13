#!/bin/bash
set -e
CURRENT_STEP="init"
CURRENT_TARGET="local"
trap 'status=$?; command_name=${BASH_COMMAND%% *}; printf "[step=%s][target=%s][failed] reason=command exited %d: %s\\n" "$CURRENT_STEP" "$CURRENT_TARGET" "$status" "$command_name" >&2' ERR
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SSH_KEY="${SSH_KEY_PATH:-$HOME/.ssh/storage-lab.pem}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -i $SSH_KEY"

CURRENT_STEP="1/3"; CURRENT_TARGET="aws:${REGION:-${AWS_REGION:-default}}"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] 인프라 정보 수집"
cd "$LAB_ROOT/opentofu"
BASTION_IP=$(tofu output -raw bastion_public_ip)
MASTER_IP=$(tofu output -json master_private_ips | jq -r '.[0]')
WORKER_IPS=($(tofu output -json worker_private_ips | jq -r '.[]'))
cd "$LAB_ROOT"

echo "  Bastion : $BASTION_IP"
echo "  Master  : $MASTER_IP"
echo "  Workers : ${WORKER_IPS[*]}"

CURRENT_STEP="2/3"; CURRENT_TARGET="bastion:${BASTION_IP:-pending}"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] Bastion 환경 준비"
ssh $SSH_OPTS ubuntu@$BASTION_IP "mkdir -p ~/scripts"
printf "SSH_KEY=\$HOME/.ssh/storage-lab.pem
M1_PUB=%s
M1_PRIV=%s
WORKER_PUBS=(%s)
WORKER_PRIVS=(%s)
" \
  "$MASTER_IP" "$MASTER_IP" \
  "${WORKER_IPS[*]}" "${WORKER_IPS[*]}" \
  | ssh $SSH_OPTS ubuntu@$BASTION_IP "cat > ~/scripts/.env"

# kubectl 설치 (없는 경우)
ssh $SSH_OPTS ubuntu@$BASTION_IP "
  if ! command -v kubectl &>/dev/null; then
    curl -sLO https://dl.k8s.io/release/v1.31.0/bin/linux/amd64/kubectl
    sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
    rm -f kubectl
  fi
"

CURRENT_STEP="3/3"; CURRENT_TARGET="bastion:${BASTION_IP:-pending}"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] rook-ceph 삭제 (Bastion에서 실행)"
ssh $SSH_OPTS ubuntu@$BASTION_IP << 'REMOTE'
set -e
export KUBECONFIG=~/.kube/config-k8s-storage-lab
source ~/scripts/.env
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=15 -i $SSH_KEY"
CSSH="ssh $SSH_OPTS ubuntu@"
WORKER_COUNT=${#WORKER_PUBS[@]}

CURRENT_STEP="1/5"; CURRENT_TARGET="local"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] API 서버 연결 확인"
API_OK=false
if kubectl cluster-info --request-timeout=10s &>/dev/null; then
  echo "  API 서버 응답 확인"
  API_OK=true
else
  echo "  [warning] API 서버 응답 없음 - K8s 리소스 삭제 단계 스킵"
fi

CURRENT_STEP="2/5"; CURRENT_TARGET="local"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] StorageClass 삭제"
if $API_OK; then
  kubectl delete storageclass ceph-rbd ceph-cephfs --ignore-not-found
  echo "  StorageClass 삭제 완료"
else
  echo "  스킵 (API 서버 미응답)"
fi

CURRENT_STEP="3/5"; CURRENT_TARGET="k8s-storage-cluster"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] CephFilesystem / CephBlockPool 삭제"
if $API_OK; then
  kubectl -n rook-ceph delete cephfilesystem labfs --ignore-not-found
  kubectl -n rook-ceph delete cephblockpool replicapool --ignore-not-found
  echo "  [대기] 삭제 대기 (30s)..."
  sleep 30
  echo "  CephFilesystem/BlockPool 삭제 완료"
else
  echo "  스킵 (API 서버 미응답)"
fi

CURRENT_STEP="4/5"; CURRENT_TARGET="k8s-storage-cluster"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] CephCluster 삭제"
if $API_OK; then
  kubectl -n rook-ceph patch cephcluster rook-ceph \
    --type merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
  kubectl -n rook-ceph delete cephcluster rook-ceph --ignore-not-found
  sleep 30

  $CSSH$M1_PUB "helm uninstall rook-ceph -n rook-ceph 2>/dev/null || true"
  kubectl delete namespace rook-ceph --ignore-not-found
  sleep 20

  kubectl get crd | grep ceph | awk '{print $1}' | xargs kubectl delete crd --ignore-not-found 2>/dev/null || true
  echo "  CephCluster / namespace / CRD 삭제 완료"
else
  echo "  스킵 (API 서버 미응답)"
fi

CURRENT_STEP="5/5"; CURRENT_TARGET="workers"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] Worker OSD 디스크 초기화 (nvme1n1, nvme2n1)"
for i in $(seq 0 $((WORKER_COUNT - 1))); do
  NODE_IP="${WORKER_PUBS[$i]}"
  NODE_NAME="worker-$((i + 1))"
  echo "  $NODE_NAME ($NODE_IP) 디스크 초기화 중..."
  $CSSH$NODE_IP "
    for dev in /dev/nvme1n1 /dev/nvme2n1 /dev/xvdb /dev/xvdc; do
      [ -b \"\$dev\" ] || continue
      echo \"  wipe: \$dev\"
      sudo sgdisk --zap-all \"\$dev\" 2>/dev/null || true
      sudo dd if=/dev/zero of=\"\$dev\" bs=1M count=100 2>/dev/null || true
    done
    sudo dmsetup remove_all 2>/dev/null || true
    sudo rm -rf /var/lib/rook
    echo '  디스크 초기화 완료'
  "
done

echo "rook-ceph 삭제 완료"
echo "   재설치: bash scripts/lifecycle/start_ceph.sh"
REMOTE
