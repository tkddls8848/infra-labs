#!/bin/bash
# Packer 공통 base 스크립트 — RHEL 9
# - swap off, 커널 모듈, sysctl, firewalld 비활성화
# - 커널 고정 불필요: BeeGFS 8이 RHEL 9 기본 커널(5.14.x) 공식 지원
set -e

# swap off
swapoff -a
sed -i '/swap/d' /etc/fstab

# firewalld 비활성화 (k3s + cephadm 포트 충돌 방지)
systemctl disable --now firewalld 2>/dev/null || true

# 공통 패키지
dnf install -y curl ca-certificates

# 커널 모듈
modprobe overlay br_netfilter
cat > /etc/modules-load.d/k3s.conf <<EOF
overlay
br_netfilter
EOF

# sysctl
cat > /etc/sysctl.d/99-k3s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system
