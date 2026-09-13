#!/bin/bash
set -e
CURRENT_STEP="init"
CURRENT_TARGET="local"
trap 'status=$?; command_name=${BASH_COMMAND%% *}; printf "[step=%s][target=%s][failed] reason=command exited %d: %s\\n" "$CURRENT_STEP" "$CURRENT_TARGET" "$status" "$command_name" >&2' ERR
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# .env에서 IP 미리 수집 (삭제 전) - 배열 포함
NODE_IPS=()
if [ -f "$LAB_ROOT/scripts/system/.env" ]; then
  source "$LAB_ROOT/scripts/system/.env"
  NODE_IPS=($M1_PUB "${WORKER_PUBS[@]}")
fi

# AWS 인프라 삭제
cd "$LAB_ROOT/opentofu"
CURRENT_STEP="1/2"; CURRENT_TARGET="aws:terraform"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] AWS 인프라 삭제"
tofu destroy -auto-approve
cd "$LAB_ROOT"

# 로컬 설정 정리
CURRENT_STEP="2/2"; CURRENT_TARGET="local"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] kubeconfig와 known_hosts 정리"
rm -f scripts/system/.env
rm -f ~/.kube/config-k8s-storage-lab

# SSH known_hosts에서 노드 IP 제거 (재생성 시 host key 충돌 방지)
for ip in "${NODE_IPS[@]}"; do
  ssh-keygen -R "$ip" 2>/dev/null || true
done

echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] 전체 삭제 완료 (인프라 + 로컬 kubeconfig + known_hosts)"
