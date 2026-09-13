#!/usr/bin/env bash
set -euo pipefail

# kubectl 사용 가능 여부 확인
if ! command -v kubectl >/dev/null 2>&1; then
  echo "[jenkins] kubectl is not available. Run kubespray.sh first." >&2
  exit 1
fi
if ! command -v helm >/dev/null 2>&1; then
  echo "[jenkins] helm is not available. Enable helm in Kubespray first." >&2
  exit 1
fi

# 환경 변수 설정
JENKINS_NAMESPACE="${JENKINS_NAMESPACE:-devops-tools}"
JENKINS_ADMIN_SECRET="${JENKINS_ADMIN_SECRET:-jenkins-admin}"
WORKDIR="${WORKDIR:-$HOME/k8s-install-manifests}"

kubectl get storageclass rook-ceph-block >/dev/null
install -m 0755 -d "$WORKDIR"
kubectl create namespace "$JENKINS_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

if ! kubectl -n "$JENKINS_NAMESPACE" get secret "$JENKINS_ADMIN_SECRET" >/dev/null 2>&1; then
  JENKINS_ADMIN_PASSWORD="$(openssl rand -base64 24)"
  kubectl -n "$JENKINS_NAMESPACE" create secret generic "$JENKINS_ADMIN_SECRET" \
    --from-literal=jenkins-admin-user=admin \
    --from-literal=jenkins-admin-password="$JENKINS_ADMIN_PASSWORD"
fi
JENKINS_ADMIN_PASSWORD="$(kubectl -n "$JENKINS_NAMESPACE" get secret "$JENKINS_ADMIN_SECRET" -o jsonpath='{.data.jenkins-admin-password}' | base64 --decode)"

# Jenkins 설치
cat > "$WORKDIR/jenkins-values.yaml" << EOF
controller:
  admin:
    existingSecret: $JENKINS_ADMIN_SECRET
    userKey: jenkins-admin-user
    passwordKey: jenkins-admin-password
  resources:
    requests:
      cpu: "500m"
      memory: "1Gi"
    limits:
      cpu: "1000m"
      memory: "2Gi"
  serviceType: NodePort
  nodePort: 30000
persistence:
  enabled: true
  storageClass: rook-ceph-block
  size: 10Gi
agent:
  resources:
    requests:
      cpu: "200m"
      memory: "256Mi"
    limits:
      cpu: "500m"
      memory: "512Mi"
EOF

# Helm으로 Jenkins 설치
helm repo add jenkins https://charts.jenkins.io --force-update
helm repo update
helm upgrade --install jenkins jenkins/jenkins \
  -f "$WORKDIR/jenkins-values.yaml" \
  -n "$JENKINS_NAMESPACE" \
  --wait \
  --timeout 15m

# 초기 관리자 비밀번호 출력
echo "Jenkins 초기 관리자 비밀번호: $JENKINS_ADMIN_PASSWORD"
echo "Jenkins URL: http://192.168.56.10:30000"
