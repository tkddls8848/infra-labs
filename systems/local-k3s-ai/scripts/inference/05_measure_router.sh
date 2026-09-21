#!/usr/bin/env bash
# 05_measure_router.sh — 실습 B. 같은 부하를 llm-d 라우터로 흘리고 A와 비교한다.
#
# 모델 서버도, 부하 스크립트도, 시드도 03 단계와 같다. 바뀐 것은 앞단뿐이다.
#
# 무엇을 보게 되는가:
#   - 접두사 캐시 히트율이 올라간다 (대화가 캐시를 가진 파드로 돌아갔다)
#   - 파드별 요청 분포는 더 이상 균등하지 않다 — 그게 의도다
#   - EPP 로그에 '어떤 후보를 어떤 점수로 골랐는지' 가 남는다

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_config
require_cmd kubectl python3

ROUTER_SVC="$(kubectl -n "$NAMESPACE" get service \
  -l "app.kubernetes.io/instance=${RELEASE_NAME}" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[[ -n "$ROUTER_SVC" ]] || die "라우터 Service 를 찾지 못했습니다. 먼저 04_router_up.sh 를 돌리세요."

ROUTER_POD="$(kubectl -n "$NAMESPACE" get pods \
  -l "app.kubernetes.io/instance=${RELEASE_NAME}" \
  -o jsonpath='{.items[0].metadata.name}')"

observe "부하를 받을 경로"
echo "Service/${ROUTER_SVC}:8081  →  Envoy  →(ext-proc)→  EPP  →  선택된 파드"
echo "03 단계와 달리 이 경로에는 '어느 파드가 무엇을 캐시하고 있는지' 를 보는 눈이 있다."

# EPP 로그를 이번 실행분만 보려고 시작 시각을 잡아 둔다.
LOG_SINCE="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

start_port_forward "svc/${ROUTER_SVC}" "$ROUTER_LOCAL_PORT" 8081

log "멀티턴 부하 시작 (실습 B) — 03 단계와 동일한 조건"
python3 "${LAB_ROOT}/bench/multiturn.py" \
  --base-url "http://127.0.0.1:${ROUTER_LOCAL_PORT}" \
  --label router \
  --namespace "$NAMESPACE" \
  --out-dir "$LAB_GENERATED" \
  "$@"

stop_port_forwards

observe "EPP 가 내린 결정의 흔적"
# 빌드에 따라 로그 문구가 다르다. 엔드포인트 선택과 점수가 들어간 줄을 넓게 건진다.
kubectl -n "$NAMESPACE" logs "$ROUTER_POD" -c epp --since-time="$LOG_SINCE" 2>/dev/null \
  | grep -iE 'score|endpoint|pick|prefix|profile' | tail -15 | sed 's/^/  /' \
  || echo "  (epp 컨테이너 로그를 읽지 못했습니다)"
echo
echo "로그가 비어 있으면 config/inference.env 의 EPP_LOG_VERBOSITY 를 올리고"
echo "04_router_up.sh 를 다시 돌린 뒤 이 단계를 반복하라."

observe "Envoy 가 실제로 보낸 업스트림"
kubectl -n "$NAMESPACE" logs "$ROUTER_POD" -c envoy-proxy --since-time="$LOG_SINCE" 2>/dev/null \
  | tail -10 | sed 's/^/  /' \
  || kubectl -n "$NAMESPACE" logs "$ROUTER_POD" --all-containers --since-time="$LOG_SINCE" 2>/dev/null \
     | tail -10 | sed 's/^/  /' \
  || echo "  (envoy 컨테이너 로그를 읽지 못했습니다)"

observe "실습 A vs 실습 B"
python3 "${LAB_ROOT}/bench/compare.py" \
  "${LAB_GENERATED}/result-baseline.json" \
  "${LAB_GENERATED}/result-router.json"

cat <<'NOTE'

여기서 멈추지 말고 한 번 더 볼 것:

  · 파드별 요청 분포가 기울었는가? 기울었다면 EPP 가 캐시 친화도를 위해
    일부러 공평함을 포기한 것이다. 글 5.2 의 "캐시가 있는 곳으로 보내되"가 이것.

  · 그런데 완전히 한 파드로 쏠리지는 않았을 것이다. token-load-scorer 와
    포화 회피가 "한 파드에 쏠려 큐가 밀리면 부하를 분산" 을 맡는다.

  · 두 힘을 직접 맞붙여 보려면 06_saturation.sh 를 돌려 보라.
NOTE
