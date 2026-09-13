#!/usr/bin/bash
# Docker and NVIDIA Container Toolkit Installation Script for Kubeflow GPU
# Ubuntu OS에서 Docker 및 NVIDIA Container Toolkit 설치
#
# 참고: MicroK8s는 내장 containerd를 사용하므로 이 Docker 런타임 설정은 MicroK8s
#       클러스터의 GPU 동작과는 무관합니다. 호스트에서의 이미지 빌드 또는 단독
#       GPU 컨테이너 테스트 용도로만 필요하며, 그 용도가 아니면 생략할 수 있습니다.

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive  # 비대화형 설치 보장

DOCKER_VERSION="5:27.5.1-1~ubuntu.24.04~noble"
CONTAINERD_VERSION="1.7.25-1"
BUILDX_VERSION="0.20.0-1~ubuntu.24.04~noble"
COMPOSE_VERSION="2.32.4-1~ubuntu.24.04~noble"
NVIDIA_TOOLKIT_VERSION="1.17.8-1"

## Installing docker and containerd runtime
sudo apt-get update
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
sudo apt-get install -y \
  "docker-ce=${DOCKER_VERSION}" \
  "docker-ce-cli=${DOCKER_VERSION}" \
  "containerd.io=${CONTAINERD_VERSION}" \
  "docker-buildx-plugin=${BUILDX_VERSION}" \
  "docker-compose-plugin=${COMPOSE_VERSION}"
sudo apt-mark hold docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

## Start and enable Docker service
sudo systemctl enable --now docker

## Add user to docker group
sudo usermod -aG docker "$USER"

## Installing nvidia-container-toolkit to host
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt-get update -y
sudo apt-get install -y "nvidia-container-toolkit=${NVIDIA_TOOLKIT_VERSION}"
sudo apt-mark hold nvidia-container-toolkit nvidia-container-toolkit-base

## Configure Docker to use NVIDIA runtime
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker

## 그룹 권한 적용 안내
# newgrp docker는 새 대화형 셸을 fork하므로 스크립트 안에서 실행하면 흐름이 멈추거나
# 효과 없이 종료됨 → 제거하고 안내 메시지로 대체
echo "✅ Docker 및 NVIDIA Container Toolkit 설치 완료"
echo "⚠️  docker 그룹 권한 적용을 위해 로그아웃 후 재로그인하세요."
echo "    (현재 셸에서 임시 적용하려면 수동으로: newgrp docker)"
