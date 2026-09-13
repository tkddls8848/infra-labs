#!/bin/bash
# Packer backend 스크립트 — RHEL 9
# - cephadm 설치 (dnf, Ceph Squid v19.2.x)
# - BeeGFS 8 서버 패키지 설치 (beegfs-mgmtd, beegfs-meta, beegfs-storage, beegfs-utils)
# - podman은 RHEL 9 기본 포함 — 별도 설치 불필요
set -e

# nvme-cli, lvm2, xfsprogs (스토리지 디스크 포맷용)
dnf install -y nvme-cli lvm2 xfsprogs

# cephadm 설치 — RHEL 9에는 centos-release-ceph-squid 없음
# Ceph 공식 RPM 저장소(Squid) 설치 후 cephadm 설치
dnf install -y https://download.ceph.com/rpm-squid/el9/noarch/ceph-release-1-1.el9.noarch.rpm
dnf install -y cephadm

echo "cephadm 설치 완료: $(cephadm version 2>/dev/null || true)"

# BeeGFS 8 YUM 저장소 추가
BEEGFS_VERSION="8.3"
curl -fsSL "https://www.beegfs.io/release/beegfs_${BEEGFS_VERSION}/dists/beegfs-rhel9.repo" \
  -o /etc/yum.repos.d/beegfs.repo \
|| curl -fsSL "https://www.beegfs.io/release/beegfs_${BEEGFS_VERSION}/dists/beegfs-el9.repo" \
  -o /etc/yum.repos.d/beegfs.repo

# BeeGFS 8 서버 패키지 (클라이언트 제외 — frontend EC2에서만 필요)
dnf install -y \
  beegfs-mgmtd \
  beegfs-meta \
  beegfs-storage \
  beegfs-utils

echo "backend AMI 패키지 설치 완료"
