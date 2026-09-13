#!/usr/bin/bash
set -euo pipefail

readonly MINIKUBE_VERSION="v1.38.1"
readonly KUBERNETES_VERSION="v1.35.1"
current_user="$(id -un)"

installed_minikube_version="$(minikube version --short)"
if [[ "$installed_minikube_version" != "$MINIKUBE_VERSION" ]]; then
  printf 'Expected Minikube %s, found %s. Re-run scripts/cluster/minikube.sh.\n' \
    "$MINIKUBE_VERSION" "$installed_minikube_version" >&2
  exit 1
fi

for required_group in libvirt kvm; do
  if ! id -nG "$current_user" | grep -qw "$required_group"; then
    printf '%s is not active in the current %s group. Reboot and log in again.\n' \
      "$current_user" "$required_group" >&2
    exit 1
  fi
done

sudo systemctl enable --now libvirtd
sudo modprobe kvm
sudo dbus-uuidgen --ensure

if ! grep -Eq '(vmx|svm)' /proc/cpuinfo || [[ ! -c /dev/kvm ]]; then
  printf 'The guest has no usable KVM device. Enable nested virtualization in the host and retry.\n' >&2
  exit 1
fi
if ! virsh --connect qemu:///system domcapabilities --virttype kvm >/dev/null; then
  printf 'libvirt cannot expose KVM capabilities to %s.\n' "$current_user" >&2
  exit 1
fi

minikube start \
  --driver=kvm2 \
  --container-runtime=containerd \
  --kubernetes-version="$KUBERNETES_VERSION" \
  --cpus=4 \
  --memory=8192

actual_version="$(minikube kubectl -- get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}')"
if [[ "$actual_version" != "$KUBERNETES_VERSION" ]]; then
  printf 'Expected Kubernetes %s from Minikube %s, got %s.\n' \
    "$KUBERNETES_VERSION" "$MINIKUBE_VERSION" "$actual_version" >&2
  exit 1
fi
printf 'Minikube %s is running Kubernetes %s with the kvm2 driver.\n' \
  "$MINIKUBE_VERSION" "$actual_version"
