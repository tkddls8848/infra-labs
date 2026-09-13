#!/bin/bash
# k3s-storage-lab 전체 삭제
set -e
CURRENT_STEP="init"
CURRENT_TARGET="local"
trap 'status=$?; command_name=${BASH_COMMAND%% *}; printf "[step=%s][target=%s][failed] reason=command exited %d: %s\\n" "$CURRENT_STEP" "$CURRENT_TARGET" "$status" "$command_name" >&2' ERR
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

cd "$LAB_ROOT/opentofu"
CURRENT_STEP="destroy"; CURRENT_TARGET="aws:terraform"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] 전체 인프라 삭제"
tofu destroy -auto-approve

echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] 전체 삭제 완료"
