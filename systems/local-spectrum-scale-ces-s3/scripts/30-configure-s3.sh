#!/usr/bin/env bash
set -euo pipefail

SYSTEM_ROOT="${SYSTEM_ROOT:-/vagrant}"
# shellcheck source=lib/common.sh
source "$SYSTEM_ROOT/scripts/lib/common.sh"
load_lab_config
require_root
require_unsupported_opt_in

export PATH="/usr/lpp/mmfs/bin:$PATH"
NODE_NAME=scale-ces1
NODE_IP="$(awk '/^scale-ces1[[:space:]]/ {for (i=2; i<=NF; i++) if ($i ~ /^ansible_host=/) {sub(/^ansible_host=/, "", $i); print $i}}' "$INVENTORY_FILE")"
CES_BASE_IP="$(awk '/^scale-ces1[[:space:]]/ {for (i=2; i<=NF; i++) if ($i ~ /^ces_base_ip=/) {sub(/^ces_base_ip=/, "", $i); print $i}}' "$INVENTORY_FILE")"
CES_IP="$(require_inventory_var "$INVENTORY_FILE" ces_ip)"
CES_PREFIX="$(require_inventory_var "$INVENTORY_FILE" ces_prefix_ipv4)"
GPFS_SUBNETS="$(require_inventory_var "$INVENTORY_FILE" gpfs_subnets)"
CLUSTER_NAME="$(require_inventory_var "$INVENTORY_FILE" cluster_name)"
PAGEPOOL="$(require_inventory_var "$INVENTORY_FILE" pagepool)"
CES_DEVICE="$(awk '/^scale-ces1[[:space:]]/ {for (i=2; i<=NF; i++) if ($i ~ /^ces_root_device=/) {sub(/^ces_root_device=/, "", $i); print $i}}' "$INVENTORY_FILE")"
S3_DEVICE="$(awk '/^scale-ces1[[:space:]]/ {for (i=2; i<=NF; i++) if ($i ~ /^s3_data_device=/) {sub(/^s3_data_device=/, "", $i); print $i}}' "$INVENTORY_FILE")"
CES_NSD="$(require_inventory_var "$INVENTORY_FILE" ces_root_nsd)"
S3_NSD="$(require_inventory_var "$INVENTORY_FILE" s3_data_nsd)"
FAILURE_GROUP="$(require_inventory_var "$INVENTORY_FILE" failure_group)"
CES_FS="$(require_inventory_var "$INVENTORY_FILE" ces_root_filesystem)"
CES_MOUNT="$(require_inventory_var "$INVENTORY_FILE" ces_root_mount)"
S3_FS="$(require_inventory_var "$INVENTORY_FILE" s3_data_filesystem)"
S3_MOUNT="$(require_inventory_var "$INVENTORY_FILE" s3_data_mount)"
S3_PORT="$(require_inventory_var "$INVENTORY_FILE" s3_endpoint_port)"

for command in mmcrcluster mmchlicense mmlscluster mmchconfig mmlsconfig mmstartup mmshutdown \
  mmgetstate mmcrnsd mmlsnsd mmcrfs mmlsfs mmmount mmchnode mmces mms3; do
  command -v "$command" >/dev/null || { printf 'Required IBM command is unavailable: %s\n' "$command" >&2; exit 1; }
done

hostnamectl set-hostname "$NODE_NAME"
sed -i -E "/[[:space:]]${NODE_NAME}([[:space:]]|$)/d; /[[:space:]]scale-ces1-ces([[:space:]]|$)/d; /[[:space:]]scale-s3-ces([[:space:]]|$)/d" /etc/hosts
cat >>/etc/hosts <<EOF
${NODE_IP} ${NODE_NAME}
${CES_BASE_IP} scale-ces1-ces
${CES_IP} scale-s3-ces
EOF

install -d -m 0700 /root/.ssh
if [[ ! -f /root/.ssh/id_ed25519 ]]; then
  ssh-keygen -q -t ed25519 -N '' -f /root/.ssh/id_ed25519
fi
touch /root/.ssh/authorized_keys
root_public_key="$(cat /root/.ssh/id_ed25519.pub)"
grep -Fqx "$root_public_key" /root/.ssh/authorized_keys || printf '%s\n' "$root_public_key" >>/root/.ssh/authorized_keys
chmod 0600 /root/.ssh/authorized_keys
cat >/root/.ssh/config <<EOF
Host ${NODE_NAME}
  BatchMode yes
  StrictHostKeyChecking accept-new
EOF
chmod 0600 /root/.ssh/config
ssh "$NODE_NAME" /usr/bin/true

state_dir=/etc/scale-lab
install -d -m 0700 "$state_dir"
node_file="$state_dir/nodes"
printf '%s:quorum-manager\n' "$NODE_NAME" >"$node_file"

if [[ ! -s /var/mmfs/gen/mmsdrfs ]]; then
  mmcrcluster -N "$node_file" -C "$CLUSTER_NAME" -r /usr/bin/ssh -R /usr/bin/scp -A
fi
if ! mmlscluster | grep -Fq "$NODE_NAME"; then
  printf 'Existing Storage Scale cluster does not contain expected node %s.\n' "$NODE_NAME" >&2
  exit 1
fi
mmchlicense server --accept -N "$NODE_NAME"
mmchconfig "subnets=${GPFS_SUBNETS},pagepool=${PAGEPOOL}"
if mmlsconfig subnets | grep -Fq '192.168.57.'; then
  printf 'CES network must never appear in GPFS subnets configuration.\n' >&2
  exit 1
fi
mmstartup -a

for _attempt in {1..30}; do
  if mmgetstate -N "$NODE_NAME" 2>/dev/null | grep -Eq '[[:space:]]active([[:space:]]|$)'; then
    break
  fi
  sleep 2
done
if ! mmgetstate -N "$NODE_NAME" | grep -Eq '[[:space:]]active([[:space:]]|$)'; then
  printf 'Storage Scale did not reach active state on %s.\n' "$NODE_NAME" >&2
  exit 1
fi

if ! mmlsfs "$CES_FS" >/dev/null 2>&1 || ! mmlsfs "$S3_FS" >/dev/null 2>&1; then
  if mmlsnsd -Y 2>/dev/null | grep -Eq ":(${CES_NSD}|${S3_NSD}):"; then
    printf 'Partial NSD state exists without both filesystems. Destroy the disposable VM and retry; no automatic disk cleanup is attempted.\n' >&2
    exit 1
  fi
  for device in "$CES_DEVICE" "$S3_DEVICE"; do
    [[ -b "$device" ]] || { printf 'Inventory storage device is missing: %s\n' "$device" >&2; exit 1; }
    if [[ -n "$(wipefs -n "$device" 2>/dev/null)" ]]; then
      printf 'Refusing to use %s because it already contains a disk signature.\n' "$device" >&2
      exit 1
    fi
  done
  ces_bytes="$(blockdev --getsize64 "$CES_DEVICE")"
  s3_bytes="$(blockdev --getsize64 "$S3_DEVICE")"
  if (( ces_bytes < 4 * 1024 * 1024 * 1024 )); then
    printf 'CES shared-root device %s is below the required 4 GiB.\n' "$CES_DEVICE" >&2
    exit 1
  fi
  if (( ces_bytes + s3_bytes >= 12 * 1024 * 1024 * 1024 * 1024 )); then
    printf 'Raw NSD capacity reaches the Developer Edition 12 TiB ceiling; refusing to continue.\n' >&2
    exit 1
  fi

  combined_stanza="$state_dir/all-nsds.stanza"
  ces_stanza="$state_dir/ces-root.stanza"
  s3_stanza="$state_dir/s3-data.stanza"
  cat >"$ces_stanza" <<EOF
%nsd:
  device=${CES_DEVICE}
  nsd=${CES_NSD}
  servers=${NODE_NAME}
  usage=dataAndMetadata
  failureGroup=${FAILURE_GROUP}
  pool=system
EOF
  cat >"$s3_stanza" <<EOF
%nsd:
  device=${S3_DEVICE}
  nsd=${S3_NSD}
  servers=${NODE_NAME}
  usage=dataAndMetadata
  failureGroup=${FAILURE_GROUP}
  pool=system
EOF
  cat "$ces_stanza" "$s3_stanza" >"$combined_stanza"
  mmcrnsd -F "$combined_stanza" -v no
  mmcrfs "$CES_FS" -F "$ces_stanza" -T "$CES_MOUNT" -B 256K -A yes \
    -m 1 -M 1 -r 1 -R 1 --inode-limit 5000
  mmcrfs "$S3_FS" -F "$s3_stanza" -T "$S3_MOUNT" -B 1M -A yes \
    -m 1 -M 1 -r 1 -R 1
fi

mmmount "$CES_FS" -a
mmmount "$S3_FS" -a
mountpoint -q "$CES_MOUNT" || { printf 'CES shared root is not mounted: %s\n' "$CES_MOUNT" >&2; exit 1; }
mountpoint -q "$S3_MOUNT" || { printf 'S3 data filesystem is not mounted: %s\n' "$S3_MOUNT" >&2; exit 1; }

configured_shared_root="$(mmlsconfig cesSharedRoot 2>/dev/null | awk '$1 == "cesSharedRoot" {print $2}' || true)"
if [[ "$configured_shared_root" != "$CES_MOUNT" ]]; then
  mmshutdown -a
  mmchconfig "cesSharedRoot=${CES_MOUNT}"
  mmstartup -a
  mmmount all -a
fi

if ! mmlscluster --ces | grep -Fq "$NODE_NAME"; then
  mmchnode --ces-enable -N "$NODE_NAME"
fi
mmces address prefix-ipv4 "$CES_PREFIX"
if ! mmces address list -Y | grep -Fq ":${CES_IP}:"; then
  mmces address add --ces-node "$NODE_NAME" --ces-ip "$CES_IP"
fi
mmces address policy node-affinity

if systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-port="${S3_PORT}/tcp"
  firewall-cmd --reload
fi

mmces service enable S3
mmces service start S3 -a
for _attempt in {1..60}; do
  if mmces service list -a 2>/dev/null | grep -Eqi 'S3.*running'; then
    break
  fi
  sleep 5
done
if ! mmces service list -a | grep -Eqi 'S3.*running'; then
  mmces state show S3 -a >&2 || true
  printf 'Native CES S3 did not reach running state.\n' >&2
  exit 1
fi
s3_config="$(mms3 config list)"
if ! grep -Eq "ENDPOINT_SSL_PORT[[:space:]]*:[[:space:]]*${S3_PORT}([[:space:]]|$)" <<<"$s3_config"; then
  printf 'mms3 does not report the pinned TLS endpoint port %s.\n%s\n' "$S3_PORT" "$s3_config" >&2
  exit 1
fi
if ! grep -Eq 'ALLOW_HTTP[[:space:]]*:[[:space:]]*false([[:space:]]|$)' <<<"$s3_config"; then
  printf 'mms3 HTTP policy differs from the documented TLS-only default.\n%s\n' "$s3_config" >&2
  exit 1
fi

printf 'Native CES S3 is running at https://%s:%s (single fixed node; this is not failover).\n' \
  "$CES_IP" "$S3_PORT"
printf 'Storage uses replication 1 in failure group %s: there is no data redundancy.\n' "$FAILURE_GROUP"
