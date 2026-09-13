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
MASTER_IP=%s
WORKER_IPS=(%s)
" \
  "$MASTER_IP" \
  "${WORKER_IPS[*]}" \
  | ssh $SSH_OPTS ubuntu@$BASTION_IP "cat > ~/scripts/.env"

# kubectl 설치 (없는 경우)
ssh $SSH_OPTS ubuntu@$BASTION_IP "
  if ! command -v kubectl &>/dev/null; then
    curl -sLO https://dl.k8s.io/release/v1.31.0/bin/linux/amd64/kubectl
    sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
    rm -f kubectl
  fi
"

CURRENT_STEP="3/3"; CURRENT_TARGET="bastion:${BASTION_IP:-pending}"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] BeeGFS 삭제 (Bastion에서 실행)"
ssh $SSH_OPTS ubuntu@$BASTION_IP << 'REMOTE'
set -e
export KUBECONFIG=~/.kube/config-k8s-storage-lab
source ~/scripts/.env
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=15 -i $SSH_KEY"
CSSH="ssh $SSH_OPTS ubuntu@"
WORKER_COUNT=${#WORKER_IPS[@]}

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
  kubectl delete storageclass beegfs-scratch --ignore-not-found
  echo "  StorageClass 삭제 완료"
else
  echo "  스킵 (API 서버 미응답)"
fi

CURRENT_STEP="3/5"; CURRENT_TARGET="local"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] beegfs-system 네임스페이스 리소스 삭제"
if $API_OK; then
  # Deployment / DaemonSet / Service / ServiceMonitor / ConfigMap
  kubectl delete deployment beegfs-mgmtd beegfs-meta beegfs-exporter \
    -n beegfs-system --ignore-not-found
  kubectl delete daemonset beegfs-storage \
    -n beegfs-system --ignore-not-found
  kubectl delete service beegfs-mgmtd beegfs-meta beegfs-exporter \
    -n beegfs-system --ignore-not-found
  kubectl delete servicemonitor beegfs-exporter \
    -n beegfs-system --ignore-not-found 2>/dev/null || true
  kubectl delete configmap beegfs-exporter-script \
    -n beegfs-system --ignore-not-found
  echo "  [대기] Pod 종료 대기 (20s)..."
  sleep 20
  echo "  beegfs-system 리소스 삭제 완료"
else
  echo "  스킵 (API 서버 미응답)"
fi

CURRENT_STEP="4/5"; CURRENT_TARGET="local"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] Grafana 대시보드 ConfigMap 삭제"
if $API_OK; then
  kubectl delete configmap beegfs-grafana-dashboard \
    -n monitoring --ignore-not-found
  echo "  Grafana 대시보드 ConfigMap 삭제 완료"
else
  echo "  스킵 (API 서버 미응답)"
fi

CURRENT_STEP="5/5"; CURRENT_TARGET="local"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] beegfs-system 네임스페이스 삭제"
if $API_OK; then
  kubectl delete namespace beegfs-system --ignore-not-found
  echo "  [대기] 네임스페이스 삭제 대기 (20s)..."
  sleep 20
  echo "  네임스페이스 삭제 완료"
else
  echo "  스킵 (API 서버 미응답)"
fi

echo "BeeGFS 삭제 완료"
echo "   재설치: bash scripts/lifecycle/start_beegfs.sh"
REMOTE
