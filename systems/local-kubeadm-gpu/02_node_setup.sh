#!/usr/bin/bash
# 02_node_setup.sh
# 모든 노드 공통 설정 (master / worker 동일하게 실행)
# Ubuntu 24.04
# ⚠️  실행 후 재부팅 필요
#
# hostname이 "k8s-master" 이면 GPU 설치 스킵 (master 노드)
# 그 외 hostname 이면 GPU worker로 간주 (nvidia-container-toolkit 설치)

set -euo pipefail

# Mutually compatible, exact package set for Ubuntu 24.04. These values are
# intentionally not environment-overridable: changing one component requires
# re-validating the full set and updating the README version table.
K8S_REPOSITORY_SERIES="1.31"
KUBERNETES_PACKAGE_VERSION="1.31.14-1.1"
CONTAINERD_PACKAGE_VERSION="1.7.22-1"
NVIDIA_TOOLKIT_PACKAGE_VERSION="1.17.8-1"
NVIDIA_DRIVER_PACKAGE="nvidia-driver-550-server"
NVIDIA_DRIVER_PACKAGE_VERSION="550.163.01-0ubuntu0.24.04.1"
NVIDIA_DRIVER_RUNTIME_VERSION="550.163.01"
MASTER_HOSTNAME="k8s-master"

log()        { echo "[$(date '+%H:%M:%S')] $1"; }
error_exit() { echo "❌ ERROR: $1"; exit 1; }

# ────────────────────────────────────────────
# 노드 역할 판별 (hostname 기준)
# ────────────────────────────────────────────
if [[ "$(hostname)" == "$MASTER_HOSTNAME" ]]; then
  IS_MASTER=true
else
  IS_MASTER=false
fi

log "=== Phase 2: 노드 공통 설정 시작 ==="
log "   hostname: $(hostname) | 역할: $( [[ $IS_MASTER == true ]] && echo 'master (GPU 없음)' || echo 'worker (GPU 사용)' )"

CPU_VENDOR=$(grep -m1 vendor_id /proc/cpuinfo | awk '{print $3}')
log "   CPU: $CPU_VENDOR"

# ────────────────────────────────────────────
# 1. Nouveau 블랙리스트 (worker만)
# ────────────────────────────────────────────
if [[ $IS_MASTER == false ]]; then
  log "1. Nouveau 블랙리스트 설정..."
  sudo tee /etc/modprobe.d/blacklist-nouveau.conf > /dev/null <<EOF
blacklist nouveau
options nouveau modeset=0
EOF
  sudo update-initramfs -u
else
  log "1. Nouveau 블랙리스트 → 스킵 (master)"
fi

# ────────────────────────────────────────────
# 2. NVIDIA 드라이버 확인 / 설치 (worker만)
# ────────────────────────────────────────────
sudo apt-get update -y

if [[ $IS_MASTER == false ]]; then
  log "2. NVIDIA 드라이버 확인 중..."

  if nvidia-smi > /dev/null 2>&1; then
    DRIVER_VER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | sed -n '1p')
    INSTALLED_DRIVER_PACKAGE_VERSION="$(dpkg-query -W -f='${Version}' "$NVIDIA_DRIVER_PACKAGE" 2>/dev/null || true)"
    [[ "$DRIVER_VER" == "$NVIDIA_DRIVER_RUNTIME_VERSION" ]] \
      || error_exit "NVIDIA runtime $DRIVER_VER 감지. 이 구성은 $NVIDIA_DRIVER_RUNTIME_VERSION 고정입니다. 정상 설치 경로에서 드라이버를 교체하지 않으므로 수동으로 버전을 맞춘 뒤 다시 실행하세요."
    [[ "$INSTALLED_DRIVER_PACKAGE_VERSION" == "$NVIDIA_DRIVER_PACKAGE_VERSION" ]] \
      || error_exit "$NVIDIA_DRIVER_PACKAGE package version 불일치 (expected $NVIDIA_DRIVER_PACKAGE_VERSION, got ${INSTALLED_DRIVER_PACKAGE_VERSION:-not-installed})."
    log "   고정 NVIDIA 드라이버 확인 완료: $NVIDIA_DRIVER_PACKAGE=$INSTALLED_DRIVER_PACKAGE_VERSION"
  else
    log "   드라이버 미설치 → 고정 패키지 설치 시작..."
    sudo apt-get install -y pciutils

    NVIDIA_GPU=$(lspci | grep -iE "(VGA|3D|Display).*NVIDIA|NVIDIA.*(VGA|3D|Display)" | sed -n '1p')
    [[ -z "$NVIDIA_GPU" ]] && error_exit "NVIDIA GPU를 찾을 수 없습니다. lspci 출력을 확인하세요."
    log "   감지된 GPU: $NVIDIA_GPU"

    AVAILABLE_DRIVER_VERSIONS="$(apt-cache madison "$NVIDIA_DRIVER_PACKAGE" | awk '{print $3}')"
    grep -Fxq "$NVIDIA_DRIVER_PACKAGE_VERSION" <<<"$AVAILABLE_DRIVER_VERSIONS" \
      || error_exit "$NVIDIA_DRIVER_PACKAGE=$NVIDIA_DRIVER_PACKAGE_VERSION 를 Ubuntu 24.04 저장소에서 찾을 수 없습니다. 저장소/아키텍처를 확인하세요."
    sudo apt-get install -y "${NVIDIA_DRIVER_PACKAGE}=${NVIDIA_DRIVER_PACKAGE_VERSION}"
    sudo apt-mark hold "$NVIDIA_DRIVER_PACKAGE"

    # PRIME (노트북 iGPU+dGPU 환경에서만 적용, 서버는 자동 스킵)
    if apt-cache show nvidia-prime &>/dev/null 2>&1; then
      sudo apt-get install -y nvidia-prime 2>/dev/null || true
      if command -v prime-select &>/dev/null; then
        if [[ "$CPU_VENDOR" == "GenuineIntel" ]]; then
          sudo prime-select intel 2>/dev/null || true
          log "   PRIME → Intel iGPU (디스플레이), NVIDIA dGPU (compute 전용)"
        else
          sudo prime-select on-demand 2>/dev/null || true
          log "   PRIME → AMD iGPU (디스플레이), NVIDIA dGPU (compute 전용)"
        fi
      fi
    fi
  fi
else
  log "2. NVIDIA 드라이버 설치 → 스킵 (master)"
fi

# ────────────────────────────────────────────
# 3. nvidia-container-toolkit 설치 (worker만)
# ────────────────────────────────────────────
if [[ $IS_MASTER == false ]]; then
  log "3. nvidia-container-toolkit 설치..."
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

  curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

  sudo apt-get update -y
  sudo apt-get install -y "nvidia-container-toolkit=${NVIDIA_TOOLKIT_PACKAGE_VERSION}"
  sudo apt-mark hold nvidia-container-toolkit nvidia-container-toolkit-base
else
  log "3. nvidia-container-toolkit → 스킵 (master)"
fi

# ────────────────────────────────────────────
# 4. 시스템 전제 조건 (swap off, modules, sysctl)
# ────────────────────────────────────────────
log "4. 시스템 설정 (swap off, kernel modules, sysctl)..."

sudo swapoff -a
sudo sed -i '/\bswap\b/s/^[^#]/#&/' /etc/fstab

sudo tee /etc/modules-load.d/k8s.conf > /dev/null <<EOF
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

sudo tee /etc/sysctl.d/k8s.conf > /dev/null <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system

# ────────────────────────────────────────────
# 5. containerd 설치 + NVIDIA runtime 설정
# ────────────────────────────────────────────
log "5. containerd 설치 및 설정..."

sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update -y
sudo apt-get install -y "containerd.io=${CONTAINERD_PACKAGE_VERSION}"
sudo apt-mark hold containerd.io

sudo mkdir -p /etc/containerd
sudo mkdir -p /etc/cni/net.d
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

if [[ $IS_MASTER == false ]]; then
  # This exception uses the classic Kubernetes device-plugin envvar path and
  # direct host /dev/nvidia* access. In `auto` mode toolkit 1.17 can prefer CDI,
  # but these pods carry no CDI annotations, so the runtime hook would not inject
  # the host driver libraries. Force `legacy` for this passthrough topology.
  #
  # `disable-require=true` prevents image NVIDIA_REQUIRE_* metadata from rejecting
  # the lab's explicitly pinned host driver before the direct-device smoke test.
  # This deliberately relaxes an image compatibility guard and is lab-only.
  #
  # Toolkit 1.17 uses /etc/nvidia-container-toolkit/config.toml; the older path is
  # retained only so reruns can diagnose/migrate a pre-existing installation.
  NVIDIA_RT_CONFIG=""
  for _cfg in \
    "/etc/nvidia-container-toolkit/config.toml" \
    "/etc/nvidia-container-runtime/config.toml"; do
    [[ -f "$_cfg" ]] && NVIDIA_RT_CONFIG="$_cfg" && break
  done

  if [[ -n "$NVIDIA_RT_CONFIG" ]]; then
    # mode: [nvidia-container-cli] 섹션 내부 또는 최상위 레벨 모두 처리
    sudo sed -i 's|^\(\s*\)mode\s*=\s*"auto"|\1mode = "legacy"|g' "$NVIDIA_RT_CONFIG"
    sudo sed -i 's|^\(\s*\)disable-require\s*=\s*false|\1disable-require = true|g' "$NVIDIA_RT_CONFIG"

    # v1.14+ 보안 정책: unprivileged 컨테이너에서 NVIDIA_VISIBLE_DEVICES 환경변수 무시
    # k8s에서 device plugin이 env로 GPU를 요청하므로 허용 필요
    if grep -q 'accept-nvidia-visible-devices-envvar-when-unprivileged' "$NVIDIA_RT_CONFIG"; then
      sudo sed -i \
        's|.*accept-nvidia-visible-devices-envvar-when-unprivileged.*|accept-nvidia-visible-devices-envvar-when-unprivileged = true|' \
        "$NVIDIA_RT_CONFIG"
    else
      sudo sed -i "1s|^|accept-nvidia-visible-devices-envvar-when-unprivileged = true\n|" \
        "$NVIDIA_RT_CONFIG"
    fi
    log "   nvidia-container-runtime config 패치 완료: $NVIDIA_RT_CONFIG"
  else
    # config 파일 없으면 nvidia-ctk로 직접 설정 (경로 자동 처리)
    sudo nvidia-ctk config --set nvidia-container-cli.mode=legacy 2>/dev/null || true
    sudo nvidia-ctk config --set nvidia-container-runtime.disable-require=true 2>/dev/null || true
    sudo nvidia-ctk config --set accept-nvidia-visible-devices-envvar-when-unprivileged=true 2>/dev/null || true
    log "   nvidia-ctk config 로 legacy 모드 설정 완료 (config 파일 미발견)"
  fi

  # nvidia-ctk로 containerd runtime 설정
  # - 버전(1.x/2.x) 자동 감지 후 올바른 포맷으로 conf.d/99-nvidia.toml 생성
  # - 수동으로 만든 이전 파일은 정상 경로에서 지우지 않고 rollback을 안내한다.
  sudo mkdir -p /etc/containerd/conf.d
  for legacy_runtime_config in \
    /etc/containerd/conf.d/nvidia-runtime.toml \
    /etc/containerd/conf.d/nvidia-runtime-v3.toml; do
    [[ ! -e "$legacy_runtime_config" ]] \
      || error_exit "Legacy containerd runtime config exists: $legacy_runtime_config. Normal setup will not delete it; run 06_rollback.sh option 04 before retrying."
  done

  sudo nvidia-ctk runtime configure --runtime=containerd --set-as-default \
    || error_exit "nvidia-ctk runtime configure 실패. nvidia-container-toolkit 설치를 확인하세요."

  # nvidia-ctk writes its runtime stanza under /etc/containerd/conf.d. Pinned
  # containerd 1.7 ignores that drop-in unless the root config imports it, so the
  # imports line is required for RuntimeClass `nvidia` to resolve after restart.
  if ! grep -q 'conf\.d' /etc/containerd/config.toml 2>/dev/null; then
    sudo sed -i '1s|^|imports = ["/etc/containerd/conf.d/*.toml"]\n|' /etc/containerd/config.toml
    log "   containerd: conf.d imports 라인 추가"
  fi
  log "   nvidia-ctk: containerd runtime 설정 완료"

  # CDI 스펙 생성 (참조용)
  sudo mkdir -p /etc/cdi
  sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml 2>/dev/null || true

  # nvidia 전용 라이브러리 스테이징 디렉토리 생성
  # - /usr/local/nvidia/lib64 에 nvidia 라이브러리 symlink만 모아둠
  # - device plugin DaemonSet이 hostPath로 이 디렉토리만 마운트 (libc 등 충돌 방지)
  # - /lib/x86_64-linux-gnu 전체 마운트 시 컨테이너 libc와 버전 충돌 발생
  NVIDIA_LIB_STAGING="/usr/local/nvidia/lib64"
  sudo mkdir -p "$NVIDIA_LIB_STAGING"
  sudo find /lib/x86_64-linux-gnu -maxdepth 1 \
    \( -name 'libnvidia-*.so*' -o -name 'libcuda.so*' \
       -o -name 'libnvcuvid.so*' -o -name 'libnvoptix.so*' \) \
    | xargs -I{} sudo ln -sf {} "$NVIDIA_LIB_STAGING/" 2>/dev/null || true
  log "   nvidia 라이브러리 스테이징 완료: $NVIDIA_LIB_STAGING ($(ls $NVIDIA_LIB_STAGING | wc -l)개)"

  log "   NVIDIA containerd runtime (nvidia-ctk) 설정 완료"
fi

sudo systemctl restart containerd
sudo systemctl enable containerd

# ────────────────────────────────────────────
# 6. kubeadm / kubelet / kubectl 설치
# ────────────────────────────────────────────
log "6. kubeadm/kubelet/kubectl ${KUBERNETES_PACKAGE_VERSION} 설치..."

sudo apt-get install -y apt-transport-https gpg

curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_REPOSITORY_SERIES}/deb/Release.key" \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
  https://pkgs.k8s.io/core:/stable:/v${K8S_REPOSITORY_SERIES}/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list > /dev/null

sudo apt-get update -y
sudo apt-get install -y \
  "kubelet=${KUBERNETES_PACKAGE_VERSION}" \
  "kubeadm=${KUBERNETES_PACKAGE_VERSION}" \
  "kubectl=${KUBERNETES_PACKAGE_VERSION}" \
  conntrack
sudo apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable kubelet

# ────────────────────────────────────────────
# 완료
# ────────────────────────────────────────────
log "=== Phase 2 완료 ==="
echo ""
if [[ $IS_MASTER == true ]]; then
  echo "✅ 설치 완료 (master 노드):"
  echo "   - containerd"
  echo "   - kubeadm/kubelet/kubectl ${KUBERNETES_PACKAGE_VERSION}"
  echo ""
  echo "재부팅 후: bash ~/03_master_init.sh"
else
  echo "✅ 설치 완료 (GPU worker 노드):"
  echo "   - Nouveau 블랙리스트"
  echo "   - NVIDIA 드라이버 확인/설치"
  echo "   - nvidia-container-toolkit"
  echo "   - containerd (NVIDIA runtime 설정)"
  echo "   - kubeadm/kubelet/kubectl ${KUBERNETES_PACKAGE_VERSION}"
  echo ""
  echo "재부팅 후: bash 04_worker_join.sh \"<master join 명령>\""
  echo "join 명령 확인: ssh ubuntu@k8s-master cat ~/k8s-setup/worker_join.sh"
fi
echo ""
read -rp "지금 재부팅하시겠습니까? (y/N): " resp
[[ "$resp" =~ ^[yY]$ ]] && sudo init 6 || echo "수동으로 재부팅 후 진행하세요."
