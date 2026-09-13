#!/bin/bash
# Worker: containerd + kubeadm + BeeGFS 7.4.6 패키지 + 커널 모듈 빌드
# (커널 6.8 재부팅 후 실행되는 단계)
set -e
export DEBIAN_FRONTEND=noninteractive

K8S_VERSION="1.31"
CONTAINERD_VERSION="1.7.22-1"
BEEGFS_VERSION="7.4.6"

echo "현재 커널: $(uname -r)"

# containerd (Docker APT repo)
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu noble stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -qq
apt-get install -y "containerd.io=${CONTAINERD_VERSION}"
apt-mark hold containerd.io

containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sed -i 's|sandbox_image = "registry.k8s.io/pause:.*"|sandbox_image = "registry.k8s.io/pause:3.10"|' /etc/containerd/config.toml
systemctl enable containerd
systemctl restart containerd

# K8s APT repo
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
  https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list
apt-get update -qq
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
systemctl enable kubelet

# BeeGFS 7.4.6 저장소 + 패키지
BEEGFS_REPO="https://www.beegfs.io/release/beegfs_${BEEGFS_VERSION}"
wget -q "${BEEGFS_REPO}/gpg/GPG-KEY-beegfs" -O /tmp/beegfs.gpg
if grep -q 'BEGIN PGP' /tmp/beegfs.gpg 2>/dev/null; then
  gpg --dearmor < /tmp/beegfs.gpg > /etc/apt/trusted.gpg.d/beegfs.gpg
else
  cp /tmp/beegfs.gpg /etc/apt/trusted.gpg.d/beegfs.gpg
fi
echo "deb [signed-by=/etc/apt/trusted.gpg.d/beegfs.gpg] ${BEEGFS_REPO}/ noble non-free" \
  > /etc/apt/sources.list.d/beegfs.list
apt-get update -qq

# 커널 헤더 (현재 6.8 기준)
apt-get install -y "linux-headers-$(uname -r)" xfsprogs dkms
apt-get install -y beegfs-storage beegfs-client beegfs-helperd beegfs-utils

# BeeGFS 커널 모듈 빌드
BUILD=/opt/beegfs/src/client/client_module_7/build
[ -d "$BUILD" ] || { echo "ERROR: BeeGFS source not found at $BUILD"; exit 1; }
make -C "$BUILD"
install -D -m644 "$BUILD/beegfs.ko" \
  "/lib/modules/$(uname -r)/extra/beegfs/beegfs.ko"
depmod -a

# 부팅 시 자동 로드
echo beegfs > /etc/modules-load.d/beegfs.conf

# HCI 노드 필수 패키지 (Ceph + 스토리지)
apt-get install -y lvm2 chrony linux-modules-extra-aws linux-headers-aws
systemctl enable chrony

# Ceph 커널 모듈 자동 로드 등록 (modprobe는 런타임에 Ansible이 수행)
printf 'rbd\nceph\n' >> /etc/modules-load.d/k8s.conf

echo "worker AMI 패키지 설치 완료 (containerd + kubeadm + BeeGFS 7.4.6 모듈)"
uname -r
