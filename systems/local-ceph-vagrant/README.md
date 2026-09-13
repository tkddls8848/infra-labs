# Local Ceph lab with VirtualBox

This directory is a self-contained Ceph lab definition for Vagrant's VirtualBox provider. It intentionally remains separate from `../local-ceph-kvm`: the two labs describe the same logical topology but have different host prerequisites, virtual-disk behavior, guest device names, and provider configuration. Use this lab when VirtualBox is the available hypervisor, especially on Windows or macOS hosts.

## Which definition should I use?

| | `local-ceph-vagrant` (this directory) | `local-ceph-kvm` |
|---|---|---|
| Provider | VirtualBox | libvirt/KVM |
| Typical host | Windows, macOS, or Linux with VirtualBox | Linux with hardware virtualization and libvirt |
| OSD backing | Persistent fixed-size VDI files under `~/vagrant_osd/ceph-cluster` | libvirt-managed raw volumes |
| Guest OSD names | SATA `/dev/sdb`, `/dev/sdc` | virtio `/dev/vdb`, `/dev/vdc` |
| Guest container runtime | Docker | Podman |

Do not run both definitions at the same time on one host without changing their inventories: both intentionally use the same VM hostnames and the same two private CIDRs.

## Source of truth and topology

Cluster facts are declared in [`inventory/inventory.ini`](inventory/inventory.ini). The Vagrantfile reads the Ceph version, host public and cluster addresses, public and cluster CIDRs, monitor/manager counts, and each storage host's `osd_devices` from that file. Do not duplicate those values in a script.

The default topology is:

- `ceph-master`: public `192.168.60.10`, cluster `192.168.61.10`
- `ceph-worker-1`: public `192.168.60.11`, cluster `192.168.61.11`, OSDs `/dev/sdb,/dev/sdc`
- `ceph-worker-2`: public `192.168.60.12`, cluster `192.168.61.12`, OSDs `/dev/sdb,/dev/sdc`

Every VM receives two private-network NICs. `192.168.60.0/24` carries client and monitor traffic; `192.168.61.0/24` carries OSD replication and recovery traffic. Provisioning fails if the CIDRs are equal or an address is outside its declared CIDR.

This is deliberately a non-HA, single-monitor lab. `mon_count=1` and `mgr_count=2` are intentional: the second manager provides manager standby only, while loss of `ceph-master` still loses monitor quorum. Use a production-oriented definition with at least three monitors for HA.

## Declared disks only

The Vagrantfile creates one fixed-size VDI per inventory-declared OSD device and attaches them in SATA order, producing `/dev/sdb` then `/dev/sdc`. `cephadm-setup.sh` receives that inventory-derived CSV and zaps/adds only those devices. `fix-osd-heartbeat.sh` reads the same inventory, applies scheduler changes on each storage host through Ansible, and warns without modifying any undeclared `sd[b-z]` candidate.

All storage hosts currently must declare the same device list because `cephadm-setup.sh` accepts one shared CSV. For this provider the list must be contiguous from `/dev/sdb`; inconsistent or invalid declarations fail before VM creation.

## Host prerequisites

- Vagrant and a working VirtualBox installation
- Hardware virtualization enabled and enough capacity for 3 VMs (about 14 GiB guest RAM plus host overhead)
- At least 40 GiB for the four default OSD VDIs, plus VM OS disks and application data
- Both `192.168.60.0/24` and `192.168.61.0/24` free of conflicting host-only networks/routes
- The VDI parent directory created before the first run:

```bash
mkdir -p ~/vagrant_osd/ceph-cluster
```

## Execution preconditions and startup

Run Vagrant from this directory. Review the inventory first, and ensure every declared OSD path refers only to an expendable lab disk. The master provisioner expects both workers to have been created, provisioned, and to have Vagrant private keys; the Vagrantfile defines workers before the master and disables parallel startup to preserve that precondition.

```bash
cd systems/local-ceph-vagrant
vagrant up
```

If nodes are started separately, complete both workers before provisioning the master:

```bash
vagrant up ceph-worker-1 ceph-worker-2
vagrant up ceph-master
```

Useful access points after provisioning:

- SSH: `vagrant ssh ceph-master` (or either worker name)
- Ceph Dashboard: `http://192.168.60.10:8080` (`admin` / `admin`, lab credentials)
- RGW S3 endpoint: `http://192.168.60.10:7480`
- Block store UI (Node.js): `http://192.168.60.10:3333`
- Block store UI (Go): `http://192.168.60.10:3334` (only when the Go binary was built, see below)
- Ceph status: `vagrant ssh ceph-master -c "sudo ceph -s"`

## Block store application: two implementations side by side

The RBD block store app ships twice, as the same application written two ways:

| | [`apps/block-store-app`](apps/block-store-app) | [`apps/block-store-app-go`](apps/block-store-app-go) |
|---|---|---|
| Language | Node.js | Go |
| Central UI | `:3333` | `:3334` |
| Node agent | `:4000` | `:4001` |

Both implementations expose the same HTTP API, serve the same UI, and read and
write the **same RBD mount** (`/srv/rbd-store`) on each worker. A file uploaded
through one UI appears in the other, so the two can be compared directly on the
same data and the same storage.

The Go implementation is optional. `block-store-app-setup.sh` deploys it only
when a built binary is present, so a host without a Go toolchain provisions the
lab exactly as before. To include it:

```bash
bash apps/block-store-app-go/scripts/build.sh   # host, once
vagrant provision --provision-with blockstoreapp
```

Then compare them on the master:

```bash
vagrant ssh ceph-master -c "bash /vagrant/scripts/ceph/block-store-compare.sh"
```

The script reports deployment footprint, idle memory, peak memory during a large
upload, node-list latency, and confirms both implementations see the same files.
Measured results and the reasons behind them are in
[`apps/block-store-app-go/README.md`](apps/block-store-app-go/README.md).

Stop or destroy the VMs with `vagrant halt` or `vagrant destroy -f`. The VDI files under `~/vagrant_osd/ceph-cluster` persist across VM destruction so the lab can be reprovisioned; remove them separately only when their data is no longer needed.
