#!/usr/bin/bash
# 01_vm_create.sh
# K8s용 KVM VM 생성 (master 1개)
# GPU worker는 호스트(베어메탈)에서 직접 실행 → iGPU 없는 환경에서도 화면 유지
#
# 아키텍처:
#   k8s-master (VM)  ← control plane (GPU 없음)
#   호스트 (psi)     ← GPU worker (베어메탈, nvidia 드라이버 직접 사용)
#
# 리소스:
#   Master : 2 vCPU, 4096MB RAM, 30GB disk
#
# 실행: bash 01_vm_create.sh
# 완료 후: master VM에서 02_node_setup.sh → 03_master_init.sh
#          호스트에서 02_node_setup.sh → 04_worker_join.sh

set -e

log()        { echo "[$(date '+%H:%M:%S')] $1"; }
warn()       { echo "[$(date '+%H:%M:%S')] WARNING: $1"; }
error_exit() { echo "❌ ERROR: $1"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log "=== VM 생성 시작 ==="

# ────────────────────────────────────────────
# 설정값
# ────────────────────────────────────────────
VM_DIR="/var/lib/libvirt/images"
SETUP_DIR="/var/lib/libvirt/images/k8s-setup"
CLOUD_IMG="$SETUP_DIR/ubuntu-24.04-cloud.img"
CLOUD_IMG_RELEASE="release-20241004"
CLOUD_IMG_URL="https://cloud-images.ubuntu.com/releases/noble/${CLOUD_IMG_RELEASE}/ubuntu-24.04-server-cloudimg-amd64.img"
CLOUD_IMG_SHA256="fad101d50b06b26590cf30542349f9e9d3041ad7929e3bc3531c81ec27f2c788"

FLANNEL_VERSION="v0.28.5"
DEVICE_PLUGIN_VERSION="v0.17.0"
MANIFEST_DIR="$SCRIPT_DIR/manifests"
FLANNEL_MANIFEST_SOURCE="$MANIFEST_DIR/kube-flannel-${FLANNEL_VERSION}.yml"
DEVICE_PLUGIN_MANIFEST_SOURCE="$MANIFEST_DIR/nvidia-device-plugin-${DEVICE_PLUGIN_VERSION}.yml"

# VM 리소스
MASTER_VCPU=2;  MASTER_MEM=4096;  MASTER_DISK=30   # master only

# VM 이름 (libvirt default NAT: 192.168.122.x)
MASTER_NAME="k8s-master"

SSH_KEY_PATH="$HOME/.ssh/id_ed25519.pub"

sudo mkdir -p "$SETUP_DIR"
sudo chown "$(id -u):$(id -g)" "$SETUP_DIR"

# ────────────────────────────────────────────
# 0. 사전 확인
# ────────────────────────────────────────────
log "0. 사전 확인..."

command -v sha256sum >/dev/null 2>&1 \
  || error_exit "sha256sum이 없어 cloud image와 Kubernetes manifest를 검증할 수 없습니다."
[[ -f "$MANIFEST_DIR/SHA256SUMS" ]] \
  || error_exit "manifest checksum 파일이 없습니다: $MANIFEST_DIR/SHA256SUMS"
(
  cd "$MANIFEST_DIR"
  sha256sum -c SHA256SUMS
) || error_exit "vendored manifest checksum 검증에 실패했습니다. VM을 만들지 않습니다."

[[ -f "/var/lib/libvirt/images/k8s-setup/host_info.env" ]] \
  && source "/var/lib/libvirt/images/k8s-setup/host_info.env" \
  || error_exit "host_info.env 없음. 먼저 00_host_setup.sh를 실행하세요."

log "   CPU: $CPU_VENDOR | GPU: $GPU_NAME | 드라이버: $DRIVER_VERSION"

# SSH 키 확인 (없으면 생성)
if [[ ! -f "$SSH_KEY_PATH" ]]; then
  log "   SSH 키 생성 중..."
  ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519" -N ""
fi
SSH_PUB_KEY=$(cat "$SSH_KEY_PATH")

# GPU는 호스트(worker)에서 직접 사용 → VM에 패스스루 불필요
log "   GPU worker: 호스트 베어메탈 (VM 패스스루 없음)"

# ────────────────────────────────────────────
# 1. Ubuntu 24.04 클라우드 이미지 다운로드
# ────────────────────────────────────────────
log "1. Ubuntu 24.04 클라우드 이미지 확인 중..."

if [[ -f "$CLOUD_IMG" ]]; then
  CLOUD_IMG_ACTUAL_SHA256="$(sha256sum "$CLOUD_IMG" | awk '{print $1}')"
  [[ "$CLOUD_IMG_ACTUAL_SHA256" == "$CLOUD_IMG_SHA256" ]] \
    || error_exit "기존 cloud image checksum 불일치: $CLOUD_IMG (expected $CLOUD_IMG_SHA256, got $CLOUD_IMG_ACTUAL_SHA256). 안전한 위치로 옮긴 뒤 다시 실행하세요."
  log "   고정 cloud image 검증 완료: Ubuntu 24.04 ${CLOUD_IMG_RELEASE}"
else
  log "   다운로드 중: $CLOUD_IMG_URL"
  CLOUD_IMG_DOWNLOAD="$(mktemp "$SETUP_DIR/ubuntu-24.04-cloud.img.XXXXXX")"
  wget -O "$CLOUD_IMG_DOWNLOAD" "$CLOUD_IMG_URL"
  CLOUD_IMG_ACTUAL_SHA256="$(sha256sum "$CLOUD_IMG_DOWNLOAD" | awk '{print $1}')"
  if [[ "$CLOUD_IMG_ACTUAL_SHA256" != "$CLOUD_IMG_SHA256" ]]; then
    rm -f "$CLOUD_IMG_DOWNLOAD"
    error_exit "다운로드한 cloud image checksum 불일치 (expected $CLOUD_IMG_SHA256, got $CLOUD_IMG_ACTUAL_SHA256)."
  fi
  mv "$CLOUD_IMG_DOWNLOAD" "$CLOUD_IMG"
  log "   다운로드 및 checksum 검증 완료"
fi

# ────────────────────────────────────────────
# 2. cloud-init 설정 생성 함수
# ────────────────────────────────────────────
create_cloud_init() {
  local vm_name="$1"

  local seed_dir="$SETUP_DIR/cloud-init-$vm_name"
  mkdir -p "$seed_dir"

  # master VM에 필요한 스크립트를 base64로 인코딩 (write_files 삽입용)
  local write_files_section=""
  local b64_02 b64_03 b64_05 b64_flannel b64_device_plugin
  b64_02=$(base64 -w0 "$SCRIPT_DIR/02_node_setup.sh" 2>/dev/null || true)
  b64_03=$(base64 -w0 "$SCRIPT_DIR/03_master_init.sh" 2>/dev/null || true)
  b64_05=$(base64 -w0 "$SCRIPT_DIR/05_gpu_plugin.sh"  2>/dev/null || true)
  b64_flannel=$(base64 -w0 "$FLANNEL_MANIFEST_SOURCE")
  b64_device_plugin=$(base64 -w0 "$DEVICE_PLUGIN_MANIFEST_SOURCE")

  # defer: true → modules-final 단계(유저 생성 완료 후)에 파일 기록
  if [[ -n "$b64_02" ]]; then
    write_files_section+="
  - path: /home/ubuntu/02_node_setup.sh
    permissions: '0755'
    owner: 'ubuntu:ubuntu'
    encoding: b64
    defer: true
    content: $b64_02"
  fi

  if [[ -n "$b64_03" ]]; then
    write_files_section+="
  - path: /home/ubuntu/03_master_init.sh
    permissions: '0755'
    owner: 'ubuntu:ubuntu'
    encoding: b64
    defer: true
    content: $b64_03"
  fi

  if [[ -n "$b64_05" ]]; then
    write_files_section+="
  - path: /home/ubuntu/05_gpu_plugin.sh
    permissions: '0755'
    owner: 'ubuntu:ubuntu'
    encoding: b64
    defer: true
    content: $b64_05"
  fi

  # 03_master_init.sh and 05_gpu_plugin.sh verify these vendored copies again
  # immediately before applying them. Embedding them avoids network-dependent
  # manifest content inside the VM while retaining checksum enforcement.
  write_files_section+="
  - path: /home/ubuntu/manifests/kube-flannel-${FLANNEL_VERSION}.yml
    permissions: '0644'
    owner: 'ubuntu:ubuntu'
    encoding: b64
    defer: true
    content: $b64_flannel
  - path: /home/ubuntu/manifests/nvidia-device-plugin-${DEVICE_PLUGIN_VERSION}.yml
    permissions: '0644'
    owner: 'ubuntu:ubuntu'
    encoding: b64
    defer: true
    content: $b64_device_plugin"

  # user-data: 패키지 설치 없음 (02_node_setup.sh에서 처리)
  # cloud-init은 사용자/SSH키 설정 + 스크립트 배포 + swap off만 담당
  cat > "$seed_dir/user-data" <<USERDATA
#cloud-config
hostname: ${vm_name}
manage_etc_hosts: true

users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    home: /home/ubuntu
    create_home: true
    ssh_authorized_keys:
      - ${SSH_PUB_KEY}

chpasswd:
  list: |
    ubuntu:ubuntu
  expire: false

ssh_pwauth: true

write_files:
  - path: /etc/apt/apt.conf.d/99force-ipv4
    content: |
      Acquire::ForceIPv4 "true";${write_files_section}

runcmd:
  - chown ubuntu:ubuntu /home/ubuntu
  - swapoff -a
  - sed -i '/\bswap\b/s/^[^#]/#&/' /etc/fstab

final_message: "VM $vm_name cloud-init 완료"
USERDATA

  # meta-data
  cat > "$seed_dir/meta-data" <<METADATA
instance-id: ${vm_name}
local-hostname: ${vm_name}
METADATA

  # seed ISO 생성
  cloud-localds "$SETUP_DIR/${vm_name}-seed.iso" \
    "$seed_dir/user-data" "$seed_dir/meta-data"
  log "   cloud-init seed: $SETUP_DIR/${vm_name}-seed.iso"
}

# ────────────────────────────────────────────
# 3. VM 디스크 생성 함수
# ────────────────────────────────────────────
create_vm_disk() {
  local vm_name="$1"
  local size_gb="$2"
  local dst="$VM_DIR/${vm_name}.qcow2"

  if [[ -f "$dst" ]]; then
    # backing file 경로가 현재 CLOUD_IMG와 일치하는지 확인
    local backing
    backing=$(sudo qemu-img info "$dst" 2>/dev/null | awk '/backing file:/{print $3}')
    if [[ "$backing" != "$CLOUD_IMG" ]]; then
      error_exit "기존 VM disk의 backing file이 다릅니다: $dst (actual ${backing:-none}, expected $CLOUD_IMG). 정상 생성 경로에서는 disk를 삭제하지 않습니다. 06_rollback.sh option 01로 정리하세요."
    else
      log "   디스크 이미 존재: $dst (스킵)"
      return 0
    fi
  fi
  sudo qemu-img create -f qcow2 -b "$CLOUD_IMG" -F qcow2 "$dst" "${size_gb}G"
  sudo chmod 644 "$dst"
  log "   디스크 생성: $dst (${size_gb}GB)"
}

# ────────────────────────────────────────────
# 4. VM 생성 함수
# ────────────────────────────────────────────
create_vm() {
  local vm_name="$1"
  local vcpu="$2"
  local mem="$3"
  local disk_gb="$4"

  log "--- VM 생성: $vm_name (${vcpu}vCPU / ${mem}MB / ${disk_gb}GB) ---"

  # 이미 존재하면 스킵
  if sudo virsh dominfo "$vm_name" &>/dev/null; then
    log "   VM '$vm_name' 이미 존재. 스킵"
    return 0
  fi

  create_vm_disk "$vm_name" "$disk_gb"
  create_cloud_init "$vm_name"

  # CPU 제조사에 따른 최적화 옵션
  local cpu_model
  case "$CPU_VENDOR" in
    GenuineIntel) cpu_model="host-model" ;;
    AuthenticAMD) cpu_model="host-passthrough" ;;
    *)            cpu_model="host-model" ;;
  esac

  sudo virt-install \
    --name "$vm_name" \
    --vcpus "$vcpu" \
    --memory "$mem" \
    --disk "path=$VM_DIR/${vm_name}.qcow2,format=qcow2,bus=virtio" \
    --disk "path=$SETUP_DIR/${vm_name}-seed.iso,device=cdrom" \
    --os-variant "ubuntu24.04" \
    --network network=default,model=virtio \
    --cpu "$cpu_model" \
    --graphics none \
    --console "pty,target_type=serial" \
    --import \
    --noautoconsole

  log "   VM '$vm_name' 생성 완료"
}

# ────────────────────────────────────────────
# 5. Master VM 생성
# ────────────────────────────────────────────
log "5. Master VM 생성 중..."

create_vm "$MASTER_NAME" "$MASTER_VCPU" "$MASTER_MEM" "$MASTER_DISK"

# ────────────────────────────────────────────
# 6. VM IP 확인 대기
# ────────────────────────────────────────────
log "6. VM 부팅 대기 중 (최대 3분)..."
sleep 30

declare -A VM_IPS
log "   $MASTER_NAME IP 확인 중..."
for i in $(seq 1 18); do
  IP=$(sudo virsh domifaddr "$MASTER_NAME" 2>/dev/null \
    | grep -oE '192\.168\.[0-9]+\.[0-9]+' | head -1)
  if [[ -n "$IP" ]]; then
    VM_IPS[$MASTER_NAME]="$IP"
    log "   $MASTER_NAME → $IP"
    break
  fi
  sleep 10
done
[[ -z "${VM_IPS[$MASTER_NAME]}" ]] && warn "$MASTER_NAME IP 확인 실패 (수동 확인: sudo virsh domifaddr $MASTER_NAME)"

# VM IP 저장
cat > "$SETUP_DIR/vm_ips.env" <<EOF
MASTER_IP=${VM_IPS[$MASTER_NAME]:-unknown}
MASTER_NAME=$MASTER_NAME
EOF
log "VM IP 저장: $SETUP_DIR/vm_ips.env"

# ────────────────────────────────────────────
# 7. Master VM에 최신 스크립트 배포 (SCP)
# ────────────────────────────────────────────
log "7. Master VM에 스크립트 최신화 중..."
MASTER_IP_FOR_SCP="${VM_IPS[$MASTER_NAME]:-}"
if [[ -n "$MASTER_IP_FOR_SCP" && "$MASTER_IP_FOR_SCP" != "unknown" ]]; then
  SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"
  # SSH 접속 가능할 때까지 대기 (최대 2분)
  for i in $(seq 1 12); do
    if ssh $SSH_OPTS "ubuntu@$MASTER_IP_FOR_SCP" true 2>/dev/null; then
      for script in 02_node_setup.sh 03_master_init.sh 05_gpu_plugin.sh; do
        if [[ -f "$SCRIPT_DIR/$script" ]]; then
          scp $SSH_OPTS "$SCRIPT_DIR/$script" \
            "ubuntu@$MASTER_IP_FOR_SCP:/home/ubuntu/$script" 2>/dev/null \
            && log "   복사 완료: $script" \
            || log "   복사 실패: $script"
        fi
      done
      break
    fi
    log "   SSH 대기 중... [$i/12]"
    sleep 10
  done
else
  warn "Master IP 미확인 → 스크립트 배포 스킵. 수동 복사 필요:"
  for script in 02_node_setup.sh 03_master_init.sh 05_gpu_plugin.sh; do
    echo "   scp $SCRIPT_DIR/$script ubuntu@k8s-master:~/"
  done
fi

# ────────────────────────────────────────────
# 8. /etc/hosts에 VM 이름 등록
# ────────────────────────────────────────────
log "8. /etc/hosts VM 이름 등록 및 known_hosts 정리 중..."
MASTER_IP="${VM_IPS[$MASTER_NAME]:-}"
if [[ -n "$MASTER_IP" && "$MASTER_IP" != "unknown" ]]; then
  sudo sed -i "/[[:space:]]${MASTER_NAME}$/d" /etc/hosts
  echo "$MASTER_IP $MASTER_NAME" | sudo tee -a /etc/hosts > /dev/null
  ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$MASTER_NAME" 2>/dev/null || true
  ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$MASTER_IP"   2>/dev/null || true
  log "   $MASTER_NAME → $MASTER_IP"
fi
log "8. /etc/hosts 등록 완료 → ssh ubuntu@k8s-master 로 접속 가능"

# ────────────────────────────────────────────
# 완료
# ────────────────────────────────────────────
log "=== VM 생성 완료 ==="
echo ""
echo "클러스터 구성:"
printf "  %-15s %s vCPU / %sMB RAM / %sGB disk | 역할: control-plane\n" \
  "$MASTER_NAME" "$MASTER_VCPU" "$MASTER_MEM" "$MASTER_DISK"
printf "  %-15s %-30s | 역할: GPU worker (베어메탈)\n" \
  "$(hostname)" "호스트 직접"
echo ""
echo "Master VM IP: ${VM_IPS[$MASTER_NAME]:-unknown}"
echo ""
echo "=== 다음 단계 ==="
echo ""
echo "① Master VM에 SSH 접속 후 노드 설정 (GPU_MODE=none 자동감지):"
echo "   ssh ubuntu@$MASTER_NAME"
echo "   bash ~/02_node_setup.sh   # 완료 후 재부팅"
echo ""
echo "② 호스트(GPU worker)에서 노드 설정 (GPU_MODE=full 자동감지):"
echo "   bash $SCRIPT_DIR/02_node_setup.sh   # 완료 후 재부팅"
echo ""
echo "③ 재부팅 후 Master VM에서 클러스터 초기화:"
echo "   bash ~/03_master_init.sh"
echo "   cat ~/k8s-setup/worker_join.sh   # join 명령 확인"
echo ""
echo "④ 재부팅 후 호스트에서 worker join:"
echo "   bash $SCRIPT_DIR/04_worker_join.sh \"<join 명령>\""
echo ""
echo "⑤ Master VM에서 GPU Plugin 배포:"
echo "   bash ~/05_gpu_plugin.sh"
