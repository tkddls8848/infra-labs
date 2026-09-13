#!/usr/bin/env bash
set -euo pipefail

MASTER_IP="${1:?master ip is required}"
NETWORK_PREFIX="${2:?network prefix is required}"
WORKER_LENGTH="${3:?worker length is required}"
KUBE_VERSION="${4:?kubernetes version is required}"
KUBE_MINOR_VERSION="v$(echo "$KUBE_VERSION" | sed -E 's/^v?([0-9]+\.[0-9]+).*/\1/')"
KUBE_DEB_VERSION="${KUBE_VERSION#v}-1.1"

echo "[kubeadm] common node setup"

ufw disable || true
systemctl stop ufw 2>/dev/null || true
systemctl disable ufw 2>/dev/null || true

grep -q "$MASTER_IP k8s-master" /etc/hosts || echo "$MASTER_IP k8s-master" >> /etc/hosts
for ((i=1; i<=WORKER_LENGTH; i++)); do
  worker_ip="${NETWORK_PREFIX}.$((i + 10))"
  worker_name="k8s-worker-$i"
  grep -q "$worker_ip $worker_name" /etc/hosts || echo "$worker_ip $worker_name" >> /etc/hosts
done

cat >/etc/modules-load.d/containerd.conf <<EOF
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

cat >/etc/sysctl.d/99-kubernetes-cri.conf <<EOF
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
EOF
sysctl --system

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y containerd curl apt-transport-https ca-certificates gpg

mkdir -p /etc/containerd
containerd config default >/etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl enable containerd
systemctl restart containerd

swapoff -a
# swap 항목만, 미주석 라인에 한해 1회 주석 처리.
# 기존 '/swap/s/^/#/' 는 "swap" 문자열이 포함된 무관 라인까지 건드리고
# 재실행 시 '#'가 누적됨. 단어 경계(\bswap\b) + 미주석([^#]) 매칭으로 멱등 처리.
# (동일 저장소 GPU용 02_node_setup.sh의 패턴과 통일)
sed -i '/\bswap\b/s/^[^#]/#&/' /etc/fstab

install -m 0755 -d /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${KUBE_MINOR_VERSION}/deb/Release.key" \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBE_MINOR_VERSION}/deb/ /" \
  >/etc/apt/sources.list.d/kubernetes.list

apt-get update
if ! apt-cache madison kubeadm | awk '{print $3}' | grep -qx "$KUBE_DEB_VERSION"; then
  echo "Requested kubeadm package version is not available: $KUBE_DEB_VERSION" >&2
  exit 1
fi

DEBIAN_FRONTEND=noninteractive apt-get install -y \
  "kubelet=$KUBE_DEB_VERSION" \
  "kubeadm=$KUBE_DEB_VERSION" \
  "kubectl=$KUBE_DEB_VERSION"
apt-mark hold kubelet kubeadm kubectl

echo "[kubeadm] common node setup complete"