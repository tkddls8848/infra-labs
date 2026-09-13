#!/usr/bin/env bash
set -euo pipefail

SYSTEM_ROOT="${SYSTEM_ROOT:-/vagrant}"
# shellcheck source=lib/common.sh
source "$SYSTEM_ROOT/scripts/lib/common.sh"
load_lab_config
require_root
require_unsupported_opt_in

export PATH="/usr/lpp/mmfs/bin:$PATH"
exec python3 "$SYSTEM_ROOT/scripts/lib/verify_s3.py" \
  --host "$(require_inventory_var "$INVENTORY_FILE" ces_ip)" \
  --port "$(require_inventory_var "$INVENTORY_FILE" s3_endpoint_port)" \
  --data-root "$(require_inventory_var "$INVENTORY_FILE" s3_data_mount)" \
  --uid "$(require_inventory_var "$INVENTORY_FILE" s3_test_uid)" \
  --gid "$(require_inventory_var "$INVENTORY_FILE" s3_test_gid)"

