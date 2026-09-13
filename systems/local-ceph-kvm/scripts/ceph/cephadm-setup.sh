#!/bin/bash
#
# Ceph 클러스터 부트스트랩 스크립트 (cephadm)
#   - cephadm SSH 키 생성 및 worker 인증
#   - cephadm bootstrap 및 호스트/OSD 등록
#
set -euo pipefail

NETWORK_PREFIX="${1:?network prefix is required}"
WORKER_LENGTH="${2:?worker length is required}"
CEPH_VERSION="${3:?Ceph version from inventory is required}"
# Intentional non-HA lab topology: one monitor (no quorum redundancy), two managers.
NUM_MON="${4:?monitor count from inventory is required}"
NUM_MGR="${5:?manager count from inventory is required}"
OSD_DEVICES_CSV="${6:?OSD device CSV from inventory is required}"

MASTER_IP="${NETWORK_PREFIX}.10"
CEPH_PUBLIC_NETWORK="${CEPH_PUBLIC_NETWORK:?public network from inventory is required}"
CEPH_CLUSTER_NETWORK="${CEPH_CLUSTER_NETWORK:?cluster network from inventory is required}"
CEPHADM_KEY="/root/.ssh/cephadm"
ANSIBLE_DIR="/tmp/cephadm-ansible"
CEPH_IMAGE="quay.io/ceph/ceph:v19.2.1"   # 클러스터 컨테이너 이미지 버전 고정 (squid)

if [[ "$CEPH_PUBLIC_NETWORK" != "${NETWORK_PREFIX}.0/24" ]]; then
  echo "ERROR: public network $CEPH_PUBLIC_NETWORK does not match network prefix $NETWORK_PREFIX" >&2
  exit 1
fi
if [[ "$CEPH_PUBLIC_NETWORK" == "$CEPH_CLUSTER_NETWORK" ]]; then
  echo "ERROR: public and cluster networks must be different: $CEPH_PUBLIC_NETWORK" >&2
  exit 1
fi

IFS=',' read -r -a RAW_OSD_DEVICES <<< "$OSD_DEVICES_CSV"
declare -a OSD_DEVICES=()
declare -A SEEN_OSD_DEVICES=()
for device in "${RAW_OSD_DEVICES[@]}"; do
  device="${device//[[:space:]]/}"
  [[ "$device" =~ ^/dev/(vd[b-z]|sd[b-z])$ ]] || {
    echo "ERROR: invalid libvirt/KVM OSD device from inventory: '$device'" >&2
    exit 1
  }
  [[ -z "${SEEN_OSD_DEVICES[$device]+x}" ]] || {
    echo "ERROR: duplicate OSD device from inventory: $device" >&2
    exit 1
  }
  SEEN_OSD_DEVICES["$device"]=1
  OSD_DEVICES+=("$device")
done
[[ ${#OSD_DEVICES[@]} -gt 0 ]] || {
  echo "ERROR: inventory OSD device list is empty" >&2
  exit 1
}

echo "[cephadm] bootstrap version=$CEPH_VERSION public=$CEPH_PUBLIC_NETWORK cluster=$CEPH_CLUSTER_NETWORK"

install -m 0700 -d /root/.ssh "$ANSIBLE_DIR"
if [[ ! -f "$CEPHADM_KEY" ]]; then
  ssh-keygen -t ed25519 -f "$CEPHADM_KEY" -N ""
fi

cat > "$ANSIBLE_DIR/inventory.ini" <<EOF
[storage]
EOF

KNOWN_HOSTS="/root/.ssh/known_hosts"
for i in $(seq 1 "$WORKER_LENGTH"); do
  host="ceph-worker-$i"
  ip="${NETWORK_PREFIX}.$((i + 10))"
  key_path="$(find "/vagrant/.vagrant/machines/$host" -path '*/private_key' -type f | head -n 1 || true)"
  if [[ -z "$key_path" ]]; then
    echo "Missing Vagrant private key for $host under /vagrant/.vagrant/machines/$host" >&2
    exit 1
  fi
  echo "$host ansible_host=$ip ansible_user=vagrant ansible_ssh_private_key_file=$key_path" >> "$ANSIBLE_DIR/inventory.ini"

  # worker 호스트 키를 미리 known_hosts에 등록 (Ansible은 ansible_host=$ip 로 접속)
  ssh-keyscan -T 10 "$ip" >> "$KNOWN_HOSTS" 2>/dev/null || {
    echo "Failed to scan SSH host key for $host ($ip)" >&2
    exit 1
  }
done
sort -u "$KNOWN_HOSTS" -o "$KNOWN_HOSTS"

cat > "$ANSIBLE_DIR/authorize-cephadm.yml" <<EOF
- hosts: storage
  become: true
  tasks:
    - name: Allow cephadm key for vagrant user
      ansible.builtin.authorized_key:
        user: vagrant
        key: "{{ lookup('file', '$CEPHADM_KEY.pub') }}"
        state: present
EOF

ansible-playbook -i "$ANSIBLE_DIR/inventory.ini" "$ANSIBLE_DIR/authorize-cephadm.yml"

# 이미 부트스트랩된 클러스터면 건너뛴다(재실행 가능).
if [[ -f /etc/ceph/ceph.conf ]] && ceph -s &>/dev/null; then
  echo "[cephadm] 이미 부트스트랩된 클러스터 — bootstrap 건너뜀"
else
  cephadm --image "$CEPH_IMAGE" bootstrap \
    --mon-ip "$MASTER_IP" \
    --ssh-user vagrant \
    --ssh-private-key "$CEPHADM_KEY" \
    --ssh-public-key "$CEPHADM_KEY.pub" \
    --cluster-network "$CEPH_CLUSTER_NETWORK"
fi

ceph cephadm set-user vagrant
ceph cephadm set-priv-key -i "$CEPHADM_KEY"
ceph cephadm set-pub-key -i "$CEPHADM_KEY.pub"

# Keep client/monitor traffic and OSD replication/recovery traffic on the two
# inventory-declared networks. Do not infer cluster_network from the public CIDR.
ceph config set global public_network "$CEPH_PUBLIC_NETWORK"
ceph config set global cluster_network "$CEPH_CLUSTER_NETWORK"

for i in $(seq 1 "$WORKER_LENGTH"); do
  host="ceph-worker-$i"
  ip="${NETWORK_PREFIX}.$((i + 10))"
  ceph orch host add "$host" "$ip" || true
done

ceph orch apply mon --placement="$NUM_MON"
ceph orch apply mgr --placement="$NUM_MGR"
ceph config set global osd_pool_default_size 2

# --- OSD 생성 (디바이스 인벤토리 준비 대기 → 선언 디바이스만 추가 → 개수 검증) ---
EXPECTED_OSDS=$(( WORKER_LENGTH * ${#OSD_DEVICES[@]} ))

current_osds="$(ceph osd stat -f json 2>/dev/null | jq -r '.num_up_osds // 0' || echo 0)"
if [[ "${current_osds:-0}" -ge "$EXPECTED_OSDS" ]]; then
  echo "[cephadm] OSD가 이미 ${current_osds}개 존재 — OSD 생성 건너뜀"
else
  # cephadm이 host add 직후 디바이스 인벤토리를 채우기 전에는 add osd가 묻히므로,
  # 워커 디바이스가 Available 로 보고될 때까지 기다린다.
  echo "[cephadm] OSD 디바이스 인벤토리 대기 중 (목표 ${EXPECTED_OSDS}개)..."
  for _ in $(seq 1 30); do
    avail="$(ceph orch device ls --format json 2>/dev/null | jq '[.[].devices[]? | select(.available)] | length' || echo 0)"
    [[ "${avail:-0}" -ge "$EXPECTED_OSDS" ]] && break
    sleep 10
  done

  # inventory 또는 group vars에 선언한 디바이스에만 OSD를 적용한다.
  for i in $(seq 1 "$WORKER_LENGTH"); do
    host="ceph-worker-$i"
    for device in "${OSD_DEVICES[@]}"; do
      ceph orch daemon add osd "${host}:${device}" || true
    done
  done

  # OSD가 목표 개수만큼 up 될 때까지 대기 후 검증한다.
  echo "[cephadm] OSD up/in 대기 중..."
  for _ in $(seq 1 30); do
    up="$(ceph osd stat -f json 2>/dev/null | jq -r '.num_up_osds // 0' || echo 0)"
    [[ "${up:-0}" -ge "$EXPECTED_OSDS" ]] && break
    sleep 10
  done
  up="$(ceph osd stat -f json 2>/dev/null | jq -r '.num_up_osds // 0' || echo 0)"
  if [[ "${up:-0}" -lt "$EXPECTED_OSDS" ]]; then
    echo "ERROR: OSD ${EXPECTED_OSDS}개를 기대했으나 ${up}개만 up 상태입니다." >&2
    ceph -s || true
    ceph orch device ls || true
    ceph orch ps --daemon_type osd || true
    exit 1
  fi
fi

ceph -s
ceph orch ls
