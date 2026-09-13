#!/usr/bin/env bash
set -euo pipefail

KUBESPRAY_HOME="${KUBESPRAY_HOME:-$HOME/kubespray}"
VENV_PATH="${VENV_PATH:-$HOME/.venv/kubespray}"
SOURCE_INVENTORY="${SOURCE_INVENTORY:-/vagrant/inventory/inventory.ini}"
CLUSTER_INVENTORY="$KUBESPRAY_HOME/inventory/k8s-clusters"

inventory_var() {
  local key="$1"
  awk -F= -v key="$key" '
    /^\[all:vars\][[:space:]]*$/ { in_all_vars = 1; next }
    /^\[/ { in_all_vars = 0 }
    in_all_vars {
      name = $1
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
      if (name == key) {
        value = substr($0, index($0, "=") + 1)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        print value
        exit
      }
    }
  ' "$SOURCE_INVENTORY"
}

inventory_host_rows() {
  awk '
    /^\[all\][[:space:]]*$/ { in_all = 1; next }
    /^\[/ { in_all = 0 }
    in_all && $0 !~ /^[[:space:]]*(#|;|$)/ {
      host = $1
      ip = ""
      key_file = ""
      for (i = 2; i <= NF; i++) {
        if ($i ~ /^ansible_host=/) {
          split($i, field, "=")
          ip = field[2]
        } else if ($i ~ /^ansible_ssh_private_key_file=/) {
          split($i, field, "=")
          key_file = field[2]
        }
      }
      print host "|" ip "|" key_file
    }
  ' "$SOURCE_INVENTORY"
}

require_inventory_var() {
  local name="$1"
  local value
  value="$(inventory_var "$name")"
  if [[ -z "$value" ]]; then
    echo "[kubespray] missing required [all:vars] value: $name" >&2
    exit 1
  fi
  printf '%s\n' "$value"
}

KUBESPRAY_VERSION="$(require_inventory_var kubespray_version)"
KUBE_VERSION="$(require_inventory_var kube_version)"
KUBE_NETWORK_PLUGIN="$(require_inventory_var kube_network_plugin)"
KUBE_PODS_SUBNET="$(require_inventory_var kube_pods_subnet)"
METALLB_IP_RANGE="$(require_inventory_var metallb_ip_range)"

if [[ "$KUBE_NETWORK_PLUGIN" != "flannel" ]]; then
  echo "[kubespray] this cluster requires kube_network_plugin=flannel in $SOURCE_INVENTORY" >&2
  exit 1
fi

mapfile -t INVENTORY_HOST_ROWS < <(inventory_host_rows)
if [[ "${#INVENTORY_HOST_ROWS[@]}" -eq 0 ]]; then
  echo "[kubespray] no hosts found in [all] in $SOURCE_INVENTORY" >&2
  exit 1
fi

copy_vagrant_keys() {
  install -m 0700 -d "$HOME/.ssh"
  local row host ip key_file src
  for row in "${INVENTORY_HOST_ROWS[@]}"; do
    IFS='|' read -r host ip key_file <<< "$row"
    if [[ -z "$ip" || -z "$key_file" ]]; then
      echo "[kubespray] host $host must define ansible_host and ansible_ssh_private_key_file" >&2
      exit 1
    fi
    src="/vagrant/.vagrant/machines/$host/virtualbox/private_key"
    if [[ ! -f "$src" ]]; then
      echo "[kubespray] missing Vagrant SSH key: $src" >&2
      exit 1
    fi
    install -m 0600 "$src" "$key_file"
  done
}

populate_known_hosts() {
  local known_hosts="$HOME/.ssh/known_hosts"
  local scan_file merged_file row host ip key_file scan
  scan_file="$(mktemp)"
  merged_file="$(mktemp)"

  for row in "${INVENTORY_HOST_ROWS[@]}"; do
    IFS='|' read -r host ip key_file <<< "$row"
    if ! scan="$(ssh-keyscan -T 10 "$ip" 2>/dev/null)" || [[ -z "$scan" ]]; then
      echo "[kubespray] failed to scan SSH host key for $host ($ip)" >&2
      rm -f "$scan_file" "$merged_file"
      exit 1
    fi
    printf '%s\n' "$scan" >> "$scan_file"
  done

  touch "$known_hosts"
  chmod 0600 "$known_hosts"
  sort -u "$known_hosts" "$scan_file" > "$merged_file"
  install -m 0600 "$merged_file" "$known_hosts"
  rm -f "$scan_file" "$merged_file"
}

echo "[kubespray] installing host packages"
sudo apt-get update
sudo apt-get install -y git openssh-client python3 python3-venv python3-pip bash-completion

if [[ ! -d "$KUBESPRAY_HOME/.git" ]]; then
  echo "[kubespray] cloning $KUBESPRAY_VERSION"
  git clone --branch "$KUBESPRAY_VERSION" --single-branch https://github.com/kubernetes-sigs/kubespray.git "$KUBESPRAY_HOME"
else
  echo "[kubespray] updating existing checkout: $KUBESPRAY_HOME"
  git -C "$KUBESPRAY_HOME" fetch --tags origin
  git -C "$KUBESPRAY_HOME" checkout "$KUBESPRAY_VERSION"
fi

if [[ ! -d "$VENV_PATH" ]]; then
  python3 -m venv "$VENV_PATH"
fi
source "$VENV_PATH/bin/activate"
python -m pip install --upgrade pip setuptools wheel
python -m pip install -r "$KUBESPRAY_HOME/requirements.txt"

if [[ ! -d "$CLUSTER_INVENTORY" ]]; then
  cp -rfp "$KUBESPRAY_HOME/inventory/sample" "$CLUSTER_INVENTORY"
fi

install -m 0755 -d "$CLUSTER_INVENTORY/group_vars/all" "$CLUSTER_INVENTORY/group_vars/k8s_cluster"
cp "$SOURCE_INVENTORY" "$CLUSTER_INVENTORY/inventory.ini"
copy_vagrant_keys
populate_known_hosts

cat > "$CLUSTER_INVENTORY/group_vars/all/etcd.yml" <<EOF
etcd_kubeadm_enabled: true
EOF

cat > "$CLUSTER_INVENTORY/group_vars/k8s_cluster/k8s-cluster.yml" <<EOF
kube_version: $KUBE_VERSION
kube_network_plugin: $KUBE_NETWORK_PLUGIN
kube_pods_subnet: $KUBE_PODS_SUBNET
kube_proxy_strict_arp: true
EOF

cat > "$CLUSTER_INVENTORY/group_vars/k8s_cluster/addons.yml" <<EOF
metrics_server_enabled: true
helm_enabled: true
metallb_enabled: true
metallb_speaker_enabled: true
metallb_config:
  address_pools:
    primary:
      ip_range:
        - "$METALLB_IP_RANGE"
      auto_assign: true
  layer2:
    - primary
EOF

ansible-inventory -i "$CLUSTER_INVENTORY/inventory.ini" --list >/dev/null
ansible-playbook -i "$CLUSTER_INVENTORY/inventory.ini" --become --become-user=root "$KUBESPRAY_HOME/cluster.yml"
deactivate

mkdir -p "$HOME/.kube"
sudo cp -f /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"
kubectl wait --for=condition=Ready nodes --all --timeout=10m

grep -q 'kubectl completion bash' "$HOME/.bashrc" || echo 'source <(kubectl completion bash)' >> "$HOME/.bashrc"
