#!/usr/bin/env bash
set -euo pipefail

if ! command -v kubectl >/dev/null 2>&1; then
  echo "[monitoring] kubectl is not available. Run kubespray.sh first." >&2
  exit 1
fi
if ! command -v helm >/dev/null 2>&1; then
  echo "[monitoring] helm is not available. Enable helm in Kubespray first." >&2
  exit 1
fi

# 환경 변수 설정
MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-monitoring}"
GRAFANA_ADMIN_SECRET="${GRAFANA_ADMIN_SECRET:-grafana-admin}"
WORKDIR="${WORKDIR:-$HOME/k8s-install-manifests}"

# Helm 저장소 추가
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
helm repo add grafana https://grafana.github.io/helm-charts --force-update
helm repo update

# 모니터링 네임스페이스 생성
kubectl get storageclass rook-ceph-block >/dev/null
install -m 0755 -d "$WORKDIR"
kubectl create namespace "$MONITORING_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

if ! kubectl -n "$MONITORING_NAMESPACE" get secret "$GRAFANA_ADMIN_SECRET" >/dev/null 2>&1; then
  GRAFANA_ADMIN_PASSWORD="$(openssl rand -base64 24)"
  kubectl -n "$MONITORING_NAMESPACE" create secret generic "$GRAFANA_ADMIN_SECRET" \
    --from-literal=admin-user=admin \
    --from-literal=admin-password="$GRAFANA_ADMIN_PASSWORD"
fi
GRAFANA_ADMIN_PASSWORD="$(kubectl -n "$MONITORING_NAMESPACE" get secret "$GRAFANA_ADMIN_SECRET" -o jsonpath='{.data.admin-password}' | base64 --decode)"

# Prometheus 설정
cat > "$WORKDIR/prometheus-values.yaml" << EOF
server:
  persistentVolume:
    enabled: true
    storageClass: rook-ceph-block
    size: 10Gi
  service:
    type: NodePort
    nodePort: 30001
  resources:
    requests:
      cpu: "500m"
      memory: "1Gi"
    limits:
      cpu: "1000m"
      memory: "2Gi"
alertmanager:
  persistence:
    enabled: true
    storageClass: rook-ceph-block
    size: 5Gi
  resources:
    requests:
      cpu: "200m"
      memory: "256Mi"
    limits:
      cpu: "500m"
      memory: "512Mi"
EOF

# Prometheus 설치
helm upgrade --install prometheus prometheus-community/prometheus \
  -f "$WORKDIR/prometheus-values.yaml" \
  -n "$MONITORING_NAMESPACE" \
  --wait \
  --timeout 15m

# Grafana 설정
cat > "$WORKDIR/grafana-values.yaml" << EOF
admin:
  existingSecret: $GRAFANA_ADMIN_SECRET
  userKey: admin-user
  passwordKey: admin-password
persistence:
  enabled: true
  storageClassName: rook-ceph-block
  size: 5Gi
service:
  type: NodePort
  nodePort: 30002
resources:
  requests:
    cpu: "200m"
    memory: "256Mi"
  limits:
    cpu: "500m"
    memory: "512Mi"
datasources:
  datasources.yaml:
    apiVersion: 1
    datasources:
      - name: Prometheus
        type: prometheus
        url: http://prometheus-server.$MONITORING_NAMESPACE.svc.cluster.local
        access: proxy
        isDefault: true
dashboardProviders:
  dashboardproviders.yaml:
    apiVersion: 1
    providers:
      - name: 'default'
        orgId: 1
        folder: ''
        type: file
        disableDeletion: false
        editable: true
        options:
          path: /var/lib/grafana/dashboards
dashboards:
  default:
    kubernetes-cluster:
      gnetId: 7249
      revision: 1
      datasource: Prometheus
EOF

# Grafana 설치
helm upgrade --install grafana grafana/grafana \
  -f "$WORKDIR/grafana-values.yaml" \
  -n "$MONITORING_NAMESPACE" \
  --wait \
  --timeout 15m

# 접속 정보 출력
echo "Grafana 초기 관리자 비밀번호: $GRAFANA_ADMIN_PASSWORD"
echo "Prometheus URL: http://192.168.56.10:30001"
echo "Grafana URL: http://192.168.56.10:30002"
