#!/usr/bin/env bash
set -euo pipefail

# Kubernetes requires swap to be disabled so kubelet can enforce pod memory limits reliably.
sudo swapoff -a
sudo sed -ri '/[[:space:]]swap[[:space:]]/s/^#?/#/' /etc/fstab

# Kubernetes networking needs bridged traffic to traverse netfilter after every reboot.
printf '%s\n' br_netfilter | sudo tee /etc/modules-load.d/kubernetes.conf >/dev/null
sudo modprobe br_netfilter

# Flannel and Kubernetes Services require bridged packet filtering and IPv4 forwarding.
cat <<'EOF' | sudo tee /etc/sysctl.d/kubernetes.conf >/dev/null
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF
sudo sysctl --system

# Kubespray and the CNI use the tc utility supplied by Rocky Linux 9 BaseOS.
sudo dnf install -y iproute-tc

# NetworkManager remains enabled because it owns the Vagrant interfaces and their DNS state.
# /etc/resolv.conf remains NetworkManager/DHCP-managed; public DNS would break local resolution.

echo "Kubernetes node prerequisites configured"
