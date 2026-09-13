# Rocky Linux 9 Minikube + KubeVirt lab

## Purpose and provider

This lab creates one Rocky Linux 9 guest with Vagrant and VirtualBox, then starts a second-level Minikube VM with Minikube's built-in `kvm2` driver. KubeVirt runs on the Minikube cluster and starts a small CirrOS test VM. This directory is the consolidated Minikube/KubeVirt definition after the duplicate CentOS 8 variant was retired.

## Prerequisites

- An x86_64 host with hardware virtualization and nested virtualization enabled.
- Vagrant and VirtualBox, with at least 16 GiB RAM and four CPUs available to the guest.
- VirtualBox host-only networking configured to allow `192.168.81.0/24`; newer VirtualBox releases otherwise reject the configured `192.168.81.10` address.
- Internet access to Rocky and Docker package repositories, Google Storage, GitHub, `registry.k8s.io`, and Quay.

Minikube's KVM driver requires libvirt 1.3.1+ and qemu-kvm 2.0+. Rocky Linux 9 supplies newer versions through its supported repositories. The scripts fail early when nested KVM, `/dev/kvm`, libvirt capabilities, or the required group membership is unavailable.

## Pinned versions

| Component | Pin |
| --- | --- |
| Vagrant box | `bento/rockylinux-9` `202510.26.0` |
| Minikube | `v1.38.1` (`minikube-linux-amd64` SHA-256 verified) |
| Kubernetes | `v1.35.1` |
| KubeVirt and `virtctl` | `v1.8.2` (release SHA-256 values verified) |
| Minikube driver/runtime | built-in `kvm2` / `containerd` |
| Test disk | `quay.io/kubevirt/cirros-container-disk-demo@sha256:ebdb8d8b9b480f6ee7664ed3fdde8428767664f507d98f94090edeff04d7ebf2` |

Minikube v1.38.1 added and defaults to Kubernetes v1.35.1. The KubeVirt support matrix lists KubeVirt 1.8 as supported on Kubernetes 1.35 and 1.34, so the explicit Kubernetes pin is within both projects' supported pair. See the [Minikube v1.38.1 release](https://github.com/kubernetes/minikube/releases/tag/v1.38.1), [KubeVirt support matrix](https://github.com/kubevirt/sig-release/blob/main/releases/k8s-support-matrix.md), and [Minikube kvm2 requirements](https://minikube.sigs.k8s.io/docs/drivers/kvm2/).

The operator and custom-resource manifests are vendored from the KubeVirt v1.8.2 GitHub release under `manifests/kubevirt/`. `kubevirt_run.sh` verifies their official release SHA-256 values and applies only local files. `test-vm.yaml` is a local equivalent of the former KubeVirt labs VM manifest with its container image pinned by digest.

## Exact step order

1. From this directory, create and provision the outer VM: `vagrant up`.
2. Enter it: `vagrant ssh`.
3. Run the pre-reboot virtualization phase: `bash /vagrant/scripts/addons/kubevirt/kubevirt_install.sh`.
4. Reboot at the explicit boundary: `sudo reboot`. The SSH session will close.
5. Re-enter the guest: `vagrant ssh`.
6. Validate KVM and start the pinned cluster: `bash /vagrant/scripts/addons/kubevirt/kubevirt_start.sh`.
7. Install KubeVirt from local manifests and exercise the test VM: `bash /vagrant/scripts/addons/kubevirt/kubevirt_run.sh`.

The install script never invokes `newgrp` or reboots itself. The post-reboot script checks that the new `libvirt` and `kvm` memberships are active before starting Minikube. The Docker group change made during Vagrant provisioning is also picked up by the later login rather than by a `newgrp` subshell.

## Consolidation from CentOS 8

| Area | Current Rocky definition | Retired CentOS 8 definition |
| --- | --- | --- |
| Vagrant box | `bento/rockylinux-9` `202510.26.0` | `generic/centos8` |
| OS lifecycle | Supported Rocky Linux 9 lifecycle; viable fresh provisioning | EOL since 2021-12-31; no supported public package bootstrap |
| Package source | Active Rocky repositories; Docker uses Docker's RHEL-compatible CentOS repository | Retired CentOS mirror metadata unless an operator supplies an archive/internal mirror |
| Intended use | Runnable canonical lab | Removed duplicate definition |

The Minikube, Kubernetes, KubeVirt, local manifests, resource sizing, network, and numbered reboot flow intentionally remain the same after consolidation; only the supported OS base changed.
