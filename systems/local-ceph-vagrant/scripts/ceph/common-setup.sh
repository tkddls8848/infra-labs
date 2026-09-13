#!/bin/bash
#
# Ceph 클러스터 공통 설치 스크립트 (워커/마스터 노드 공통)
#   - 시스템 기본 설정
#   - Docker 설치
#   - Ceph 공통 패키지 설치
#   - 네트워크 설정
#   - 노드별 특화 설정
#

set -e  # 오류 발생 시 스크립트 중단

# 비대화형 설치를 위한 환경 변수 설정 (스크립트 시작 시)
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

# needrestart 설정 (패키지 설치 이전에 적용해야 효과가 있음)
mkdir -p /etc/needrestart/conf.d
cat > /etc/needrestart/conf.d/50local.conf << 'EOF'
$nrconf{restart} = 'a';
$nrconf{kernelhints} = -1;
EOF

# 인자 받기 (누락 시 즉시 실패)
MASTER_IP="${1:?master ip is required}"
NETWORK_PREFIX="${2:?network prefix is required}"
WORKER_LENGTH="${3:?worker length is required}"
CEPH_PUBLIC_NETWORK="${CEPH_PUBLIC_NETWORK:?public network from inventory is required}"
CEPH_CLUSTER_NETWORK="${CEPH_CLUSTER_NETWORK:?cluster network from inventory is required}"

if [[ "$CEPH_PUBLIC_NETWORK" != "${NETWORK_PREFIX}.0/24" ]]; then
  echo "ERROR: public network $CEPH_PUBLIC_NETWORK does not match network prefix $NETWORK_PREFIX" >&2
  exit 1
fi
if [[ "$CEPH_PUBLIC_NETWORK" == "$CEPH_CLUSTER_NETWORK" ]]; then
  echo "ERROR: public and cluster networks must be different: $CEPH_PUBLIC_NETWORK" >&2
  exit 1
fi

# 노드 타입 확인 (호스트명으로 판단)
NODE_TYPE="worker"
[[ $(hostname) == "ceph-master" ]] && NODE_TYPE="master"

echo "=========================================="
echo "Ceph 클러스터 공통 설치 스크립트 시작"
echo "=========================================="
echo "마스터 IP: $MASTER_IP"
echo "네트워크: $NETWORK_PREFIX"
echo "워커 노드 수: $WORKER_LENGTH"
echo "현재 노드 타입: $NODE_TYPE"
echo "현재 호스트명: $(hostname)"
echo "=========================================="

# --- 1. 시스템 업데이트 (공통) ---
echo -e "\n[단계 1/6] 시스템 업데이트를 시작합니다..."

echo ">> APT 업데이트 중..."
apt-get update -y

echo ">> 기본 패키지 설치 중..."
apt-get install -y -q curl gnupg2 ca-certificates

# --- 2. Docker 설치 (공통) ---
echo -e "\n[단계 2/6] Docker 설치를 시작합니다..."

echo ">> Docker 공식 저장소 추가 중..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update -y

echo ">> Docker Engine 설치 중..."
apt-get install -y -q docker-ce docker-ce-cli containerd.io

echo ">> Docker 서비스 활성화 중..."
systemctl enable docker
systemctl restart docker

echo ">> Docker 설치 확인 중..."
if command -v docker &> /dev/null; then
    echo ">> Docker 설치 성공: $(docker --version)"
else
    echo ">> Docker 설치 실패"
    exit 1
fi

# --- 3. Ceph 공통 패키지 설치 (공통) ---
echo -e "\n[단계 3/6] Ceph 공통 패키지 설치를 시작합니다..."

echo ">> Ceph 공통 패키지 설치 중..."
apt-get install -y -q ceph-common lvm2

echo ">> 시간 동기화 서비스 설정 중..."
apt-get install -y -q chrony
systemctl enable chrony
systemctl restart chrony

# --- 4. 네트워크 설정 (공통) ---
echo -e "\n[단계 4/6] 네트워크 설정을 시작합니다..."

# privileged(root) 실행이므로 sudo 없이 직접 append
echo ">> /etc/hosts 파일 업데이트 중..."
MASTER_HOSTNAME="ceph-master"
grep -q "$MASTER_IP $MASTER_HOSTNAME" /etc/hosts || echo "$MASTER_IP $MASTER_HOSTNAME" >> /etc/hosts

for i in $(seq 1 "$WORKER_LENGTH"); do
  WORKER_IP="${NETWORK_PREFIX}.$((i + 10))"
  WORKER_HOSTNAME="ceph-worker-${i}"
  grep -q "$WORKER_IP $WORKER_HOSTNAME" /etc/hosts || echo "$WORKER_IP $WORKER_HOSTNAME" >> /etc/hosts
done

# --- 5. 노드별 특화 설정 ---
echo -e "\n[단계 5/6] 노드별 특화 설정을 시작합니다..."

if [[ $NODE_TYPE == "master" ]]; then
    echo ">> 마스터 노드 특화 설정 중..."

    # jq: object-storage(radosgw-admin) 파싱, ceph-fuse: CephFS 마운트 테스트 — 마스터에서만 사용
    echo ">> 마스터 노드용 패키지 설치 중..."
    apt-get install -y -q ansible jq ceph-fuse

    # Ceph host 도구(cephadm/ceph-common)는 배포판 패키지를 사용한다.
    # 클러스터 컨테이너 버전은 cephadm-setup.sh의 --image로 고정한다.
    if ! command -v cephadm &> /dev/null; then
        echo ">> cephadm 설치 중..."
        apt-get install -y -q cephadm
    fi

    echo ">> 마스터 노드용 디렉토리 생성 중..."
    mkdir -p /opt/ceph/{config,logs,backup}

    echo ">> 마스터 노드 설정 완료"
else
    echo ">> 워커 노드 특화 설정 중..."

    echo ">> 워커 노드용 디렉토리 생성 중..."
    mkdir -p /opt/ceph/{osd,logs}

    echo ">> 블록 디바이스 현황 (OSD 대상은 inventory의 osd_devices만 사용):"
    lsblk -d -o NAME,SIZE,TYPE

    echo ">> 워커 노드 설정 완료"
fi

# --- 6. 환경 변수 설정 (공통) ---
echo -e "\n[단계 6/6] 환경 변수 설정을 시작합니다..."

# /etc/environment는 pam_env 파일이라 export 문법을 지원하지 않는다 → KEY=VALUE 사용.
# 재프로비저닝 시 중복 누적을 막기 위해 기존 키를 제거 후 재기록(멱등).
echo ">> Ceph 환경 변수 기록 중..."
CEPH_ENV_LINES=(
  "CEPH_PUBLIC_NETWORK=${CEPH_PUBLIC_NETWORK}"
  "CEPH_CLUSTER_NETWORK=${CEPH_CLUSTER_NETWORK}"
)
for line in "${CEPH_ENV_LINES[@]}"; do
  key="${line%%=*}"
  sed -i "/^${key}=/d" /etc/environment
  echo "$line" >> /etc/environment
done

# --- 설치 완료 요약 ---
echo -e "\n=========================================="
echo "Ceph 클러스터 공통 설치 완료"
echo "=========================================="
echo "노드 타입: $NODE_TYPE"
echo "호스트명: $(hostname)"
echo "IP 주소: $(hostname -I | awk '{print $1}')"
echo "Docker 버전: $(docker --version)"
echo "설치된 패키지:"
echo "  - Docker: $(which docker)"
echo "  - SSH: $(systemctl is-active ssh)"
echo "  - Chrony: $(systemctl is-active chrony)"
echo "  - Ceph Common: $(which ceph)"
if [[ $NODE_TYPE == "master" ]]; then
    echo "  - Cephadm: $(which cephadm)"
fi
echo "=========================================="

echo -e "\n[완료] Ceph 클러스터 공통 설치가 완료되었습니다."
echo "다음 단계:"
if [[ $NODE_TYPE == "master" ]]; then
    echo "  - cephadm-setup.sh 실행 (Ceph 클러스터 초기화)"
else
    echo "  - 마스터 노드에서 Ceph 클러스터 초기화 대기"
fi
