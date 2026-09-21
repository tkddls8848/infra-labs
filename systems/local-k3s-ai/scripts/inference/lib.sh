#!/usr/bin/env bash
# lib.sh — 추론 랩 스크립트들이 공유하는 헬퍼.
#
# 이 파일은 실행하지 않고 source 한다. 각 스크립트가 독립 배포되는
# local-kubeadm-gpu 와 달리 여기 스크립트들은 항상 저장소 트리에서 같이
# 실행되므로, 검증 헬퍼를 복제하지 않고 한 곳에 둔다.

set -euo pipefail

LAB_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd "${LAB_SCRIPT_DIR}/../.." && pwd)"
LAB_CONFIG="${LAB_CONFIG:-${LAB_ROOT}/config/inference.env}"
# shellcheck disable=SC2034  # 이 파일을 source 하는 스크립트들이 쓴다
LAB_MANIFESTS="${LAB_ROOT}/manifests/inference"
# .generated/ 는 .gitignore 의 systems/**/.generated/ 규칙으로 커밋되지 않는다.
LAB_GENERATED="${LAB_ROOT}/.generated"

log()   { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn()  { printf '[%s] ⚠️  %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
die()   { printf '❌ %s\n' "$*" >&2; exit 1; }

# 실습에서 "여기를 보라"고 짚어 주는 구분선.
observe() {
  printf '\n──────────────────────────────────────────────────────────────\n'
  printf '👀 확인: %s\n' "$*"
  printf '──────────────────────────────────────────────────────────────\n'
}

load_config() {
  [[ -f "$LAB_CONFIG" ]] || die "설정 파일이 없습니다: $LAB_CONFIG"
  # shellcheck disable=SC1090
  source "$LAB_CONFIG"
  : "${NAMESPACE:?inference.env 에 NAMESPACE 가 없습니다}"
  : "${RELEASE_NAME:?inference.env 에 RELEASE_NAME 이 없습니다}"
  # bench/*.py 가 자식 프로세스로 돌면서 이 둘을 읽는다.
  export NAMESPACE MODEL_LABEL
  mkdir -p "$LAB_GENERATED"
}

require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "$cmd 가 필요합니다. 설치 후 다시 실행하세요."
  done
}

# 원격 파일을 받고 sha256 을 대조한다. 불일치면 적용하지 않고 멈춘다.
# 저장소 정책: kubectl apply -f <URL> 로 미검증 원격 매니페스트를 적용하지 않는다.
fetch_verified() {
  local label="$1" url="$2" want="$3" dest="$4" got
  [[ "$want" =~ ^[[:xdigit:]]{64}$ ]] || die "$label SHA-256 은 64자리 16진수여야 합니다: $want"
  [[ "$url" == https://* ]]           || die "$label URL 은 HTTPS 여야 합니다: $url"

  if [[ -s "$dest" ]] && [[ "$(sha256sum "$dest" | awk '{print $1}')" == "${want,,}" ]]; then
    log "$label 캐시 사용 (checksum 일치): $dest"
    return 0
  fi

  log "$label 다운로드: $url"
  curl --proto '=https' --tlsv1.2 -fsSL --retry 3 --retry-delay 2 -o "$dest" "$url" \
    || die "$label 다운로드 실패: $url"
  [[ -s "$dest" ]] || die "$label 다운로드 결과가 비어 있습니다: $url"
  got="$(sha256sum "$dest" | awk '{print $1}')"
  [[ "$got" == "${want,,}" ]] \
    || die "$label checksum 불일치 (기대 ${want,,}, 실제 $got). 적용을 중단합니다."
  log "$label 검증 완료: $got"
}

# inference.env 값을 매니페스트 템플릿의 __PLACEHOLDER__ 자리에 채운다.
# envsubst 를 쓰지 않는 이유: vLLM 인자와 Envoy 설정에 $ 가 들어가는 경우를
# 통째로 먹어버려 조용히 망가진다.
render_manifest() {
  local src="$1" dest="$2"
  [[ -f "$src" ]] || die "매니페스트 템플릿이 없습니다: $src"
  sed \
    -e "s|__NAMESPACE__|${NAMESPACE}|g" \
    -e "s|__RELEASE_NAME__|${RELEASE_NAME}|g" \
    -e "s|__VLLM_IMAGE__|${VLLM_IMAGE}|g" \
    -e "s|__MODEL_ID__|${MODEL_ID}|g" \
    -e "s|__MODEL_LABEL__|${MODEL_LABEL}|g" \
    -e "s|__REPLICAS__|${REPLICAS}|g" \
    -e "s|__MAX_MODEL_LEN__|${MAX_MODEL_LEN}|g" \
    -e "s|__GPU_MEMORY_UTILIZATION__|${GPU_MEMORY_UTILIZATION}|g" \
    -e "s|__DEVICE_PLUGIN_IMAGE__|${DEVICE_PLUGIN_IMAGE}|g" \
    -e "s|__GPU_TIME_SLICING_REPLICAS__|${GPU_TIME_SLICING_REPLICAS}|g" \
    -e "s|__VLLM_CPU_REQUEST__|${VLLM_CPU_REQUEST}|g" \
    -e "s|__VLLM_MEMORY_REQUEST__|${VLLM_MEMORY_REQUEST}|g" \
    -e "s|__VLLM_MEMORY_LIMIT__|${VLLM_MEMORY_LIMIT}|g" \
    -e "s|__EPP_CPU_REQUEST__|${EPP_CPU_REQUEST}|g" \
    -e "s|__EPP_MEMORY_REQUEST__|${EPP_MEMORY_REQUEST}|g" \
    -e "s|__EPP_MEMORY_LIMIT__|${EPP_MEMORY_LIMIT}|g" \
    -e "s|__PROXY_CPU_REQUEST__|${PROXY_CPU_REQUEST}|g" \
    -e "s|__PROXY_MEMORY_REQUEST__|${PROXY_MEMORY_REQUEST}|g" \
    -e "s|__PROXY_MEMORY_LIMIT__|${PROXY_MEMORY_LIMIT}|g" \
    -e "s|__ROUTER_EPP_IMAGE_REGISTRY__|${ROUTER_EPP_IMAGE_REGISTRY}|g" \
    -e "s|__ROUTER_EPP_IMAGE_REPOSITORY__|${ROUTER_EPP_IMAGE_REPOSITORY}|g" \
    -e "s|__ROUTER_EPP_IMAGE_TAG__|${ROUTER_EPP_IMAGE_TAG}|g" \
    -e "s|__PEAK_PREFILL_THROUGHPUT__|${PEAK_PREFILL_THROUGHPUT}|g" \
    -e "s|__EPP_LOG_VERBOSITY__|${EPP_LOG_VERBOSITY}|g" \
    "$src" > "$dest"
  log "렌더 완료: $dest"
}

# 파드 하나의 vLLM /metrics 를 API 서버 프록시로 읽는다. port-forward 도,
# 파드 안의 curl 도 필요 없다 — vLLM 이미지에는 curl 이 없다.
pod_metrics() {
  local pod="$1"
  kubectl get --raw "/api/v1/namespaces/${NAMESPACE}/pods/${pod}:8000/proxy/metrics" 2>/dev/null
}

modelserver_pods() {
  kubectl -n "$NAMESPACE" get pods \
    -l "llm-d.ai/model=${MODEL_LABEL}" \
    --field-selector=status.phase=Running \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
}

wait_rollout() {
  local kind="$1" name="$2" timeout="${3:-900s}"
  log "$kind/$name 준비 대기 (최대 $timeout)…"
  kubectl -n "$NAMESPACE" rollout status "$kind/$name" --timeout="$timeout" \
    || die "$kind/$name 가 준비되지 않았습니다. 'kubectl -n $NAMESPACE describe $kind $name' 로 확인하세요."
}

# ── port-forward 관리 ────────────────────────────────────────────────────────
# 실습은 호스트에서 부하를 흘린다. 스크립트가 끝날 때(정상/실패/Ctrl-C 모두)
# 터널이 남지 않도록 PID 를 모아 두고 trap 으로 정리한다.
LAB_PF_PIDS=()

stop_port_forwards() {
  local pid
  for pid in "${LAB_PF_PIDS[@]:-}"; do
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
  done
  LAB_PF_PIDS=()
}

start_port_forward() {
  local target="$1" local_port="$2" remote_port="$3" pid
  # 이미 쓰고 있는 포트면 남아 있는 터널이나 다른 프로세스와 충돌한다.
  if (exec 3<>"/dev/tcp/127.0.0.1/${local_port}") 2>/dev/null; then
    exec 3<&- 2>/dev/null || true
    die "로컬 포트 ${local_port} 가 이미 사용 중입니다. 남아 있는 port-forward 를 정리하거나 config/inference.env 에서 포트를 바꾸세요."
  fi

  kubectl -n "$NAMESPACE" port-forward "$target" "${local_port}:${remote_port}" >/dev/null 2>&1 &
  pid=$!
  LAB_PF_PIDS+=("$pid")
  trap stop_port_forwards EXIT INT TERM

  for _ in $(seq 1 40); do
    if (exec 3<>"/dev/tcp/127.0.0.1/${local_port}") 2>/dev/null; then
      exec 3<&- 2>/dev/null || true
      log "port-forward 준비됨: ${target} → 127.0.0.1:${local_port}"
      return 0
    fi
    kill -0 "$pid" 2>/dev/null || die "port-forward 가 죽었습니다: $target"
    sleep 0.5
  done
  die "port-forward 가 ${local_port} 에서 열리지 않았습니다: $target"
}
