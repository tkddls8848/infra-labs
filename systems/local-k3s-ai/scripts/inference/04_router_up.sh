#!/usr/bin/env bash
# 04_router_up.sh — 모델 서버 앞에 llm-d 라우터(Envoy + EPP)를 세운다.
#
# 글 5장의 구성요소 세 개가 여기서 다 생긴다.
#   Router        = Envoy 사이드카(프록시) + EPP(결정)
#   InferencePool = 같은 모델을 서빙하는 파드들을 라벨로 묶은 것
#   Model Server  = 02 단계에서 이미 올린 vLLM 파드들 (그대로 둔다)
#
# 모델 서버는 손대지 않는다. 앞단만 바뀐다 — 그래야 03 단계와 비교가 된다.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_config
require_cmd kubectl helm curl sha256sum

kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 \
  || die "네임스페이스 $NAMESPACE 가 없습니다. 먼저 02_modelserver_up.sh 를 돌리세요."

# ── 1. InferencePool CRD ────────────────────────────────────────────────────
# Gateway API Inference Extension. InferencePool 은 표준 리소스이고, llm-d 는
# 그 구현 중 하나일 뿐이다 — 글에서 말한 "상류 표준을 따른다"가 이 부분이다.
observe "1단계 — InferencePool CRD (Gateway API Inference Extension ${GAIE_VERSION})"
GAIE_CRD="inferencepools.inference.networking.k8s.io"

# CRD 는 클러스터 스코프다. 이미 다른 설치본이 쓰고 있다면 버전을 바꿔 끼우는
# 순간 그쪽의 기존 InferencePool 들이 스키마와 어긋날 수 있다. 남의 것은 건드리지
# 않고 그대로 쓴다 — 롤백도 우리가 만든 것만 지운다.
if resource_exists crd "$GAIE_CRD" && ! lab_owns crd "$GAIE_CRD"; then
  warn "InferencePool CRD 가 이미 있고 이 랩이 만든 것이 아닙니다. 그대로 사용합니다."
  warn "버전이 다르면 라우터 설치가 실패할 수 있습니다:"
  kubectl get crd "$GAIE_CRD" \
    -o custom-columns='CRD:.metadata.name,VERSIONS:.spec.versions[*].name' >&2
  warn "이 CRD 는 롤백 대상에서 제외됩니다 (다른 워크로드가 쓰고 있을 수 있음)."
else
  GAIE_FILE="${LAB_GENERATED}/gaie-${GAIE_VERSION}-v1-manifests.yaml"
  fetch_verified "GAIE" "$GAIE_MANIFEST_URL" "$GAIE_MANIFEST_SHA256" "$GAIE_FILE"
  kubectl apply -f "$GAIE_FILE"
  mark_owned crd "$GAIE_CRD"
fi
kubectl get crd "$GAIE_CRD" \
  -o custom-columns='CRD:.metadata.name,GROUP:.spec.group,VERSIONS:.spec.versions[*].name'

# ── 2. 라우터 차트 ──────────────────────────────────────────────────────────
# OCI 레지스트리에서 받아 sha256 을 대조한 뒤, 검증한 그 파일로 설치한다.
# helm install 이 레지스트리를 다시 찾아가게 두면 검증한 것과 설치한 것이
# 다를 수 있다.
observe "2단계 — llm-d 라우터 차트 ${ROUTER_CHART_VERSION} 내려받아 검증"
CHART_DIR="${LAB_GENERATED}/charts"
mkdir -p "$CHART_DIR"
CHART_TGZ="$(ls "${CHART_DIR}"/llm-d-router-standalone-*.tgz 2>/dev/null | head -1 || true)"
if [[ -z "$CHART_TGZ" ]] || [[ "$(sha256sum "$CHART_TGZ" | awk '{print $1}')" != "$ROUTER_CHART_SHA256" ]]; then
  rm -f "${CHART_DIR}"/llm-d-router-standalone-*.tgz
  log "helm pull ${ROUTER_CHART} --version ${ROUTER_CHART_VERSION}"
  helm pull "$ROUTER_CHART" --version "$ROUTER_CHART_VERSION" -d "$CHART_DIR" \
    || die "차트를 받지 못했습니다. helm 3.8 이상인지, ghcr.io 로 나갈 수 있는지 확인하세요."
  CHART_TGZ="$(ls "${CHART_DIR}"/llm-d-router-standalone-*.tgz | head -1)"
fi
GOT="$(sha256sum "$CHART_TGZ" | awk '{print $1}')"
[[ "$GOT" == "$ROUTER_CHART_SHA256" ]] \
  || die "차트 checksum 불일치 (기대 $ROUTER_CHART_SHA256, 실제 $GOT). 설치를 중단합니다."
log "차트 검증 완료: $GOT"

render_manifest "${LAB_MANIFESTS}/router-values.yaml" "${LAB_GENERATED}/router-values.yaml"

# ── 3. 설치 전에 무엇이 만들어지는지 먼저 읽는다 ────────────────────────────
# 실습의 목적이 '구조 확인'이므로 helm install 로 블랙박스에 넣기 전에
# 렌더 결과를 파일로 남긴다.
helm template "$RELEASE_NAME" "$CHART_TGZ" \
  -n "$NAMESPACE" -f "${LAB_GENERATED}/router-values.yaml" \
  > "${LAB_GENERATED}/router-rendered.yaml"

observe "3단계 — 차트가 만들 리소스 목록 (설치 전)"
grep -E '^kind: |^  name: ' "${LAB_GENERATED}/router-rendered.yaml" \
  | paste - - 2>/dev/null | sed 's/^/  /' || true
echo
echo "전체 매니페스트는 여기에 있다. 실습 중 언제든 열어 보라:"
echo "  ${LAB_GENERATED}/router-rendered.yaml"

# ── 4. 설치 ─────────────────────────────────────────────────────────────────
log "라우터 설치/갱신"
helm upgrade --install "$RELEASE_NAME" "$CHART_TGZ" \
  -n "$NAMESPACE" \
  -f "${LAB_GENERATED}/router-values.yaml" \
  --wait --timeout 10m \
  || die "차트 설치 실패. 'kubectl -n $NAMESPACE get pods' 와 'helm -n $NAMESPACE status $RELEASE_NAME' 를 보세요."

EPP_DEPLOY="$(kubectl -n "$NAMESPACE" get deployment \
  -l "app.kubernetes.io/instance=${RELEASE_NAME}" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[[ -n "$EPP_DEPLOY" ]] || die "라우터 Deployment 를 찾지 못했습니다."
wait_rollout deployment "$EPP_DEPLOY" 600s

# ── 5. 구조 확인 ────────────────────────────────────────────────────────────
observe "InferencePool — '무엇을 고를 것인가'"
kubectl -n "$NAMESPACE" get inferencepool -o yaml \
  | grep -A 12 '^  spec:' | sed 's/^/  /'
echo
echo "selector 가 02 단계에서 올린 vLLM 파드의 라벨과 같다. Service 와 달리"
echo "이 풀은 '누가 어떤 접두사를 캐시하고 있는가' 를 EPP 가 추적할 대상이다."

observe "라우터 파드 — 한 파드 안에 프록시와 두뇌가 같이 있다"
kubectl -n "$NAMESPACE" get pods -l "app.kubernetes.io/instance=${RELEASE_NAME}" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{range .spec.containers[*]}    - {.name}  ({.image}){"\n"}{end}{end}'
echo
echo "Envoy 는 8081 로 트래픽을 받고, 어디로 보낼지는 localhost:9002 의 EPP 에게"
echo "ext-proc(gRPC)로 물어본다. 답은 x-gateway-destination-endpoint 헤더로 온다."

observe "엔드포인트 — 라우터가 고를 수 있는 모델 서버들"
kubectl -n "$NAMESPACE" get pods -l "llm-d.ai/model=${MODEL_LABEL}" \
  -o custom-columns='POD:.metadata.name,IP:.status.podIP,READY:.status.containerStatuses[0].ready'

cat <<'NOTE'

되돌리려면 (모델 서버는 그대로 두고 라우터만 걷어낸다):
  scripts/inference/90_rollback.sh 04

NOTE
log "완료. 다음: scripts/inference/05_measure_router.sh"
