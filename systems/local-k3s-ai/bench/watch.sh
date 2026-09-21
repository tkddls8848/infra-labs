#!/usr/bin/env bash
# watch.sh — 부하가 흐르는 동안 모델 서버들이 어떤 상태인지 실시간으로 본다.
#
# 다른 터미널에서 이걸 띄워 놓고 03/05/06 실습을 돌리면, 요청이 어느 파드로
# 몰리는지, 큐가 어디서 밀리는지, 캐시 히트율이 어떻게 움직이는지가 보인다.
# 결과 표(숫자 하나)로는 안 보이는 '과정' 이 여기 있다.
#
#   bench/watch.sh          2초 간격
#   bench/watch.sh 1        1초 간격
#
# 보여 주는 지표 (글 12장의 '추론 시대의 관측성' 에 대응):
#   RUN   처리 중인 요청 수            vllm:num_requests_running
#   WAIT  큐에서 대기 중인 요청 수     vllm:num_requests_waiting
#   KV    KV 캐시 점유율               vllm:kv_cache_usage_perc
#   HIT   누적 접두사 캐시 히트율      prefix_cache_hits / queries

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../scripts/inference/lib.sh"
load_config
require_cmd kubectl awk

INTERVAL="${1:-2}"

# 지표 하나를 뽑아 라벨 구분 없이 합산한다. 이 랩은 파드당 모델이 하나뿐이다.
# 라벨이 없는 샘플(`name 1.0`)도 있으므로 이름 뒤에 { 또는 공백이 오는 경우를
# 모두 받는다. 값이 없으면 0 을 돌려준다 — 표에서 바로 printf 로 쓰기 위해서다.
metric_sum() {
  local blob="$1" names="$2"
  printf '%s\n' "$blob" | awk -v pat="^($names)([{[:space:]])" '
    $0 !~ /^#/ && $0 ~ pat { sum += $NF; found = 1 }
    END { if (found) printf "%.4f", sum; else printf "0" }
  '
}

printf '%s 간격으로 갱신합니다. Ctrl-C 로 종료.\n' "${INTERVAL}초"
trap 'printf "\n종료합니다.\n"; exit 0' INT TERM

while true; do
  printf '\n[%s]  네임스페이스=%s\n' "$(date '+%H:%M:%S')" "$NAMESPACE"
  printf '  %-42s %6s %6s %8s %8s\n' "POD" "RUN" "WAIT" "KV%" "HIT%"

  pods="$(modelserver_pods || true)"
  if [[ -z "$pods" ]]; then
    printf '  (Running 상태의 모델 서버 파드가 없습니다)\n'
    sleep "$INTERVAL"
    continue
  fi

  for pod in $pods; do
    blob="$(pod_metrics "$pod" || true)"
    if [[ -z "$blob" ]]; then
      printf '  %-42s %6s %6s %8s %8s\n' "$pod" "-" "-" "-" "-"
      continue
    fi
    run="$(metric_sum "$blob" 'vllm:num_requests_running')"
    wait_="$(metric_sum "$blob" 'vllm:num_requests_waiting')"
    kv="$(metric_sum "$blob" 'vllm:kv_cache_usage_perc|vllm:gpu_cache_usage_perc')"
    q="$(metric_sum "$blob" 'vllm:prefix_cache_queries_total|vllm:gpu_prefix_cache_queries_total')"
    h="$(metric_sum "$blob" 'vllm:prefix_cache_hits_total|vllm:gpu_prefix_cache_hits_total')"
    hit="$(awk -v q="$q" -v h="$h" 'BEGIN{ if (q+0 > 0) printf "%.1f", h/q*100; else printf "-" }')"
    kvpct="$(awk -v v="$kv" 'BEGIN{ printf "%.1f", v*100 }')"
    printf '  %-42s %6.0f %6.0f %8s %8s\n' "$pod" "$run" "$wait_" "$kvpct" "$hit"
  done

  sleep "$INTERVAL"
done
