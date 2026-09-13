#!/bin/bash
# Master: containerd 1.7.22 + kubeadm/kubelet/kubectl 1.31 설치
set -e
export DEBIAN_FRONTEND=noninteractive

K8S_VERSION="1.31"
CONTAINERD_VERSION="1.7.22-1"

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

# containerd 설정
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

echo "master AMI 패키지 설치 완료 (containerd + kubeadm/kubelet/kubectl)"
