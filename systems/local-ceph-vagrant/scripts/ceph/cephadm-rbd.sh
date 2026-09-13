#!/bin/bash
#
# Ceph RBD 설치 스크립트 (Podman 버전)
#

set -e  # 오류 발생 시 스크립트 중단

# 네트워크 인자 받기
NETWORK_PREFIX=$1
MASTER_IP=$2

echo "=========================================="
echo "Ceph RBD 설치 시작"
echo "=========================================="
echo "네트워크 설정: NETWORK_PREFIX=$NETWORK_PREFIX, MASTER_IP=$MASTER_IP"
echo "=========================================="

# --- 1. 설정 변수 ---
# Ceph RBD 기본 설정
export CEPH_POOL_NAME="rbd-pool"
export CEPH_PG_NUM=128

# Ceph 클라이언트 사용자 설정
export CEPH_CSI_USER="csi-rbd-user"

# --- 2. Ceph RBD 풀 생성 ---
echo -e "\n[단계 1/4] Ceph RBD 풀 생성을 시작합니다..."

# 2.1 RBD 풀 생성 및 초기화
echo ">> RBD 풀 '$CEPH_POOL_NAME' 생성 중..."
ceph osd pool create "$CEPH_POOL_NAME" "$CEPH_PG_NUM" replicated
ceph osd pool application enable "$CEPH_POOL_NAME" rbd
rbd pool init "$CEPH_POOL_NAME"
echo ">> RBD 풀 생성 완료"

# 풀 상태 확인
echo ">> RBD 풀 상태 확인:"
ceph osd pool ls | grep "$CEPH_POOL_NAME"
echo "[단계 1/4] Ceph RBD 풀 생성 완료"

# --- 3. CSI 사용자 생성 및 클러스터 정보 수집 ---
echo -e "\n[단계 2/4] CSI 사용자 생성 및 클러스터 정보 수집을 시작합니다..."

# 3.1 CSI 클라이언트 사용자 생성
echo ">> Ceph 사용자 'client.$CEPH_CSI_USER' 생성 및 권한 부여 중..."
ceph auth add client.$CEPH_CSI_USER \
  mon 'profile rbd' \
  osd "profile rbd pool=$CEPH_POOL_NAME" \
  mgr "profile rbd pool=$CEPH_POOL_NAME"
echo ">> 사용자 생성 완료"

# 3.2 사용자 키링 및 클러스터 정보 수집
echo ">> Ceph 사용자 키링 및 클러스터 정보 수집 중..."
# 키링 가져오기
CEPH_USER_KEYRING=$(ceph auth get-key client.$CEPH_CSI_USER)

# 클러스터 ID 가져오기
CEPH_CLUSTER_ID=$(ceph fsid)

# 모니터 주소 목록 가져오기 (v1 Port 6789)
CEPH_MONITOR_IPS=$(ceph mon dump 2>/dev/null | grep -oE 'v1:[0-9.]+:6789' | sed 's/v1://' | tr '\n' ',' | sed 's/,$//')

# 수집된 정보 확인
echo ">> 수집된 Ceph 클러스터 정보:"
echo "   - Cluster ID: $CEPH_CLUSTER_ID"
echo "   - Monitor IPs: $CEPH_MONITOR_IPS"
echo "   - User Keyring (client.$CEPH_CSI_USER): *****" # 보안상 키링 값은 마스킹 처리
echo "[단계 2/4] CSI 사용자 생성 및 클러스터 정보 수집 완료"

# --- 4. RBD 이미지 생성 및 테스트 ---
echo -e "\n[단계 3/4] RBD 이미지 생성 및 테스트를 시작합니다..."

# RBD 이미지 생성
RBD_IMAGE_NAME="test-image"
RBD_IMAGE_SIZE="1G"

echo ">> RBD 이미지 '$RBD_IMAGE_NAME' 생성 중..."
rbd create --pool "$CEPH_POOL_NAME" --image "$RBD_IMAGE_NAME" --size "$RBD_IMAGE_SIZE"

# 이미지 정보 확인
echo ">> RBD 이미지 정보 확인:"
rbd info --pool "$CEPH_POOL_NAME" --image "$RBD_IMAGE_NAME"

# 이미지 목록 확인
echo ">> RBD 이미지 목록:"
rbd ls --pool "$CEPH_POOL_NAME"

echo "[단계 3/4] RBD 이미지 생성 완료"

# --- 5. RBD 마운트 테스트 ---
echo -e "\n[단계 4/4] RBD 마운트 테스트를 시작합니다..."

# 커널 모듈 로드
echo ">> RBD 커널 모듈 로드 중..."
modprobe rbd

# RBD 디바이스 매핑
echo ">> RBD 디바이스 매핑 중..."
rbd map --pool "$CEPH_POOL_NAME" --image "$RBD_IMAGE_NAME"

# 매핑된 디바이스 확인
RBD_DEVICE=$(rbd showmapped | grep "$RBD_IMAGE_NAME" | awk '{print $5}')
echo ">> 매핑된 디바이스: $RBD_DEVICE"

if [ -n "$RBD_DEVICE" ]; then
    # 파일시스템 생성
    echo ">> 파일시스템 생성 중..."
    mkfs.ext4 "$RBD_DEVICE"
    
    # 마운트 포인트 생성
    MOUNT_POINT="/mnt/rbd"
    echo ">> 마운트 포인트 '$MOUNT_POINT' 생성 중..."
    mkdir -p "$MOUNT_POINT"
    
    # 마운트
    echo ">> RBD 디바이스 마운트 중..."
    mount "$RBD_DEVICE" "$MOUNT_POINT"
    
    # 마운트 확인
    if mountpoint -q "$MOUNT_POINT"; then
        echo ">> RBD 마운트 성공!"
        echo "   마운트 포인트: $MOUNT_POINT"
        echo "   디바이스: $RBD_DEVICE"
        
        # 테스트 파일 생성
        echo ">> 테스트 파일 생성 중..."
        echo "RBD 테스트 파일 - $(date)" > "$MOUNT_POINT/test.txt"
        echo "   테스트 파일 생성 완료: $MOUNT_POINT/test.txt"
        
        # 파일 내용 확인
        echo ">> 테스트 파일 내용:"
        cat "$MOUNT_POINT/test.txt"
        
        # 마운트 해제
        echo ">> 마운트 해제 중..."
        umount "$MOUNT_POINT"
        
        # RBD 디바이스 언매핑
        echo ">> RBD 디바이스 언매핑 중..."
        rbd unmap "$RBD_DEVICE"
        
        echo ">> RBD 테스트 완료"
    else
        echo ">> RBD 마운트 실패!"
        exit 1
    fi
else
    echo ">> RBD 디바이스 매핑 실패!"
    exit 1
fi

echo -e "\n[완료] Ceph RBD 설치 및 테스트가 완료되었습니다."
echo "=========================================="
echo "RBD 사용법:"
echo "  - 이미지 생성: rbd create --pool $CEPH_POOL_NAME --image <이미지명> --size <크기>"
echo "  - 디바이스 매핑: rbd map --pool $CEPH_POOL_NAME --image <이미지명>"
echo "  - 마운트: mount <디바이스> <마운트포인트>"
echo "  - 언매핑: rbd unmap <디바이스>"
echo "  - 이미지 목록: rbd ls --pool $CEPH_POOL_NAME"
echo "=========================================="