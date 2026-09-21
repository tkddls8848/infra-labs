#!/usr/bin/env bash
# 03_measure_baseline.sh — 실습 A. 상태를 모르는 Service 로 멀티턴 부하를 흘린다.
#
# 글 4.2 의 재현이다. 같은 대화의 후속 질문이 매번 다른 파드로 가면, 그 파드에는
# KV 캐시가 없으니 프롬프트를 처음부터 다시 계산한다.
#
# 무엇을 보게 되는가:
#   - 접두사 캐시 히트율이 파드 수의 역수(3개면 ~33%) 근처에 머문다
#   - 요청은 파드마다 고르게 나뉜다 (부하 분산 자체는 잘 되고 있다)
#   - 바로 그 '고르게'가 캐시를 깨뜨린다

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_config
require_cmd kubectl python3

READY="$(kubectl -n "$NAMESPACE" get deployment decode -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
[[ "${READY:-0}" -ge 1 ]] || die "모델 서버가 준비되지 않았습니다. 먼저 02_modelserver_up.sh 를 돌리세요."

observe "부하를 받을 경로"
echo "Service/vllm-baseline → 엔드포인트 ${READY}개 중 iptables 가 확률로 하나 선택"
echo "이 경로에는 EPP 도, InferencePool 도 없다. 대화가 누구에게 갔는지 아무도 기억하지 않는다."

start_port_forward "svc/vllm-baseline" "$BASELINE_LOCAL_PORT" 8000

log "멀티턴 부하 시작 (실습 A)"
python3 "${LAB_ROOT}/bench/multiturn.py" \
  --base-url "http://127.0.0.1:${BASELINE_LOCAL_PORT}" \
  --label baseline \
  --namespace "$NAMESPACE" \
  --out-dir "$LAB_GENERATED" \
  "$@"

stop_port_forwards

observe "지금 읽어야 할 것"
cat <<'NOTE'
1) 접두사 캐시 히트율 — 파드 수가 3이면 대체로 30%대에 머문다. 대화의 앞부분이
   매 턴 똑같은데도 히트가 안 난다는 뜻이다. 캐시를 가진 파드로 가지 않았다.

2) 파드별 요청 분포 — 거의 균등하다. Service 는 '공평하게' 나눴다. 일반 웹
   서비스였다면 이게 정답이다. LLM 에서는 이 공평함이 재연산 비용으로 돌아온다.

3) 파드별 히트율 — 어느 파드도 특별히 높지 않다. 각자 조각난 대화 일부만 쥐고 있다.

다음: 04_router_up.sh 로 앞단에 llm-d 라우터를 세우고, 05_measure_router.sh 로
같은 부하를 다시 흘려 이 숫자들이 어떻게 달라지는지 본다.
NOTE
