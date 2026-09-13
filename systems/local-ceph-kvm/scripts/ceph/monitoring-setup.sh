#!/bin/bash
#
# Ceph 모니터링 설정 스크립트 (cephadm orchestrator 네이티브)
#   - Ceph Dashboard 활성화
#   - cephadm orchestrator로 Prometheus/Grafana/Alertmanager/node-exporter 배포
#   - Dashboard ↔ Grafana/Prometheus 자동 연동 (수동 데이터소스 설정 불필요)
#
set -euo pipefail

HOST_IP="$(hostname -I | awk '{print $1}')"

echo "=========================================="
echo "Ceph 모니터링 설정 시작 (cephadm 네이티브)"
echo "현재 호스트: $(hostname) ($HOST_IP)"
echo "=========================================="

# --- 1. Ceph Dashboard 활성화 ---
echo -e "\n[단계 1/4] Ceph Dashboard 활성화 중..."
ceph mgr module enable dashboard
ceph config set mgr mgr/dashboard/ssl false          # 실습용: Dashboard HTTPS 비활성화
ceph config set mgr mgr/dashboard/server_port 8080

# 로그인 자격증명 (실습용 admin/admin)
DASHBOARD_PW_FILE="$(mktemp)"
printf 'admin' > "$DASHBOARD_PW_FILE"
ceph dashboard set-login-credentials admin -i "$DASHBOARD_PW_FILE"
rm -f "$DASHBOARD_PW_FILE"

# --- 2. Prometheus mgr exporter 모듈 활성화 ---
echo -e "\n[단계 2/4] Prometheus mgr exporter 모듈 활성화 중..."
ceph mgr module enable prometheus
ceph config set mgr mgr/prometheus/server_port 9283

# --- 3. 모니터링 스택 배포 (cephadm orchestrator) ---
echo -e "\n[단계 3/4] 모니터링 스택 배포 중 (node-exporter/prometheus/alertmanager/grafana)..."
# 컨테이너 이미지는 cephadm이 ceph 릴리스별로 고정한 기본값을 사용한다(latest 아님).
ceph orch apply node-exporter
ceph orch apply prometheus
ceph orch apply alertmanager
ceph orch apply grafana
# orchestrator 배포 시 Dashboard가 Grafana/Prometheus API URL을 자동 연동한다.
ceph dashboard set-grafana-api-ssl-verify false || true   # 실습용: self-signed 인증서 검증 비활성화

# --- 4. 배포 상태 확인 ---
echo -e "\n[단계 4/4] 모니터링 스택 배포 대기 및 확인 중..."
MAX_RETRIES=30
RETRY_INTERVAL=10
count=0
while [ "$count" -lt "$MAX_RETRIES" ]; do
  if ceph orch ls grafana 2>/dev/null | grep -q "1/1"; then
    echo ">> Grafana 배포 완료"
    break
  fi
  echo "   모니터링 스택 배포 대기 중... ($((count+1))/$MAX_RETRIES)"
  sleep "$RETRY_INTERVAL"
  count=$((count+1))
done

echo ">> MGR 모듈 상태:"
ceph mgr module ls | grep -E "(dashboard|prometheus)" || true
echo ">> orchestrator 서비스 목록:"
ceph orch ls

echo -e "\n[완료] Ceph 모니터링 설정 완료"
echo "=========================================="
echo "Ceph Dashboard : http://${HOST_IP}:8080  (admin/admin)"
echo "Grafana        : ceph orch ps --daemon_type grafana 로 노드 확인 (기본 3000)"
echo "Prometheus     : 기본 9095, Ceph metrics exporter: http://${HOST_IP}:9283/metrics"
echo "Alertmanager   : 기본 9093"
echo "------------------------------------------"
echo "유용한 명령어: ceph -s / ceph orch ls / ceph orch ps / ceph health detail"
echo "=========================================="
