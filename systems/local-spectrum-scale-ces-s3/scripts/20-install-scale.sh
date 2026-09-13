#!/usr/bin/env bash
set -euo pipefail

SYSTEM_ROOT="${SYSTEM_ROOT:-/vagrant}"
# shellcheck source=lib/common.sh
source "$SYSTEM_ROOT/scripts/lib/common.sh"
load_lab_config
require_root
require_unsupported_opt_in
validate_installer

KERNEL_EVR="$(require_inventory_var "$INVENTORY_FILE" kernel_evr)"
KERNEL_ARCH="$(require_inventory_var "$INVENTORY_FILE" kernel_arch)"
EXPECTED_KERNEL="${KERNEL_EVR}.${KERNEL_ARCH}"
SCALE_EXTRACT_DIR="$(require_inventory_var "$INVENTORY_FILE" scale_extract_dir)"

running_kernel="$(uname -r)"
if [[ "$running_kernel" != "$EXPECTED_KERNEL" ]]; then
  printf 'GPL build refused: running kernel is %s, inventory pins %s. Check the Vagrant reboot phase.\n' \
    "$running_kernel" "$EXPECTED_KERNEL" >&2
  exit 1
fi
if ! rpm -q "kernel-devel-${running_kernel}" >/dev/null; then
  printf 'GPL build refused: kernel-devel does not exactly match running kernel %s.\n' \
    "$running_kernel" >&2
  exit 1
fi
if [[ ! -d "/lib/modules/${running_kernel}/build" ]]; then
  printf 'GPL build refused: /lib/modules/%s/build is missing.\n' "$running_kernel" >&2
  exit 1
fi

if [[ ! -d "$SCALE_EXTRACT_DIR" ]]; then
  printf 'Extracting the user-supplied IBM archive with its documented --silent mode.\n'
  if ! "$INSTALLER" --silent; then
    printf 'IBM installer extraction failed for expected release %s. The user artifact remains at %s.\n' \
      "$SCALE_VERSION" "$INSTALLER" >&2
    exit 1
  fi
fi
if [[ ! -d "$SCALE_EXTRACT_DIR" ]]; then
  printf 'IBM extraction did not create the pinned directory %s.\n' "$SCALE_EXTRACT_DIR" >&2
  exit 1
fi
[[ -f "$INSTALLER" && -s "$INSTALLER" ]] || {
  printf 'The user-owned installer disappeared during extraction; refusing to continue.\n' >&2
  exit 1
}

select_rpm() {
  local package_name="$1"
  local platform_marker="${2:-}"
  local candidate
  local actual_name
  local -a matches=()

  while IFS= read -r -d '' candidate; do
    actual_name="$(rpm -qp --queryformat '%{NAME}' "$candidate" 2>/dev/null || true)"
    [[ "$actual_name" == "$package_name" ]] || continue
    if [[ -n "$platform_marker" && "$(basename "$candidate")" != *"$platform_marker"* ]]; then
      continue
    fi
    matches+=("$candidate")
  done < <(find "$SCALE_EXTRACT_DIR" -type f -name '*.rpm' -print0)

  if [[ "${#matches[@]}" -ne 1 ]]; then
    printf 'Expected exactly one %s RPM (platform marker %s) under %s; found %s.\n' \
      "$package_name" "${platform_marker:-none}" "$SCALE_EXTRACT_DIR" "${#matches[@]}" >&2
    printf '%s\n' "${matches[@]:-no candidates}" >&2
    return 1
  fi
  printf '%s\n' "${matches[0]}"
}

core_rpms=(
  "$(select_rpm gpfs.base)"
  "$(select_rpm gpfs.gpl)"
  "$(select_rpm gpfs.license.dev)"
  "$(select_rpm gpfs.gskit)"
  "$(select_rpm gpfs.msg.en_US)"
  "$(select_rpm gpfs.docs)"
  "$(select_rpm gpfs.adv)"
  "$(select_rpm gpfs.crypto)"
)
s3_rpms=(
  "$(select_rpm gpfs.mms3 .el9.)"
  "$(select_rpm noobaa-core .el9.)"
)

dnf --disablerepo='*' --enablerepo=scale-lab-baseos,scale-lab-appstream,scale-lab-crb \
  install -y "${core_rpms[@]}" "${s3_rpms[@]}"

for package in gpfs.base gpfs.gpl gpfs.license.dev gpfs.msg.en_US gpfs.docs gpfs.adv gpfs.crypto; do
  installed_evr="$(rpm -q --queryformat '%{VERSION}-%{RELEASE}' "$package")"
  if [[ "$installed_evr" != "$SCALE_RPM_EVR" ]]; then
    printf 'Installed %s is %s; expected the pinned Storage Scale RPM level %s.\n' \
      "$package" "$installed_evr" "$SCALE_RPM_EVR" >&2
    exit 1
  fi
done
printf 'Archive-bundled component RPM metadata (not independently guessed or pinned):\n'
rpm -q gpfs.gskit gpfs.mms3 noobaa-core

gpl_log=/var/log/scale-lab-mmbuildgpl.log
if ! /usr/lpp/mmfs/bin/mmbuildgpl --build-package 2>&1 | tee "$gpl_log"; then
  cat >&2 <<EOF
GPL portability layer compilation failed.
This Rocky Linux ${VERSION_ID:-9} / kernel ${running_kernel} combination is outside IBM's support matrix
and is the most likely first-use failure point. Full build output is in ${gpl_log}.
EOF
  exit 1
fi
if ! modprobe mmfs26; then
  printf 'mmbuildgpl returned success, but mmfs26 could not be loaded for kernel %s. See %s.\n' \
    "$running_kernel" "$gpl_log" >&2
  exit 1
fi

cat >/etc/profile.d/ibm-storage-scale.sh <<'EOF'
export PATH="/usr/lpp/mmfs/bin:$PATH"
EOF
printf 'Installed IBM Storage Scale %s native CES S3 packages and built GPL for %s.\n' \
  "$SCALE_VERSION" "$running_kernel"
