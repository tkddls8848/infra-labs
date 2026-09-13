#!/bin/bash
#
# 스토리지 노드(워커)에서 root로 실행.
# 이 노드 전용 RBD 이미지 1개를 생성/맵/포맷/마운트해 블록 스토어로 만든다.
# (RBD는 단일 writer라 이미지 1개당 노드 1개만 마운트한다)
#
# 사전조건: 이 노드에 ceph 클라이언트 설정이 있어야 한다
#   - /etc/ceph/ceph.conf
#   - rbd 권한 키링 (예: /etc/ceph/ceph.client.block-store.keyring)
#   master에서 준비:
#     ceph auth get-or-create client.block-store \
#         mon 'profile rbd' osd 'profile rbd pool=rbd-pool' mgr 'profile rbd pool=rbd-pool' \
#       > /etc/ceph/ceph.client.block-store.keyring
#     ceph config generate-minimal-conf > /tmp/ceph.conf
#   위 ceph.conf + 키링을 각 워커의 /etc/ceph/ 로 복사한 뒤 CEPH_USER=block-store 로 실행.
#
# 사용: sudo POOL=rbd-pool SIZE=5G CEPH_USER=block-store bash setup-rbd-node.sh

set -euo pipefail

POOL="${POOL:-rbd-pool}"
IMAGE="${IMAGE:-block-store-$(hostname)}"
SIZE="${SIZE:-5G}"
MOUNT="${MOUNT:-/srv/rbd-store}"
CEPH_USER="${CEPH_USER:-admin}"
FSTYPE="${FSTYPE:-ext4}"
RBD="rbd --id ${CEPH_USER}"

echo "== RBD block store setup: pool=$POOL image=$IMAGE size=$SIZE mount=$MOUNT user=$CEPH_USER =="

modprobe rbd || true

# 1) 이미지 생성 (없을 때만)
if ! $RBD info "$POOL/$IMAGE" &>/dev/null; then
  echo ">> creating image $POOL/$IMAGE ($SIZE)"
  $RBD create "$POOL/$IMAGE" --size "$SIZE"
else
  echo ">> image already exists"
fi

# 2) 매핑 (이미 매핑돼 있으면 그 디바이스 재사용)
DEV="$($RBD showmapped 2>/dev/null | awk -v i="$IMAGE" '$0 ~ i {print $NF}' | head -n1)"
if [[ -z "$DEV" ]]; then
  DEV="$($RBD map "$POOL/$IMAGE")"
fi
echo ">> mapped device: $DEV"

# 3) 포맷 (파일시스템 없을 때만 — 기존 데이터 보호)
if ! blkid "$DEV" &>/dev/null; then
  echo ">> formatting $DEV ($FSTYPE)"
  mkfs."$FSTYPE" "$DEV"
else
  echo ">> filesystem already present, skip mkfs"
fi

# 4) 마운트
mkdir -p "$MOUNT"
if ! mountpoint -q "$MOUNT"; then
  mount "$DEV" "$MOUNT"
fi
chmod 0777 "$MOUNT"   # 실습용: 에이전트가 쓰기 가능하도록

echo ">> block store ready: $POOL/$IMAGE -> $DEV -> $MOUNT"
df -h "$MOUNT"
