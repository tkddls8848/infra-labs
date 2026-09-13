# Local MicroK8s Kubeflow GPU lab

This system creates a single-host, non-HA Kubeflow Lite lab on Ubuntu with an
NVIDIA GPU. MicroK8s keeps its built-in/default CNI; these scripts do not replace
it with Flannel, Calico, or another cluster CNI.

## Cluster configuration

Both cluster install scripts source [`config/cluster.env`](config/cluster.env).
That file is the checked-in source of truth for:

| Setting | Checked-in value |
|---|---|
| MicroK8s channel | `1.32/stable` |
| Juju channel | `3.6/stable` |
| Kubeflow Lite channel | `1.10/stable` |
| MetalLB range | `172.30.1.240-172.30.1.250` |
| Local dashboard port | `1234` |
| Lab dashboard user | `admin` |
| NVIDIA host driver | `nvidia-driver-550-server=550.163.01-0ubuntu0.24.04.1` |
| Optional host Docker | `27.5.1` (`5:27.5.1-1~ubuntu.24.04~noble`) |
| Optional host containerd | `1.7.25-1` |
| Optional NVIDIA Container Toolkit | `1.17.8-1` |

The checked-in dashboard password is intentionally empty. The Juju installer
generates a fresh random password and prints it once at completion. For a stable
lab credential, copy `config/cluster.env` outside the repository, set
`KUBEFLOW_PASSWORD`, and run with `CLUSTER_CONFIG=/absolute/path/cluster.env`.
Do not commit a real password.

The MetalLB range is an example for a host with a `172.30.1.0/24` interface. The
entire start/end range must belong to one non-loopback IPv4 network configured
on the host. `03_microk8s_gpu_addon_install.sh` checks this with `ipaddress` and
`ip -4 addr` before it installs MicroK8s or changes the cluster. Change the
config value to an unused range on the host's actual L2 network; do not use
addresses assigned by DHCP or another device.

## Host and GPU prerequisites

- Ubuntu 24.04 x86-64 with `snapd`, `python3`, `iproute2`, `jq`, and `openssl`.
- A supported NVIDIA GPU visible to the host.
- Working NVIDIA kernel driver: `nvidia-smi` must succeed after a reboot.
- MicroK8s' NVIDIA add-on must then expose `nvidia.com/gpu` on the node.
- Kubeflow is installed only after that add-on becomes ready.

The optional Docker/toolkit script configures host Docker for standalone GPU
containers or image builds. MicroK8s uses its own embedded containerd, so Docker
configuration is not part of the MicroK8s GPU runtime chain.

## Install order

Run from this system directory:

```bash
bash scripts/host/01_nvidia_driver_install.sh
# Reboot, then confirm: nvidia-smi

# Optional: host Docker GPU support only
bash scripts/host/02_docker_nvidia_toolkit_install.sh

bash scripts/cluster/03_microk8s_gpu_addon_install.sh
bash scripts/cluster/04_juju_kubeflow_lite_install.sh
```

The cluster scripts validate their configured channels before installation.
The Kubeflow script also requires the MicroK8s step to have completed.

## Destroy and reset policy

Normal install scripts never purge MicroK8s/Juju or recursively delete their
state. `RESET_MICROK8S=true` and `RESET_JUJU=true` are rejected with a pointer to
the lifecycle script. To intentionally remove the lab, run:

```bash
bash scripts/lifecycle/destroy_cluster.sh
```

That destructive script tears down the Kubeflow model/controller, removes the
snaps, and deletes only the explicitly named MicroK8s, kubeconfig, and Juju
state/cache paths. It attempts a timestamped Juju data backup first.

## Limitations

This is a local, single-user, single-node lab. It is non-HA, uses hostpath
storage, exposes the dashboard through a localhost port-forward, and configures
Dex with one static lab credential. It is not a production deployment and must
not be exposed to an untrusted network.
