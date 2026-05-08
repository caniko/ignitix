collect_remote_closure_mismatches() {
  local root_path=$1
  local path
  local closure
  local registered_nar_sri
  local registered_nar_nix32
  local actual_nix32
  local deriver
  local remote_cmd

  printf -v remote_cmd 'nix-store -qR %q' "$root_path"
  # shellcheck disable=SC2029
  closure=$(ssh "${installer_ssh_args[@]}" "$target_host" "$remote_cmd") || {
    echo "Failed to enumerate remote disko closure '$root_path' on '$target_host'." >&2
    exit 1
  }

  while IFS= read -r path; do
    [[ -n "$path" ]] || continue

    # Trust Nix's registered NAR hash for the path, not the bytes we
    # just found on disk. The actual hash is only used to detect
    # corruption; it must never be promoted into expected metadata.
    registered_nar_sri=$(
      NIX_SSHOPTS="$ssh_opts" nix path-info \
        --extra-experimental-features 'nix-command' \
        --store "$remote_store_uri" \
        --json \
        "$path" | jq -r '.[].narHash'
    ) || {
      echo "Failed to read registered NAR hash for '$path' from '$target_host'." >&2
      exit 1
    }

    if [[ ! "$registered_nar_sri" =~ ^sha256- ]]; then
      echo "Remote path '$path' has no trusted registered sha256 NAR hash." >&2
      echo "Refusing to derive expected hash from actual path contents." >&2
      exit 1
    fi

    registered_nar_nix32=$(
      nix hash convert --hash-algo sha256 --to nix32 "$registered_nar_sri"
    ) || {
      echo "Failed to convert registered NAR hash for '$path': $registered_nar_sri" >&2
      exit 1
    }

    printf -v remote_cmd 'nix-hash --type sha256 --base32 %q' "$path"
    # shellcheck disable=SC2029
    actual_nix32=$(ssh -n "${installer_ssh_args[@]}" "$target_host" "$remote_cmd") || {
      echo "Failed to hash remote path '$path' on '$target_host'." >&2
      exit 1
    }

    if [[ "$registered_nar_nix32" != "$actual_nix32" ]]; then
      printf -v remote_cmd 'nix-store -q --deriver %q 2>/dev/null || true' "$path"
      # shellcheck disable=SC2029
      deriver=$(ssh -n "${installer_ssh_args[@]}" "$target_host" "$remote_cmd")
      printf '%s\t%s\t%s\t%s\n' "$path" "$registered_nar_nix32" "$actual_nix32" "$deriver"
    fi
  done <<<"$closure"
}

print_remote_closure_mismatches() {
  local mismatches=$1
  local path
  local registered_nar_nix32
  local actual_nix32
  local deriver

  while IFS=$'\t' read -r path registered_nar_nix32 actual_nix32 deriver; do
    [[ -n "$path" ]] || continue
    printf '  %s\n' "$path" >&2
    printf '    registered NAR hash: %s\n' "$registered_nar_nix32" >&2
    printf '    actual:    %s\n' "$actual_nix32" >&2
    if [[ -n "$deriver" && "$deriver" != "unknown-deriver" ]]; then
      printf '    deriver:   %s\n' "$deriver" >&2
    fi
  done <<<"$mismatches"
}

repair_remote_closure_mismatches() {
  local mismatches=$1
  local path
  local registered_nar_nix32
  local actual_nix32
  local deriver
  local remote_cmd

  while IFS=$'\t' read -r path registered_nar_nix32 actual_nix32 deriver; do
    [[ -n "$path" ]] || continue
    printf -v remote_cmd 'nix-store --repair-path %q' "$path"
    # shellcheck disable=SC2029
    ssh -n "${installer_ssh_args[@]}" "$target_host" "$remote_cmd" || return 1
  done <<<"$mismatches"
}

verify_or_repair_remote_disko_closure() {
  local disko_script_path=$1
  local mismatches
  local remaining_mismatches

  echo "Split build: verifying remote disko closure"
  if ! mismatches=$(collect_remote_closure_mismatches "$disko_script_path"); then
    exit 1
  fi
  if [[ -z "$mismatches" ]]; then
    return 0
  fi

  echo "Split build: detected corrupt remote disko store path(s) on '$target_host':" >&2
  print_remote_closure_mismatches "$mismatches"
  echo "Split build: repairing corrupt remote disko store path(s)" >&2

  if ! repair_remote_closure_mismatches "$mismatches"; then
    echo "Failed to repair corrupt remote disko store path(s) on '$target_host'." >&2
    echo "Manual repair command(s):" >&2
    while IFS=$'\t' read -r path _expected _actual _deriver; do
      [[ -n "$path" ]] || continue
      printf "  ssh %q 'nix-store --repair-path %q'\n" "$target_host" "$path" >&2
    done <<<"$mismatches"
    echo "Validation command:" >&2
    printf "  ssh %q 'nix-store --verify --check-contents'\n" "$target_host" >&2
    exit 1
  fi

  if ! remaining_mismatches=$(collect_remote_closure_mismatches "$disko_script_path"); then
    exit 1
  fi
  if [[ -n "$remaining_mismatches" ]]; then
    echo "Remote disko closure is still corrupt after targeted repair on '$target_host':" >&2
    print_remote_closure_mismatches "$remaining_mismatches"
    echo "Manual repair command(s):" >&2
    while IFS=$'\t' read -r path _expected _actual _deriver; do
      [[ -n "$path" ]] || continue
      printf "  ssh %q 'nix-store --repair-path %q'\n" "$target_host" "$path" >&2
    done <<<"$remaining_mismatches"
    echo "Deep validation command:" >&2
    printf "  ssh %q 'nix-store --verify --check-contents'\n" "$target_host" >&2
    exit 1
  fi

  echo "Split build: remote disko closure repaired"
}
