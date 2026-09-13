#!/usr/bin/env bash
set -euo pipefail

SYSTEM_ROOT="${SYSTEM_ROOT:-/vagrant}"
SOURCE_INVENTORY="${SOURCE_INVENTORY:-$SYSTEM_ROOT/inventory.ini}"

if [[ ! -f "$SOURCE_INVENTORY" ]]; then
  echo "Inventory not found: $SOURCE_INVENTORY" >&2
  exit 1
fi

# shellcheck source=/dev/null
source "$SYSTEM_ROOT/common/inventory.sh"

JENKINS_COMMIT="$(require_inventory_var "$SOURCE_INVENTORY" jenkins_git_commit)"
JENKINS_IMAGE="$(require_inventory_var "$SOURCE_INVENTORY" jenkins_image)"
JENKINS_STORAGE_NODE="$(require_inventory_var "$SOURCE_INVENTORY" jenkins_storage_node)"
JENKINS_CHECKOUT="${JENKINS_CHECKOUT:-$HOME/.cache/kubernetes-jenkins}"

ensure_pinned_checkout \
  "https://github.com/scriptcamp/kubernetes-jenkins.git" \
  "$JENKINS_COMMIT" \
  "$JENKINS_COMMIT" \
  "$JENKINS_CHECKOUT"

render_dir="$(mktemp -d)"
trap 'rm -rf "$render_dir"' EXIT
cp "$JENKINS_CHECKOUT"/*.yaml "$render_dir/"

# Render the exact image and inventory-owned storage node without dirtying the checkout.
sed -i -E "s#^([[:space:]]*image:).*#\1 $JENKINS_IMAGE#" "$render_dir/deployment.yaml"
sed -i "s/worker-node01/$JENKINS_STORAGE_NODE/g" "$render_dir/volume.yaml"

kubectl create namespace devops-tools --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "$render_dir"
