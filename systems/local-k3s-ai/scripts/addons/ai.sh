#!/usr/bin/env bash
set -euo pipefail

K3S_VERSION="v1.32.3+k3s1"
K3S_INSTALLER_URL="https://get.k3s.io"
K3S_INSTALLER_SHA256="ed01f89fd977bf20ac1516bbebf8370bf3ddbaa55dac8aba610956a4c78cc00b"
K3AI_INSTALLER_URL="${K3AI_INSTALLER_URL:-}"
K3AI_INSTALLER_SHA256="${K3AI_INSTALLER_SHA256:-}"

command -v curl >/dev/null 2>&1 || { echo "curl is required." >&2; exit 1; }
command -v sha256sum >/dev/null 2>&1 || { echo "sha256sum is required." >&2; exit 1; }

K3S_INSTALLER="$(mktemp "${TMPDIR:-/tmp}/k3s-install.XXXXXX")"
K3AI_INSTALLER=""
cleanup() {
  rm -f -- "$K3S_INSTALLER"
  [[ -z "$K3AI_INSTALLER" ]] || rm -f -- "$K3AI_INSTALLER"
}
trap cleanup EXIT

download_verified_installer() {
  local label="$1" url="$2" expected_sha="$3" destination="$4" actual_sha
  [[ "$expected_sha" =~ ^[[:xdigit:]]{64}$ ]] \
    || { echo "$label SHA-256 must contain exactly 64 hexadecimal characters." >&2; return 1; }
  [[ "$url" == https://* ]] \
    || { echo "$label installer URL must use HTTPS: $url" >&2; return 1; }

  curl --proto '=https' --tlsv1.2 -fsSL --retry 3 --retry-delay 2 \
    -o "$destination" "$url"
  [[ -s "$destination" ]] \
    || { echo "$label installer download is empty: $url" >&2; return 1; }
  actual_sha="$(sha256sum "$destination" | awk '{print $1}')"
  [[ "$actual_sha" == "${expected_sha,,}" ]] \
    || { echo "$label installer checksum mismatch (expected ${expected_sha,,}, got $actual_sha)." >&2; return 1; }
  head -n 1 "$destination" | grep -Eq '^#!.*(ba)?sh' \
    || { echo "$label installer is not a shell script." >&2; return 1; }
  chmod 0700 "$destination"
  echo "$label installer verified: $actual_sha"
}

# Keep the node swap-free across the current session and reboots.
sudo swapoff -a
sudo sed -i '/\bswap\b/s/^[^#]/#&/' /etc/fstab

download_verified_installer \
  "K3s" "$K3S_INSTALLER_URL" "$K3S_INSTALLER_SHA256" "$K3S_INSTALLER"

# Run the verified file as root with both the binary version and server options
# explicit. No network response is ever piped into a shell.
sudo env \
  INSTALL_K3S_VERSION="$K3S_VERSION" \
  INSTALL_K3S_EXEC="server --write-kubeconfig-mode=0644" \
  sh "$K3S_INSTALLER"

if [[ -n "$K3AI_INSTALLER_URL" ]]; then
  [[ -n "$K3AI_INSTALLER_SHA256" ]] \
    || { echo "K3AI_INSTALLER_SHA256 is required when K3AI_INSTALLER_URL is set." >&2; exit 1; }
  K3AI_INSTALLER="$(mktemp "${TMPDIR:-/tmp}/k3ai-install.XXXXXX")"
  download_verified_installer \
    "K3AI" "$K3AI_INSTALLER_URL" "$K3AI_INSTALLER_SHA256" "$K3AI_INSTALLER"
  sh "$K3AI_INSTALLER" --pipelines
elif [[ -n "$K3AI_INSTALLER_SHA256" ]]; then
  echo "K3AI_INSTALLER_URL is required when K3AI_INSTALLER_SHA256 is set." >&2
  exit 1
else
  echo "Skipping K3AI. Set both K3AI_INSTALLER_URL and K3AI_INSTALLER_SHA256 to enable it."
fi
