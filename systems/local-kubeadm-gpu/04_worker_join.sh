#!/usr/bin/env bash
set -euo pipefail

MASTER="${MASTER:-ubuntu@k8s-master}"

log() { echo "[$(date '+%H:%M:%S')] $1"; }
error_exit() { echo "ERROR: $1" >&2; exit 1; }

log "Phase 4: worker join"

kubeadm version >/dev/null 2>&1 || error_exit "kubeadm not found. Run 02_node_setup.sh first."
systemctl is-active --quiet containerd || error_exit "containerd is not active."

for kubeadm_state in \
  /etc/kubernetes/kubelet.conf \
  /etc/kubernetes/bootstrap-kubelet.conf \
  /etc/kubernetes/pki/ca.crt \
  /var/lib/kubelet/config.yaml; do
  [[ ! -e "$kubeadm_state" ]] \
    || error_exit "Existing kubeadm state found at $kubeadm_state. Run 06_rollback.sh option 04 before joining again."
done

if [[ $# -gt 0 && -n "$1" ]]; then
  JOIN_CMD="$1"
else
  log "fetching join command from $MASTER"
  ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$MASTER" "command -v kubeadm >/dev/null" \
    || error_exit "Cannot reach master over SSH. Pass a join command as the first argument."
  JOIN_CMD="$(ssh -o StrictHostKeyChecking=no "$MASTER" "sudo kubeadm token create --print-join-command 2>/dev/null")"
fi

[[ -n "$JOIN_CMD" ]] || error_exit "Join command is empty."
sudo $JOIN_CMD

log "worker join complete"
