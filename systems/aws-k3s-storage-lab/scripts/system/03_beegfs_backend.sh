#!/bin/bash
# Phase 4: Backend — BeeGFS 8 서비스 구성 및 기동
# 전제: beegfs-mgmtd, beegfs-meta, beegfs-storage, beegfs-utils, xfsprogs, lvm2 는 Packer AMI에 사전 설치됨
# 실행: ssh ec2-user@<BACKEND_IP> 'sudo bash -s' < 03_beegfs_backend.sh
set -e
export PATH="/usr/local/bin:/usr/local/sbin:$PATH"

PRIVATE_IP=$(hostname -I | awk '{print $1}')

echo "=============================="
echo " [1/3] 스토리지 디스크 준비 (EBS volume ID → LVM 스트라이프 → XFS)"
echo "=============================="
# Nitro NVMe 번호는 부트 순서에 따라 비결정적 — EBS volume serial로 정확히 식별
: "${BEEGFS_STORAGE_1_VOL:?필수: BEEGFS_STORAGE_1_VOL 환경변수 없음}"
: "${BEEGFS_STORAGE_2_VOL:?필수: BEEGFS_STORAGE_2_VOL 환경변수 없음}"

vol_to_dev() {
  local vol_id="${1//-/}"  # vol-0abc123 → vol0abc123
  local by_id="/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${vol_id}"
  if [ -L "$by_id" ]; then
    readlink -f "$by_id"
  else
    lsblk -o NAME,SERIAL -d 2>/dev/null \
      | awk -v s="${vol_id}" 'tolower($2) == tolower(s) {print "/dev/" $1}' \
      | head -1
  fi
}

BEEGFS_DEV1=$(vol_to_dev "$BEEGFS_STORAGE_1_VOL")
BEEGFS_DEV2=$(vol_to_dev "$BEEGFS_STORAGE_2_VOL")
if [ -z "$BEEGFS_DEV1" ] || [ -z "$BEEGFS_DEV2" ]; then
  echo "❌ EBS volume → 디바이스 매핑 실패."
  echo "  BEEGFS_STORAGE_1_VOL=$BEEGFS_STORAGE_1_VOL → $BEEGFS_DEV1"
  echo "  BEEGFS_STORAGE_2_VOL=$BEEGFS_STORAGE_2_VOL → $BEEGFS_DEV2"
  echo "  lsblk --output NAME,SERIAL:"
  lsblk -o NAME,SERIAL
  exit 1
fi
echo "  BeeGFS 디스크 #1: $BEEGFS_DEV1 ($BEEGFS_STORAGE_1_VOL)"
echo "  BeeGFS 디스크 #2: $BEEGFS_DEV2 ($BEEGFS_STORAGE_2_VOL)"

pvcreate -ff -y "$BEEGFS_DEV1" "$BEEGFS_DEV2"
vgcreate beegfs-vg "$BEEGFS_DEV1" "$BEEGFS_DEV2"
lvcreate -i 2 -l 100%VG -n beegfs-lv beegfs-vg
mkfs.xfs /dev/beegfs-vg/beegfs-lv
mkdir -p /mnt/beegfs/storage
mount /dev/beegfs-vg/beegfs-lv /mnt/beegfs/storage
grep -q "beegfs-vg" /etc/fstab || \
  echo "/dev/beegfs-vg/beegfs-lv /mnt/beegfs/storage xfs defaults 0 0" >> /etc/fstab
mkdir -p /mnt/beegfs/mgmtd /mnt/beegfs/meta

echo "=============================="
echo " [2/3] BeeGFS 8 서비스 설정"
echo "=============================="
# ── mgmtd: TOML 형식 (Rust 기반, SQLite DB 사용) ──────────────────────
# tls-disable = true 필수 — BeeGFS 8은 TLS를 기본 요구, 미설정 시 서비스 시작 실패
cat > /etc/beegfs/beegfs-mgmtd.toml <<EOF
beemsg-port  = 8008
grpc-port    = 8010
log-level    = "info"
auth-disable = true
tls-disable  = true
db-file      = "/mnt/beegfs/mgmtd/mgmtd.sqlite"
EOF

# ── meta: .conf 형식 (기존 C++ 서비스, BeeGFS 8에서도 .conf 유지) ─────
cat > /etc/beegfs/beegfs-meta.conf <<EOF
sysMgmtdHost              = ${PRIVATE_IP}
connMetaPortTCP           = 8005
connMetaPortUDP           = 8005
storeMetaDirectory        = /mnt/beegfs/meta
storeAllowFirstRunInit    = true
connDisableAuthentication = true
logLevel                  = 3
EOF

# ── storage: .conf 형식 ────────────────────────────────────────────────
cat > /etc/beegfs/beegfs-storage.conf <<EOF
sysMgmtdHost              = ${PRIVATE_IP}
connStoragePortTCP        = 8003
connStoragePortUDP        = 8003
storeStorageDirectory     = /mnt/beegfs/storage
storeAllowFirstRunInit    = true
connDisableAuthentication = true
logLevel                  = 3
EOF

echo "=============================="
echo " [3/3] 데몬 기동"
echo "=============================="
# mgmtd SQLite DB 초기화 (첫 기동 전 필수)
/opt/beegfs/sbin/beegfs-mgmtd --init 2>/dev/null || true

_start_svc() {
  local svc="$1"
  systemctl enable "$svc"
  systemctl start "$svc" || {
    echo "❌ ${svc} 시작 실패. journalctl 출력:"
    journalctl -u "$svc" --no-pager -n 50
    exit 1
  }
}

_start_svc beegfs-mgmtd
echo "  mgmtd 기동 대기 (10초)..."
sleep 10

_start_svc beegfs-meta
_start_svc beegfs-storage

echo "  서비스 안정화 대기 (10초)..."
sleep 10

for svc in beegfs-mgmtd beegfs-meta beegfs-storage; do
  systemctl is-active "$svc" || {
    echo "❌ ${svc} 비정상. journalctl 출력:"
    journalctl -u "$svc" --no-pager -n 50
    exit 1
  }
done

# BeeGFS 8 CLI (beegfs — Go 기반, beegfs-utils 패키지)
beegfs node list --node-type=storage 2>/dev/null \
  || beegfs-ctl --listnodes --nodetype=storage 2>/dev/null \
  || echo "  (beegfs CLI 확인 필요)"
beegfs node list --node-type=meta 2>/dev/null \
  || beegfs-ctl --listnodes --nodetype=meta 2>/dev/null \
  || echo "  (beegfs CLI 확인 필요)"

echo ""
echo "BeeGFS 8 backend 구성 완료"
echo "   mgmtd IP: ${PRIVATE_IP}:8008"
