#!/usr/bin/env bash
# 06_saturation.sh — 실습 C. 캐시 친화도와 부하 분산을 일부러 맞붙인다.
#
# 글 5.2 는 EPP 가 "캐시가 있는 곳으로 보내되, 한 파드에 쏠려 큐가 밀리면
# 부하를 분산" 한다고 말한다. 그 균형을 말로만 두지 않고 직접 흔들어 본다.
#
# prefix-cache-affinity-filter 는 엔드포인트가 포화됐다고 판단하면 캐시 친화도를
# 포기한다. 그 판단 기준이 peakPrefillThroughput 이다. 이 값을 비현실적으로
# 낮추면 EPP 는 늘 "다들 뜨겁다"고 보고 캐시를 버린 채 흩뜨린다.
#
# 사용법:
#   06_saturation.sh            # 기준값 50 으로 실행
#   06_saturation.sh 5          # 더 극단적으로
#
# 무엇을 보게 되는가: 라우터를 그대로 둔 채 숫자 하나만 바꿨는데 히트율이
# baseline 수준으로 되돌아간다. 라우팅을 결정하는 것은 '라우터가 있느냐'가
# 아니라 '어떤 신호에 얼마의 가중치를 주느냐' 라는 것.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_config
require_cmd kubectl helm python3

SATURATED_PEAK="${1:-50}"
[[ "$SATURATED_PEAK" =~ ^[0-9]+$ ]] || die "첫 인자는 정수여야 합니다 (초당 prefill 토큰): $SATURATED_PEAK"
shift || true

CHART_TGZ="$(ls "${LAB_GENERATED}/charts"/llm-d-router-standalone-*.tgz 2>/dev/null | head -1 || true)"
[[ -n "$CHART_TGZ" ]] || die "검증된 차트가 없습니다. 먼저 04_router_up.sh 를 돌리세요."

ORIGINAL_PEAK="$PEAK_PREFILL_THROUGHPUT"

restore_peak() {
  # 이 실습은 라우터 설정을 일부러 망가뜨린다. 스크립트가 어떻게 끝나든
  # 원래 값으로 되돌려, 다음 실습이 오염된 상태에서 시작하지 않게 한다.
  log "peakPrefillThroughput 를 원래 값(${ORIGINAL_PEAK})으로 되돌린다"
  PEAK_PREFILL_THROUGHPUT="$ORIGINAL_PEAK" \
    render_manifest "${LAB_MANIFESTS}/router-values.yaml" "${LAB_GENERATED}/router-values.yaml"
  helm upgrade "$RELEASE_NAME" "$CHART_TGZ" -n "$NAMESPACE" \
    -f "${LAB_GENERATED}/router-values.yaml" --wait --timeout 5m >/dev/null \
    || warn "되돌리기에 실패했습니다. 04_router_up.sh 를 다시 돌리세요."
  stop_port_forwards
}

observe "라우터 설정만 바꾼다 — 모델 서버도, 부하도 그대로"
echo "peakPrefillThroughput: ${ORIGINAL_PEAK}  →  ${SATURATED_PEAK}"
echo "이 값이 낮을수록 EPP 는 엔드포인트를 쉽게 '포화됐다'고 본다."

PEAK_PREFILL_THROUGHPUT="$SATURATED_PEAK" \
  render_manifest "${LAB_MANIFESTS}/router-values.yaml" "${LAB_GENERATED}/router-values-saturated.yaml"

trap restore_peak EXIT INT TERM

log "라우터 갱신"
helm upgrade "$RELEASE_NAME" "$CHART_TGZ" -n "$NAMESPACE" \
  -f "${LAB_GENERATED}/router-values-saturated.yaml" --wait --timeout 10m \
  || die "라우터 갱신 실패."

ROUTER_SVC="$(kubectl -n "$NAMESPACE" get service \
  -l "app.kubernetes.io/instance=${RELEASE_NAME}" \
  -o jsonpath='{.items[0].metadata.name}')"

start_port_forward "svc/${ROUTER_SVC}" "$ROUTER_LOCAL_PORT" 8081

log "같은 부하를 다시 흘린다 (실습 C)"
python3 "${LAB_ROOT}/bench/multiturn.py" \
  --base-url "http://127.0.0.1:${ROUTER_LOCAL_PORT}" \
  --label router-saturated \
  --namespace "$NAMESPACE" \
  --out-dir "$LAB_GENERATED" \
  "$@"

stop_port_forwards

observe "정상 라우팅 vs 포화 회피가 항상 켜진 라우팅"
python3 "${LAB_ROOT}/bench/compare.py" \
  "${LAB_GENERATED}/result-router.json" \
  "${LAB_GENERATED}/result-router-saturated.json"

cat <<'NOTE'

읽는 법: 두 실행 모두 llm-d 라우터를 거쳤다. EPP 도, InferencePool 도,
Envoy 도 그대로다. 그런데 히트율은 baseline 쪽으로 되돌아갔을 것이다.

즉 "AI 라우터를 깔았다" 가 결론이 아니다. 어떤 신호를 얼마나 믿을지가
결론이다. 글이 말한 peakPrefillThroughput 보정(calibration)이 실제 운영에서
왜 별도 절차로 존재하는지가 여기서 드러난다.

이 스크립트는 끝나면서 설정을 원래대로 되돌린다.
NOTE
