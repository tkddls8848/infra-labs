#!/usr/bin/bash
set -euo pipefail

# Phase 1: install the host virtualization stack and grant access to it.
# Rocky 9 no longer provides bridge-utils; libvirt's default network does not require brctl.
sudo dnf install -y qemu-kvm libvirt libvirt-client virt-install
sudo systemctl enable --now libvirtd

current_user="$(id -un)"
for required_group in libvirt kvm; do
  if ! getent group "$required_group" >/dev/null; then
    printf 'Required group %s was not created by the virtualization packages.\n' "$required_group" >&2
    exit 1
  fi
done
sudo usermod -aG libvirt,kvm "$current_user"

cat <<EOF
Host virtualization prerequisites are installed for ${current_user}.
Reboot the guest now so the libvirt/kvm group membership and libvirt networking
are active, then run /vagrant/scripts/addons/kubevirt/kubevirt_start.sh as the same user.

Minikube v1.38.1 contains its KVM driver; no external driver binary is required.
EOF
