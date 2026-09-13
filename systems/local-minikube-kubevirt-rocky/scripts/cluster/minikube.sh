#!/usr/bin/bash
set -euo pipefail

# Disable swap for the Kubernetes node and keep it disabled after reboot.
sudo swapoff -a
sudo sed -i '/\bswap\b/s/^[^#]/#&/' /etc/fstab

# Install Docker CE on Rocky Linux through Docker's RHEL-compatible CentOS repository.
sudo dnf -y install dnf-plugins-core
sudo dnf config-manager --add-repo=https://download.docker.com/linux/centos/docker-ce.repo
sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo systemctl enable --now docker
current_user="$(id -un)"
sudo usermod -aG docker "$current_user"
printf 'Docker group membership will be active in the next login session for %s.\n' "$current_user"

readonly MINIKUBE_VERSION="v1.38.1"
readonly MINIKUBE_SHA256="099477eaf248bcb5bcea8ce78a2898e93ac01461c35189da1848c3de82ecd22e"
download_file="$(mktemp)"
trap 'rm -f "$download_file"' EXIT

curl -fL --retry 3 \
  "https://storage.googleapis.com/minikube/releases/${MINIKUBE_VERSION}/minikube-linux-amd64" \
  -o "$download_file"
printf '%s  %s\n' "$MINIKUBE_SHA256" "$download_file" | sha256sum --check -
sudo install -m 0755 "$download_file" /usr/local/bin/minikube
