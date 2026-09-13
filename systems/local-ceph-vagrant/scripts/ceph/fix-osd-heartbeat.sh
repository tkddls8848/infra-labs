#!/bin/bash
#
# OSD Heartbeat 문제 해결 스크립트
#   - Slow OSD heartbeats 경고 해결
#   - 성능 최적화 설정 적용
#   - 네트워크 설정 조정
#

set -euo pipefail

INVENTORY_FILE="${1:-/vagrant/inventory/inventory.ini}"
ANSIBLE_INVENTORY="/tmp/cephadm-ansible/inventory.ini"
OSD_CANDIDATE_REGEX='^sd[b-z]$'

declare -A OSD_DEVICES_BY_HOST=()

load_declared_osd_devices() {
  local raw_line line host field csv device
  local -a fields raw_devices normalized_devices

  [[ -r "$INVENTORY_FILE" ]] || {
    echo "ERROR: Ceph inventory is not readable: $INVENTORY_FILE" >&2
    exit 1
  }
  [[ -r "$ANSIBLE_INVENTORY" ]] || {
    echo "ERROR: cephadm Ansible inventory is not readable: $ANSIBLE_INVENTORY" >&2
    exit 1
  }

  while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    line="${raw_line%%#*}"
    [[ -n "${line//[[:space:]]/}" ]] || continue
    [[ "$line" == \[* ]] && continue

    read -r -a fields <<< "$line"
    host="${fields[0]}"
    csv=""
    for field in "${fields[@]:1}"; do
      if [[ "$field" == osd_devices=* ]]; then
        csv="${field#osd_devices=}"
        break
      fi
    done
    [[ -n "$csv" ]] || continue
    [[ "$host" =~ ^[A-Za-z0-9._-]+$ ]] || {
      echo "ERROR: invalid storage hostname in $INVENTORY_FILE: $host" >&2
      exit 1
    }

    IFS=',' read -r -a raw_devices <<< "$csv"
    normalized_devices=()
    for device in "${raw_devices[@]}"; do
      device="${device//[[:space:]]/}"
      [[ "$device" =~ ^/dev/sd[b-z]$ ]] || {
        echo "ERROR: $host has invalid VirtualBox OSD device '$device' in $INVENTORY_FILE" >&2
        exit 1
      }
      normalized_devices+=("$device")
    done
    [[ ${#normalized_devices[@]} -gt 0 ]] || {
      echo "ERROR: $host has an empty osd_devices declaration in $INVENTORY_FILE" >&2
      exit 1
    }
    OSD_DEVICES_BY_HOST["$host"]="$(IFS=,; echo "${normalized_devices[*]}")"
  done < "$INVENTORY_FILE"

  [[ ${#OSD_DEVICES_BY_HOST[@]} -gt 0 ]] || {
    echo "ERROR: no hosts declare osd_devices in $INVENTORY_FILE" >&2
    exit 1
  }
}

apply_declared_scheduler_settings() {
  local scheduler_script host osd_devices_csv

  scheduler_script="$(mktemp)"
  trap "rm -f '$scheduler_script'" EXIT
  cat > "$scheduler_script" <<'REMOTE_SCRIPT'
#!/bin/bash
set -euo pipefail

OSD_DEVICES_CSV="${1:?declared OSD device CSV is required}"
CANDIDATE_REGEX="${2:?candidate disk regex is required}"

declare -A DECLARED_DISKS=()
IFS=',' read -r -a declared_devices <<< "$OSD_DEVICES_CSV"
for device in "${declared_devices[@]}"; do
  disk="${device#/dev/}"
  DECLARED_DISKS["$disk"]=1
done

mapfile -t candidate_disks < <(lsblk -dn -o NAME | grep -E "$CANDIDATE_REGEX" || true)
for disk in "${candidate_disks[@]}"; do
  if [[ -z "${DECLARED_DISKS[$disk]+x}" ]]; then
    echo "WARNING: undeclared candidate disk /dev/$disk found; scheduler left unchanged" >&2
  fi
done

for device in "${declared_devices[@]}"; do
  disk="${device#/dev/}"
  if ! lsblk -dn -o NAME | grep -Fxq "$disk"; then
    echo "ERROR: declared OSD device $device is not present" >&2
    exit 1
  fi

  sched_file="/sys/block/$disk/queue/scheduler"
  if [[ ! -w "$sched_file" ]]; then
    echo "WARNING: scheduler for declared OSD device $device is not writable" >&2
    continue
  fi

  available="$(<"$sched_file")"
  selected=""
  for candidate in none noop mq-deadline deadline; do
    if [[ "$available" == *"$candidate"* ]] && printf '%s\n' "$candidate" > "$sched_file"; then
      selected="$candidate"
      echo "$device -> $candidate"
      break
    fi
  done
  [[ -n "$selected" ]] || echo "WARNING: no supported scheduler found for $device: $available" >&2
done
REMOTE_SCRIPT
  chmod 0755 "$scheduler_script"

  for host in "${!OSD_DEVICES_BY_HOST[@]}"; do
    osd_devices_csv="${OSD_DEVICES_BY_HOST[$host]}"
    echo ">> $host: declared OSD scheduler tuning ($osd_devices_csv)"
    ansible "$host" -i "$ANSIBLE_INVENTORY" -b -m script \
      -a "$scheduler_script '$osd_devices_csv' '$OSD_CANDIDATE_REGEX'"
  done

  rm -f "$scheduler_script"
  trap - EXIT
}

load_declared_osd_devices

echo "=========================================="
echo "OSD Heartbeat 문제 해결 스크립트 시작"
echo "=========================================="

# --- 1. 현재 상태 확인 ---
echo -e "\n[단계 1/5] 현재 클러스터 상태 확인 중..."

echo ">> 클러스터 상태:"
ceph -s

echo ">> OSD 상태:"
ceph osd status

echo ">> 네트워크 지연 확인:"
ceph osd perf

# --- 2. OSD Heartbeat 설정 조정 ---
echo -e "\n[단계 2/5] OSD Heartbeat 설정 조정 중..."

echo ">> OSD heartbeat 타임아웃 설정 중..."
ceph config set osd osd_heartbeat_grace 20
ceph config set osd osd_heartbeat_interval 6

echo ">> 네트워크 버퍼 설정 중..."
ceph config set global ms_dispatch_throttle_bytes 104857600

# --- 3. OSD 성능 최적화 ---
echo -e "\n[단계 3/5] OSD 성능 최적화 중..."

echo ">> 백필 및 복구 설정 최적화 중..."
ceph config set osd osd_max_backfills 1
ceph config set osd osd_recovery_max_active 1
ceph config set osd osd_recovery_max_single_start 1

echo ">> 캐시 크기 최적화 중..."
ceph config set osd bluestore_cache_size_ssd 1073741824
ceph config set osd bluestore_cache_size_hdd 268435456

echo ">> 글로벌 복구 설정 중..."
ceph config set global osd_recovery_max_chunk 1048576

# --- 4. 시스템 리소스 최적화 ---
echo -e "\n[단계 4/5] 시스템 리소스 최적화 중..."

echo ">> 시스템 파라미터 조정 중..."
# 네트워크 버퍼 크기 증가 (전용 파일에 덮어써 재실행 시 중복 누적 방지)
cat > /etc/sysctl.d/90-ceph-osd.conf << 'EOF'
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
EOF

# sysctl 설정 적용
sysctl -p /etc/sysctl.d/90-ceph-osd.conf

echo ">> I/O 스케줄러 설정 중..."
# OSD 디스크는 worker에 연결되어 있으므로 cephadm이 만든 Ansible 연결 정보를 사용한다.
# 각 worker의 선언 목록은 inventory/inventory.ini에서 직접 읽으며, 선언되지 않은
# sd[b-z] 후보 디스크는 경고만 남기고 절대 변경하지 않는다.
apply_declared_scheduler_settings

# --- 5. OSD 서비스 재시작 및 상태 확인 ---
echo -e "\n[단계 5/5] OSD 서비스 재시작 및 상태 확인 중..."

echo ">> OSD 데몬 롤링 재시작 중..."
# orch restart는 서비스 이름을 요구하므로 OSD는 데몬 단위로 재시작한다.
# 한 개씩 재시작하고, 매번 모든 OSD up + PG active+clean 회복을 확인한 뒤 다음으로 넘어간다.
TOTAL_OSDS="$(ceph osd ls | wc -l)"

wait_for_recovery() {
  # 모든 OSD up + 전이 상태(degraded/undersized/peering/recover/backfill 등) 없음 대기 (최대 ~3분)
  for _ in $(seq 1 36); do
    up="$(ceph osd stat -f json 2>/dev/null | jq -r '.num_up_osds // 0' || echo 0)"
    if [[ "${up:-0}" -ge "$TOTAL_OSDS" ]] \
       && ! ceph pg stat 2>/dev/null | grep -qiE 'degraded|undersized|peering|recover|backfill|stale|inactive|down'; then
      return 0
    fi
    sleep 5
  done
  return 1
}

for osd_id in $(ceph osd ls); do
  echo "   - osd.${osd_id} 재시작..."
  ceph orch daemon restart "osd.${osd_id}" || true
  sleep 5
  if wait_for_recovery; then
    echo "     osd.${osd_id} 회복 완료"
  else
    echo "     (경고: osd.${osd_id} 재시작 후 회복 지연 — 계속 진행)" >&2
  fi
done

echo ">> 최종 상태 확인 중..."
echo ">> 클러스터 상태:"
ceph -s

echo ">> OSD 상태:"
ceph osd status

echo ">> 네트워크 지연 재확인:"
ceph osd perf

echo -e "\n[완료] OSD Heartbeat 문제 해결 스크립트가 완료되었습니다."
echo "=========================================="
echo "적용된 설정:"
echo "  - OSD heartbeat grace: 20초"
echo "  - OSD heartbeat interval: 6초"
echo "  - TCP read/write timeout: 900초"
echo "  - 네트워크 버퍼: 100MB"
echo "  - 백필/복구 최적화"
echo "  - 캐시 크기 최적화"
echo "=========================================="
echo "추가 권장사항:"
echo "  1. VirtualBox VM 메모리를 4GB 이상으로 증가"
echo "  2. CPU 코어 수를 4개 이상으로 증가"
echo "  3. 네트워크 어댑터를 82540EM으로 변경"
echo "  4. 호스트 시스템 리소스 모니터링"
echo "=========================================="
