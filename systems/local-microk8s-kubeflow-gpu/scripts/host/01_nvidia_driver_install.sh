#!/usr/bin/bash
# NVIDIA Driver Installation Script for Kubeflow GPU
# Ubuntu OS에서 NVIDIA 드라이버 설치
# 사용: bash 01_nvidia_driver_install.sh [--reboot]

set -euo pipefail

NVIDIA_DRIVER_PACKAGE="nvidia-driver-550-server"
NVIDIA_DRIVER_PACKAGE_VERSION="550.163.01-0ubuntu0.24.04.1"
NVIDIA_DRIVER_RUNTIME_VERSION="550.163.01"

## blacklist nouveau
sudo tee /etc/modules-load.d/ipmi.conf <<< "ipmi_msghandler"
sudo tee /etc/modprobe.d/blacklist-nouveau.conf <<< "blacklist nouveau"
sudo tee -a /etc/modprobe.d/blacklist-nouveau.conf <<< "options nouveau modeset=0"
sudo update-initramfs -u

## 드라이버가 이미 정상 동작 중이면 재설치 스킵
# (일괄 'nvidia*' purge는 nvidia-container-toolkit까지 제거될 수 있어 위험)
if command -v nvidia-smi &> /dev/null && nvidia-smi &> /dev/null; then
    driver_version="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | sed -n '1p')"
    package_version="$(dpkg-query -W -f='${Version}' "$NVIDIA_DRIVER_PACKAGE" 2>/dev/null || true)"
    [[ "$driver_version" == "$NVIDIA_DRIVER_RUNTIME_VERSION" ]] \
        || { echo "ERROR: NVIDIA runtime $driver_version detected; expected $NVIDIA_DRIVER_RUNTIME_VERSION." >&2; exit 1; }
    [[ "$package_version" == "$NVIDIA_DRIVER_PACKAGE_VERSION" ]] \
        || { echo "ERROR: $NVIDIA_DRIVER_PACKAGE package is ${package_version:-not-installed}; expected $NVIDIA_DRIVER_PACKAGE_VERSION." >&2; exit 1; }
    echo "✅ 고정 NVIDIA 드라이버가 이미 동작 중입니다. 설치를 건너뜁니다."
    nvidia-smi --query-gpu=name,driver_version --format=csv,noheader
    exit 0
fi

## 정상 설치 경로는 기존 드라이버를 제거하지 않는다. 충돌 상태는 명확히 실패하고
## 운영자가 원인을 확인한 뒤 lifecycle/destroy 또는 수동 복구를 선택하게 한다.
if dpkg -l | grep -qE '^ii\s+nvidia-driver-'; then
    echo "ERROR: NVIDIA driver packages exist but nvidia-smi is not healthy. Refusing to purge drivers in the normal install path." >&2
    exit 1
fi

## Install the exact Ubuntu 24.04 driver package.
sudo apt-get update
available_driver_versions="$(apt-cache madison "$NVIDIA_DRIVER_PACKAGE" | awk '{print $3}')"
grep -Fxq "$NVIDIA_DRIVER_PACKAGE_VERSION" <<<"$available_driver_versions" \
    || { echo "ERROR: $NVIDIA_DRIVER_PACKAGE=$NVIDIA_DRIVER_PACKAGE_VERSION is unavailable." >&2; exit 1; }
sudo apt-get install -y "${NVIDIA_DRIVER_PACKAGE}=${NVIDIA_DRIVER_PACKAGE_VERSION}"
sudo apt-mark hold "$NVIDIA_DRIVER_PACKAGE"

echo "✅ NVIDIA 드라이버 설치 완료"
echo "⚠️  NVIDIA 드라이버 적용을 위해 시스템 재부팅이 필요합니다."

## 재부팅 처리: --reboot 플래그(자동화용) 또는 tty에서만 대화형 질문
if [[ "${1:-}" == "--reboot" ]]; then
    echo "시스템을 재부팅합니다..."
    sudo init 6
elif [[ -t 0 ]]; then
    read -rp "재부팅을 진행하시겠습니까? (y/N) " response
    if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
        echo "시스템을 재부팅합니다..."
        sudo init 6
    else
        echo "재부팅을 건너뜁니다. 수동으로 재부팅 후 다음 스크립트를 실행하세요."
    fi
else
    echo "재부팅을 건너뜁니다. 수동으로 재부팅 후 다음 스크립트를 실행하세요."
    echo "(자동 재부팅하려면 --reboot 플래그를 사용하세요.)"
fi
