#!/bin/bash
# 배스천에서 실행: 각 K8s 노드 자원 현황 수집
# Usage: bash ~/scripts/check_resources.sh

SSH_KEY="${SSH_KEY_PATH:-$HOME/.ssh/storage-lab.pem}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -i $SSH_KEY"
MASTER="master-1"

# ── K8s 뷰 ───────────────────────────────────────────────────────────────────
echo "════════════════════════════════════════════════════════════"
echo "  K8s 실시간 사용량 (kubectl top nodes)"
echo "════════════════════════════════════════════════════════════"
ssh $SSH_OPTS ubuntu@$MASTER "kubectl top nodes 2>/dev/null" \
  || echo "  (metrics-server 미응답)"

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  K8s 스케줄러 할당 현황 (Requests / Limits)"
echo "════════════════════════════════════════════════════════════"
NODE_LIST=$(ssh $SSH_OPTS ubuntu@$MASTER \
  "kubectl get nodes -o jsonpath='{.items[*].metadata.name}'")

for NODE in $NODE_LIST; do
  ROLE=$(ssh $SSH_OPTS ubuntu@$MASTER \
    "kubectl get node $NODE --no-headers \
     -o custom-columns=ROLE:.metadata.labels.'node-role\.kubernetes\.io/control-plane'" 2>/dev/null)
  [ "$ROLE" = "<none>" ] && ROLE="worker" || ROLE="master"

  echo ""
  echo "  [$ROLE] $NODE"
  ssh $SSH_OPTS ubuntu@$MASTER \
    "kubectl describe node $NODE | grep -A 5 'Allocated resources' | tail -4" \
    | sed 's/^/    /'
done

# ── 호스트 레벨: 각 노드 SSH 순회 ────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════"
echo "  호스트 레벨 자원 현황 (SSH 순회)"
echo "════════════════════════════════════════════════════════════"

# kubectl 에서 노드명 + InternalIP 목록 수집
NODE_IPS=$(ssh $SSH_OPTS ubuntu@$MASTER \
  "kubectl get nodes \
   -o jsonpath='{range .items[*]}{.metadata.name}{\"\t\"}{.status.addresses[?(@.type==\"InternalIP\")].address}{\"\n\"}{end}'")

while IFS=$'\t' read -r NAME IP; do
  [ -z "$NAME" ] && continue
  echo ""
  echo "  ┌─ $NAME  ($IP) ─────────────────────────────────────────"

  ssh $SSH_OPTS ubuntu@$IP /bin/bash <<'REMOTE' 2>/dev/null | sed 's/^/  │ /'
CPU_CORES=$(nproc)
LOAD=$(uptime | awk -F'load average:' '{gsub(/ /,"",$2); print $2}')
printf "[CPU]     코어: %-3s  load avg: %s\n" "$CPU_CORES" "$LOAD"

read -r _ TOTAL _ FREE _ _ AVAIL _ <<< $(free -m | grep '^Mem:')
USED=$((TOTAL - FREE))
printf "[MEMORY]  total:%-6s used:%-6s free:%-6s avail:%s MiB\n" \
  "$TOTAL" "$USED" "$FREE" "$AVAIL"

read -r _ DTOTAL DUSED DAVAIL DPCT _ <<< $(df -h / | tail -1)
printf "[DISK /]  total:%-6s used:%-6s avail:%-6s use:%s\n" \
  "$DTOTAL" "$DUSED" "$DAVAIL" "$DPCT"

if mountpoint -q /mnt/beegfs/storage 2>/dev/null; then
  read -r _ BTOTAL BUSED BAVAIL BPCT _ <<< $(df -h /mnt/beegfs/storage | tail -1)
  printf "[BEEGFS]  total:%-6s used:%-6s avail:%-6s use:%s\n" \
    "$BTOTAL" "$BUSED" "$BAVAIL" "$BPCT"
fi
REMOTE

  echo "  └────────────────────────────────────────────────────────────"
done <<< "$NODE_IPS"

echo ""
echo "완료"
