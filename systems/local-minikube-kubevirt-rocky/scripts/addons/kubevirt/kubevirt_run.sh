#!/usr/bin/bash
set -euo pipefail

readonly KUBERNETES_VERSION="v1.35.1"
readonly KUBEVIRT_VERSION="v1.8.2"
readonly KUBEVIRT_OPERATOR_SHA256="57e0822062e6617964fd7e1731f9ace531f8ee34a0e48cf8dd0ccce72196e1d6"
readonly KUBEVIRT_CR_SHA256="43106136dbce3312bdbfdeae612aacafc6c12da518d233f90645b4685d84a2af"
readonly VIRTCTL_SHA256="745f3c58c6a77be65b828e67b6ad930e9039ab293ed5b2bef6d44c8681af5b75"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
manifest_dir="$(cd -- "$script_dir/../../../manifests/kubevirt" && pwd)"
operator_manifest="$manifest_dir/kubevirt-operator.yaml"
cr_manifest="$manifest_dir/kubevirt-cr.yaml"
test_vm_manifest="$manifest_dir/test-vm.yaml"
kubectl=(minikube kubectl --)

for manifest in "$operator_manifest" "$cr_manifest" "$test_vm_manifest"; do
  if [[ ! -r "$manifest" ]]; then
    printf 'Required local manifest is missing or unreadable: %s\n' "$manifest" >&2
    exit 1
  fi
done
printf '%s  %s\n%s  %s\n' \
  "$KUBEVIRT_OPERATOR_SHA256" "$operator_manifest" \
  "$KUBEVIRT_CR_SHA256" "$cr_manifest" | sha256sum --check -

actual_version="$("${kubectl[@]}" get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}')"
if [[ "$actual_version" != "$KUBERNETES_VERSION" ]]; then
  printf 'This lab pairs KubeVirt %s with Kubernetes %s; found %s.\n' \
    "$KUBEVIRT_VERSION" "$KUBERNETES_VERSION" "$actual_version" >&2
  exit 1
fi

use_emulation=false
if ! minikube ssh -- "test -c /dev/kvm && grep -Eq '(vmx|svm)' /proc/cpuinfo"; then
  use_emulation=true
  printf 'The Minikube node has no usable KVM device; enabling KubeVirt software emulation.\n'
fi

"${kubectl[@]}" apply -f "$operator_manifest"
"${kubectl[@]}" wait --for=condition=Established crd/kubevirts.kubevirt.io --timeout=180s
"${kubectl[@]}" apply -f "$cr_manifest"
if [[ "$use_emulation" == true ]]; then
  "${kubectl[@]}" -n kubevirt patch kubevirt kubevirt --type=merge \
    --patch '{"spec":{"configuration":{"developerConfiguration":{"useEmulation":true}}}}'
fi
"${kubectl[@]}" -n kubevirt wait kubevirt kubevirt --for=condition=Available --timeout=10m

virtctl_download="$(mktemp)"
trap 'rm -f "$virtctl_download"' EXIT
curl -fL --retry 3 \
  "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/virtctl-${KUBEVIRT_VERSION}-linux-amd64" \
  -o "$virtctl_download"
printf '%s  %s\n' "$VIRTCTL_SHA256" "$virtctl_download" | sha256sum --check -
sudo install -m 0755 "$virtctl_download" /usr/local/bin/virtctl

"${kubectl[@]}" apply -f "$test_vm_manifest"
virtctl start testvm
"${kubectl[@]}" wait vmi/testvm --for=condition=Ready --timeout=5m
virtctl stop testvm
"${kubectl[@]}" wait --for=delete vmi/testvm --timeout=2m
