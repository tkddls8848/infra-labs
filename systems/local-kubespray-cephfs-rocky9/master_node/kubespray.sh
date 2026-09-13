#!/usr/bin/env bash
set -euo pipefail

SYSTEM_ROOT="${SYSTEM_ROOT:-/vagrant}"
SOURCE_INVENTORY="${SOURCE_INVENTORY:-$SYSTEM_ROOT/inventory.ini}"
KUBESPRAY_HOME="${KUBESPRAY_HOME:-$HOME/kubespray}"
VENV_PATH="${VENV_PATH:-$HOME/.venv/kubespray}"

if [[ ! -f "$SOURCE_INVENTORY" ]]; then
  echo "Inventory not found: $SOURCE_INVENTORY" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$SYSTEM_ROOT/common/inventory.sh"

ANSIBLE_USER="$(require_inventory_var "$SOURCE_INVENTORY" ansible_user)"
CLUSTER_NAME="$(require_inventory_var "$SOURCE_INVENTORY" cluster_name)"
KUBESPRAY_VERSION="$(require_inventory_var "$SOURCE_INVENTORY" kubespray_version)"
KUBESPRAY_COMMIT="$(require_inventory_var "$SOURCE_INVENTORY" kubespray_git_commit)"
PYTHON_VERSION="$(require_inventory_var "$SOURCE_INVENTORY" python_version)"
PYTHON_SHA256="$(require_inventory_var "$SOURCE_INVENTORY" python_source_sha256)"
METALLB_RANGE="$(require_inventory_var "$SOURCE_INVENTORY" metallb_address_pool_cidr)"
CLUSTER_INVENTORY="$KUBESPRAY_HOME/inventory/$CLUSTER_NAME"

sudo dnf install -y bash-completion git

python_bin="$(command -v python3.11 || true)"
if [[ -n "$python_bin" ]]; then
  installed_python_version="$($python_bin -c 'import platform; print(platform.python_version())')"
  if [[ "$installed_python_version" != "$PYTHON_VERSION" ]]; then
    echo "python3.11 is $installed_python_version; inventory requires $PYTHON_VERSION" >&2
    exit 1
  fi
else
  # Build the exact pinned controller runtime instead of accepting a different package patch level.
  # Rocky Linux 9 keeps gdbm-devel and uuid-devel in CRB.
  sudo dnf install -y dnf-plugins-core
  sudo dnf config-manager --set-enabled crb
  sudo dnf install -y \
    bzip2 bzip2-devel gcc gdbm-devel libffi-devel libuuid-devel make ncurses-devel openssl-devel \
    readline-devel sqlite sqlite-devel tar uuid-devel wget xz-devel zlib-devel

  python_cache="$HOME/.cache/python-build"
  python_archive="$python_cache/Python-$PYTHON_VERSION.tgz"
  python_source_root="$python_cache/source-$PYTHON_SHA256"
  python_source_dir="$python_source_root/Python-$PYTHON_VERSION"
  mkdir -p "$python_cache" "$python_source_root"

  if [[ -f "$python_archive" ]]; then
    printf '%s  %s\n' "$PYTHON_SHA256" "$python_archive" | sha256sum --check --status - || {
      echo "Cached Python archive checksum mismatch: $python_archive" >&2
      exit 1
    }
  else
    wget -O "$python_archive.part" \
      "https://www.python.org/ftp/python/$PYTHON_VERSION/Python-$PYTHON_VERSION.tgz"
    printf '%s  %s\n' "$PYTHON_SHA256" "$python_archive.part" | sha256sum --check --status - || {
      echo "Downloaded Python $PYTHON_VERSION archive failed SHA-256 verification" >&2
      exit 1
    }
    mv "$python_archive.part" "$python_archive"
  fi

  # Re-extraction and make are safe after an interrupted build and avoid the old PGO delay.
  tar -xzf "$python_archive" -C "$python_source_root"
  pushd "$python_source_dir" >/dev/null
  ./configure --prefix=/usr/local --with-ensurepip=install
  make -j"$(nproc)"
  sudo make altinstall
  popd >/dev/null

  python_bin="$(command -v python3.11 || true)"
  if [[ -z "$python_bin" || "$($python_bin -c 'import platform; print(platform.python_version())')" != "$PYTHON_VERSION" ]]; then
    echo "Python $PYTHON_VERSION installation did not produce the expected python3.11" >&2
    exit 1
  fi
fi

"$python_bin" - "$SOURCE_INVENTORY" <<'PY'
import ipaddress
import shlex
import sys

inventory_path = sys.argv[1]
section = None
hosts = {}
all_vars = {}

with open(inventory_path, encoding="utf-8") as inventory:
    for raw_line in inventory:
        line = raw_line.strip()
        if not line or line.startswith(("#", ";")):
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1]
            continue
        if section == "all":
            fields = shlex.split(line)
            host = fields.pop(0)
            hosts[host] = dict(field.split("=", 1) for field in fields)
        elif section == "all:vars" and "=" in line:
            key, value = line.split("=", 1)
            all_vars[key.strip()] = value.strip().strip("'\"")

required = (
    "node_network_cidr",
    "metallb_address_pool_cidr",
    "kube_pods_subnet",
    "kube_service_addresses",
)
missing = [name for name in required if not all_vars.get(name)]
if missing:
    raise SystemExit(f"Network validation failed: missing inventory vars: {', '.join(missing)}")

try:
    node_network = ipaddress.ip_network(all_vars["node_network_cidr"], strict=True)
    metallb_network = ipaddress.ip_network(all_vars["metallb_address_pool_cidr"], strict=True)
    pod_network = ipaddress.ip_network(all_vars["kube_pods_subnet"], strict=True)
    service_network = ipaddress.ip_network(all_vars["kube_service_addresses"], strict=True)
except ValueError as exc:
    raise SystemExit(f"Network validation failed: {exc}") from exc

if not metallb_network.subnet_of(node_network):
    raise SystemExit(
        f"Network validation failed: MetalLB pool {metallb_network} is not inside "
        f"node network {node_network}"
    )
if pod_network.overlaps(node_network) or service_network.overlaps(node_network):
    raise SystemExit("Network validation failed: pod/service ranges must not overlap the node network")
if pod_network.overlaps(service_network):
    raise SystemExit("Network validation failed: pod and service ranges overlap")

seen_addresses = set()
for host, host_vars in hosts.items():
    try:
        address = ipaddress.ip_address(host_vars["ansible_host"])
    except (KeyError, ValueError) as exc:
        raise SystemExit(f"Network validation failed for {host}: invalid ansible_host") from exc
    if address not in node_network:
        raise SystemExit(f"Network validation failed: {host} address {address} is outside {node_network}")
    if address in metallb_network:
        raise SystemExit(f"Network validation failed: {host} address {address} overlaps {metallb_network}")
    if address in seen_addresses:
        raise SystemExit(f"Network validation failed: duplicate node address {address}")
    seen_addresses.add(address)

print(
    f"Validated node network {node_network}, MetalLB pool {metallb_network}, "
    f"pod network {pod_network}, and service network {service_network}"
)
PY

ensure_pinned_checkout \
  "https://github.com/kubernetes-sigs/kubespray.git" \
  "refs/tags/$KUBESPRAY_VERSION" \
  "$KUBESPRAY_COMMIT" \
  "$KUBESPRAY_HOME"

if [[ -e "$VENV_PATH" && ! -f "$VENV_PATH/pyvenv.cfg" ]]; then
  echo "Refusing to replace non-venv path: $VENV_PATH" >&2
  exit 1
fi
if [[ ! -f "$VENV_PATH/pyvenv.cfg" ]]; then
  "$python_bin" -m venv "$VENV_PATH"
fi

venv_python_version="$($VENV_PATH/bin/python -c 'import platform; print(platform.python_version())')"
if [[ "$venv_python_version" != "$PYTHON_VERSION" ]]; then
  echo "Existing venv uses Python $venv_python_version; inventory requires $PYTHON_VERSION" >&2
  exit 1
fi

# Kubespray's requirements are exact-version pins; reinstalling them is safe and idempotent.
"$VENV_PATH/bin/python" -m pip install -r "$KUBESPRAY_HOME/requirements.txt"
"$VENV_PATH/bin/python" -m pip check

mkdir -p "$CLUSTER_INVENTORY/group_vars/all"
if [[ ! -f "$CLUSTER_INVENTORY/inventory.ini" ]] || \
   ! cmp -s "$SOURCE_INVENTORY" "$CLUSTER_INVENTORY/inventory.ini"; then
  install -m 0644 "$SOURCE_INVENTORY" "$CLUSTER_INVENTORY/inventory.ini"
fi

generated_vars="$CLUSTER_INVENTORY/group_vars/all/generated-metallb.yml"
generated_vars_tmp="$(mktemp "$generated_vars.XXXXXX")"
cat >"$generated_vars_tmp" <<EOF
---
# Generated from metallb_address_pool_cidr in inventory.ini; do not edit this copy.
metallb_config:
  address_pools:
    primary:
      ip_range:
        - "$METALLB_RANGE"
      auto_assign: true
  layer2:
    - primary
EOF
if [[ ! -f "$generated_vars" ]] || ! cmp -s "$generated_vars_tmp" "$generated_vars"; then
  mv "$generated_vars_tmp" "$generated_vars"
else
  rm -f "$generated_vars_tmp"
fi

"$VENV_PATH/bin/ansible-inventory" -i "$CLUSTER_INVENTORY/inventory.ini" --list >/dev/null
"$VENV_PATH/bin/ansible-playbook" \
  -i "$CLUSTER_INVENTORY/inventory.ini" \
  --become --become-user=root \
  "$KUBESPRAY_HOME/cluster.yml"

ansible_home="$(getent passwd "$ANSIBLE_USER" | cut -d: -f6)"
ansible_group="$(id -gn "$ANSIBLE_USER")"
if [[ -z "$ansible_home" ]]; then
  echo "Unable to determine home directory for $ANSIBLE_USER" >&2
  exit 1
fi
sudo install -d -m 0700 -o "$ANSIBLE_USER" -g "$ansible_group" "$ansible_home/.kube"
sudo install -m 0600 -o "$ANSIBLE_USER" -g "$ansible_group" \
  /etc/kubernetes/admin.conf "$ansible_home/.kube/config"

grep -q 'kubectl completion bash' "$HOME/.bashrc" || \
  echo 'source <(kubectl completion bash)' >>"$HOME/.bashrc"
grep -q 'alias k=kubectl' "$HOME/.bashrc" || echo 'alias k=kubectl' >>"$HOME/.bashrc"
