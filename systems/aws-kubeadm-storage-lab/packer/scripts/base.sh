#!/bin/bash
# 공통 베이스: swap off, 커널 모듈, sysctl, 공통 패키지
set -e
export DEBIAN_FRONTEND=noninteractive

# swap off
swapoff -a
sed -i '/swap/d' /etc/fstab

# 공통 패키지
apt-get update -qq
apt-get install -y \
  curl ca-certificates gnupg git \
  nfs-common open-iscsi \
  python3 python3.12 \
  conntrack socat nftables

# nftables 활성화
systemctl enable nftables
systemctl start nftables

# 커널 모듈
cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
nf_tables
nft_masq
EOF
modprobe overlay br_netfilter nf_tables nft_masq

# sysctl
cat > /etc/sysctl.d/99-k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system
