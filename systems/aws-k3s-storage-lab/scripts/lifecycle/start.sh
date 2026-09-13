#!/bin/bash
# k3s-storage-lab 전체 구성 자동화 — Stage 1 → 2 → 3 순차 실행
# 각 스테이지를 개별 실행하려면:
#   bash scripts/lifecycle/start_1_infra_k3s.sh
#   bash scripts/lifecycle/start_2_ceph.sh
#   bash scripts/lifecycle/start_3_beegfs.sh
#
# 롤백 (역순):
#   bash scripts/lifecycle/rollback_3_beegfs.sh
#   bash scripts/lifecycle/rollback_2_ceph.sh
#   bash scripts/lifecycle/rollback_1_infra.sh
set -e
CURRENT_STEP="init"
CURRENT_TARGET="local"
trap 'status=$?; command_name=${BASH_COMMAND%% *}; printf "[step=%s][target=%s][failed] reason=command exited %d: %s\\n" "$CURRENT_STEP" "$CURRENT_TARGET" "$status" "$command_name" >&2' ERR
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

CURRENT_STEP="1/3"; CURRENT_TARGET="aws/k3s"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] 인프라와 k3s 구성"
bash "$SCRIPT_DIR/start_1_infra_k3s.sh"
CURRENT_STEP="2/3"; CURRENT_TARGET="ceph"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] Ceph 구성"
bash "$SCRIPT_DIR/start_2_ceph.sh"
CURRENT_STEP="3/3"; CURRENT_TARGET="beegfs"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] BeeGFS 구성"
bash "$SCRIPT_DIR/start_3_beegfs.sh"
