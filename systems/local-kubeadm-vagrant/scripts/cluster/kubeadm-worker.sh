#!/usr/bin/env bash
set -euo pipefail

JOIN_FILE="${1:?join file path is required}"
TIMEOUT_SECONDS="${JOIN_TIMEOUT_SECONDS:-600}"

echo "[kubeadm] waiting for join command: $JOIN_FILE"
for ((elapsed=0; elapsed<TIMEOUT_SECONDS; elapsed+=5)); do
  if [[ -s "$JOIN_FILE" ]]; then
    JOIN_CMD="$(cat "$JOIN_FILE")"
    echo "[kubeadm] joining worker"
    $JOIN_CMD
    echo "[kubeadm] worker joined"
    exit 0
  fi
  sleep 5
done

echo "Join command was not created within ${TIMEOUT_SECONDS}s: $JOIN_FILE" >&2
exit 1
