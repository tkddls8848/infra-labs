#!/usr/bin/env bash
set -euo pipefail

MASTER_IP="${1:?master ip is required}"
POD_CIDR="${2:?pod cidr is required}"
FLANNEL_VERSION="${3:?flannel version is required}"
KUBE_VERSION="${4:?kubernetes version is required}"
JOIN_FILE="${5:?join file path is required}"

if [[ "$POD_CIDR" != "10.244.0.0/16" ]]; then
  echo "Flannel manifest is used without sed patching; POD_CIDR must be 10.244.0.0/16." >&2
  exit 1
fi

echo "[kubeadm] control-plane init"
kubeadm config images pull --kubernetes-version="$KUBE_VERSION"
kubeadm init \
  --apiserver-advertise-address="$MASTER_IP" \
  --pod-network-cidr="$POD_CIDR" \
  --kubernetes-version="$KUBE_VERSION"

mkdir -p /home/vagrant/.kube
cp /etc/kubernetes/admin.conf /home/vagrant/.kube/config
chown -R vagrant:vagrant /home/vagrant/.kube

mkdir -p "$HOME/.kube"
cp /etc/kubernetes/admin.conf "$HOME/.kube/config"

kubectl apply -f "https://github.com/flannel-io/flannel/releases/download/${FLANNEL_VERSION}/kube-flannel.yml"

mkdir -p "$(dirname "$JOIN_FILE")"
kubeadm token create --print-join-command > "$JOIN_FILE"
chmod 0755 "$JOIN_FILE"

echo "[kubeadm] join command written to $JOIN_FILE"
