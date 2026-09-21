#!/usr/bin/env bash
# 02_modelserver_up.sh — vLLM 모델 서버 N개와 '평범한 Service' 를 올린다.
#
# 글 4장의 비교 대상(랜덤 분산 경로)이 여기서 완성된다. 라우터는 아직 없다.
#
# 실습 포인트: 파드 3개가 물리 GPU 1장을 나눠 쓰고 있다는 것, 그리고 각 파드가
# 자기만의 KV 캐시를 따로 들고 있다는 것(= 캐시가 공유되지 않는다는 것).

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_config
require_cmd kubectl

render_manifest "${LAB_MANIFESTS}/vllm-decode.yaml" "${LAB_GENERATED}/vllm-decode.yaml"

log "네임스페이스와 모델 서버 적용"
kubectl apply -f "${LAB_GENERATED}/vllm-decode.yaml"

# gated 모델로 바꾼 경우에만 필요하다. 기본 모델은 토큰 없이 받아진다.
if [[ -n "${HF_TOKEN:-}" ]]; then
  log "llm-d-hf-token 시크릿 생성/갱신"
  kubectl -n "$NAMESPACE" create secret generic llm-d-hf-token \
    --from-literal="HF_TOKEN=${HF_TOKEN}" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n "$NAMESPACE" rollout restart deployment/decode
else
  log "HF_TOKEN 미설정 — 공개 모델로 진행합니다 (${MODEL_ID})."
fi

# 레플리카 여러 개가 같은 캐시 디렉터리로 동시에 내려받으면 서로의 락을 기다리며
# 기동이 오래 걸리거나 부분 파일이 남는다. 1개로 받아 두고 나서 늘린다.
log "첫 레플리카로 가중치를 먼저 받는다 (첫 실행은 수 분 걸릴 수 있다)"
wait_rollout deployment decode 1800s

if [[ "$REPLICAS" -gt 1 ]]; then
  log "레플리카 ${REPLICAS} 로 확장 — 이제 캐시가 차 있어 빠르게 뜬다"
  kubectl -n "$NAMESPACE" scale deployment/decode --replicas="$REPLICAS"
  wait_rollout deployment decode 900s
fi

observe "GPU 1장 위에 올라간 모델 서버들"
kubectl -n "$NAMESPACE" get pods -l "llm-d.ai/model=${MODEL_LABEL}" \
  -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName,GPU:.spec.containers[0].resources.requests.nvidia\.com/gpu,STATUS:.status.phase'
echo
echo "nvidia-smi 로 보면 프로세스는 ${REPLICAS}개지만 GPU 는 한 장이다:"
nvidia-smi --query-compute-apps=pid,used_memory --format=csv 2>/dev/null | sed 's/^/  /' \
  || echo "  (호스트에서 nvidia-smi 를 직접 실행해 보세요)"

observe "Service 뒤에 붙은 엔드포인트 — 여기서 확률로 하나가 뽑힌다"
kubectl -n "$NAMESPACE" get endpointslice -l "kubernetes.io/service-name=vllm-baseline" \
  -o jsonpath='{range .items[*].endpoints[*]}  {.addresses[0]}  →  {.targetRef.name}{"\n"}{end}'
echo
echo "Service 는 어느 파드가 어떤 대화의 KV 캐시를 들고 있는지 전혀 모른다."
echo "kube-proxy 의 iptables 규칙은 그냥 엔드포인트를 균등 확률로 고를 뿐이다."

observe "각 파드의 접두사 캐시 지표 (아직 요청이 없으니 0)"
for pod in $(modelserver_pods); do
  printf '  %s\n' "$pod"
  pod_metrics "$pod" | grep -E '^vllm:(prefix_cache_(queries|hits)_total|num_requests_running)' \
    | sed 's/^/    /' || echo "    (지표를 읽지 못했습니다)"
done

cat <<'NOTE'

되돌리려면 (네임스페이스와 내려받은 모델 가중치까지 사라진다):
  scripts/inference/90_rollback.sh 02

NOTE
log "완료. 다음: scripts/inference/03_measure_baseline.sh"
