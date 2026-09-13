#!/bin/bash
# Worker: 커널 6.8 설치 + GRUB 설정 (재부팅 전 단계)
# BeeGFS 7.4.6은 커널 6.11까지만 지원 — 6.8로 다운그레이드 필요
set -e
export DEBIAN_FRONTEND=noninteractive

apt-get update -qq

# 커널 6.8 패키지 탐색 및 설치
IMG=$(apt-cache search 'linux-image-6\.8.*-aws' | awk '{print $1}' | sort -V | tail -1)
HDR=$(apt-cache search 'linux-headers-6\.8.*-aws' | awk '{print $1}' | sort -V | tail -1)
[ -z "$IMG" ] && { echo "ERROR: linux-image-6.8.*-aws 패키지 없음"; exit 1; }
apt-get install -y "$IMG" "$HDR"

# 설치된 6.8 커널 버전 문자열
KERNEL_68=$(dpkg -l | grep 'linux-image-6\.8.*-aws' \
  | awk '{print $2}' | sed 's/linux-image-//' | sort -V | tail -1)
echo "설치된 6.8 커널: ${KERNEL_68}"

# GRUB 기본값을 6.8로 설정
sed -i "s|^GRUB_DEFAULT=.*|GRUB_DEFAULT=\"Advanced options for Ubuntu>Ubuntu, with Linux ${KERNEL_68}\"|" \
  /etc/default/grub
update-grub

CURRENT_KERNEL=$(uname -r)

# [1/5] APT preferences — 6.8 외 커널 패키지 설치 자체를 차단
cat > /etc/apt/preferences.d/kernel-68-pin <<EOF
Package: linux-image-6.8.*-aws linux-headers-6.8.*-aws linux-modules-6.8.*-aws linux-modules-extra-6.8.*-aws
Pin: release *
Pin-Priority: 1001

Package: linux-image-*-aws linux-headers-*-aws linux-modules-*-aws linux-modules-extra-*-aws
Pin: release *
Pin-Priority: -1
EOF

# [2/5] apt-mark hold — 6.8 커널 명시적 보호
apt-mark hold \
  "linux-image-${KERNEL_68}" \
  "linux-headers-${KERNEL_68}" 2>/dev/null || true

# [3/5] 구버전/고버전 커널 완전 제거 (DKMS 불필요한 빌드 방지 포함)
apt-get remove -y --purge \
  "linux-image-${CURRENT_KERNEL}" \
  "linux-headers-${CURRENT_KERNEL}" \
  "linux-modules-${CURRENT_KERNEL}" \
  "linux-modules-extra-${CURRENT_KERNEL}" 2>/dev/null || true
apt-get autoremove -y

# [4/5] GRUB — savedefault 비활성화 (grub-reboot 무력화)
grep -q '^GRUB_SAVEDEFAULT=' /etc/default/grub \
  && sed -i 's|^GRUB_SAVEDEFAULT=.*|GRUB_SAVEDEFAULT=false|' /etc/default/grub \
  || echo 'GRUB_SAVEDEFAULT=false' >> /etc/default/grub
update-grub

# [5/5] Unattended-upgrades 커널 자동 업그레이드 차단
mkdir -p /etc/apt/apt.conf.d
cat > /etc/apt/apt.conf.d/99-no-kernel-upgrade <<EOF
Unattended-Upgrade::Package-Blacklist {
    "linux-image";
    "linux-headers";
    "linux-modules";
    "linux-modules-extra";
};
EOF

echo "  hold 목록:"; apt-mark showhold | grep linux
echo "커널 6.8 설치 완료 — 재부팅 후 BeeGFS 모듈 빌드 진행"
