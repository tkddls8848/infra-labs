# Local Ceph lab with libvirt/KVM

This directory is a self-contained Ceph lab definition for Vagrant's libvirt/KVM provider. It intentionally remains separate from `../local-ceph-vagrant`: the logical topology is similar, but KVM needs different host software, networking, disk creation, guest device names, and tuning. Use this lab on a Linux host where KVM acceleration and libvirt are available.

## Which definition should I use?

| | `local-ceph-kvm` (this directory) | `local-ceph-vagrant` |
|---|---|---|
| Provider | libvirt/KVM through `vagrant-libvirt` | VirtualBox |
| Typical host | Linux with `/dev/kvm` and libvirt | Windows, macOS, or Linux with VirtualBox |
| OSD backing | libvirt-managed 10 GiB raw volumes | Persistent fixed-size VDI files |
| Guest OSD names | virtio `/dev/vdb`, `/dev/vdc` | SATA `/dev/sdb`, `/dev/sdc` |
| Guest container runtime | Podman | Docker |

Do not run both definitions at the same time on one host without changing their inventories: both intentionally use the same VM hostnames and the same two private CIDRs.

## Source of truth and topology

Cluster facts are declared in [`inventory/inventory.ini`](inventory/inventory.ini). The Vagrantfile reads the Ceph version, host public and cluster addresses, public and cluster CIDRs, monitor/manager counts, and each storage host's `osd_devices` from that file. The KVM definition does not import or share configuration with the VirtualBox definition.

The default topology is:

- `ceph-master`: public `192.168.60.10`, cluster `192.168.61.10`
- `ceph-worker-1`: public `192.168.60.11`, cluster `192.168.61.11`, OSDs `/dev/vdb,/dev/vdc`
- `ceph-worker-2`: public `192.168.60.12`, cluster `192.168.61.12`, OSDs `/dev/vdb,/dev/vdc`

Every VM receives two libvirt private-network NICs. `192.168.60.0/24` carries client and monitor traffic; `192.168.61.0/24` carries OSD replication and recovery traffic. Provisioning fails if the CIDRs are equal or an address is outside its declared CIDR.

This is deliberately a non-HA, single-monitor lab. `mon_count=1` and `mgr_count=2` are intentional: the second manager is only a manager standby, and loss of `ceph-master` still loses monitor quorum. Use at least three monitors for an HA cluster.

## Declared disks only

For each inventory-declared OSD device, the libvirt provider creates one raw volume on the virtio bus; after the OS disk (`/dev/vda`) these appear as `/dev/vdb` and `/dev/vdc`. `cephadm-setup.sh` receives the inventory-derived CSV and adds only those devices. `fix-osd-heartbeat.sh` reads the same inventory, applies scheduler changes on each storage host through Ansible, and warns without modifying undeclared `vd[b-z]` or `sd[b-z]` candidates.

All storage hosts currently must declare the same device list because `cephadm-setup.sh` accepts one shared CSV. For this provider the list must be contiguous from `/dev/vdb`; inconsistent or invalid declarations fail before VM creation.

## Host prerequisites

- A Linux host with CPU virtualization enabled and `/dev/kvm` available
- QEMU/KVM, libvirt, and a running libvirt daemon
- Vagrant plus the `vagrant-libvirt` plugin
- Permission for the current user to manage libvirt (commonly membership in the `libvirt` group)
- Enough capacity for 3 VMs (about 14 GiB guest RAM plus host overhead), four 10 GiB OSD volumes, and VM OS disks
- Both `192.168.60.0/24` and `192.168.61.0/24` free of conflicting libvirt networks/routes

Confirm the provider before starting:

```bash
virsh list --all
vagrant plugin list | grep vagrant-libvirt
```

## Execution preconditions and startup

Run Vagrant from this directory. Review the inventory first and treat every declared OSD path as destructive/expendable lab storage. The master provisioner expects both workers and their Vagrant private keys to exist, so the Vagrantfile disables parallel startup and defines workers before the master.

```bash
cd systems/local-ceph-kvm
vagrant up --provider=libvirt
```

If nodes are started separately, complete both workers before provisioning the master:

```bash
vagrant up --provider=libvirt ceph-worker-1 ceph-worker-2
vagrant up --provider=libvirt ceph-master
```

Useful access points after provisioning:

- SSH: `vagrant ssh ceph-master` (or either worker name)
- Ceph Dashboard: `http://192.168.60.10:8080` (`admin` / `admin`, lab credentials)
- RGW S3 endpoint: `http://192.168.60.10:7480`
- Ceph status: `vagrant ssh ceph-master -c "sudo ceph -s"`

Stop or destroy the lab with `vagrant halt` or `vagrant destroy -f`; libvirt owns the raw volume lifecycle for this definition.

## Application lockfile note

`apps/share-object-app/package.json` directly controls `pm2` (`^6.0.6`). The `"@pm2/pm2-version-check": "latest"` text in `package-lock.json` is dependency metadata inside PM2's transitive lock entry, not a direct dependency selected by this repository. Do not hand-edit that lock entry; update the direct PM2 dependency and regenerate the lockfile with npm if a dependency refresh is intended.
