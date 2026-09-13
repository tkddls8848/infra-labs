#!/usr/bin/env bash
set -euo pipefail

# KubeVirt 애드온 설치 스크립트 (k8s-master 노드에서 실행)
#
# 매니페스트는 원격 URL에서 내려받지 않고 저장소에 고정(vendored)된
# manifests/ 디렉터리에서만 적용한다. GitHub API로 릴리스 태그를 조회하지
# 않으며, 버전은 아래 KUBEVIRT_VERSION 한 곳에서만 관리한다.

KUBEVIRT_VERSION="v1.8.2"
NODE_NAME="$(hostname)"
READY_TIMEOUT="${KUBEVIRT_READY_TIMEOUT:-600s}"

# Vagrant 동기화 폴더(/vagrant = scripts/addons/kubevirt) 우선,
# 없으면 스크립트 기준 상대 경로로 탐색한다.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_DIR="${KUBEVIRT_MANIFEST_DIR:-}"
if [[ -z "$MANIFEST_DIR" ]]; then
  for candidate in /vagrant/manifests "$SCRIPT_DIR/../manifests"; do
    if [[ -d "$candidate" ]]; then
      MANIFEST_DIR="$(cd "$candidate" && pwd)"
      break
    fi
  done
fi

log()  { echo "[kubevirt][$NODE_NAME] $*"; }
fail() { echo "[kubevirt][$NODE_NAME] FAILED: $*" >&2; exit 1; }

# 고정된 매니페스트의 SHA256. 파일이 교체/손상되면 적용을 중단한다.
OPERATOR_SHA256="57e0822062e6617964fd7e1731f9ace531f8ee34a0e48cf8dd0ccce72196e1d6"
CR_SHA256="43106136dbce3312bdbfdeae612aacafc6c12da518d233f90645b4685d84a2af"
VIRTCTL_SHA256="745f3c58c6a77be65b828e67b6ad930e9039ab293ed5b2bef6d44c8681af5b75"

verify_manifest() {
  local file="$1" expected="$2" actual
  [[ -f "$file" ]] || fail "매니페스트 파일이 없음: $file (저장소의 manifests/ 디렉터리를 확인)"
  [[ -s "$file" ]] || fail "매니페스트 파일이 비어 있음: $file"
  actual="$(sha256sum "$file" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    fail "매니페스트 체크섬 불일치: $file (기대 $expected, 실제 $actual)"
  fi
  log "매니페스트 검증 완료: $(basename "$file")"
}

# 지정한 리소스가 생성될 때까지 대기한다. operator가 virt-api/virt-controller
# 디플로이먼트를 나중에 만들기 때문에, wait 전에 존재 여부를 먼저 확인해야 한다.
wait_for_resource() {
  local kind="$1" name="$2" namespace="$3" timeout="${4:-300}" elapsed=0
  log "$kind/$name 생성 대기 중 (최대 ${timeout}s)"
  while (( elapsed < timeout )); do
    if kubectl -n "$namespace" get "$kind" "$name" >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
    (( elapsed += 5 ))
  done
  fail "$kind/$name 이(가) ${timeout}s 안에 생성되지 않음 (namespace=$namespace)"
}

wait_available() {
  local kind="$1" name="$2" namespace="$3"
  wait_for_resource "$kind" "$name" "$namespace"
  log "$kind/$name Available 대기 중 (최대 $READY_TIMEOUT)"
  if ! kubectl -n "$namespace" wait --for=condition=Available \
      --timeout="$READY_TIMEOUT" "$kind/$name"; then
    kubectl -n "$namespace" get pods -o wide || true
    fail "$kind/$name 이(가) $READY_TIMEOUT 안에 Available 상태가 되지 않음"
  fi
}

command -v kubectl >/dev/null 2>&1 || fail "kubectl 을 찾을 수 없음 (control-plane 초기화 완료 여부 확인)"
[[ -n "$MANIFEST_DIR" ]] || fail "매니페스트 디렉터리를 찾을 수 없음 (/vagrant/manifests 또는 $SCRIPT_DIR/../manifests)"

OPERATOR_MANIFEST="$MANIFEST_DIR/kubevirt-operator.yaml"
CR_MANIFEST="$MANIFEST_DIR/kubevirt-cr.yaml"

log "KubeVirt $KUBEVIRT_VERSION 설치 시작 (매니페스트 경로: $MANIFEST_DIR)"
verify_manifest "$OPERATOR_MANIFEST" "$OPERATOR_SHA256"
verify_manifest "$CR_MANIFEST" "$CR_SHA256"

log "1/4 operator 매니페스트 적용"
kubectl apply -f "$OPERATOR_MANIFEST" \
  || fail "operator 매니페스트 적용 실패: $OPERATOR_MANIFEST"

log "2/4 virt-operator 기동 확인"
wait_available deployment virt-operator kubevirt

log "3/4 KubeVirt CR 적용"
kubectl apply -f "$CR_MANIFEST" \
  || fail "KubeVirt CR 적용 실패: $CR_MANIFEST"

log "4/4 KubeVirt 컴포넌트 기동 확인"
# CR 의 Available 조건이 서면 operator 가 하위 컴포넌트 배포를 마친 상태다.
if ! kubectl -n kubevirt wait --for=condition=Available \
    --timeout="$READY_TIMEOUT" kubevirt/kubevirt; then
  kubectl -n kubevirt get kubevirt kubevirt -o yaml || true
  kubectl -n kubevirt get pods -o wide || true
  fail "KubeVirt CR 이 $READY_TIMEOUT 안에 Available 상태가 되지 않음"
fi
wait_available deployment virt-api kubevirt
wait_available deployment virt-controller kubevirt

# virtctl 설치 (고정 버전 바이너리)
VIRTCTL_URL="https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/virtctl-${KUBEVIRT_VERSION}-linux-amd64"
log "virtctl $KUBEVIRT_VERSION 다운로드"
TMP_VIRTCTL="$(mktemp)"
trap 'rm -f "$TMP_VIRTCTL"' EXIT
curl -fsSL --retry 3 -o "$TMP_VIRTCTL" "$VIRTCTL_URL" \
  || fail "virtctl 다운로드 실패: $VIRTCTL_URL"
[[ -s "$TMP_VIRTCTL" ]] || fail "virtctl 다운로드 결과가 비어 있음: $VIRTCTL_URL"
VIRTCTL_ACTUAL_SHA256="$(sha256sum "$TMP_VIRTCTL" | awk '{print $1}')"
if [[ "$VIRTCTL_ACTUAL_SHA256" != "$VIRTCTL_SHA256" ]]; then
  fail "virtctl 체크섬 불일치 (기대 $VIRTCTL_SHA256, 실제 $VIRTCTL_ACTUAL_SHA256)"
fi
install -m 0755 "$TMP_VIRTCTL" /usr/local/bin/virtctl \
  || fail "virtctl 설치 실패: /usr/local/bin/virtctl"
rm -f "$TMP_VIRTCTL"
trap - EXIT

log "KubeVirt $KUBEVIRT_VERSION 설치 완료"
kubectl -n kubevirt get pods -o wide
