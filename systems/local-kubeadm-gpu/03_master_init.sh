#!/usr/bin/env bash
# 03_master_init.sh
# Master VM에서 실행: kubeadm init → Flannel CNI → worker join 명령 생성
#
# ── 매니페스트 정책 (devops/docs/kubernetes-review-fix-list.md) ─────────────
#   * CNI 매니페스트 버전은 고정하고, apply 전에 반드시 검증한다.
#   * 우선순위 1: 저장소에 vendoring된 사본(manifests/)을 sha256 검증 후 적용한다.
#   * 우선순위 2: 사본이 없으면 고정 URL에서 "파일로" 내려받아 동일한 sha256으로
#                검증한 뒤 적용한다.
#   * 어느 경로든 검증 실패 시 apply하지 않고 즉시 실패한다.
#     → `kubectl apply -f <URL>` 로 미검증 원격 매니페스트를 직접 적용하지 않는다.
#   * 내려받은 매니페스트를 sed 등으로 수정하지 않는다. 매니페스트에 내장된
#     네트워크와 POD_CIDR이 다르면 매니페스트를 고치지 말고 실패시킨다.
#
# ── 파괴적 동작 정책 ──────────────────────────────────────────────────────
#   * 이 스크립트는 kubeadm reset 등 파괴적 동작을 수행하지 않는다.
#     기존 kubeadm 상태가 남아 있으면 정리하지 않고 실패한다. 정리는 06_rollback.sh.

set -euo pipefail

SINGLE_NODE="${SINGLE_NODE:-false}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
K8S_SETUP_DIR="$HOME/k8s-setup"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── 고정 버전 (README의 버전 표와 반드시 함께 갱신할 것) ────────────────────
# FLANNEL_MANIFEST_SHA256은 FLANNEL_VERSION에 종속된 값이다.
# 버전을 올릴 때는 manifests/ 사본, SHA256SUMS, 아래 상수를 한 번에 갱신한다.
FLANNEL_VERSION="v0.28.5"
FLANNEL_MANIFEST_SHA256="ad73016448206826206907084982b8ec50ef49be5db91badb673bca64007d8f3"
FLANNEL_MANIFEST_URL="https://github.com/flannel-io/flannel/releases/download/${FLANNEL_VERSION}/kube-flannel.yml"
# kube-flannel.yml의 net-conf.json에 내장된 네트워크 값.
# POD_CIDR과 반드시 일치해야 한다 (불일치 시 Pod 네트워크가 동작하지 않는다).
FLANNEL_MANIFEST_NETWORK="10.244.0.0/16"

log()        { echo "[$(date '+%H:%M:%S')] $1"; }
error_exit() { echo "ERROR: $1" >&2; exit 1; }

# ────────────────────────────────────────────
# 매니페스트 검증 헬퍼
# ────────────────────────────────────────────

# vendoring된 매니페스트 탐색 경로:
#   1) MANIFEST_DIR 환경변수
#   2) 스크립트와 같은 위치의 manifests/  (호스트에서 저장소 체크아웃으로 실행할 때)
#   3) $HOME/manifests/                   (01_vm_create.sh가 VM에 배포한 위치)
find_vendored_manifest() {
  local name="$1" dir
  for dir in ${MANIFEST_DIR:+"$MANIFEST_DIR"} "$SCRIPT_DIR/manifests" "$HOME/manifests"; do
    if [[ -f "$dir/$name" ]]; then
      printf '%s\n' "$dir/$name"
      return 0
    fi
  done
  return 1
}

verify_sha256() {
  local file="$1" want="$2" got
  command -v sha256sum >/dev/null 2>&1 \
    || error_exit "sha256sum not found; cannot verify manifest before applying."
  got="$(sha256sum "$file" | awk '{print $1}')"
  [[ "$got" == "$want" ]] \
    || error_exit "manifest checksum mismatch for $file (expected $want, got $got). Refusing to apply."
}

# 검증이 끝난 로컬 파일 경로를 stdout으로 반환한다.
resolve_manifest() {
  local name="$1" url="$2" want_sha="$3" path
  if path="$(find_vendored_manifest "$name")"; then
    verify_sha256 "$path" "$want_sha"
    log "manifest verified (vendored): $path" >&2
  else
    path="$(mktemp "${TMPDIR:-/tmp}/${name}.XXXXXX")"
    log "manifest not vendored locally; downloading pinned URL: $url" >&2
    curl -fsSL --retry 3 --retry-delay 2 -o "$path" "$url" \
      || error_exit "manifest download failed: $url"
    verify_sha256 "$path" "$want_sha"
    log "manifest verified (downloaded): $path" >&2
  fi
  [[ -s "$path" ]] || error_exit "manifest is empty: $path"
  grep -q '^kind:' "$path" || error_exit "manifest does not look like Kubernetes YAML: $path"
  printf '%s\n' "$path"
}

# ────────────────────────────────────────────
# 사전 확인
# ────────────────────────────────────────────
log "Phase 3: master init"
log "single node mode: $SINGLE_NODE"

kubeadm version >/dev/null 2>&1 || error_exit "kubeadm not found. Run 02_node_setup.sh first."
systemctl is-active --quiet containerd || error_exit "containerd is not active."

# 파괴적 reset은 06_rollback.sh에만 둔다. 여기서는 명확히 실패시킨다.
if [[ -f /etc/kubernetes/admin.conf || -f /etc/kubernetes/kubelet.conf ]]; then
  error_exit "Existing kubeadm state found on this node. Run 06_rollback.sh (option 03) before initializing again."
fi

# POD_CIDR과 매니페스트 내장 네트워크 일치 확인 (매니페스트를 수정하는 대신 실패)
if [[ "$POD_CIDR" != "$FLANNEL_MANIFEST_NETWORK" ]]; then
  error_exit "POD_CIDR ($POD_CIDR) does not match the network baked into kube-flannel ${FLANNEL_VERSION} ($FLANNEL_MANIFEST_NETWORK). Editing the downloaded manifest is not allowed; use a matching POD_CIDR or vendor a manifest built for it."
fi

# kubeadm init 전에 매니페스트를 먼저 확보/검증한다.
# (init 후에 검증 실패로 멈추면 클러스터가 CNI 없이 반쯤 올라간 상태로 남는다)
FLANNEL_MANIFEST="$(resolve_manifest \
  "kube-flannel-${FLANNEL_VERSION}.yml" \
  "$FLANNEL_MANIFEST_URL" \
  "$FLANNEL_MANIFEST_SHA256")"

# ────────────────────────────────────────────
# kubeadm init
# ────────────────────────────────────────────
sudo kubeadm init \
  --pod-network-cidr="$POD_CIDR" \
  --cri-socket=unix:///run/containerd/containerd.sock \
  | tee /tmp/kubeadm_init.log

mkdir -p "$HOME/.kube"
sudo cp /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"

# ────────────────────────────────────────────
# Flannel CNI (검증 완료된 로컬 파일에서 적용)
# ────────────────────────────────────────────
log "applying flannel ${FLANNEL_VERSION} from verified file: $FLANNEL_MANIFEST"
kubectl apply -f "$FLANNEL_MANIFEST"

if [[ "$SINGLE_NODE" == "true" ]]; then
  kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true
else
  log "multi-node mode: keeping control-plane taint"
fi

mkdir -p "$K8S_SETUP_DIR"
kubeadm token create --print-join-command | tee "$K8S_SETUP_DIR/worker_join.sh"
chmod +x "$K8S_SETUP_DIR/worker_join.sh"

log "waiting for master Ready state"
for i in $(seq 1 36); do
  status="$(kubectl get nodes --no-headers 2>/dev/null | awk '{print $2}' | head -1 || true)"
  echo "  [$i/36] node status: ${status:-Initializing}"
  [[ "$status" == "Ready" ]] && break
  sleep 5
done

kubectl get nodes -o wide
echo "Worker join command:"
cat "$K8S_SETUP_DIR/worker_join.sh"
