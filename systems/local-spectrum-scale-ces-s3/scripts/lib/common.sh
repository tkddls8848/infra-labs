#!/usr/bin/env bash
set -euo pipefail

inventory_var() {
  local inventory_file="$1"
  local wanted="$2"

  awk -v wanted="$wanted" '
    /^\[all:vars\][[:space:]]*$/ { in_all_vars = 1; next }
    /^\[/ { in_all_vars = 0 }
    in_all_vars {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line == "" || line ~ /^[#;]/) next
      separator = index(line, "=")
      if (separator == 0) next
      key = substr(line, 1, separator - 1)
      value = substr(line, separator + 1)
      sub(/[[:space:]]+$/, "", key)
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      if (key == wanted) { print value; exit }
    }
  ' "$inventory_file"
}

require_inventory_var() {
  local inventory_file="$1"
  local wanted="$2"
  local value

  value="$(inventory_var "$inventory_file" "$wanted")"
  if [[ -z "$value" ]]; then
    printf 'Missing required inventory variable %s in %s\n' "$wanted" "$inventory_file" >&2
    return 1
  fi
  printf '%s\n' "$value"
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    printf 'This provisioning phase must run as root.\n' >&2
    exit 1
  fi
}

load_lab_config() {
  SYSTEM_ROOT="${SYSTEM_ROOT:-/vagrant}"
  INVENTORY_FILE="${INVENTORY_FILE:-$SYSTEM_ROOT/inventory.ini}"
  [[ -r "$INVENTORY_FILE" ]] || { printf 'Inventory not readable: %s\n' "$INVENTORY_FILE" >&2; exit 1; }

  SCALE_VERSION="$(require_inventory_var "$INVENTORY_FILE" scale_version)"
  SCALE_RPM_EVR="$(require_inventory_var "$INVENTORY_FILE" scale_rpm_evr)"
  INSTALLER="$(require_inventory_var "$INVENTORY_FILE" installer_path)"
  REGISTRATION_URL="$(require_inventory_var "$INVENTORY_FILE" installer_registration_url)"
  CHECKSUM_ENV_NAME="$(require_inventory_var "$INVENTORY_FILE" installer_sha256_env)"
  OPT_IN_ENV_NAME="$(require_inventory_var "$INVENTORY_FILE" unsupported_opt_in_env)"
  OPT_IN_REQUIRED="$(require_inventory_var "$INVENTORY_FILE" unsupported_opt_in_value)"
}

print_unsupported_banner() {
  cat >&2 <<'BANNER'
================================================================================
UNSUPPORTED EXPERIMENTAL LAB: IBM SUPPORT IS NOT AVAILABLE FOR THIS COMBINATION.
Deviation 1: Rocky Linux 9 replaces the supported RHEL 9.8 platform.
Deviation 2: one 16 GiB node replaces the three-node, 64 GiB-per-node baseline.
There is NO quorum redundancy, NO CES IP failover, and NO data redundancy.
This lab is limited to functional CES S3 verification.
================================================================================
BANNER
}

require_unsupported_opt_in() {
  local actual="${!OPT_IN_ENV_NAME:-}"

  print_unsupported_banner
  if [[ "$actual" != "$OPT_IN_REQUIRED" ]]; then
    printf 'Refusing to provision unsupported mode. Set %s=%s and retry.\n' \
      "$OPT_IN_ENV_NAME" "$OPT_IN_REQUIRED" >&2
    exit 1
  fi
}

validate_installer() {
  local expected_checksum="${!CHECKSUM_ENV_NAME:-}"
  local actual_checksum
  local manifest

  if [[ ! -f "$INSTALLER" ]]; then
    printf 'IBM installer is missing: %s\nRegister at %s and provide IBM Storage Scale Developer Edition %s for RHEL x86_64.\n' \
      "$INSTALLER" "$REGISTRATION_URL" "$SCALE_VERSION" >&2
    exit 1
  fi
  if [[ ! -s "$INSTALLER" ]]; then
    printf 'IBM installer is empty: %s\nExpected Developer Edition %s from %s\n' \
      "$INSTALLER" "$SCALE_VERSION" "$REGISTRATION_URL" >&2
    exit 1
  fi
  if [[ ! -x "$INSTALLER" ]]; then
    printf 'IBM installer is not executable: %s\nMake the user-supplied artifact executable; provisioning will not change it.\nExpected Developer Edition %s from %s\n' \
      "$INSTALLER" "$SCALE_VERSION" "$REGISTRATION_URL" >&2
    exit 1
  fi

  if [[ -n "$expected_checksum" ]]; then
    if [[ ! "$expected_checksum" =~ ^[[:xdigit:]]{64}$ ]]; then
      printf '%s must be exactly 64 hexadecimal SHA-256 characters.\n' "$CHECKSUM_ENV_NAME" >&2
      exit 1
    fi
    actual_checksum="$(sha256sum "$INSTALLER" | awk '{print $1}')"
    if [[ "${actual_checksum,,}" != "${expected_checksum,,}" ]]; then
      printf 'IBM installer SHA-256 mismatch: expected %s, got %s.\n' \
        "$expected_checksum" "$actual_checksum" >&2
      exit 1
    fi
    printf 'Verified the installer against the user-supplied SHA-256: %s\n' "$actual_checksum"
  else
    printf 'WARNING: %s is unset. Supplier checksum/authenticity verification was NOT performed.\n' \
      "$CHECKSUM_ENV_NAME" >&2
    printf 'Only the archive manifest will be checked; this does not prove supplier authenticity.\n' >&2
  fi

  if ! manifest="$("$INSTALLER" --manifest 2>&1)"; then
    printf 'The installer --manifest command failed. Expected IBM Storage Scale Developer Edition %s.\n%s\n' \
      "$SCALE_VERSION" "$manifest" >&2
    exit 1
  fi
  if ! grep -Eq '5\.2\.3([.-])8([^0-9]|$)' <<<"$manifest"; then
    printf 'Installer manifest does not identify release %s (accepted RPM form: %s).\n' \
      "$SCALE_VERSION" "$SCALE_RPM_EVR" >&2
    exit 1
  fi
  if ! grep -Eq 'gpfs\.license\.dev[^,[:space:]]*\.rpm' <<<"$manifest"; then
    printf 'Installer manifest lacks the Developer Edition license RPM (gpfs.license.dev).\n' >&2
    exit 1
  fi
  if ! grep -Eq 'gpfs\.mms3[^,[:space:]]*\.el9[^,[:space:]]*\.rpm' <<<"$manifest"; then
    printf 'Installer manifest lacks the RHEL 9 native CES S3 gpfs.mms3 RPM.\n' >&2
    exit 1
  fi
  if ! grep -Eq 'noobaa-core-[^,[:space:]]*\.el9[^,[:space:]]*\.rpm' <<<"$manifest"; then
    printf 'Installer manifest lacks the RHEL 9 native CES S3 noobaa-core RPM.\n' >&2
    exit 1
  fi
  printf 'Manifest identifies Storage Scale %s Developer Edition and native CES S3 EL9 packages.\n' \
    "$SCALE_VERSION"

  # Deliberately do not remove or modify $INSTALLER. It is owned by the user.
}
