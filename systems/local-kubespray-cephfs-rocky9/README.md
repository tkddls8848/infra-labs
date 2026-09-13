# Local Kubespray + Rook CephFS lab on Rocky Linux 9

This system creates a four-VM Kubernetes and Rook/Ceph lab with Vagrant and the
VirtualBox provider. It is intended for disposable local testing of Kubespray,
MetalLB, RBD, and CephFS. It is not a production design.

## Topology and networks

[`inventory.ini`](inventory.ini) is the single source of truth for VM names, node
roles, addresses, SSH keys, resource sizes, storage devices, component versions,
and network ranges. The Vagrantfile reads that inventory instead of maintaining a
second node list.

- One control-plane/etcd VM: `192.168.56.10`
- Three worker/storage VMs: `192.168.56.21` through `192.168.56.23`
- Node network: `192.168.56.0/24`
- MetalLB pool: `192.168.56.128/28`
- Pod network: `10.244.0.0/16` (Flannel)
- Service network: `10.96.0.0/12`
- One inventory-declared 10 GiB `/dev/sdb` OSD device per storage VM

The Vagrantfile and `master_node/kubespray.sh` both reject a MetalLB pool outside
the node network or one that overlaps a node address. Before `vagrant up`, also
check the host routing table and change the inventory ranges if the host already
uses `192.168.56.0/24`; a guest cannot reliably detect every host/VPN route.

`common/config.sh` leaves SELinux, firewalld, and NetworkManager in their existing
states. In particular, NetworkManager stays enabled and `/etc/resolv.conf` remains
under NetworkManager/DHCP ownership so Vagrant networking and local DNS are not
silently replaced by a public resolver.

## Pinned stack

- Vagrant box: `bento/rockylinux-9` `202510.26.0` (Rocky Linux 9)
- Kubespray: `v2.25.0` at commit `7e0a4072`
- Kubernetes: `v1.29.5`, Flannel `v0.22.0`, and MetalLB `v0.13.9`
- Python controller runtime: `3.11.9`, source archive SHA-256
  `e7de3240a8bc2b1e1ba5c81bf943f06861ff494b69fda990ce2722a504c6153d`
- Rook: `v1.14.8` at commit `35b3b9e4`, with Ceph Reef `v18.2.2`
- Optional Jenkins image: `jenkins/jenkins:2.452.2-lts-jdk17`, with its manifest
  repository pinned to commit `0c3fba18`
- Optional Prometheus chart: `25.22.0`; Grafana chart: `8.2.1`

The [Rook 1.14 support matrix](https://rook.io/docs/rook/v1.14/Getting-Started/quickstart/)
lists Kubernetes 1.25 through 1.30, so it covers the pinned 1.29.5 cluster. The
Rook script checks out the declared tag and immutable commit, vendors
the required upstream files into `manifests/rook-<version>/`, renders only the
inventory-declared nodes/devices, and applies those local files. It never applies a
remote URL or reads manifests directly from an upstream examples directory.

The [Kubespray v2.25.0 supported-distributions list](https://github.com/kubernetes-sigs/kubespray/blob/v2.25.0/README.md#supported-linux-distributions)
explicitly includes Rocky Linux 8 and 9, so this lab keeps the pinned Kubespray
release and immutable commit. The provisioner also retains the checksum-verified,
non-PGO Python source build to guarantee the exact pinned 3.11.9 controller runtime;
it skips the build only when that exact interpreter already exists. Rocky Linux 9
keeps two build dependencies in CRB, which the provisioner enables explicitly.

## Create and destroy

Prerequisites are Vagrant, VirtualBox, enough memory for the four VMs, and access
to the pinned upstream repositories and container registries.

```bash
cd systems/local-kubespray-cephfs-rocky9
vagrant validate
vagrant up --provider=virtualbox
```

The optional Jenkins and monitoring provisioners are commented out in the
Vagrantfile. Enable them deliberately after the Rook storage classes are ready.

Destroy the VMs with:

```bash
vagrant destroy -f
```

The cluster is non-HA because it has a single Kubernetes control-plane and etcd
member. Although Ceph uses three storage nodes and three monitors, the tiny disks,
lab resource limits, single failure domain, fixed local network, Vagrant keys, and
disposable lifecycle remain lab-only assumptions. Rook consumes the declared raw
OSD devices; never point `rook_device` at a disk containing data.
