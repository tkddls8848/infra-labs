#!/usr/bin/env bash
# 90_rollback.sh — 단계별 선택 롤백
#
# 단계 번호를 주면 그 단계를 실행하기 이전 상태로 되돌린다. 해당 단계를 포함해
# 이후 단계가 모두 역순으로 제거된다 — 이 저장소의 local-kubeadm-gpu/06_rollback.sh
# 와 같은 방식이다.
#
#   90_rollback.sh              메뉴를 띄운다
#   90_rollback.sh 04           04단계(라우터) 이전으로. 모델 서버는 남는다
#   90_rollback.sh 01 --yes     전체 제거, 확인 없이
#   90_rollback.sh results      실습 결과 JSON 만 지운다 (클러스터 무변화)
#
# 이 랩은 기존 K3s 클러스터를 빌려 쓴다. 그래서 롤백에는 두 가지 원칙이 있다.
#
#   1. K3s 자체는 어느 경우에도 건드리지 않는다.
#      클러스터까지 지우려면: sudo /usr/local/bin/k3s-uninstall.sh
#
#   2. 네임스페이스 밖의 리소스(kube-system 의 device plugin, 클러스터 스코프
#      CRD)는 이 랩이 만든 것으로 표시된 경우에만 지운다. 원래 있던 것은
#      남긴다 — 다른 워크로드가 쓰고 있을 수 있다.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_config
require_cmd kubectl

ASSUME_YES=0
CHOICE=""
for arg in "$@"; do
  case "$arg" in
    --yes|-y) ASSUME_YES=1 ;;
    *)        CHOICE="$arg" ;;
  esac
done

GAIE_CRD="inferencepools.inference.networking.k8s.io"

# ── 각 단계의 역작업 ─────────────────────────────────────────────────────────

undo_07() {
  # 07 은 읽기 전용이었다. 클러스터에 남긴 것이 없고 받아 둔 체크아웃만 지운다.
  local src="${LAB_GENERATED}/llm-d-${LLMD_VERSION}"
  if [[ -d "$src" ]]; then
    log "07 되돌리기 — llm-d 체크아웃 삭제 ($src)"
    rm -rf "$src"
  fi
  rm -f "${LAB_GENERATED}/pd-rendered.yaml"
}

undo_06() {
  # 06 은 끝나면서 스스로 되돌린다. 하지만 Ctrl-C 나 helm 실패로 낮춘 값이
  # 남아 있을 수 있으므로 여기서 확실히 기본값으로 되돌린다.
  local chart
  chart="$(ls "${LAB_GENERATED}/charts"/llm-d-router-standalone-*.tgz 2>/dev/null | head -1 || true)"
  if [[ -z "$chart" ]] || ! helm -n "$NAMESPACE" status "$RELEASE_NAME" >/dev/null 2>&1; then
    log "06 되돌리기 — 라우터가 설치돼 있지 않다. 건너뛴다."
    rm -f "${LAB_GENERATED}/router-values-saturated.yaml"
    return 0
  fi
  log "06 되돌리기 — peakPrefillThroughput 를 ${PEAK_PREFILL_THROUGHPUT} 로 복원"
  render_manifest "${LAB_MANIFESTS}/router-values.yaml" "${LAB_GENERATED}/router-values.yaml"
  helm upgrade "$RELEASE_NAME" "$chart" -n "$NAMESPACE" \
    -f "${LAB_GENERATED}/router-values.yaml" --wait --timeout 5m >/dev/null \
    || warn "복원에 실패했습니다. 04_router_up.sh 를 다시 돌리세요."
  rm -f "${LAB_GENERATED}/router-values-saturated.yaml"
}

undo_results() {
  local f found=0
  for f in "${LAB_GENERATED}"/result-*.json; do
    [[ -e "$f" ]] || continue
    found=1
    rm -f "$f"
  done
  [[ "$found" -eq 1 ]] && log "실습 결과 JSON 삭제" || log "지울 실습 결과가 없다."
}

undo_04() {
  if command -v helm >/dev/null 2>&1 && helm -n "$NAMESPACE" status "$RELEASE_NAME" >/dev/null 2>&1; then
    log "04 되돌리기 — helm 릴리스 제거: $RELEASE_NAME"
    helm -n "$NAMESPACE" uninstall "$RELEASE_NAME" --wait --timeout 5m \
      || warn "helm uninstall 실패 — 남은 리소스를 직접 확인하세요."
  else
    log "04 되돌리기 — helm 릴리스가 없다. 건너뛴다."
  fi

  # CRD 는 우리가 만든 것일 때만 지운다.
  if resource_exists crd "$GAIE_CRD"; then
    if lab_owns crd "$GAIE_CRD"; then
      log "InferencePool CRD 제거 (이 랩이 만든 것)"
      kubectl delete crd "$GAIE_CRD" --wait=true || warn "CRD 삭제 실패"
    else
      log "InferencePool CRD 는 이 랩이 만든 것이 아니다 — 남긴다."
    fi
  fi

  rm -f "${LAB_GENERATED}/router-rendered.yaml" "${LAB_GENERATED}/router-values.yaml"
}

undo_02() {
  if kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    log "02 되돌리기 — 네임스페이스 삭제: $NAMESPACE"
    echo "  (Deployment, Service, PVC, 그리고 내려받은 모델 가중치까지 함께 사라진다)"
    kubectl delete namespace "$NAMESPACE" --wait=true --timeout=5m \
      || warn "네임스페이스 삭제가 끝나지 않았습니다. 'kubectl get ns $NAMESPACE' 로 확인하세요."
  else
    log "02 되돌리기 — 네임스페이스가 없다. 건너뛴다."
  fi
  rm -f "${LAB_GENERATED}/vllm-decode.yaml"
}

undo_01() {
  local removed=0
  if resource_exists -n kube-system daemonset nvidia-device-plugin-daemonset; then
    if lab_owns -n kube-system daemonset nvidia-device-plugin-daemonset; then
      log "01 되돌리기 — device plugin DaemonSet 제거"
      kubectl -n kube-system delete daemonset nvidia-device-plugin-daemonset --wait=true \
        || warn "DaemonSet 삭제 실패"
      removed=1
    else
      log "01 되돌리기 — device plugin 이 이 랩 것이 아니다. 남긴다."
    fi
  fi
  if resource_exists -n kube-system configmap nvidia-device-plugin-config \
     && lab_owns -n kube-system configmap nvidia-device-plugin-config; then
    kubectl -n kube-system delete configmap nvidia-device-plugin-config --wait=true \
      || warn "ConfigMap 삭제 실패"
    removed=1
  fi
  rm -f "${LAB_GENERATED}/nvidia-device-plugin.yaml"

  if [[ "$removed" -eq 1 ]]; then
    echo
    echo "  노드의 nvidia.com/gpu capacity 가 사라진다. 이 노드에서 GPU 를 쓰던"
    echo "  다른 워크로드가 있었다면 그쪽도 스케줄되지 않는다."
    echo "  이 랩을 다시 하려면 01_gpu_timeslicing.sh 부터."
  fi
}

# ── 단계 정의 ───────────────────────────────────────────────────────────────
# 각 항목: 번호|설명|남는 것
declare -a STEPS=(
  "01|GPU 공유 설정 이전 (= 전체 제거)|K3s 클러스터, RuntimeClass"
  "02|모델 서버 이전|GPU 공유 설정"
  "04|라우터 이전|모델 서버와 평범한 Service — 실습 A 는 계속 가능"
  "06|포화 실험 이전|라우터 설정을 기본값으로 복원"
  "07|P/D 해부 이전|받아 둔 llm-d 체크아웃만 삭제"
)

run_rollback() {
  case "$1" in
    07) undo_07 ;;
    06) undo_07; undo_06 ;;
    04) undo_07; undo_06; undo_results; undo_04 ;;
    02) undo_07; undo_06; undo_results; undo_04; undo_02 ;;
    01) undo_07; undo_06; undo_results; undo_04; undo_02; undo_01 ;;
    results) undo_results ;;
    *) die "알 수 없는 단계: $1" ;;
  esac
}

describe() {
  case "$1" in
    01) echo "01단계(GPU 공유) 이전 = 이 랩이 만든 것 전부 제거" ;;
    02) echo "02단계(모델 서버) 이전 — 라우터·네임스페이스·모델 가중치 삭제, GPU 공유는 유지" ;;
    04) echo "04단계(라우터) 이전 — 라우터만 걷어낸다. 모델 서버는 남는다" ;;
    06) echo "06단계(포화 실험) 이전 — 라우터 설정을 기본값으로 되돌린다" ;;
    07) echo "07단계(P/D 해부) 이전 — 받아 둔 체크아웃만 삭제. 클러스터 무변화" ;;
    results) echo "실습 결과 JSON 만 삭제. 클러스터 무변화" ;;
  esac
}

# ── 메뉴 ────────────────────────────────────────────────────────────────────
if [[ -z "$CHOICE" ]]; then
  echo
  echo "=== 추론 랩 단계별 롤백 ==="
  echo
  echo "  번호를 입력하면 해당 단계 실행 이전 상태로 되돌립니다."
  echo "  (해당 단계를 포함해 이후 단계가 역순으로 제거됩니다)"
  echo
  for entry in "${STEPS[@]}"; do
    IFS='|' read -r num desc keep <<< "$entry"
    printf '  %s : %-28s 남는 것: %s\n' "$num" "$desc" "$keep"
  done
  echo "  r  : 실습 결과 JSON 만 삭제      남는 것: 클러스터 전부"
  echo
  read -rp "어느 단계 이전까지 되돌리시겠습니까? (01/02/04/06/07, r, q=취소): " CHOICE
  [[ "$CHOICE" == "q" || -z "$CHOICE" ]] && { echo "취소했습니다."; exit 0; }
  [[ "$CHOICE" == "r" ]] && CHOICE="results"
fi

# 01, 1, results 등을 정규화한다.
case "$CHOICE" in
  1|01)      CHOICE="01" ;;
  2|02)      CHOICE="02" ;;
  4|04)      CHOICE="04" ;;
  6|06)      CHOICE="06" ;;
  7|07)      CHOICE="07" ;;
  r|results) CHOICE="results" ;;
  all)       CHOICE="01" ;;
  *) die "알 수 없는 단계: $CHOICE  (01/02/04/06/07, results, all 중 하나)" ;;
esac

observe "되돌릴 범위"
describe "$CHOICE"
echo
echo "K3s 클러스터 자체는 건드리지 않는다."
echo "네임스페이스 밖의 리소스는 이 랩이 만든 것으로 표시된 경우에만 지운다."

if [[ "$ASSUME_YES" -ne 1 ]]; then
  echo
  read -rp "진행할까요? (yes/N): " CONFIRM
  [[ "$CONFIRM" == "yes" ]] || { echo "취소했습니다."; exit 0; }
fi

run_rollback "$CHOICE"

observe "남은 상태"
kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 \
  && kubectl -n "$NAMESPACE" get deployment,svc 2>/dev/null | sed 's/^/  /' \
  || echo "  네임스페이스 $NAMESPACE 없음"
NODE="$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -n "$NODE" ]]; then
  echo "  노드 nvidia.com/gpu capacity: $(kubectl get node "$NODE" \
    -o jsonpath='{.status.capacity.nvidia\.com/gpu}' 2>/dev/null || echo '(없음)')"
fi

log "롤백 완료."
