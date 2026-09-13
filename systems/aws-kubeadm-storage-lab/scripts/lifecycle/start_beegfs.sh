#!/bin/bash
set -e
CURRENT_STEP="init"
CURRENT_TARGET="local"
trap 'status=$?; command_name=${BASH_COMMAND%% *}; printf "[step=%s][target=%s][failed] reason=command exited %d: %s\\n" "$CURRENT_STEP" "$CURRENT_TARGET" "$status" "$command_name" >&2' ERR
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SSH_KEY="${SSH_KEY_PATH:-$HOME/.ssh/storage-lab.pem}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -i $SSH_KEY"

CURRENT_STEP="0/4"; CURRENT_TARGET="local"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] 사전 요구사항 확인"
MISSING=()
for cmd in tofu ssh scp; do
  if ! command -v "$cmd" &>/dev/null; then
    MISSING+=("$cmd")
  fi
done
if [ ! -f "$SSH_KEY" ]; then
  MISSING+=("ssh-key:$SSH_KEY")
fi
if [ ${#MISSING[@]} -gt 0 ]; then
  echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET][failed] reason=누락된 항목: ${MISSING[*]}" >&2
  exit 1
fi
echo "모든 필수 항목 확인 완료"

CURRENT_STEP="1/4"; CURRENT_TARGET="aws:${REGION:-${AWS_REGION:-default}}"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] 인프라 정보 수집"
cd "$LAB_ROOT/opentofu"
BASTION_IP=$(tofu output -raw bastion_public_ip)
cd "$LAB_ROOT"
echo "  Bastion : $BASTION_IP"

CURRENT_STEP="2/4"; CURRENT_TARGET="bastion:${BASTION_IP:-pending}"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] Bastion 환경 준비"
scp -O $SSH_OPTS -r "$LAB_ROOT/ansible"    ubuntu@$BASTION_IP:~/
scp -O $SSH_OPTS -r "$LAB_ROOT/manifests"  ubuntu@$BASTION_IP:~/
echo "  파일 전송 완료"

CURRENT_STEP="3/4"; CURRENT_TARGET="bastion:${BASTION_IP:-pending}"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] BeeGFS 설치 (Bastion Ansible 실행)"
ssh $SSH_OPTS ubuntu@$BASTION_IP \
  "cd ~/ansible && /home/ubuntu/.local/bin/ansible-playbook \
     -i inventory/aws_ec2.yml playbooks/beegfs.yml"

CURRENT_STEP="4/4"; CURRENT_TARGET="local"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] 완료"
echo "BeeGFS 설치 완료!"
echo "   StorageClass     : beegfs-scratch"
echo "   BeeGFS 파드      : kubectl get pods -n beegfs-system"
echo "   Prometheus 메트릭: http://<exporter-svc>:9100/metrics"
echo "   Grafana 대시보드 : BeeGFS Overview (자동 import)"
echo "   kubeconfig       : ~/.kube/config-k8s-storage-lab (배스천)"
echo "   PVC 테스트:"
echo "   kubectl apply -f manifests/examples/test-pvc-beegfs.yaml"
echo "   BeeGFS 재설치 필요 시:"
echo "   bash scripts/lifecycle/destroy_beegfs.sh && bash scripts/lifecycle/start_beegfs.sh"
