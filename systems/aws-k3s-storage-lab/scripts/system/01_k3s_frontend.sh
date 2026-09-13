#!/bin/bash
# Phase 2: Frontend — k3s server 서비스 등록 + agent × 2 조인
# 전제: k3s 바이너리는 Packer AMI에 사전 설치됨 (INSTALL_K3S_SKIP_DOWNLOAD=true)
# 실행: ssh ec2-user@<FRONTEND_IP> 'sudo bash -s' < 01_k3s_frontend.sh
set -e
export PATH="/usr/local/bin:/usr/local/sbin:$PATH"

K3S_VERSION="v1.32.3+k3s1"
EC2_USER_HOME="/home/ec2-user"
PRIVATE_IP=$(hostname -I | awk '{print $1}')

echo "=============================="
echo " [1/4] k3s server 서비스 등록 (${K3S_VERSION})"
echo "=============================="
# INSTALL_K3S_SKIP_DOWNLOAD=true: 바이너리 재다운로드 없이 서비스만 등록
# --selinux: RHEL 9 SELinux enforcing 환경 필수
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="${K3S_VERSION}" \
  INSTALL_K3S_SKIP_DOWNLOAD=true \
  sh -s - server \
  --selinux \
  --disable traefik \
  --node-label role=master \
  --node-name k3s-master \
  --write-kubeconfig-mode 644

mkdir -p "${EC2_USER_HOME}/.kube"
cp /etc/rancher/k3s/k3s.yaml "${EC2_USER_HOME}/.kube/config"
sed -i "s/127.0.0.1/${PRIVATE_IP}/g" "${EC2_USER_HOME}/.kube/config"
chown ec2-user:ec2-user "${EC2_USER_HOME}/.kube" "${EC2_USER_HOME}/.kube/config"
chmod 600 "${EC2_USER_HOME}/.kube/config"

# ec2-user 로그인 시 자동으로 kubeconfig 적용
grep -q "KUBECONFIG" "${EC2_USER_HOME}/.bashrc" || \
  echo "export KUBECONFIG=${EC2_USER_HOME}/.kube/config" >> "${EC2_USER_HOME}/.bashrc"

export KUBECONFIG="${EC2_USER_HOME}/.kube/config"

echo "=============================="
echo " [2/4] k3s agent-1 서비스 등록"
echo "=============================="
# k3s server가 node-token 파일을 생성할 때까지 대기
echo "  node-token 생성 대기 중..."
until [ -f /var/lib/rancher/k3s/server/node-token ]; do
  sleep 2
done
K3S_TOKEN=$(cat /var/lib/rancher/k3s/server/node-token)

cat > /etc/systemd/system/k3s-agent1.service <<EOF
[Unit]
Description=Lightweight Kubernetes Agent 1
Documentation=https://k3s.io
After=network-online.target

[Service]
Type=exec
EnvironmentFile=/etc/systemd/system/k3s-agent1.env
ExecStart=/usr/local/bin/k3s agent \
  --selinux \
  --node-label role=worker \
  --node-name k3s-worker-1 \
  --data-dir /var/lib/rancher/k3s-agent1
KillMode=process
Delegate=yes
LimitNOFILE=1048576
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
TimeoutStartSec=0
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/k3s-agent1.env <<EOF
K3S_URL=https://${PRIVATE_IP}:6443
K3S_TOKEN=${K3S_TOKEN}
K3S_SELINUX=true
EOF

echo "=============================="
echo " [3/4] k3s agent-2 서비스 등록"
echo "=============================="
cat > /etc/systemd/system/k3s-agent2.service <<EOF
[Unit]
Description=Lightweight Kubernetes Agent 2
Documentation=https://k3s.io
After=network-online.target

[Service]
Type=exec
EnvironmentFile=/etc/systemd/system/k3s-agent2.env
ExecStart=/usr/local/bin/k3s agent \
  --selinux \
  --node-label role=worker \
  --node-name k3s-worker-2 \
  --data-dir /var/lib/rancher/k3s-agent2
KillMode=process
Delegate=yes
LimitNOFILE=1048576
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
TimeoutStartSec=0
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/k3s-agent2.env <<EOF
K3S_URL=https://${PRIVATE_IP}:6443
K3S_TOKEN=${K3S_TOKEN}
K3S_SELINUX=true
EOF

systemctl daemon-reload
systemctl enable --now k3s-agent1
systemctl enable --now k3s-agent2

echo "=============================="
echo " [4/4] 노드 확인 (30초 대기)"
echo "=============================="
sleep 30
kubectl get nodes
echo ""
echo "k3s frontend 구성 완료 (Packer AMI)"
echo "   kubeconfig: ${EC2_USER_HOME}/.kube/config"
