#!/usr/bin/env bash
# 00_preflight.sh — 실습을 시작하기 전에 호스트와 클러스터가 조건을 만족하는지 본다.
#
# 이 스크립트는 아무것도 설치하거나 바꾸지 않는다. 읽기만 한다.
# 실패하면 무엇이 빠졌는지 알려 주고 멈춘다.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_config

FAILED=0
check_fail() { printf '  ❌ %s\n' "$*"; FAILED=1; }
check_ok()   { printf '  ✅ %s\n' "$*"; }

echo "── 1. 호스트 도구 ─────────────────────────────────────────────"
for c in kubectl helm curl sha256sum python3 awk; do
  if command -v "$c" >/dev/null 2>&1; then check_ok "$c"; else check_fail "$c 없음"; fi
done

# helm 은 OCI 레지스트리에서 차트를 받는다 (3.8.0 부터 GA).
if command -v helm >/dev/null 2>&1; then
  HELM_VER="$(helm version --template '{{.Version}}' 2>/dev/null || echo unknown)"
  echo "     helm ${HELM_VER}"
fi

echo
echo "── 2. NVIDIA 드라이버 / GPU ───────────────────────────────────"
if command -v nvidia-smi >/dev/null 2>&1; then
  check_ok "nvidia-smi"
  nvidia-smi --query-gpu=index,name,memory.total,driver_version \
    --format=csv,noheader | sed 's/^/     /'
  GPU_COUNT="$(nvidia-smi --query-gpu=index --format=csv,noheader | wc -l)"
  VRAM_MIB="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1 | tr -cd '0-9')"
  # 드라이버가 숫자 대신 [N/A] 같은 걸 돌려주는 경우가 있다. 산정을 건너뛴다.
  VRAM_MIB="${VRAM_MIB:-0}"
else
  check_fail "nvidia-smi 없음 — 호스트에 NVIDIA 드라이버가 설치되어야 합니다."
  GPU_COUNT=0
  VRAM_MIB=0
fi

echo
echo "── 3. 컨테이너 런타임의 GPU 연결 ──────────────────────────────"
# k3s 는 nvidia-container-runtime 을 발견하면 기동 시 'nvidia' RuntimeClass 를
# 스스로 만든다. 없다면 nvidia-container-toolkit 설치 후 k3s 를 재시작해야 한다.
if command -v nvidia-ctk >/dev/null 2>&1; then
  check_ok "nvidia-container-toolkit ($(nvidia-ctk --version 2>/dev/null | head -1))"
else
  check_fail "nvidia-ctk 없음 — nvidia-container-toolkit 을 설치하세요."
fi

echo
echo "── 4. 클러스터 ────────────────────────────────────────────────"
if kubectl version -o json >/dev/null 2>&1; then
  check_ok "kubectl 이 클러스터에 접속됨"
  kubectl get nodes -o wide | sed 's/^/     /'
else
  check_fail "클러스터에 접속할 수 없습니다. 먼저 scripts/addons/ai.sh 로 K3s 를 설치하세요."
fi

if kubectl get runtimeclass nvidia >/dev/null 2>&1; then
  check_ok "RuntimeClass/nvidia 존재"
else
  check_fail "RuntimeClass/nvidia 없음 — nvidia-container-toolkit 설치 후 'sudo systemctl restart k3s' 로 K3s 가 다시 탐지하게 하세요."
fi

echo
echo "── 5. GPU 메모리 산정 ─────────────────────────────────────────"
# time-slicing 은 SM 시간만 나눈다. 메모리는 나누지 않으므로 각 vLLM 레플리카가
# '전체 VRAM x GPU_MEMORY_UTILIZATION' 을 각자 통째로 예약한다.
TOTAL_FRACTION="$(awk -v r="$REPLICAS" -v u="$GPU_MEMORY_UTILIZATION" 'BEGIN{printf "%.2f", r*u}')"
echo "     REPLICAS=${REPLICAS}  x  GPU_MEMORY_UTILIZATION=${GPU_MEMORY_UTILIZATION}  =  ${TOTAL_FRACTION}"
if awk -v t="$TOTAL_FRACTION" 'BEGIN{exit !(t >= 0.95)}'; then
  check_fail "합이 0.95 이상입니다. 레플리카들이 서로 VRAM 을 빼앗아 CUDA OOM 으로 죽습니다. config/inference.env 에서 REPLICAS 나 GPU_MEMORY_UTILIZATION 을 낮추세요."
else
  check_ok "합이 0.95 미만 — 레플리카당 VRAM 예약이 겹치지 않습니다."
fi

if [[ "$VRAM_MIB" -gt 0 ]]; then
  PER_REPLICA_MIB="$(awk -v v="$VRAM_MIB" -v u="$GPU_MEMORY_UTILIZATION" 'BEGIN{printf "%d", v*u}')"
  echo "     레플리카당 예약 ≈ ${PER_REPLICA_MIB} MiB (전체 ${VRAM_MIB} MiB 중)"
  # 가중치 + KV 캐시가 들어가야 접두사 캐시 실습이 의미를 갖는다.
  if [[ "$PER_REPLICA_MIB" -lt 2048 ]]; then
    check_fail "레플리카당 2 GiB 미만입니다. KV 캐시 블록이 거의 남지 않아 접두사 캐시 실습이 성립하지 않습니다. GPU_MEMORY_UTILIZATION 을 올리세요 (REPLICAS 와의 곱은 0.95 미만이어야 합니다). 둘을 동시에 만족할 수 없으면 — VRAM 이 약 4.4 GiB 미만이면 — 더 작은 모델을 써야 합니다. REPLICAS 는 2 미만으로 내릴 수 없습니다."
  else
    check_ok "레플리카당 KV 캐시 여유 있음"
  fi
fi

echo
echo "── 6. 노드 메모리 vs 파드 요청 합계 ───────────────────────────"
# VRAM 만 보고 넘어가면 두 번째 레플리카가 Pending 으로 남는 것을 여기서 못 잡는다.
# vLLM 은 GPU 만큼이나 호스트 RAM 을 쓰고, 그 몫은 노드 allocatable 에서 나온다.
ALLOCATABLE="$(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.memory}' 2>/dev/null || true)"
if [[ -n "$ALLOCATABLE" ]]; then
  ALLOC_MIB="$(mem_to_mib "$ALLOCATABLE")"
  REQ_MIB=$(( $(mem_to_mib "$VLLM_MEMORY_REQUEST") * REPLICAS \
              + $(mem_to_mib "$EPP_MEMORY_REQUEST") \
              + $(mem_to_mib "$PROXY_MEMORY_REQUEST") ))
  echo "     요청 합계 ${REQ_MIB} MiB (vLLM ${VLLM_MEMORY_REQUEST} x ${REPLICAS} + EPP + Envoy)"
  echo "     노드 allocatable ${ALLOC_MIB} MiB"
  if [[ "$REQ_MIB" -ge "$ALLOC_MIB" ]]; then
    check_fail "요청 합계가 노드 용량 이상입니다. 파드가 Pending 으로 남습니다. config/inference.env 의 VLLM_MEMORY_REQUEST 를 낮추거나 노드 메모리를 늘리세요 (WSL 이면 .wslconfig 의 memory)."
  elif awk -v r="$REQ_MIB" -v a="$ALLOC_MIB" 'BEGIN{exit !(r > a * 0.85)}'; then
    warn "요청 합계가 노드 용량의 85% 를 넘습니다. K3s 자체와 시스템 파드가 쓸 몫이 빠듯합니다."
  else
    check_ok "요청 합계가 노드 용량에 들어갑니다"
  fi
else
  echo "     (클러스터에 접속하지 못해 건너뜁니다)"
fi

echo
if [[ "$GPU_COUNT" -gt 1 ]]; then
  echo "     GPU ${GPU_COUNT} 장 감지 — 07_pd_anatomy.sh 의 구조를 실제로 올려 볼 여지가 있습니다 (상류 pd-disaggregation 가이드 참고)."
fi

echo
if [[ "$FAILED" -ne 0 ]]; then
  die "사전 점검 실패. 위의 ❌ 항목을 해결한 뒤 다시 실행하세요."
fi
log "사전 점검 통과. 다음: scripts/inference/01_gpu_timeslicing.sh"
