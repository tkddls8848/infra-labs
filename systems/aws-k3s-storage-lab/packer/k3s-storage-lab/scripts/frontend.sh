#!/bin/bash
# Packer frontend 스크립트 — RHEL 9
# - k3s 바이너리 사전 설치 (서비스 등록 X)
# - k3s-selinux 패키지 설치
# - BeeGFS 8 클라이언트 패키지 설치 (자체 빌드 시스템, DKMS 미사용)
# - helm 바이너리 사전 설치
# - BeeGFS CSI driver 사전 클론 (v1.8.0)
# - ceph-csi helm repo 사전 캐시
set -e

K3S_VERSION="v1.32.3+k3s1"
BEEGFS_CSI_VERSION="v1.8.0"

# SELinux 의존 패키지
dnf install -y container-selinux selinux-policy-base

# k3s-selinux RPM 설치
dnf install -y https://rpm.rancher.io/k3s/latest/common/centos/9/noarch/k3s-selinux-1.6-1.el9.noarch.rpm \
  || dnf install -y k3s-selinux 2>/dev/null || true

# k3s 바이너리만 다운로드 (서비스 등록 X)
# INSTALL_K3S_SKIP_START=true: 설치 후 서비스 시작 안 함
# INSTALL_K3S_SKIP_ENABLE=true: systemd enable 안 함
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="${K3S_VERSION}" \
  INSTALL_K3S_SKIP_START=true \
  INSTALL_K3S_SKIP_ENABLE=true \
  sh -

echo "k3s 바이너리 설치 완료 (서비스 등록 제외)"
/usr/local/bin/k3s --version

# BeeGFS 8 YUM 저장소 추가
BEEGFS_VERSION="8.3"
curl -fsSL "https://www.beegfs.io/release/beegfs_${BEEGFS_VERSION}/dists/beegfs-rhel9.repo" \
  -o /etc/yum.repos.d/beegfs.repo \
|| curl -fsSL "https://www.beegfs.io/release/beegfs_${BEEGFS_VERSION}/dists/beegfs-el9.repo" \
  -o /etc/yum.repos.d/beegfs.repo

# BeeGFS 8 클라이언트 패키지 설치
# BeeGFS 8은 DKMS 미사용 — 자체 빌드 시스템(/opt/beegfs/src/client/client_module_8/build/)
# kernel-devel은 실행 중인 커널과 정확히 일치해야 빌드 가능
# beegfs-tools: /usr/sbin/beegfs Go CLI 제공 — BeeGFS 8 CSI driver 필수
dnf install -y "kernel-devel-$(uname -r)" beegfs-client beegfs-utils beegfs-tools

# Packer 단계에서 커널 모듈 사전 빌드 (AMI에 포함)
# BEEGFS_NO_RDMA=1: EC2에 ib_core.ko 없음 — RDMA 심볼 제외
BUILD_DIR="/opt/beegfs/src/client/client_module_8/build"
rm -f "${BUILD_DIR}/feature-detect.cache"
make -C "$BUILD_DIR" BEEGFS_NO_RDMA=1
KO_FILE=$(find /opt/beegfs/src/client/client_module_8/source -name beegfs.ko | head -1)
# updates/ 경로에 설치 (beegfs-client 패키지 기본 경로이자 extra/ 보다 우선순위 높음)
INSTALL_PATH="/lib/modules/$(uname -r)/updates/fs/beegfs_autobuild/beegfs.ko"
mkdir -p "$(dirname "$INSTALL_PATH")"
install -m644 "$KO_FILE" "$INSTALL_PATH"
depmod -a
echo "beegfs.ko 사전 빌드 완료 (RDMA 비활성화): $KO_FILE"

# helm 바이너리 설치
# get-helm-3 스크립트는 설치 후 PATH 검증에서 실패할 수 있으므로 직접 설치
HELM_VERSION="v3.17.3"
curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" -o /tmp/helm.tar.gz
tar -zxf /tmp/helm.tar.gz -C /tmp
install -m755 /tmp/linux-amd64/helm /usr/local/bin/helm
rm -rf /tmp/helm.tar.gz /tmp/linux-amd64
/usr/local/bin/helm version --short

# ceph-csi helm repo 사전 캐시 (런타임 repo add 스킵)
export PATH=$PATH:/usr/local/bin
helm repo add ceph-csi https://ceph.github.io/csi-charts
helm repo update

# BeeGFS CSI driver 사전 클론 (런타임 git clone 스킵)
dnf install -y git
git clone --depth 1 --branch "${BEEGFS_CSI_VERSION}" \
  https://github.com/ThinkParQ/beegfs-csi-driver.git /opt/beegfs-csi-driver

echo "frontend AMI 패키지 설치 완료"
