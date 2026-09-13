#!/bin/bash
#
# Ceph Object Storage (RGW) 설치 및 테스트 스크립트 (s3cmd)
#

set -e  # 오류 발생 시 스크립트 중단

# 네트워크 인자 받기
NETWORK_PREFIX=$1
MASTER_IP=$2

# Object Storage 설정
export RGW_PORT=7480
export RGW_USER="s3user"
export RGW_DISPLAY_NAME="S3 Test User"
export RGW_BUCKET="testbucket"
export MASTER_HOSTNAME=$(hostname)  # cephadm 설치 시 지정한 hostname

echo "=========================================="
echo "Ceph Object Storage (s3cmd) 설치 시작"
echo "=========================================="
echo "RGW 포트: $RGW_PORT"
echo "마스터 호스트명: $MASTER_HOSTNAME"
echo "=========================================="

# --- 1. RGW 서비스 배포 ---
echo -e "\n[단계 1/4] RadosGW (RGW) 서비스 배포 중..."

# 간단한 방식으로 RGW 배포
ceph orch apply rgw s3 --port=$RGW_PORT --placement="1 $MASTER_HOSTNAME"

# RGW 서비스 시작 대기
echo "RGW 서비스 배포 대기 중..."
MAX_RETRIES=20
RETRY_INTERVAL=10
count=0

while [ $count -lt $MAX_RETRIES ]; do
  if ceph orch ls --service_name=rgw.s3 | grep -q "1/1"; then
    echo "RGW 서비스 성공적으로 배포됨"
    break
  fi
  echo "RGW 배포 대기 중... ($((count+1))/$MAX_RETRIES)"
  sleep $RETRY_INTERVAL
  count=$((count+1))
done

# --- 2. S3 사용자 생성 ---
echo -e "\n[단계 2/3] S3 사용자 생성 중..."
radosgw-admin user create --uid=$RGW_USER --display-name="$RGW_DISPLAY_NAME"

# 액세스 키 확인
ACCESS_KEY=$(radosgw-admin user info --uid=$RGW_USER | jq -r '.keys[0].access_key')
SECRET_KEY=$(radosgw-admin user info --uid=$RGW_USER | jq -r '.keys[0].secret_key')

echo "S3 사용자 생성 완료"
echo "Access Key: $ACCESS_KEY"
echo "Secret Key: <숨김>"

# --- 3. s3cmd 클라이언트 설치 및 테스트 ---
echo -e "\n[단계 3/3] s3cmd 클라이언트 설치 및 테스트"

echo ">> s3cmd 설치 중..."
apt-get install -y -q s3cmd

# s3cmd 설정 파일 생성
cat > ~/.s3cfg << EOF
[default]
access_key = $ACCESS_KEY
secret_key = $SECRET_KEY
host_base = $MASTER_IP:$RGW_PORT
host_bucket = $MASTER_IP:$RGW_PORT/%(bucket)s
bucket_location = default
use_https = False
check_ssl_certificate = False
check_ssl_hostname = False
signature_v2 = True
EOF

# 버킷 생성
echo ">> 테스트 버킷 생성 중..."
s3cmd mb s3://${RGW_BUCKET}-s3cmd || true

# 테스트 파일 업로드
echo ">> 테스트 파일 업로드 중..."
echo "Hello S3 from s3cmd" > test-s3cmd.txt
s3cmd put test-s3cmd.txt s3://${RGW_BUCKET}-s3cmd/

# 버킷 목록 확인
echo ">> 버킷 목록 확인 중..."
s3cmd ls

# --- 완료: 상태 확인 및 정보 표시 ---
echo -e "\n[완료] Object Storage 설치 완료"
echo ""
echo "===== Object Storage 정보 ====="
echo "RGW Endpoint: http://$MASTER_HOSTNAME:$RGW_PORT"
echo ""
echo "S3 API 접속 정보:"
echo "  Access Key: $ACCESS_KEY"
echo "  Secret Key: $SECRET_KEY"
echo "  설정 파일: ~/.s3cfg"
echo ""
echo "===== s3cmd 사용법 ====="
echo "  s3cmd ls                          # 버킷 목록"
echo "  s3cmd mb s3://<버킷>              # 버킷 생성"
echo "  s3cmd put <파일> s3://<버킷>/    # 파일 업로드"
echo "  s3cmd get s3://<버킷>/<파일>     # 파일 다운로드"
echo "  s3cmd del s3://<버킷>/<파일>     # 파일 삭제"
echo ""
echo "RGW 서비스 상태 확인:"
echo "  ceph orch ls --service_name=rgw.s3"
echo "  ceph -s"