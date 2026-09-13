#!/bin/bash
set -e
SSH_KEY="${SSH_KEY_PATH:-$HOME/.ssh/storage-lab.pem}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -i $SSH_KEY"

MASTER_IP=$(kubectl get nodes -o wide --no-headers | grep master-1 | awk '{print $6}')
if [ -z "$MASTER_IP" ]; then
  echo "❌ master-1 IP를 찾을 수 없습니다."
  exit 1
fi
echo "  mgmtd IP: $MASTER_IP"

CONF=$(cat << EOF
storeStorageDirectory        = /mnt/beegfs/storage
storeAllowFirstRunInit       = true
connDisableAuthentication    = true
sysMgmtdHost                 = $MASTER_IP
connMgmtdPortTCP             = 8008
connMgmtdPortUDP             = 8008
connStoragePortTCP           = 8003
connStoragePortUDP           = 8003
logLevel                     = 2
logType                      = syslog
EOF
)

for node_ip in $(kubectl get nodes -o wide --no-headers | grep worker | awk '{print $6}'); do
  echo "  ▶ $node_ip — beegfs-storage.conf 업데이트"
  echo "$CONF" | ssh $SSH_OPTS ubuntu@$node_ip \
    "sudo tee /etc/beegfs/beegfs-storage.conf > /dev/null && echo '    ✅ 완료'"
done

echo "  파드 재시작..."
kubectl rollout restart daemonset/beegfs-storage -n beegfs-system
echo "  대기 중..."
kubectl rollout status daemonset/beegfs-storage -n beegfs-system --timeout=120s
