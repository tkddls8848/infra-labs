#!/usr/bin/bash
# 00_host_setup.sh
# 호스트 KVM 환경 준비
# - Intel/AMD CPU 자동 감지 → IOMMU GRUB 설정
# - KVM/libvirt 설치
# - NVIDIA 드라이버 확인
# - /dev/nvidia* 장치 권한 설정
# - libvirt 네트워크 확인
#
# 실행: bash 00_host_setup.sh
# 완료 후 01_vm_create.sh 실행

set -e

# Pinned for the Ubuntu 24.04 / Kubernetes 1.31 GPU lab. Keep this in sync
# with 02_node_setup.sh and the README version table. The host driver is a
# prerequisite because this bare-metal worker exposes /dev/nvidia* directly.
NVIDIA_DRIVER_PACKAGE="nvidia-driver-550-server"
NVIDIA_DRIVER_PACKAGE_VERSION="550.163.01-0ubuntu0.24.04.1"
NVIDIA_DRIVER_RUNTIME_VERSION="550.163.01"

log()        { echo "[$(date '+%H:%M:%S')] $1"; }
warn()       { echo "[$(date '+%H:%M:%S')] WARNING: $1"; }
error_exit() { echo "❌ ERROR: $1"; exit 1; }

log "=== Phase 0: 호스트 환경 준비 시작 ==="

# ────────────────────────────────────────────
# 1. CPU 제조사 감지 (Intel / AMD)
# ────────────────────────────────────────────
log "1. CPU 제조사 감지 중..."

CPU_VENDOR=$(grep -m1 vendor_id /proc/cpuinfo | awk '{print $3}')
log "   감지된 CPU: $CPU_VENDOR"

case "$CPU_VENDOR" in
  GenuineIntel)
    IOMMU_PARAM="intel_iommu=on iommu=pt"
    VIRT_MODULE="kvm_intel"
    log "   Intel CPU → intel_iommu=on iommu=pt"
    ;;
  AuthenticAMD)
    IOMMU_PARAM="amd_iommu=on iommu=pt"
    VIRT_MODULE="kvm_amd"
    log "   AMD CPU → amd_iommu=on iommu=pt"
    ;;
  *)
    error_exit "지원하지 않는 CPU 제조사: $CPU_VENDOR (Intel/AMD 만 지원)"
    ;;
esac

# ────────────────────────────────────────────
# 2. GRUB IOMMU 파라미터 추가
# ────────────────────────────────────────────
log "2. GRUB IOMMU 설정 확인 중..."

GRUB_FILE="/etc/default/grub"
REBOOT_REQUIRED=false

if grep -q "^GRUB_CMDLINE_LINUX.*iommu" "$GRUB_FILE"; then
  log "   IOMMU 파라미터가 이미 설정되어 있습니다. 스킵"
else
  log "   GRUB에 IOMMU 파라미터 추가: $IOMMU_PARAM"
  # 기존 값이 비어있으면 공백 없이, 있으면 공백 추가
  sudo sed -i \
    "s/GRUB_CMDLINE_LINUX_DEFAULT=\"\(\)/GRUB_CMDLINE_LINUX_DEFAULT=\"$IOMMU_PARAM\"/;t;s/GRUB_CMDLINE_LINUX_DEFAULT=\"\(.*\)\"/GRUB_CMDLINE_LINUX_DEFAULT=\"\1 $IOMMU_PARAM\"/" \
    "$GRUB_FILE"
  sudo update-grub
  REBOOT_REQUIRED=true
  log "   GRUB 업데이트 완료"
fi

# ────────────────────────────────────────────
# 3. 가상화 지원 확인
# ────────────────────────────────────────────
log "3. 가상화 지원 확인 중..."

grep -qE '(vmx|svm)' /proc/cpuinfo \
  || error_exit "CPU가 가상화를 지원하지 않습니다. BIOS에서 VT-x/AMD-V를 활성화하세요."

log "   CPU 가상화 지원 확인 완료"

# ────────────────────────────────────────────
# 4. KVM / libvirt 패키지 설치
# ────────────────────────────────────────────
log "4. KVM/libvirt 패키지 설치 중..."

sudo apt-get update -y
sudo apt-get install -y \
  qemu-kvm \
  libvirt-daemon-system \
  libvirt-clients \
  bridge-utils \
  virtinst \
  cloud-image-utils \
  cpu-checker \
  nftables

# 사용자 그룹 추가
sudo usermod -aG libvirt,kvm "$USER"
log "   $USER 를 libvirt, kvm 그룹에 추가 완료"

# KVM 사용 가능 확인
sudo kvm-ok || error_exit "KVM을 사용할 수 없습니다. BIOS에서 가상화를 활성화하세요."

# nftables 먼저 시작 (libvirtd보다 먼저 올라와야 backend 전환이 유효함)
sudo systemctl enable --now nftables 2>/dev/null || true
log "   nftables 서비스 활성화 완료"

# libvirtd 시작 전 nftables 백엔드 설정
# Ubuntu 24.04는 nftables 사용 → 먼저 설정해야 첫 시작부터 올바른 백엔드 사용
LIBVIRT_NET_CONF="/etc/libvirt/network.conf"
sudo mkdir -p /etc/libvirt
# 파일 전체를 덮어써서 주석 라인 매칭 실패나 중복 항목 문제를 방지
sudo tee "$LIBVIRT_NET_CONF" > /dev/null <<'EOF'
firewall_backend = "nftables"
EOF
log "   libvirt firewall_backend = nftables 설정 완료 ($LIBVIRT_NET_CONF)"

# libvirtd 시작/재시작 (설정 변경 반영을 위해 restart 사용)
sudo systemctl enable libvirtd
sudo systemctl restart libvirtd
# libvirtd가 완전히 뜰 때까지 대기 (소켓 준비 확인)
for i in $(seq 1 10); do
  sudo virsh list --all > /dev/null 2>&1 && break
  sleep 1
done
log "   libvirtd 재시작 완료 (nftables 백엔드 적용)"

# ────────────────────────────────────────────
# 5. NVIDIA 드라이버 확인
# ────────────────────────────────────────────
log "5. NVIDIA 드라이버 확인 중..."

nvidia-smi > /dev/null 2>&1 \
  || error_exit "NVIDIA 드라이버가 로드되지 않았습니다. Ubuntu 24.04에서 'sudo apt install ${NVIDIA_DRIVER_PACKAGE}=${NVIDIA_DRIVER_PACKAGE_VERSION}' 실행 후 재부팅하세요."

DRIVER_VERSION=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)
DRIVER_MAJOR=$(echo "$DRIVER_VERSION" | cut -d. -f1)
GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
INSTALLED_DRIVER_PACKAGE_VERSION="$(dpkg-query -W -f='${Version}' "$NVIDIA_DRIVER_PACKAGE" 2>/dev/null || true)"

[[ "$DRIVER_VERSION" == "$NVIDIA_DRIVER_RUNTIME_VERSION" ]] \
  || error_exit "NVIDIA driver $DRIVER_VERSION is loaded, but this lab pins $NVIDIA_DRIVER_RUNTIME_VERSION (${NVIDIA_DRIVER_PACKAGE}=${NVIDIA_DRIVER_PACKAGE_VERSION}). Refusing a mixed-version setup."
[[ "$INSTALLED_DRIVER_PACKAGE_VERSION" == "$NVIDIA_DRIVER_PACKAGE_VERSION" ]] \
  || error_exit "$NVIDIA_DRIVER_PACKAGE package version mismatch (expected $NVIDIA_DRIVER_PACKAGE_VERSION, got ${INSTALLED_DRIVER_PACKAGE_VERSION:-not-installed})."

log "   GPU: $GPU_NAME"
log "   드라이버 버전: $DRIVER_VERSION (major: $DRIVER_MAJOR)"

# 드라이버 버전을 VM 생성 스크립트가 참조할 수 있도록 저장
sudo mkdir -p "/var/lib/libvirt/images/k8s-setup"
sudo tee "/var/lib/libvirt/images/k8s-setup/host_info.env" > /dev/null <<EOF
CPU_VENDOR=$CPU_VENDOR
VIRT_MODULE=$VIRT_MODULE
DRIVER_VERSION=$DRIVER_VERSION
DRIVER_MAJOR=$DRIVER_MAJOR
GPU_NAME="$GPU_NAME"
EOF
log "   호스트 정보 저장: /var/lib/libvirt/images/k8s-setup/host_info.env"

# ────────────────────────────────────────────
# 6. /dev/nvidia* 장치 권한 설정
# ────────────────────────────────────────────
log "6. /dev/nvidia* 장치 권한 설정 중..."

ls /dev/nvidia* > /dev/null 2>&1 \
  || error_exit "/dev/nvidia* 장치를 찾을 수 없습니다."

log "   발견된 장치:"
ls -la /dev/nvidia* | while read -r line; do log "     $line"; done

# libvirt가 장치에 접근할 수 있도록 권한 추가
for dev in /dev/nvidia*; do
  sudo chmod 0666 "$dev"
done

# udev rule 추가 (재부팅 후에도 권한 유지)
sudo tee /etc/udev/rules.d/99-nvidia-libvirt.rules > /dev/null <<'EOF'
KERNEL=="nvidia*", MODE="0666"
EOF
sudo udevadm control --reload-rules
sudo udevadm trigger --subsystem-match=char 2>/dev/null || true
log "   udev rule 추가 완료 (재부팅 후에도 유지)"

# ────────────────────────────────────────────
# 7. libvirt 기본 네트워크 확인 및 NAT 영구 설정
# ────────────────────────────────────────────
log "7. libvirt 네트워크 확인 중..."

if ! sudo virsh net-list --all | grep -q "default"; then
  warn "default 네트워크가 없습니다. 재생성 중..."
  sudo virsh net-define /usr/share/libvirt/networks/default.xml 2>/dev/null \
    || error_exit "default 네트워크 정의 실패. /usr/share/libvirt/networks/default.xml 확인하세요."
fi

# ip_forward 영구 활성화 (net-start 전에 설정해야 포워딩 가능)
sudo sysctl -w net.ipv4.ip_forward=1 > /dev/null
if ! grep -q 'net.ipv4.ip_forward' /etc/sysctl.d/99-libvirt-nat.conf 2>/dev/null; then
  echo 'net.ipv4.ip_forward = 1' | sudo tee /etc/sysctl.d/99-libvirt-nat.conf > /dev/null
fi
log "   ip_forward 활성화 완료"

# libvirt default 네트워크 서브넷 동적 감지 (net-start 전에 수행: 정의만 있으면 가능)
log "   호스트 인터넷 인터페이스: $(ip route | awk '/^default/{print $5; exit}')"

LIBVIRT_SUBNET=$(sudo virsh net-dumpxml default 2>/dev/null \
  | grep -oP 'address="\K[0-9.]+' | head -1)
LIBVIRT_PREFIX=$(sudo virsh net-dumpxml default 2>/dev/null \
  | grep -oP "prefix=\"\K[0-9]+" | head -1)
# prefix 없으면 netmask로 변환
if [[ -z "$LIBVIRT_PREFIX" ]]; then
  NETMASK=$(sudo virsh net-dumpxml default 2>/dev/null \
    | grep -oP "netmask=\"\K[0-9.]+" | head -1)
  LIBVIRT_PREFIX=$(python3 -c \
    "import ipaddress; print(ipaddress.IPv4Network('0.0.0.0/${NETMASK:-255.255.255.0}').prefixlen)" \
    2>/dev/null || echo "24")
fi
LIBVIRT_NET="${LIBVIRT_SUBNET:-192.168.122.0}/${LIBVIRT_PREFIX:-24}"
log "   libvirt 네트워크 서브넷: $LIBVIRT_NET"

# nftables 백업 NAT 규칙 항상 저장
# - libvirt가 net-start 시 자체 nftables 규칙(masquerade)을 추가하지만
#   재부팅 시 서비스 시작 타이밍에 따라 규칙이 없을 수 있음
# - libvirt_helper 테이블은 libvirt 규칙과 독립적으로 NAT를 보장하는 폴백
# - nftables.service는 libvirtd보다 먼저 시작(Before=network.target)되므로
#   부팅 시 libvirt_helper가 먼저 로드되고 libvirt가 자체 규칙을 추가함 → 충돌 없음
sudo mkdir -p /etc/nftables.d
sudo tee /etc/nftables.d/99-libvirt-nat.nft > /dev/null << EOF
table ip libvirt_helper {
  chain postrouting {
    type nat hook postrouting priority srcnat;
    ip saddr ${LIBVIRT_NET} oif != "virbr0" masquerade
  }
  chain forward {
    type filter hook forward priority filter;
    iif "virbr0" oif != "virbr0" accept
    iif != "virbr0" oif "virbr0" ct state related,established accept
  }
}
EOF

if ! grep -q 'nftables.d' /etc/nftables.conf 2>/dev/null; then
  echo 'include "/etc/nftables.d/*.nft"' | sudo tee -a /etc/nftables.conf > /dev/null
fi
# nftables 서비스는 위에서 이미 활성화됨 — 설정 파일만 reload
sudo systemctl reload-or-restart nftables 2>/dev/null || true
log "   nftables NAT 백업 규칙 저장 완료 (/etc/nftables.d/99-libvirt-nat.nft)"

# 현재 세션에 live 규칙 즉시 적용 (net-start 전 시점 기준으로 확인)
if ! sudo nft list ruleset 2>/dev/null | grep -q "libvirt_helper"; then
  sudo nft add table ip libvirt_helper 2>/dev/null || true
  sudo nft add chain ip libvirt_helper postrouting \
    '{ type nat hook postrouting priority srcnat; }' 2>/dev/null || true
  sudo nft add rule ip libvirt_helper postrouting \
    ip saddr "$LIBVIRT_NET" oif != "virbr0" masquerade 2>/dev/null || true
  sudo nft add chain ip libvirt_helper forward \
    '{ type filter hook forward priority filter; }' 2>/dev/null || true
  sudo nft add rule ip libvirt_helper forward \
    iif "virbr0" oif != "virbr0" accept 2>/dev/null || true
  sudo nft add rule ip libvirt_helper forward \
    iif != "virbr0" oif "virbr0" ct state related,established accept 2>/dev/null || true
  log "   libvirt_helper 테이블 live 적용 완료"
fi

# 이미 실행 중이면 재시작하여 libvirt nftables 규칙 재적용
# ⚠️ net-destroy는 연결된 VM 네트워크를 일시 단절함 (초기 설정 단계에서만 실행 권장)
if sudo virsh net-list | grep -q "default.*active"; then
  sudo virsh net-destroy default 2>/dev/null || true
fi
sudo virsh net-start default \
  || error_exit "default 네트워크 시작 실패. 'sudo virsh net-start default' 수동 확인하세요."
sudo virsh net-autostart default 2>/dev/null || true
log "   libvirt default 네트워크 활성화 완료"

# ────────────────────────────────────────────
# 완료
# ────────────────────────────────────────────
log "=== Phase 0 완료 ==="
echo ""
echo "   CPU: $CPU_VENDOR | GPU: $GPU_NAME | 드라이버: $DRIVER_VERSION"
echo ""

if [[ "$REBOOT_REQUIRED" == "true" ]]; then
  echo "⚠️  GRUB이 변경되었습니다. 재부팅 후 01_vm_create.sh를 실행하세요."
  read -rp "지금 재부팅하시겠습니까? (y/N): " resp
  [[ "$resp" =~ ^[yY]$ ]] && sudo reboot || echo "수동으로 재부팅 후 계속 진행하세요."
else
  echo "다음 단계: bash 01_vm_create.sh"
fi
