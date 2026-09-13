#!/bin/bash
# BeeGFS CSI 설치 — 커널 모듈 빌드 + kustomize
# 실행 위치: EC2 #1 (frontend)
# 필수 환경변수: BACKEND_PRIVATE_IP
set -e
export PATH="/usr/local/bin:/usr/local/sbin:$PATH"
export KUBECONFIG="${KUBECONFIG:-/home/ec2-user/.kube/config}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFEST_DIR="${SCRIPT_DIR}/manifests"

: "${BACKEND_PRIVATE_IP:?필수: BACKEND_PRIVATE_IP}"

echo "=============================="
echo " [1/3] 필수 패키지 및 커널 모듈 준비"
echo "=============================="
# 아래 항목들은 Packer AMI에 사전 설치됨 — 없을 경우 fallback 설치

# git (Packer AMI 사전 설치)
if ! command -v git &>/dev/null; then
  dnf install -y git
fi

# BeeGFS 8 저장소 (Packer AMI에 사전 설정)
if [ ! -f /etc/yum.repos.d/beegfs.repo ]; then
  BEEGFS_VERSION="8.3"
  curl -fsSL "https://www.beegfs.io/release/beegfs_${BEEGFS_VERSION}/dists/beegfs-rhel9.repo" \
    -o /etc/yum.repos.d/beegfs.repo \
  || curl -fsSL "https://www.beegfs.io/release/beegfs_${BEEGFS_VERSION}/dists/beegfs-el9.repo" \
    -o /etc/yum.repos.d/beegfs.repo
fi

# beegfs-client, beegfs-utils, beegfs-tools (Packer AMI 사전 설치)
if ! rpm -q beegfs-client &>/dev/null; then
  dnf install -y beegfs-client beegfs-utils beegfs-tools || {
    echo "❌ beegfs-client 설치 실패."; dnf repolist all; exit 1
  }
fi

# beegfs.ko — Packer AMI에서 사전 빌드됨, 없을 경우에만 빌드
INSTALL_PATH="/lib/modules/$(uname -r)/updates/fs/beegfs_autobuild/beegfs.ko"
if [ ! -f "$INSTALL_PATH" ]; then
  echo "  beegfs.ko 미발견 — fallback 빌드 ($(uname -r))..."
  dnf install -y "kernel-devel-$(uname -r)" || {
    echo "❌ kernel-devel-$(uname -r) 설치 실패."
    dnf list available 'kernel-devel-*' 2>/dev/null | head -10
    exit 1
  }
  BUILD_DIR="/opt/beegfs/src/client/client_module_8/build"
  [ -d "$BUILD_DIR" ] || { echo "❌ BeeGFS 빌드 디렉토리 없음: $BUILD_DIR"; exit 1; }
  rm -f "${BUILD_DIR}/feature-detect.cache"
  make -C "$BUILD_DIR" BEEGFS_NO_RDMA=1 || { make -C "$BUILD_DIR" BEEGFS_NO_RDMA=1 | tail -50; exit 1; }
  KO_FILE=$(find /opt/beegfs/src/client/client_module_8/source -name "beegfs.ko" 2>/dev/null | head -1)
  [ -z "$KO_FILE" ] && { echo "❌ beegfs.ko 없음."; exit 1; }
  mkdir -p "$(dirname "$INSTALL_PATH")"
  install -m644 "$KO_FILE" "$INSTALL_PATH"
  depmod -a
else
  echo "  beegfs.ko 사전 빌드 확인 (Packer AMI): $INSTALL_PATH"
fi

modprobe beegfs 2>/dev/null || insmod "$INSTALL_PATH" 2>/dev/null || true
if ! lsmod | grep -q "^beegfs"; then
  echo "❌ beegfs.ko 로드 실패."
  dmesg | tail -20
  exit 1
fi
echo "  beegfs.ko 로드 확인: $(lsmod | grep ^beegfs | awk '{print $1, $2}')"

echo "=============================="
echo " [2/3] BeeGFS CSI v1.8.0 설치"
echo "=============================="
BEEGFS_CSI_VERSION="v1.8.0"
# Packer AMI에 사전 클론됨 — 없을 경우 fallback 클론
if [ -d /opt/beegfs-csi-driver ]; then
  cp -r /opt/beegfs-csi-driver /tmp/beegfs-csi-driver
elif [ ! -d /tmp/beegfs-csi-driver ]; then
  git clone --depth 1 --branch "${BEEGFS_CSI_VERSION}" \
    https://github.com/ThinkParQ/beegfs-csi-driver.git /tmp/beegfs-csi-driver \
  || git clone --depth 1 \
    https://github.com/ThinkParQ/beegfs-csi-driver.git /tmp/beegfs-csi-driver
fi

cat > "${MANIFEST_DIR}/beegfs-csi/csi-beegfs-config.yaml" <<EOF
# BACKEND_PRIVATE_IP 로 자동 생성
# connAuthFile: disabled — 백엔드가 auth-disable=true 이므로 클라이언트도 인증 비활성화
config:
  beegfsClientConf:
    connDisableAuthentication: "true"
fileSystemSpecificConfigs:
  - sysMgmtdHost: ${BACKEND_PRIVATE_IP}
    config:
      beegfsClientConf:
        connDisableAuthentication: "true"
EOF

cat > "${MANIFEST_DIR}/beegfs-csi/storageclass-beegfs.yaml" <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: beegfs-scratch
provisioner: beegfs.csi.netapp.com
parameters:
  sysMgmtdHost: ${BACKEND_PRIVATE_IP}
  volDirBasePath: /k8s/dynamic
reclaimPolicy: Delete
volumeBindingMode: Immediate
allowVolumeExpansion: false
EOF

cp "${MANIFEST_DIR}/beegfs-csi/csi-beegfs-config.yaml" \
  /tmp/beegfs-csi-driver/deploy/k8s/overlays/default/csi-beegfs-config.yaml

kubectl apply -k /tmp/beegfs-csi-driver/deploy/k8s/overlays/default

echo "  BeeGFS CSI 롤아웃 대기..."
kubectl rollout status statefulset/csi-beegfs-controller -n beegfs-csi --timeout=180s
kubectl rollout status daemonset/csi-beegfs-node         -n beegfs-csi --timeout=180s

kubectl apply -f "${MANIFEST_DIR}/beegfs-csi/storageclass-beegfs.yaml"

echo "=============================="
echo " [3/3] 결과 확인"
echo "=============================="
kubectl get storageclass | grep -E "NAME|beegfs"
echo ""
echo "✅ BeeGFS CSI 설치 완료 — StorageClass: beegfs-scratch"
