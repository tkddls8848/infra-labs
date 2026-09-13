#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYSTEM_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLUSTER_CONFIG="${CLUSTER_CONFIG:-$SYSTEM_DIR/config/cluster.env}"
RESET_MICROK8S="${RESET_MICROK8S:-false}"

[[ -f "$CLUSTER_CONFIG" ]] \
  || { echo "Cluster config not found: $CLUSTER_CONFIG" >&2; exit 1; }
# shellcheck source=/dev/null
source "$CLUSTER_CONFIG"

: "${MICROK8S_CHANNEL:?MICROK8S_CHANNEL must be set in $CLUSTER_CONFIG}"
: "${METALLB_RANGE:?METALLB_RANGE must be set in $CLUSTER_CONFIG}"

if [[ ! "$MICROK8S_CHANNEL" =~ ^[0-9]+\.[0-9]+/(stable|candidate|beta|edge)$ ]]; then
  echo "Invalid MICROK8S_CHANNEL in $CLUSTER_CONFIG: $MICROK8S_CHANNEL" >&2
  exit 1
fi

if [[ "$RESET_MICROK8S" == "true" ]]; then
  echo "RESET_MICROK8S is not allowed in the install path. Run scripts/lifecycle/destroy_cluster.sh first." >&2
  exit 1
fi

command -v python3 >/dev/null 2>&1 \
  || { echo "python3 is required to validate METALLB_RANGE." >&2; exit 1; }
command -v ip >/dev/null 2>&1 \
  || { echo "iproute2 is required to validate METALLB_RANGE." >&2; exit 1; }

# MetalLB L2 addresses must be on an IPv4 network that is actually configured
# on this host. Validate the complete range before installing or changing the
# cluster, not merely its textual shape.
python3 - "$METALLB_RANGE" <<'PY'
import ipaddress
import subprocess
import sys

raw_range = sys.argv[1]
try:
    start_text, end_text = raw_range.split("-", 1)
    start = ipaddress.IPv4Address(start_text)
    end = ipaddress.IPv4Address(end_text)
except (ipaddress.AddressValueError, ValueError) as exc:
    raise SystemExit(f"Invalid METALLB_RANGE {raw_range!r}: {exc}")

if int(start) > int(end):
    raise SystemExit(f"Invalid METALLB_RANGE {raw_range!r}: start is after end")

try:
    output = subprocess.check_output(
        ["ip", "-4", "-o", "addr", "show", "scope", "global"],
        text=True,
    )
except (OSError, subprocess.CalledProcessError) as exc:
    raise SystemExit(f"Could not inspect host IPv4 networks: {exc}")

matches = []
for line in output.splitlines():
    fields = line.split()
    if len(fields) < 4 or fields[2] != "inet":
        continue
    interface = fields[1]
    network = ipaddress.ip_interface(fields[3]).network
    if start in network and end in network:
        if start in (network.network_address, network.broadcast_address):
            continue
        if end in (network.network_address, network.broadcast_address):
            continue
        matches.append((interface, network))

if not matches:
    networks = ", ".join(
        f"{line.split()[1]}={ipaddress.ip_interface(line.split()[3]).network}"
        for line in output.splitlines()
        if len(line.split()) >= 4 and line.split()[2] == "inet"
    ) or "none"
    raise SystemExit(
        f"METALLB_RANGE {raw_range} is not wholly inside a configured host "
        f"IPv4 network (found: {networks})"
    )

interface, network = matches[0]
print(f"Validated METALLB_RANGE {raw_range} on {interface} ({network})")
PY

command -v snap >/dev/null 2>&1 \
  || { echo "snap is required; this system supports Ubuntu hosts with snapd installed." >&2; exit 1; }

if ! systemctl is-active --quiet snapd; then
  sudo systemctl enable --now snapd
fi

sudo swapoff -a
sudo sed -e '/swap/s/^/#/' -i /etc/fstab

if ! snap list microk8s >/dev/null 2>&1; then
  sudo snap install microk8s --classic --channel="$MICROK8S_CHANNEL"
fi

mkdir -p "$HOME/.kube"
sudo usermod -a -G microk8s "$USER"
sudo chown -f -R "$USER" "$HOME/.kube"

sudo microk8s start
sudo microk8s status --wait-ready

sudo microk8s enable dns
sudo microk8s enable hostpath-storage
sudo microk8s enable rbac

sudo microk8s enable "metallb:$METALLB_RANGE"

if ! sudo microk8s enable nvidia; then
  sleep 30
  sudo microk8s enable nvidia --validate=false
fi

TIMEOUT=900
COUNTER=0
while [[ "$COUNTER" -lt "$TIMEOUT" ]]; do
  if sudo microk8s kubectl get namespace gpu-operator-resources >/dev/null 2>&1; then
    if sudo microk8s kubectl get pods -n gpu-operator-resources -l app=nvidia-operator-validator --no-headers 2>/dev/null | grep -q "Running"; then
      break
    fi
  elif sudo microk8s kubectl get pods -n kube-system -l app=nvidia-device-plugin-daemonset --no-headers 2>/dev/null | grep -q "Running"; then
    break
  fi
  sleep 5
  COUNTER=$((COUNTER + 5))
done

if [[ "$COUNTER" -ge "$TIMEOUT" ]]; then
  echo "GPU addon did not become ready within ${TIMEOUT}s." >&2
  exit 1
fi

sudo microk8s kubectl get nodes -o wide
sudo microk8s kubectl describe nodes | grep -i nvidia || true
