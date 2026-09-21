#!/usr/bin/env bash
# 07_pd_anatomy.sh — 실습 D. Prefill/Decode 분리 구조를 해부한다. 적용하지 않는다.
#
# 왜 적용하지 않는가:
#   글 7장의 P/D 분리는 prefill 풀과 decode 풀 사이로 KV 캐시를 옮긴다. 그
#   전송을 NIXL 이 RDMA(InfiniBand·RoCE·EFA)로 GPU 메모리 간에 직접 한다.
#   GPU 한 장짜리 랩에는 옮길 '건너편' 이 없다. 억지로 올리면 파드는 뜨지만
#   요청은 KV 전송에서 막히고, 그 실패를 보고 배울 수 있는 것도 없다.
#
#   그래서 이 단계는 상류의 실제 매니페스트를 렌더해서 '무엇이 어떻게 갈라지는가'
#   를 눈으로 확인하는 데까지만 간다. 그 이상은 GPU 2장 이상에서 한다.
#
# 무엇을 보게 되는가:
#   - 하나였던 Deployment 가 prefill / decode 둘로 갈라진다
#   - 두 워크로드를 가르는 것은 llm-d.ai/role 라벨 하나다
#   - decode 파드에 라우팅 사이드카가 붙는다
#   - vLLM 에 --kv-transfer-config 로 NIXL 커넥터가 들어간다

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_config
require_cmd git kubectl

SRC="${LAB_GENERATED}/llm-d-${LLMD_VERSION}"
if [[ ! -d "$SRC/.git" ]]; then
  log "llm-d ${LLMD_VERSION} 체크아웃 (읽기 전용, ${SRC})"
  git clone --depth 1 --branch "$LLMD_VERSION" "$LLMD_REPO_URL" "$SRC" \
    || die "llm-d 저장소를 받지 못했습니다."
else
  log "이미 받아 둔 체크아웃 사용: $SRC"
fi

# 레시피 base 가 아니라 가이드 오버레이를 렌더한다. NIXL 커넥터 설정과 실제
# vLLM 인자는 오버레이 쪽에 있어서, base 만 보면 정작 중요한 줄이 안 나온다.
PD_BASE="${SRC}/guides/pd-disaggregation/modelserver/gpu/vllm/base"
[[ -d "$PD_BASE" ]] || die "P/D 오버레이 경로가 없습니다: $PD_BASE (llm-d 버전이 바뀌었을 수 있습니다)"

RENDERED="${LAB_GENERATED}/pd-rendered.yaml"
log "P/D 매니페스트 렌더 (적용하지 않음)"
kubectl kustomize "$PD_BASE" > "$RENDERED" \
  || die "kustomize 렌더 실패: $PD_BASE"

observe "1 — 하나였던 워크로드가 둘로 갈라진다"
grep -nE '^kind: (Deployment|Service|ServiceAccount)$' -A 3 "$RENDERED" \
  | grep -E 'kind:|name:' | sed 's/^/  /'
echo
echo "지금 우리 랩에는 decode 하나뿐이다:"
kubectl -n "$NAMESPACE" get deployment -L llm-d.ai/role 2>/dev/null | sed 's/^/  /'

observe "2 — 두 풀을 가르는 것은 라벨 하나다"
grep -nE 'llm-d\.ai/role' "$RENDERED" | sed 's/^/  /' | head -20
echo
echo "EPP 는 이 라벨로 'prefill 담당'과 'decode 담당'을 구분해 각각 고른다."
echo "글 7장의 'EPP 가 decode 워커와 prefill 워커를 각각 골라준다' 가 이것이다."

observe "3 — KV 캐시를 풀 사이로 옮기는 설정"
grep -nE 'kv-transfer-config|NixlConnector|kv_role|name: nixl|containerPort: 5600' "$RENDERED" \
  | sed 's/^/  /' | head -20 \
  || echo "  (커넥터 설정을 찾지 못했습니다 — $RENDERED 를 직접 열어 보세요)"
echo
echo "이 한 줄이 글에서 말한 '노드 경계를 넘는 고속 전송' 의 입구다."
echo "여기서부터 EC2 placement group, EFA, NeuronLink 같은 이야기가 시작된다."

observe "4 — decode 파드에 붙는 라우팅 사이드카"
# 상류는 이것을 initContainers 에 restartPolicy: Always 로 넣는다 — 즉
# 사이드카 컨테이너다. 이름은 routing-proxy 이고 --kv-connector 를 받는다.
grep -nE 'name: routing-proxy|--kv-connector|restartPolicy: Always' "$RENDERED" \
  | sed 's/^/  /' | head -10 \
  || echo "  (사이드카를 찾지 못했습니다 — $RENDERED 를 직접 열어 보세요)"
echo
echo "전체 렌더 결과는 여기 있다:"
echo "  $RENDERED"

cat <<'NOTE'

정리 — 로컬에서 어디까지 확인했고 어디부터 못 했는가:

  확인함   워크로드가 prefill/decode 로 갈라지는 방식, 라벨로 역할을 나누는 법,
           EPP 가 두 풀을 각각 고른다는 구조, KV 전송 설정이 들어가는 자리

  확인 못 함  실제 KV 전송, 그리고 글이 말한 "처리량 최대 2배, 비용 30~40% 절감".
           이건 GPU 2장 이상과 고속 인터커넥트가 있어야 재현된다. GPU 1장에서
           P/D 를 나누면 전송 오버헤드만 남아 오히려 느려지는 게 정상이다.
NOTE
