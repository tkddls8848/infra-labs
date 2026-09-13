#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYSTEM_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLUSTER_CONFIG="${CLUSTER_CONFIG:-$SYSTEM_DIR/config/cluster.env}"
RESET_JUJU="${RESET_JUJU:-false}"

[[ -f "$CLUSTER_CONFIG" ]] \
  || { echo "Cluster config not found: $CLUSTER_CONFIG" >&2; exit 1; }
# shellcheck source=/dev/null
source "$CLUSTER_CONFIG"

: "${JUJU_CHANNEL:?JUJU_CHANNEL must be set in $CLUSTER_CONFIG}"
: "${KUBEFLOW_CHANNEL:?KUBEFLOW_CHANNEL must be set in $CLUSTER_CONFIG}"
: "${KUBEFLOW_PORT:?KUBEFLOW_PORT must be set in $CLUSTER_CONFIG}"
: "${KUBEFLOW_USERNAME:?KUBEFLOW_USERNAME must be set in $CLUSTER_CONFIG}"
KUBEFLOW_PASSWORD="${KUBEFLOW_PASSWORD:-}"

for channel_name in JUJU_CHANNEL KUBEFLOW_CHANNEL; do
  channel_value="${!channel_name}"
  if [[ ! "$channel_value" =~ ^[0-9]+\.[0-9]+/(stable|candidate|beta|edge)$ ]]; then
    echo "Invalid $channel_name in $CLUSTER_CONFIG: $channel_value" >&2
    exit 1
  fi
done
if [[ ! "$KUBEFLOW_PORT" =~ ^[0-9]+$ ]] \
  || (( KUBEFLOW_PORT < 1024 || KUBEFLOW_PORT > 65535 )); then
  echo "KUBEFLOW_PORT must be an unprivileged TCP port (1024-65535)." >&2
  exit 1
fi

if [[ "$RESET_JUJU" == "true" ]]; then
  echo "RESET_JUJU is not allowed in the install path. Run scripts/lifecycle/destroy_cluster.sh first." >&2
  exit 1
fi

command -v snap >/dev/null 2>&1 \
  || { echo "snap is required; this system supports Ubuntu hosts with snapd installed." >&2; exit 1; }
command -v microk8s >/dev/null 2>&1 \
  || { echo "microk8s is not installed. Run 03_microk8s_gpu_addon_install.sh first." >&2; exit 1; }
command -v jq >/dev/null 2>&1 \
  || { echo "jq is required for the GPU readiness check." >&2; exit 1; }

# This is a single-user local lab, not a production identity setup. An empty
# config value generates a fresh credential; operators who need a stable lab
# password can supply it through a private CLUSTER_CONFIG file.
if [[ -z "$KUBEFLOW_PASSWORD" ]]; then
  command -v openssl >/dev/null 2>&1 \
    || { echo "openssl is required to generate the lab dashboard password." >&2; exit 1; }
  KUBEFLOW_PASSWORD="$(openssl rand -hex 16)"
fi

if ! snap list juju >/dev/null 2>&1; then
  sudo snap install juju --channel="$JUJU_CHANNEL"
fi

export JUJU_DATA="$HOME/.local/share/juju"
mkdir -p "$JUJU_DATA"

microk8s config | juju add-k8s my-k8s --client
juju bootstrap my-k8s
juju add-model kubeflow
juju deploy kubeflow-lite --trust --channel="$KUBEFLOW_CHANNEL"

juju config dex-auth static-username="$KUBEFLOW_USERNAME"
juju config dex-auth static-password="$KUBEFLOW_PASSWORD"

sudo sysctl fs.inotify.max_user_instances=1280
sudo sysctl fs.inotify.max_user_watches=655360

timeout 1800 bash -c 'until juju status kubeflow 2>/dev/null | grep -q "active"; do sleep 60; done'

nohup microk8s kubectl port-forward -n kubeflow svc/istio-ingressgateway-workload "${KUBEFLOW_PORT}:80" \
  >/tmp/kubeflow-port-forward.log 2>&1 &
echo $! >/tmp/kubeflow-port-forward.pid

if microk8s kubectl get nodes -o json | jq -e '.items[].status.allocatable | select(."nvidia.com/gpu" != null)' >/dev/null 2>&1; then
  echo "GPU is available for Kubeflow workloads."
else
  echo "GPU was not detected by Kubernetes; GPU workloads may not schedule." >&2
fi

echo "Kubeflow dashboard: http://localhost:${KUBEFLOW_PORT}"
echo "LAB-ONLY static credential; do not expose this non-HA dashboard to an untrusted network."
echo "Username: $KUBEFLOW_USERNAME"
echo "Password: $KUBEFLOW_PASSWORD"
