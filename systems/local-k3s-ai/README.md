# Local K3s AI lab

This system installs a lightweight, single-node K3s base for local AI pipeline
experiments. K3AI is optional because this repository does not carry a pinned
K3AI installer release; operators must provide both its HTTPS URL and SHA-256.

## Pinned install

- K3s: `v1.32.3+k3s1`
- K3s installer URL: `https://get.k3s.io`
- Installer SHA-256:
  `ed01f89fd977bf20ac1516bbebf8370bf3ddbaa55dac8aba610956a4c78cc00b`
- Server option: `--write-kubeconfig-mode=0644`

The installer is downloaded to a temporary file, checked for non-empty shell
content, verified against the pinned checksum, and only then executed. A changed
response from `get.k3s.io` fails closed until its content is reviewed and the
checksum is deliberately updated. Nothing is piped from the network to `sh`.

## Host prerequisites

- A Linux host with systemd and `sudo` (Ubuntu 22.04/24.04 is the intended lab
  environment).
- `curl`, `sha256sum`, and outbound HTTPS access to the K3s release endpoints.
- Enough local CPU, memory, and disk for the AI workloads added afterward.
- Port `6443` and the K3s pod/service networking ranges must not conflict with
  another local cluster.

The script disables swap for the current boot and comments swap entries in
`/etc/fstab`, as required by this lab's Kubernetes setup.

## Install

```bash
bash scripts/addons/ai.sh
sudo systemctl status k3s
sudo kubectl get nodes
```

To opt into a reviewed K3AI installer, provide both integrity inputs:

```bash
K3AI_INSTALLER_URL="https://example.invalid/pinned/k3ai-install.sh" \
K3AI_INSTALLER_SHA256="<64-hex-sha256>" \
bash scripts/addons/ai.sh
```

The K3AI installer runs from the verified local file with the explicit
`--pipelines` option. Do not set only a URL; the script rejects unverified
installer content.

## Uninstall

K3s creates its supported uninstall helper during installation:

```bash
sudo /usr/local/bin/k3s-uninstall.sh
```

Review and remove any AI workload data or external volumes separately. The K3s
uninstaller does not know the retention policy for those application artifacts.
