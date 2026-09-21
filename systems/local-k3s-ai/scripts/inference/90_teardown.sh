#!/usr/bin/env bash
# 90_teardown.sh — 랩이 만든 것을 걷어낸다.
#
# 기본 동작은 이 랩의 네임스페이스만 지운다. 클러스터 전체에 영향을 주는 것들
# (CRD, device plugin) 은 다른 워크로드가 같이 쓰고 있을 수 있으므로 명시적으로
# 요구할 때만 건드린다 — 이 저장소의 파괴적 작업 정책과 같은 방식이다.
#
#   90_teardown.sh              네임스페이스만 삭제
#   90_teardown.sh --all        + GAIE CRD + device plugin + 받아 둔 파일까지
#
# K3s 자체는 건드리지 않는다. 클러스터까지 지우려면:
#   sudo /usr/local/bin/k3s-uninstall.sh

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_config
require_cmd kubectl

DEEP=0
[[ "${1:-}" == "--all" ]] && DEEP=1

if kubectl -n "$NAMESPACE" get deployment >/dev/null 2>&1; then
  if command -v helm >/dev/null 2>&1 && helm -n "$NAMESPACE" status "$RELEASE_NAME" >/dev/null 2>&1; then
    log "helm 릴리스 제거: $RELEASE_NAME"
    helm -n "$NAMESPACE" uninstall "$RELEASE_NAME" --wait --timeout 5m || warn "helm uninstall 실패 — 네임스페이스 삭제로 이어갑니다."
  fi
  log "네임스페이스 삭제: $NAMESPACE"
  # PVC 와 그 안의 모델 가중치도 같이 사라진다. 다시 올리면 다시 받는다.
  kubectl delete namespace "$NAMESPACE" --wait=true --timeout=5m || warn "네임스페이스 삭제가 끝나지 않았습니다."
else
  log "네임스페이스 $NAMESPACE 가 없습니다 — 건너뜁니다."
fi

if [[ "$DEEP" -eq 1 ]]; then
  warn "--all: 클러스터 공용 리소스까지 제거합니다."

  if kubectl get crd inferencepools.inference.networking.k8s.io >/dev/null 2>&1; then
    log "InferencePool CRD 제거"
    kubectl delete crd inferencepools.inference.networking.k8s.io --wait=true || warn "CRD 삭제 실패"
  fi

  if kubectl -n kube-system get daemonset nvidia-device-plugin-daemonset >/dev/null 2>&1; then
    log "NVIDIA device plugin 과 time-slicing 설정 제거"
    kubectl -n kube-system delete daemonset nvidia-device-plugin-daemonset --wait=true || warn "DaemonSet 삭제 실패"
    kubectl -n kube-system delete configmap nvidia-device-plugin-config --ignore-not-found
    echo "  → 노드의 nvidia.com/gpu capacity 가 사라진다. 다른 GPU 워크로드가"
    echo "    이 노드를 쓰고 있었다면 01_gpu_timeslicing.sh 로 다시 올려야 한다."
  fi

  if [[ -d "$LAB_GENERATED" ]]; then
    log "생성물 삭제: $LAB_GENERATED"
    echo "  (렌더된 매니페스트, 받아 둔 차트, 실습 결과 JSON, llm-d 체크아웃)"
    rm -rf "$LAB_GENERATED"
  fi
fi

log "정리 완료."
