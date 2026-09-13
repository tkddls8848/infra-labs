#!/usr/bin/env bash
set -euo pipefail

SYSTEM_ROOT="${SYSTEM_ROOT:-/vagrant}"
# shellcheck source=lib/common.sh
source "$SYSTEM_ROOT/scripts/lib/common.sh"
load_lab_config
require_root
require_unsupported_opt_in

source /etc/os-release
if [[ "${ID:-}" != "rocky" || "${VERSION_ID:-}" != 9.* ]]; then
  printf 'This experimental lab requires Rocky Linux 9; found ID=%s VERSION_ID=%s.\n' \
    "${ID:-unknown}" "${VERSION_ID:-unknown}" >&2
  exit 1
fi
if [[ "$(uname -m)" != "x86_64" ]]; then
  printf 'IBM Storage Scale Developer Edition requires x86_64; found %s.\n' "$(uname -m)" >&2
  exit 1
fi

minimum_memory_mb="$(require_inventory_var "$INVENTORY_FILE" minimum_memory_mb)"
memory_mb="$(( $(awk '/MemTotal:/ {print $2}' /proc/meminfo) / 1024 ))"
if (( memory_mb < minimum_memory_mb )); then
  printf 'Reduced mode still requires at least %s MiB visible RAM; found %s MiB.\n' \
    "$minimum_memory_mb" "$memory_mb" >&2
  exit 1
fi

node_ip="$(awk '/^scale-ces1[[:space:]]/ {for (i=2; i<=NF; i++) if ($i ~ /^ansible_host=/) {sub(/^ansible_host=/, "", $i); print $i}}' "$INVENTORY_FILE")"
ces_base_ip="$(awk '/^scale-ces1[[:space:]]/ {for (i=2; i<=NF; i++) if ($i ~ /^ces_base_ip=/) {sub(/^ces_base_ip=/, "", $i); print $i}}' "$INVENTORY_FILE")"
for address in "$node_ip" "$ces_base_ip"; do
  if ! ip -4 -o address show | grep -Fq " ${address}/"; then
    printf 'Inventory address %s is not configured on this VM.\n' "$address" >&2
    exit 1
  fi
done

validate_installer
printf 'Preflight passed on Rocky %s with %s MiB RAM. No IBM package has been extracted yet.\n' \
  "$VERSION_ID" "$memory_mb"

