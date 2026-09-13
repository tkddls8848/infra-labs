# Local Kubespray + Rook Ceph lab

This system creates a VirtualBox Kubernetes storage lab on Ubuntu 24.04. It is intended for local testing only.

## Source of truth

[`inventory/inventory.ini`](inventory/inventory.ini) is the source of truth for node names, node addresses, roles, forwarded SSH ports, component versions, and cluster network ranges. `Vagrantfile` reads the inventory to construct the VM topology; workers are started before the control plane so their SSH host keys are available during provisioning.

The current inventory defines one control-plane/etcd node and three workers. Each worker receives one 20 GiB raw disk for Rook. Do not add a second node list or worker-count constant to a script or to `Vagrantfile`.

Kubespray copies the Vagrant private keys named by the inventory and populates `~/.ssh/known_hosts` with `ssh-keyscan` for every inventory `ansible_host`. Provisioning stops if any host does not return a key. The inventory intentionally has no host-key-checking bypass or null known-hosts override.

## Networking and versions

- CNI: Flannel
- Pod CIDR: `10.244.0.0/16`
- VirtualBox private network: `192.168.56.0/24`
- MetalLB pool: `192.168.56.128-192.168.56.143`
- Kubespray: `v2.31.0`
- Kubernetes: `1.35.4`
- Rook: `v1.20.0`
- Ceph daemon and toolbox image: `quay.io/ceph/ceph:v20.2.1`

Change inventory values together and review the generated Kubespray group vars before upgrading. The main provisioners are `scripts/cluster/kubespray.sh` and `scripts/storage/rook-ceph.sh`; `vagrant up` runs them on the control-plane VM.

## Vendored Rook manifests

All Rook resources applied by this system are stored under [`manifests/rook-ceph`](manifests/rook-ceph). The upstream examples were fetched from Rook tag `v1.20.0` at commit `51bca7e46d7557031dde89c900483e6c0681ce23`; runtime provisioning uses no home-directory Rook checkout and applies no remote URL. The toolbox image was narrowed from the upstream major-only `v20` tag to `v20.2.1` to match `cluster.yaml`.

The base install applies the vendored CRDs, common resources, CSI operator, Rook operator, Ceph cluster, toolbox, RBD StorageClass, and dashboard LoadBalancer. Optional block, filesystem, and object scripts also apply only vendored files:

- Block: `rook-ceph-block`, backed by a host-failure-domain pool with replica size 3.
- Filesystem: `rook-ceph-filesystem`, backed by metadata and data pools with replica size 3. Its optional demo uses `busybox:1.37.0`.
- Object: the `my-store` RGW resource and `my-user`; it does not create a Kubernetes StorageClass.

The optional WordPress block demo keeps the upstream pinned WordPress image and pins MySQL to `mysql:5.6.51`. To refresh the vendored manifests, fetch a specific upstream Rook tag, copy only the files this system applies, preserve the cluster-specific StorageClass names and replica-3 settings, and review the resulting repository diff before changing `rook_version`.

## Lab-only assumptions

The Kubernetes control plane and etcd are single-node and are not highly available. Ceph uses three monitors and replica-3 block, filesystem, and object pools across the three workers, so all three workers and their raw disks are required for a healthy initial deployment. The dashboard is exposed directly on a private Layer-2 MetalLB network, secrets use the Vagrant lab trust boundary, and no production backup, ingress, certificate, upgrade, or disaster-recovery policy is provided.
