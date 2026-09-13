#!/usr/bin/env bash

# Read a scalar from the inventory's [all:vars] section without requiring Ansible.
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
      if (line == "" || line ~ /^[#;]/) {
        next
      }
      separator = index(line, "=")
      if (separator == 0) {
        next
      }
      key = substr(line, 1, separator - 1)
      value = substr(line, separator + 1)
      sub(/[[:space:]]+$/, "", key)
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      if (key == wanted) {
        print value
        exit
      }
    }
  ' "$inventory_file"
}

require_inventory_var() {
  local inventory_file="$1"
  local wanted="$2"
  local value

  value="$(inventory_var "$inventory_file" "$wanted")"
  if [[ -z "$value" ]]; then
    echo "Missing required inventory variable '$wanted' in $inventory_file" >&2
    return 1
  fi
  printf '%s\n' "$value"
}

# Create or update a clean checkout at an immutable commit without resetting local edits.
ensure_pinned_checkout() {
  local repository_url="$1"
  local fetch_ref="$2"
  local expected_commit="$3"
  local checkout_dir="$4"
  local configured_remote
  local fetched_commit

  if [[ -e "$checkout_dir" && ! -d "$checkout_dir/.git" ]]; then
    echo "Refusing to replace non-Git path: $checkout_dir" >&2
    return 1
  fi

  if [[ ! -d "$checkout_dir/.git" ]]; then
    mkdir -p "$(dirname "$checkout_dir")"
    git init "$checkout_dir"
    git -C "$checkout_dir" remote add origin "$repository_url"
  fi

  configured_remote="$(git -C "$checkout_dir" remote get-url origin)"
  if [[ "$configured_remote" != "$repository_url" ]]; then
    echo "Refusing to use $checkout_dir: origin is '$configured_remote', expected '$repository_url'" >&2
    return 1
  fi

  if [[ -n "$(git -C "$checkout_dir" status --porcelain --untracked-files=no)" ]]; then
    echo "Refusing to overwrite tracked changes in $checkout_dir" >&2
    return 1
  fi

  if ! git -C "$checkout_dir" cat-file -e "${expected_commit}^{commit}" 2>/dev/null; then
    git -C "$checkout_dir" fetch --depth 1 origin "$fetch_ref"
    fetched_commit="$(git -C "$checkout_dir" rev-parse 'FETCH_HEAD^{commit}')"
    if [[ "$fetched_commit" != "$expected_commit" ]]; then
      echo "Pinned ref '$fetch_ref' resolved to $fetched_commit, expected $expected_commit" >&2
      return 1
    fi
  fi

  if [[ "$(git -C "$checkout_dir" rev-parse --verify HEAD 2>/dev/null || true)" != "$expected_commit" ]]; then
    git -C "$checkout_dir" checkout --detach "$expected_commit"
  fi
}
