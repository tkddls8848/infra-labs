#!/usr/bin/env bash
# 01_gpu_timeslicing.sh — GPU 1장을 nvidia.com/gpu N개로 쪼개 광고한다.
#
# 글의 "GPU 공유(time-slicing·MPS·MIG)" 에 해당하는 단계다. 이걸 켜야 vLLM
# 레플리카 여러 개가 물리 GPU 한 장 위에 스케줄되고, 그래야 '랜덤 분산 vs
# 캐시 인지 라우팅' 비교가 성립한다.
#
# 실습 포인트: 적용 전후로 노드의 nvidia.com/gpu capacity 가 1 → N 으로 바뀐다.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_config
require_cmd kubectl awk

NODE="$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')"
[[ -n "$NODE" ]] || die "노드를 찾을 수 없습니다."

gpu_capacity() {
  kubectl get node "$NODE" -o jsonpath='{.status.capacity.nvidia\.com/gpu}' 2>/dev/null
}

observe "적용 전 노드의 GPU capacity"
echo "노드: $NODE"
echo "nvidia.com/gpu capacity = $(gpu_capacity || echo '(없음 — device plugin 미설치)')"

# 이 랩은 기존 K3s 클러스터를 빌려 쓴다. kube-system 에 이미 다른 것이 관리하는
# device plugin 이 있을 수 있다 (GPU Operator, 다른 랩, 수동 설치). 덮어쓰면
# 그쪽이 조용히 망가지므로 먼저 확인한다.
claim_or_refuse -n kube-system daemonset nvidia-device-plugin-daemonset \
  "kube-system 의 DaemonSet/nvidia-device-plugin-daemonset"
claim_or_refuse -n kube-system configmap nvidia-device-plugin-config \
  "kube-system 의 ConfigMap/nvidia-device-plugin-config"

render_manifest "${LAB_MANIFESTS}/nvidia-device-plugin.yaml" \
                "${LAB_GENERATED}/nvidia-device-plugin.yaml"

log "device plugin 적용 (time-slicing replicas=${GPU_TIME_SLICING_REPLICAS})"
kubectl apply -f "${LAB_GENERATED}/nvidia-device-plugin.yaml"

# 롤백이 '우리가 만든 것만' 지울 수 있도록 표시를 남긴다.
mark_owned -n kube-system daemonset nvidia-device-plugin-daemonset
mark_owned -n kube-system configmap nvidia-device-plugin-config

# ConfigMap 만 바뀐 경우 DaemonSet 파드는 그대로 남아 예전 설정을 계속 쓴다.
# 재적용을 반복해도 결과가 같도록 항상 한 번 굴린다.
log "DaemonSet 재시작해 새 설정을 읽게 한다"
kubectl -n kube-system rollout restart daemonset/nvidia-device-plugin-daemonset
kubectl -n kube-system rollout status daemonset/nvidia-device-plugin-daemonset --timeout=180s \
  || die "device plugin 이 뜨지 않았습니다. 'kubectl -n kube-system logs -l name=nvidia-device-plugin-ds' 를 보세요."

# kubelet 이 플러그인의 재등록을 반영해 노드 상태를 갱신할 때까지 기다린다.
log "노드가 새 capacity 를 보고할 때까지 대기…"
for _ in $(seq 1 60); do
  CAP="$(gpu_capacity || true)"
  [[ "$CAP" == "$GPU_TIME_SLICING_REPLICAS" ]] && break
  sleep 2
done

CAP="$(gpu_capacity || echo 0)"
observe "적용 후 노드의 GPU capacity"
kubectl get node "$NODE" -o jsonpath='{.status.capacity.nvidia\.com/gpu}{"\n"}'
echo
echo "물리 GPU 는 그대로 1장이다. 위 숫자는 '동시에 몇 개의 파드에 GPU 를"
echo "줄 수 있는가' 일 뿐, 메모리가 N등분된다는 뜻이 아니다."

if [[ "$CAP" != "$GPU_TIME_SLICING_REPLICAS" ]]; then
  warn "capacity 가 ${GPU_TIME_SLICING_REPLICAS} 이 아니라 '${CAP}' 입니다."
  warn "device plugin 로그를 확인하세요: kubectl -n kube-system logs -l name=nvidia-device-plugin-ds"
  die "GPU 공유 설정이 반영되지 않아 다음 단계로 갈 수 없습니다."
fi

cat <<'NOTE'

되돌리려면:
  scripts/inference/90_rollback.sh 01

NOTE
log "완료. 다음: scripts/inference/02_modelserver_up.sh"
