#!/usr/bin/env bash
set -euo pipefail

SYSTEM_ROOT="${SYSTEM_ROOT:-/vagrant}"
# shellcheck source=lib/common.sh
source "$SYSTEM_ROOT/scripts/lib/common.sh"
load_lab_config
require_root
require_unsupported_opt_in

ROCKY_RELEASE="$(require_inventory_var "$INVENTORY_FILE" rocky_release)"
ROCKY_VAULT_BASEURL="$(require_inventory_var "$INVENTORY_FILE" rocky_vault_baseurl)"
KERNEL_EVR="$(require_inventory_var "$INVENTORY_FILE" kernel_evr)"
KERNEL_ARCH="$(require_inventory_var "$INVENTORY_FILE" kernel_arch)"
KERNEL_RELEASE="${KERNEL_EVR}.${KERNEL_ARCH}"

source /etc/os-release
if [[ "${ID:-}" != "rocky" || "${VERSION_ID:-}" != "$ROCKY_RELEASE" ]]; then
  printf 'Pinned box is expected to be Rocky %s; found ID=%s VERSION_ID=%s.\n' \
    "$ROCKY_RELEASE" "${ID:-unknown}" "${VERSION_ID:-unknown}" >&2
  exit 1
fi

cat >/etc/yum.repos.d/scale-lab-rocky-vault.repo <<EOF
[scale-lab-baseos]
name=Scale lab Rocky ${ROCKY_RELEASE} BaseOS vault
baseurl=${ROCKY_VAULT_BASEURL}/BaseOS/x86_64/os/
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9

[scale-lab-appstream]
name=Scale lab Rocky ${ROCKY_RELEASE} AppStream vault
baseurl=${ROCKY_VAULT_BASEURL}/AppStream/x86_64/os/
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9

[scale-lab-crb]
name=Scale lab Rocky ${ROCKY_RELEASE} CRB vault
baseurl=${ROCKY_VAULT_BASEURL}/CRB/x86_64/os/
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-9
EOF

repos=(--disablerepo='*' --enablerepo=scale-lab-baseos,scale-lab-appstream,scale-lab-crb)
packages=(
  "kernel-${KERNEL_EVR}.${KERNEL_ARCH}"
  "kernel-core-${KERNEL_EVR}.${KERNEL_ARCH}"
  "kernel-modules-${KERNEL_EVR}.${KERNEL_ARCH}"
  "kernel-devel-${KERNEL_EVR}.${KERNEL_ARCH}"
  "cpp-$(require_inventory_var "$INVENTORY_FILE" cpp_evr).x86_64"
  "gcc-$(require_inventory_var "$INVENTORY_FILE" gcc_evr).x86_64"
  "gcc-c++-$(require_inventory_var "$INVENTORY_FILE" gcc_cxx_evr).x86_64"
  "binutils-$(require_inventory_var "$INVENTORY_FILE" binutils_evr).x86_64"
  "elfutils-libelf-devel-$(require_inventory_var "$INVENTORY_FILE" elfutils_libelf_devel_evr).x86_64"
  "make-$(require_inventory_var "$INVENTORY_FILE" make_evr).x86_64"
  "rpm-build-$(require_inventory_var "$INVENTORY_FILE" rpm_build_evr).x86_64"
  "bzip2-$(require_inventory_var "$INVENTORY_FILE" bzip2_evr).x86_64"
  "dnf-plugins-core-$(require_inventory_var "$INVENTORY_FILE" dnf_plugins_core_evr).noarch"
  "python3-$(require_inventory_var "$INVENTORY_FILE" python3_evr).x86_64"
)

dnf "${repos[@]}" install -y "${packages[@]}"

for package in kernel kernel-core kernel-modules kernel-devel; do
  rpm -q "${package}-${KERNEL_RELEASE}" >/dev/null || {
    printf 'Pinned package is not installed: %s-%s\n' "$package" "$KERNEL_RELEASE" >&2
    exit 1
  }
done

# Exact versionlocks reject future kernel installs; the four kernel packages share one EVR/architecture.
dnf "${repos[@]}" versionlock add \
  "kernel-${KERNEL_RELEASE}" \
  "kernel-core-${KERNEL_RELEASE}" \
  "kernel-modules-${KERNEL_RELEASE}" \
  "kernel-devel-${KERNEL_RELEASE}"

kernel_image="/boot/vmlinuz-${KERNEL_RELEASE}"
if [[ ! -f "$kernel_image" ]]; then
  printf 'Pinned kernel image was not installed: %s\n' "$kernel_image" >&2
  exit 1
fi
grubby --set-default "$kernel_image"
printf 'Pinned kernel/toolchain installed. Vagrant will reboot into %s before GPL compilation.\n' \
  "$KERNEL_RELEASE"

