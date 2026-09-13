#!/bin/bash
# Phase 3: Backend — Ceph 클러스터 구성 실행
# 전제: podman, cephadm, nvme-cli 는 Packer AMI에 사전 설치됨
# 실행: ssh ec2-user@<BACKEND_IP> 'sudo bash -s' < 02_ceph_backend.sh
set -e

PRIVATE_IP=$(hostname -I | awk '{print $1}')
HOSTNAME=$(hostname -f)  # Ceph은 --allow-fqdn-hostname 으로 bootstrap — FQDN 필수

echo "=============================="
echo " [1/5] Ceph 클러스터 부트스트랩"
echo "=============================="
# 기존 클러스터가 있으면 먼저 정리
EXISTING_FSID=$(cephadm ls 2>/dev/null | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print(d[0]['fsid'] if d else '')" 2>/dev/null || true)
if [ -n "$EXISTING_FSID" ]; then
  echo "  기존 클러스터 감지 (fsid: $EXISTING_FSID) — 정리 중..."
  # hung 컨테이너 강제 정리 후 rm-cluster
  podman ps -aq --filter "label=ceph=True" 2>/dev/null \
    | xargs -r podman rm -f 2>/dev/null || true
  cephadm rm-cluster --force --zap-osds --fsid "$EXISTING_FSID" || true
  echo "  기존 클러스터 정리 완료"
fi

cephadm bootstrap \
  --mon-ip "${PRIVATE_IP}" \
  --single-host-defaults \
  --skip-monitoring-stack \
  --allow-overwrite \
  --allow-fqdn-hostname

echo "=============================="
echo " [2/5] Orchestrator 준비 대기"
echo "=============================="
# bootstrap 직후엔 MGR orchestrator가 아직 초기화 중 — 먼저 대기
for i in $(seq 1 30); do
  ORCH_STATUS=$(cephadm shell -- ceph orch status --format json 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('available', False))" 2>/dev/null || echo "False")
  [ "$ORCH_STATUS" = "True" ] && { echo "  Orchestrator ready ✅"; break; }
  echo -n "  ($i/30) 대기..."; sleep 10
done

# OSD 자동 탐색 비활성화 — BeeGFS 디스크를 Ceph가 선점하지 않도록
cephadm shell -- ceph orch apply osd --all-available-devices --unmanaged=true

echo "=============================="
echo " [3/5] 단일 노드 복제 설정"
echo "=============================="
cephadm shell -- ceph config set global osd_pool_default_size 1
cephadm shell -- ceph config set global osd_pool_default_min_size 1

cephadm shell -- ceph osd crush rule rm replicated_rule 2>/dev/null || true
cephadm shell -- ceph osd crush rule create-replicated replicated_rule default host

echo "=============================="
echo " [4/5] OSD 추가 (EBS volume ID로 디스크 탐색)"
echo "=============================="
# Nitro NVMe 번호는 부트 순서에 따라 비결정적 — EBS volume serial로 정확히 식별
# /dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_vol<id_no_dashes> 심볼릭 링크 사용
: "${CEPH_OSD_1_VOL:?필수: CEPH_OSD_1_VOL 환경변수 없음}"
: "${CEPH_OSD_2_VOL:?필수: CEPH_OSD_2_VOL 환경변수 없음}"

vol_to_dev() {
  local vol_id="${1//-/}"  # vol-0abc123 → vol0abc123
  local by_id="/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${vol_id}"
  if [ -L "$by_id" ]; then
    readlink -f "$by_id"
  else
    # fallback: lsblk --output SERIAL 으로 매핑
    lsblk -o NAME,SERIAL -d 2>/dev/null \
      | awk -v s="${vol_id}" 'tolower($2) == tolower(s) {print "/dev/" $1}' \
      | head -1
  fi
}

OSD_DEV1=$(vol_to_dev "$CEPH_OSD_1_VOL")
OSD_DEV2=$(vol_to_dev "$CEPH_OSD_2_VOL")
if [ -z "$OSD_DEV1" ] || [ -z "$OSD_DEV2" ]; then
  echo "❌ EBS volume → 디바이스 매핑 실패."
  echo "  CEPH_OSD_1_VOL=$CEPH_OSD_1_VOL → $OSD_DEV1"
  echo "  CEPH_OSD_2_VOL=$CEPH_OSD_2_VOL → $OSD_DEV2"
  echo "  /dev/disk/by-id 목록:"
  ls /dev/disk/by-id/ | grep -i beegfs || ls /dev/disk/by-id/
  lsblk -o NAME,SERIAL
  exit 1
fi
echo "  Ceph OSD 디스크 #1: $OSD_DEV1 ($CEPH_OSD_1_VOL)"
echo "  Ceph OSD 디스크 #2: $OSD_DEV2 ($CEPH_OSD_2_VOL)"

# 이전 Ceph 잔재(LVM 메타데이터) 완전 제거 — rollback 후 재실행 시 필수
cephadm shell -- ceph orch device zap "${HOSTNAME}" "${OSD_DEV1}" --force 2>/dev/null || true
cephadm shell -- ceph orch device zap "${HOSTNAME}" "${OSD_DEV2}" --force 2>/dev/null || true
sleep 5

cephadm shell -- ceph orch daemon add osd "${HOSTNAME}:${OSD_DEV1}"
cephadm shell -- ceph orch daemon add osd "${HOSTNAME}:${OSD_DEV2}"

echo "OSD 준비 대기 (90초)..."
sleep 90

# OSD 실제 기동 검증
OSD_COUNT=$(cephadm shell -- ceph osd stat --format json 2>/dev/null \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('num_up_osds', 0))" 2>/dev/null || echo "0")
if [ "$OSD_COUNT" -lt 1 ]; then
  echo "❌ OSD 기동 실패 (up OSD: ${OSD_COUNT}). 진단 정보:"
  cephadm shell -- ceph orch ps
  cephadm shell -- ceph health detail
  exit 1
fi
echo "  OSD up: ${OSD_COUNT} ✅"
cephadm shell -- ceph osd tree

echo "=============================="
echo " [5/6] CephFS 활성화"
echo "=============================="
cephadm shell -- ceph fs volume create cephfs
cephadm shell -- ceph fs subvolumegroup create cephfs csi
echo "  CephFS CSI subvolume group 생성 ✅"

echo "=============================="
echo " [6/6] 클러스터 안정화 + RBD pool 생성"
echo "=============================="
echo "  Ceph HEALTH_OK/WARN 대기 (최대 5분)..."
CEPH_HEALTH=""
for i in $(seq 1 30); do
  CEPH_HEALTH=$(cephadm shell -- ceph health --format json 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status',''))" 2>/dev/null || echo "")
  if [ "$CEPH_HEALTH" = "HEALTH_OK" ] || [ "$CEPH_HEALTH" = "HEALTH_WARN" ]; then
    echo "  Ceph 상태: $CEPH_HEALTH ✅"
    break
  fi
  echo -n "  ($i/30) ${CEPH_HEALTH:-UNKNOWN} 대기 중..."; sleep 10
done
if [ "$CEPH_HEALTH" != "HEALTH_OK" ] && [ "$CEPH_HEALTH" != "HEALTH_WARN" ]; then
  echo "❌ Ceph 클러스터 안정화 실패 (상태: ${CEPH_HEALTH:-UNKNOWN})"
  cephadm shell -- ceph health detail
  exit 1
fi

cephadm shell -- ceph osd pool create kubernetes 2>/dev/null || true
cephadm shell -- ceph config set global mon_allow_pool_size_one true
cephadm shell -- ceph osd pool set kubernetes size 1 --yes-i-really-mean-it
cephadm shell -- ceph osd pool set kubernetes min_size 1
cephadm shell -- ceph osd pool application enable kubernetes rbd 2>/dev/null || true
# 모든 pool size=1 적용 (단일 노드 랩)
for pool in $(cephadm shell -- ceph osd pool ls 2>/dev/null); do
  cephadm shell -- ceph osd pool set "$pool" size 1 --yes-i-really-mean-it 2>/dev/null || true
done
cephadm shell -- ceph config set global mon_warn_on_pool_no_redundancy false
echo "  kubernetes RBD pool 생성 ✅"

cephadm shell -- ceph -s
echo ""
echo "=============================="
echo " Ceph 사이클 완료"
echo "=============================="
echo "  fsid      : $(cephadm shell -- ceph fsid 2>/dev/null)"
echo "  admin key : $(cephadm shell -- ceph auth get-key client.admin 2>/dev/null)"
echo "  mon IP    : ${PRIVATE_IP}"
