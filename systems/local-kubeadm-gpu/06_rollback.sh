#!/usr/bin/bash
# 06_rollback.sh
# 단계별 선택 롤백
# 
# 각 단계는 해당 단계 이후 변경사항을 모두 역순으로 제거합니다.
#   1단계 이전: VM 전체 삭제 (디스크 포함)
#   2단계 이전: VM 재생성 필요 (= 1단계 이전 수준)
#   3단계 이전: kubeadm reset, CNI/iptables 초기화, kubectl 설정 제거
#   4단계 이전: worker 노드 제거 후 3단계 이전 수행
#   5단계 이전: GPU Device Plugin 제거만 수행
#
# 실행: bash 06_rollback.sh

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
warn() { echo "[$(date '+%H:%M:%S')] WARNING: $*"; }

VM_NAMES=("k8s-master")   # worker는 호스트 베어메탈 (VM 없음)
VM_DIR="/var/lib/libvirt/images"
SETUP_DIR="/var/lib/libvirt/images/k8s-setup"
VM_IPS_ENV="$SETUP_DIR/vm_ips.env"
SSH_KEY="$HOME/.ssh/id_ed25519"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes -i $SSH_KEY"

# ────────────────────────────────────────────
# 메뉴
# ────────────────────────────────────────────
echo ""
echo "=== K8s 단계별 롤백 ==="
echo ""
echo "  단계 번호를 입력하면 해당 단계 실행 이전 상태로 되돌립니다."
echo "  (해당 단계 포함 이후 모든 단계가 역순으로 제거됩니다)"
echo ""
echo "  01 : VM 생성 이전     (VM 전체 삭제, cloud image / host_info.env 보존)"
echo "  02 : 노드 설정 이전   (VM 삭제 후 재생성 권장)"
echo "  03 : Master init 이전 (kubeadm reset, CNI/iptables 초기화, kubectl 설정 제거)"
echo "  04 : Worker join 이전 (Worker 노드 제거 + kubeadm reset)"
echo "  05 : GPU plugin 이전  (GPU Device Plugin / CUDA 테스트 Pod 제거)"
echo ""
read -rp "어느 단계 이전까지 롤백하시겠습니까? (01~05, q=취소): " CHOICE

# 앞의 0 제거하여 정규화 (01→1, 05→5)
CHOICE="${CHOICE#0}"

case "$CHOICE" in
  1|2|3|4|5) ;;
  q|Q) echo "취소됨."; exit 0 ;;
  *) echo "ERROR: 잘못된 입력입니다. (01~05 또는 q)"; exit 1 ;;
esac

echo ""
case "$CHOICE" in
  1) echo "  → 01단계(VM 생성) 이전으로 롤백: VM 전체 삭제" ;;
  2) echo "  → 02단계(노드 설정) 이전으로 롤백: VM 삭제 후 재생성 필요" ;;
  3) echo "  → 03단계(Master init) 이전으로 롤백: 클러스터 전체 해체" ;;
  4) echo "  → 04단계(Worker join) 이전으로 롤백: Worker 노드 제거" ;;
  5) echo "  → 05단계(GPU plugin) 이전으로 롤백: GPU Plugin 제거" ;;
esac
echo ""
read -rp "계속 진행하시겠습니까? (y/N): " resp
[[ "$resp" =~ ^[yY]$ ]] || { echo "취소됨."; exit 0; }
echo ""

# ────────────────────────────────────────────
# 롤백 함수
# ────────────────────────────────────────────

rollback_05() {
  log "--- [05단계 롤백] GPU Device Plugin 제거 ---"
  if kubectl get nodes &>/dev/null; then
    kubectl delete daemonset nvidia-device-plugin-daemonset \
      -n kube-system --ignore-not-found=true 2>/dev/null || true
    kubectl delete pod cuda-test --ignore-not-found=true 2>/dev/null || true
    log "   GPU Plugin / 테스트 Pod 제거 완료"
  else
    warn "kubectl 접근 불가 → GPU Plugin 제거 스킵"
  fi
}

rollback_04() {
  log "--- [04단계 롤백] Worker(호스트) 노드 제거 ---"
  local HOST_NODE
  HOST_NODE=$(hostname)

  # master에서 호스트 노드 drain & delete
  if kubectl get nodes &>/dev/null; then
    kubectl drain "$HOST_NODE" --ignore-daemonsets --delete-emptydir-data --force \
      2>/dev/null || true
    kubectl delete node "$HOST_NODE" --ignore-not-found=true 2>/dev/null || true
    log "   호스트 노드 $HOST_NODE 삭제 완료"
  else
    warn "kubectl 접근 불가 → 노드 삭제 스킵"
  fi

  # 호스트에서 kubeadm reset (로컬 실행)
  log "   호스트 kubeadm reset 중..."
  sudo kubeadm reset --force \
    --cri-socket=unix:///run/containerd/containerd.sock 2>/dev/null || true
  sudo rm -rf /etc/cni/net.d/* /var/lib/cni 2>/dev/null || true  # 디렉터리 자체는 보존 (containerd 필요)
  sudo iptables -F 2>/dev/null || true
  sudo iptables -t nat -F 2>/dev/null || true
  log "   호스트 kubeadm reset 완료"

  # 패키지 제거 (02_node_setup.sh 에서 설치된 것들)
  log "   호스트 패키지 제거 중..."
  sudo apt-mark unhold kubelet kubeadm kubectl 2>/dev/null || true
  sudo apt-get purge -y kubeadm kubelet kubectl 2>/dev/null || true
  sudo apt-get purge -y nvidia-container-toolkit 2>/dev/null || true
  sudo apt-get purge -y containerd.io 2>/dev/null || true
  sudo apt-get autoremove -y 2>/dev/null || true

  # APT 소스 / 키링 정리
  sudo rm -f /etc/apt/sources.list.d/kubernetes.list
  sudo rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  sudo rm -f /etc/apt/sources.list.d/nvidia-container-toolkit.list
  sudo rm -f /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  sudo rm -f /etc/apt/sources.list.d/docker.list
  sudo rm -f /etc/apt/keyrings/docker.asc

  # 설정 파일 정리 (GPU 드라이버 관련 요소는 보존)
  sudo rm -rf /etc/containerd 2>/dev/null || true
  sudo rm -rf /etc/cdi 2>/dev/null || true          # nvidia-ctk CDI 스펙
  sudo rm -f /etc/modules-load.d/k8s.conf 2>/dev/null || true
  sudo rm -f /etc/sysctl.d/k8s.conf 2>/dev/null || true
  # blacklist-nouveau.conf 보존: nvidia 드라이버 유지 시 nouveau 충돌 방지
  sudo rm -f "$HOME/.kube/config" 2>/dev/null || true

  log "   패키지 및 설정 파일 제거 완료"
  log "   보존: NVIDIA 드라이버, blacklist-nouveau.conf"
}

rollback_03() {
  log "--- [03단계 롤백] Master 클러스터 해체 ---"
  # Master는 VM → SSH로 접속하여 reset

  local MASTER_IP=""
  if [[ -f "$VM_IPS_ENV" ]]; then
    source "$VM_IPS_ENV"
    MASTER_IP="${MASTER_IP:-}"
  fi

  if [[ -n "$MASTER_IP" && "$MASTER_IP" != "unknown" ]]; then
    log "   Master VM ($MASTER_IP) → kubeadm reset 중..."
    ssh $SSH_OPTS "ubuntu@${MASTER_IP}" \
      "sudo kubeadm reset --force --cri-socket=unix:///run/containerd/containerd.sock 2>/dev/null; \
       sudo rm -rf /etc/cni/net.d/* /var/lib/cni 2>/dev/null; \
       sudo iptables -F 2>/dev/null; sudo iptables -t nat -F 2>/dev/null; \
       rm -f ~/.kube/config 2>/dev/null; rm -rf ~/k8s-setup 2>/dev/null; \
       sudo systemctl restart containerd 2>/dev/null" \
      || warn "Master VM SSH 실패 → ssh ubuntu@${MASTER_IP} 접속 후 수동으로 kubeadm reset 실행"
    log "   Master 클러스터 해체 완료"
  else
    warn "Master VM IP를 찾을 수 없습니다."
    warn "직접 실행: ssh ubuntu@<master-ip>"
    warn "  sudo kubeadm reset --force --cri-socket=unix:///run/containerd/containerd.sock"
    warn "  sudo rm -rf /etc/cni/net.d /var/lib/cni ~/.kube ~/k8s-setup"
  fi
}

rollback_02() {
  log "--- [02단계 롤백] VM 내부 패키지 제거 ---"
  warn "02_node_setup.sh 는 VM 내부에서 실행된 것으로, 패키지 단위 롤백은 지원하지 않습니다."
  warn "VM을 삭제하고 01_vm_create.sh 재실행을 권장합니다. (01단계 롤백으로 이어서 처리)"
}

rollback_01() {
  log "--- [01단계 롤백] VM 전체 삭제 ---"

  for vm in "${VM_NAMES[@]}"; do
    if sudo virsh dominfo "$vm" &>/dev/null; then
      log "   $vm → 강제 중지 중..."
      sudo virsh destroy "$vm" 2>/dev/null || true
      log "   $vm → 정의 삭제 중..."
      sudo virsh undefine "$vm" --remove-all-storage 2>/dev/null \
        || sudo virsh undefine "$vm" 2>/dev/null \
        || warn "$vm undefine 실패"
      log "   $vm 삭제 완료"
    else
      log "   $vm 존재하지 않음 (스킵)"
    fi
    sudo rm -f "$VM_DIR/${vm}.qcow2" 2>/dev/null || true
  done

  # cloud-init 임시 파일 정리 (cloud image, host_info.env 는 보존)
  sudo rm -f  "$SETUP_DIR"/*-seed.iso   2>/dev/null || true
  sudo rm -rf "$SETUP_DIR"/cloud-init-* 2>/dev/null || true
  sudo rm -f  "$SETUP_DIR/vm_ips.env"  2>/dev/null || true

  # /etc/hosts 및 known_hosts VM 항목 제거
  for vm in "${VM_NAMES[@]}"; do
    sudo sed -i "/[[:space:]]${vm}$/d" /etc/hosts
    ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$vm" 2>/dev/null || true
  done
  log "   /etc/hosts 및 known_hosts VM 항목 제거 완료"

  log "   VM 삭제 완료"
  log "   보존: $SETUP_DIR/ubuntu-24.04-cloud.img"
  log "   보존: $SETUP_DIR/host_info.env"
}

# ────────────────────────────────────────────
# 선택에 따라 역순 누적 실행
# (입력한 단계 포함 이후를 모두 제거)
# ────────────────────────────────────────────
[[ "$CHOICE" -le 5 ]] && rollback_05
[[ "$CHOICE" -le 4 ]] && rollback_04
[[ "$CHOICE" -le 3 ]] && rollback_03
[[ "$CHOICE" -le 2 ]] && rollback_02   # 경고 출력 후 rollback_01로 이어짐
[[ "$CHOICE" -le 2 ]] && rollback_01

# ────────────────────────────────────────────
# 완료
# ────────────────────────────────────────────
echo ""
log "=== 롤백 완료 ==="
echo ""
echo "재시작 위치:"
case "$CHOICE" in
  5) echo "   master VM: bash ~/05_gpu_plugin.sh" ;;
  4) echo "   호스트(worker): bash 04_worker_join.sh \"<join 명령>\"" ;;
  3) echo "   master VM: bash ~/03_master_init.sh" ;;
  1|2) echo "   호스트: bash 01_vm_create.sh" ;;
esac
echo ""
