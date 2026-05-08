{
  config,
  inputs,
  lib,
  ...
}: let
  inherit
    (builtins)
    attrNames
    toJSON
    ;
  inherit
    (lib)
    attrByPath
    concatMapStringsSep
    escapeShellArg
    genAttrs
    mapAttrs
    mkIf
    mkMerge
    mkOption
    recursiveUpdate
    splitString
    types
    ;

  cfg = config.ignitix.installTargets;
  hostMetadata = config.ignitix.hostMetadata;
  installMediaLib = import ../lib {
    inherit
      inputs
      lib
      ;
  };

  resolveHostField = hostName: field:
    attrByPath (splitString "." field) null (hostMetadata.${hostName} or {});

  resolveRouteTargetHost = hostName: target: targetUser: routeName: route: let
    mediaCfg = attrByPath ["ignitix" "installMedia" target.media] null config;
    nixosAnywhereCfg = mediaCfg.nixosAnywhere or {};
  in
    if route.resolver.type == "hostField"
    then let
      value = resolveHostField hostName route.resolver.field;
    in
      if value == null
      then throw "ignitix.installTargets.${hostName}: route '${routeName}' needs host field '${route.resolver.field}'"
      else "${targetUser}@${value}"
    else let
      endpointName = route.resolver.endpoint;
      endpoint =
        if endpointName == null
        then null
        else nixosAnywhereCfg.endpoints.${endpointName} or null;
    in
      if endpoint == null
      then throw "ignitix.installTargets.${hostName}: missing media endpoint '${endpointName}' for media '${target.media}'"
      else "${targetUser}@${endpoint.host}";

  resolvedTargets = mapAttrs (hostName: target: let
    mediaCfg = attrByPath ["ignitix" "installMedia" target.media] null config;
    nixosAnywhereCfg =
      if mediaCfg == null
      then throw "ignitix.installTargets.${hostName}: unknown media '${target.media}'"
      else mediaCfg.nixosAnywhere;
    targetUser = nixosAnywhereCfg.targetUser or "root";
    routes = mapAttrs (routeName: route: {
      targetHost = resolveRouteTargetHost hostName target targetUser routeName route;
    }) target.routes;
  in {
    app = "install";
    rescueApp = "rescue";
    probeApp = "probe-hardware";
    flakeUri = ".#${target.flakeAttr}";
    media = target.media;
    targetPort = nixosAnywhereCfg.targetPort;
    sshOptions = nixosAnywhereCfg.sshOptions;
    inherit routes;
    hardwareReport = target.hardwareReport;
  }) cfg;

  renderRouteDescription = hostName: routeName: _: "  ${hostName}: ${routeName}";

  renderAvailableTargets = targets:
    concatMapStringsSep "\n" (hostName:
      concatMapStringsSep "\n" (routeName:
        renderRouteDescription hostName routeName targets.${hostName}.routes.${routeName}
      ) (attrNames targets.${hostName}.routes)
    ) (attrNames targets);

  installTargetsJson = toJSON resolvedTargets;

  targetWrapperPackages = genAttrs installMediaLib.supportedBuildSystems (buildSystem: let
    pkgs = inputs.nixpkgs.legacyPackages.${buildSystem};
    availableTargets = renderAvailableTargets cfg;
  in {
    install = pkgs.writeShellApplication {
      name = "install";
      runtimeInputs = [
        pkgs.coreutils
        pkgs.jq
        pkgs.nix
        pkgs.openssh
      ];
      text = ''
        set -euo pipefail

        resolved_targets_json=${escapeShellArg installTargetsJson}

        usage() {
          printf '%s\n' \
            'Usage: install <route> <host> [wrapper args] -- [nixos-anywhere args]' \
            "" \
            'Wrapper args:' \
            '  --flake <flake-uri>   Override the default flake attr for the target' \
            '  --build-on <mode>     Build mode: local, remote, auto, or split' \
            '  -h, --help            Show this help' \
            "" \
            'Available targets:' \
            '${availableTargets}'
        }

        if [[ $# -eq 0 || "$1" == "--help" || "$1" == "-h" ]]; then
          usage
          exit 0
        fi

        if [[ $# -lt 2 ]]; then
          usage >&2
          exit 1
        fi

        route_input=$1
        shift
        host_input=$1
        shift

        flake_override=""
        build_on=""
        passthrough_args=()

        while [[ $# -gt 0 ]]; do
          case "$1" in
            --help|-h)
              usage
              exit 0
              ;;
            --flake)
              if [[ $# -lt 2 ]]; then
                echo "Missing value for --flake" >&2
                exit 1
              fi
              flake_override=$2
              shift 2
              ;;
            --build-on)
              if [[ $# -lt 2 ]]; then
                echo "Missing value for --build-on" >&2
                exit 1
              fi
              case "$2" in
                auto|local|remote|split) ;;
                *)
                  echo "Unsupported --build-on mode: $2" >&2
                  echo "Expected one of: auto, local, remote, split" >&2
                  exit 1
                  ;;
              esac
              build_on=$2
              shift 2
              ;;
            --)
              shift
              passthrough_args=("$@")
              break
              ;;
            *)
              echo "Unknown wrapper argument: $1" >&2
              usage >&2
              exit 1
              ;;
          esac
        done

        target_json=$(jq -cer --arg host "$host_input" '.[$host]' <<<"$resolved_targets_json") || {
          echo "Unknown install target: $host_input" >&2
          usage >&2
          exit 1
        }

        route_name=$(jq -r --arg route "$route_input" '
          if .routes[$route] then
            $route
          else
            empty
          end
        ' <<<"$target_json")

        if [[ -z "$route_name" ]]; then
          echo "Unknown route '$route_input' for target '$host_input'" >&2
          usage >&2
          exit 1
        fi

        target_host=$(jq -r --arg route "$route_name" '.routes[$route].targetHost' <<<"$target_json")
        media=$(jq -r '.media' <<<"$target_json")
        target_port=$(jq -r '.targetPort' <<<"$target_json")
        default_flake=$(jq -r '.flakeUri' <<<"$target_json")
        hardware_backend=$(jq -r '.hardwareReport.backend // empty' <<<"$target_json")
        hardware_path=$(jq -r '.hardwareReport.path // empty' <<<"$target_json")

        store_paths_mode=false
        explicit_flake=false
        explicit_hardware_report=false
        explicit_flake_value=""
        explicit_hardware_backend=""
        passthrough_help=false
        for ((i = 0; i < ''${#passthrough_args[@]}; i++)); do
          arg=''${passthrough_args[$i]}
          case "$arg" in
            --help|-h)
              passthrough_help=true
              ;;
            --store-paths|-s)
              store_paths_mode=true
              ;;
            --flake|-f)
              explicit_flake=true
              if (( i + 1 >= ''${#passthrough_args[@]} )); then
                echo "Missing value for $arg" >&2
                exit 1
              fi
              explicit_flake_value=''${passthrough_args[$((i + 1))]}
              ;;
            --generate-hardware-config)
              explicit_hardware_report=true
              if (( i + 2 >= ''${#passthrough_args[@]} )); then
                echo "Missing arguments for --generate-hardware-config <backend> <path>" >&2
                exit 1
              fi
              explicit_hardware_backend=''${passthrough_args[$((i + 1))]}
              ;;
          esac
        done

        normalize_nixos_anywhere_flake() {
          local flake_ref=$1

          if [[ $flake_ref =~ ^(.*)\#([^\#\"]*)$ ]]; then
            eval_flake_root=''${BASH_REMATCH[1]}
            eval_flake_attr=''${BASH_REMATCH[2]}
          else
            echo "Install preflight needs a flake URI fragment, got '$flake_ref'" >&2
            exit 1
          fi

          if [[ -z "$eval_flake_attr" ]]; then
            echo "Install preflight needs a non-empty flake attribute in '$flake_ref'" >&2
            exit 1
          fi

          if [[ $eval_flake_attr != nixosConfigurations.* ]]; then
            eval_flake_attr="nixosConfigurations.\"$eval_flake_attr\".config"
          fi
        }

        ensure_declared_disko_disks_exist() {
          local flake_ref=$1
          local declared_disko_disks_json
          local missing_devices=()

          normalize_nixos_anywhere_flake "$flake_ref"

          declared_disko_disks_json=$(
            nix eval \
              --extra-experimental-features 'nix-command flakes' \
              --json \
              --apply 'ds: builtins.mapAttrs (_: d: d.device) ds' \
              "''${eval_flake_root}#''${eval_flake_attr}.disko.devices.disk"
          ) || {
            echo "Failed to evaluate disko disk inputs for '$flake_ref'" >&2
            exit 1
          }

          local ssh_args=(-T -p "$target_port")
          while IFS= read -r option; do
            ssh_args+=(-o "$option")
          done < <(jq -r '.sshOptions[]?' <<<"$target_json")

          while IFS= read -r device_path; do
            [[ -n "$device_path" ]] || continue

            printf -v remote_test 'test -b %q' "$device_path"
            # shellcheck disable=SC2029
            if ! ssh "''${ssh_args[@]}" "$target_host" "$remote_test"; then
              missing_devices+=("$device_path")
            fi
          done < <(jq -r '.[]' <<<"$declared_disko_disks_json")

          if (( ''${#missing_devices[@]} > 0 )); then
            echo "Install preflight failed for '$target_host'." >&2
            echo "The selected flake's disk configuration does not match the probed machine." >&2
            echo "Missing disko input path(s):" >&2
            printf '  %s\n' "''${missing_devices[@]}" >&2
            exit 1
          fi
        }

        installer_ssh_args=()
        build_installer_ssh_args() {
          installer_ssh_args=(-T -p "$target_port")
          while IFS= read -r option; do
            installer_ssh_args+=(-o "$option")
          done < <(jq -r '.sshOptions[]?' <<<"$target_json")
        }

        check_installer_free_space() {
          local required_kib=524288
          local available_kib
          local df_output

          build_installer_ssh_args
          df_output=$(ssh "''${installer_ssh_args[@]}" "$target_host" 'df -Pk /nix 2>/dev/null || df -Pk /') || {
            echo "Failed to check free space on installer '$target_host'." >&2
            exit 1
          }
          available_kib=$(awk 'NR == 2 { print $4 }' <<<"$df_output")

          if [[ -z "$available_kib" || ! "$available_kib" =~ ^[0-9]+$ ]]; then
            echo "Failed to parse installer free-space report from '$target_host'." >&2
            printf '%s\n' "$df_output" >&2
            exit 1
          fi

          if (( available_kib < required_kib )); then
            printf '%s\n' \
              "Installer '$target_host' does not have enough free space for split install builds." \
              "Required: at least 512 MiB free on /nix or /." \
              "" \
              "Current installer disk usage:" >&2
            ssh "''${installer_ssh_args[@]}" "$target_host" 'df -h / /nix 2>/dev/null || df -h /' >&2 || true
            printf '%s\n' \
              "" \
              "Try cleaning the installer store, then retry:" \
              "  ssh $target_host 'nix-store --gc; df -h / /nix'" >&2
            exit 1
          fi
        }

        collect_remote_closure_mismatches() {
          local root_path=$1
          local path
          local closure
          local expected_sri
          local expected_nix32
          local actual_nix32
          local deriver
          local remote_cmd

          printf -v remote_cmd 'nix-store -qR %q' "$root_path"
          # shellcheck disable=SC2029
          closure=$(ssh "''${installer_ssh_args[@]}" "$target_host" "$remote_cmd") || {
            echo "Failed to enumerate remote disko closure '$root_path' on '$target_host'." >&2
            exit 1
          }

          while IFS= read -r path; do
            [[ -n "$path" ]] || continue

            expected_sri=$(
              NIX_SSHOPTS="$ssh_opts" nix path-info \
                --extra-experimental-features 'nix-command' \
                --store "$remote_store_uri" \
                --json \
                "$path" | jq -r '.[].narHash'
            ) || {
              echo "Failed to read registered NAR hash for '$path' from '$target_host'." >&2
              exit 1
            }

            expected_nix32=$(
              nix hash convert --hash-algo sha256 --to nix32 "$expected_sri"
            ) || {
              echo "Failed to convert registered NAR hash for '$path': $expected_sri" >&2
              exit 1
            }

            printf -v remote_cmd 'nix-hash --type sha256 --base32 %q' "$path"
            # shellcheck disable=SC2029
            actual_nix32=$(ssh -n "''${installer_ssh_args[@]}" "$target_host" "$remote_cmd") || {
              echo "Failed to hash remote path '$path' on '$target_host'." >&2
              exit 1
            }

            if [[ "$expected_nix32" != "$actual_nix32" ]]; then
              printf -v remote_cmd 'nix-store -q --deriver %q 2>/dev/null || true' "$path"
              # shellcheck disable=SC2029
              deriver=$(ssh -n "''${installer_ssh_args[@]}" "$target_host" "$remote_cmd")
              printf '%s\t%s\t%s\t%s\n' "$path" "$expected_nix32" "$actual_nix32" "$deriver"
            fi
          done <<<"$closure"
        }

        print_remote_closure_mismatches() {
          local mismatches=$1
          local path
          local expected_nix32
          local actual_nix32
          local deriver

          while IFS=$'\t' read -r path expected_nix32 actual_nix32 deriver; do
            [[ -n "$path" ]] || continue
            printf '  %s\n' "$path" >&2
            printf '    specified: %s\n' "$expected_nix32" >&2
            printf '    actual:    %s\n' "$actual_nix32" >&2
            if [[ -n "$deriver" && "$deriver" != "unknown-deriver" ]]; then
              printf '    deriver:   %s\n' "$deriver" >&2
            fi
          done <<<"$mismatches"
        }

        repair_remote_closure_mismatches() {
          local mismatches=$1
          local path
          local expected_nix32
          local actual_nix32
          local deriver
          local remote_cmd

          while IFS=$'\t' read -r path expected_nix32 actual_nix32 deriver; do
            [[ -n "$path" ]] || continue
            printf -v remote_cmd 'nix-store --repair-path %q' "$path"
            # shellcheck disable=SC2029
            ssh -n "''${installer_ssh_args[@]}" "$target_host" "$remote_cmd" || return 1
          done <<<"$mismatches"
        }

        verify_or_repair_remote_disko_closure() {
          local disko_script_path=$1
          local mismatches
          local remaining_mismatches

          echo "Split build: verifying remote disko closure"
          mismatches=$(collect_remote_closure_mismatches "$disko_script_path")
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

          remaining_mismatches=$(collect_remote_closure_mismatches "$disko_script_path")
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

        build_split_store_paths() {
          local flake_ref=$1
          local system_path
          local disko_script_path
          local ssh_opts
          local remote_store_uri

          normalize_nixos_anywhere_flake "$flake_ref"
          check_installer_free_space

          echo "Split build: building NixOS system locally"
          system_path=$(
            nix build \
              --extra-experimental-features 'nix-command flakes' \
              --print-out-paths \
              --no-link \
              "''${eval_flake_root}#''${eval_flake_attr}.system.build.toplevel"
          ) || {
            echo "Failed to build NixOS system for '$flake_ref'." >&2
            exit 1
          }

          ssh_opts=$(printf '%q ' "''${installer_ssh_args[@]}")
          remote_store_uri="ssh-ng://$target_host?compress=true"

          echo "Split build: building disko script on installer"
          disko_script_path=$(
            NIX_SSHOPTS="$ssh_opts" nix build \
              --extra-experimental-features 'nix-command flakes' \
              --print-out-paths \
              --no-link \
              --eval-store auto \
              --store "$remote_store_uri" \
              "''${eval_flake_root}#''${eval_flake_attr}.system.build.diskoScriptNoDeps"
          ) || {
            echo "Failed to build disko script for '$flake_ref' on '$target_host'." >&2
            exit 1
          }

          verify_or_repair_remote_disko_closure "$disko_script_path"

          echo "Split build: copying disko script from installer"
          NIX_SSHOPTS="$ssh_opts" nix copy \
            --extra-experimental-features 'nix-command flakes' \
            --no-check-sigs \
            --from "$remote_store_uri" \
            "$disko_script_path" || {
              echo "Failed to copy disko script '$disko_script_path' from '$target_host'." >&2
              exit 1
            }

          split_disko_script_path=$disko_script_path
          split_system_path=$system_path
        }

        # Pre-flight hardware report refresh. nixos-anywhere with a disko
        # config has to evaluate the flake before its own
        # --generate-hardware-config step, so a stale report blocks the
        # install — even though the report would have been regenerated a
        # moment later. nixos-anywhere also builds nixos-facter for the
        # *target* platform when running --generate-hardware-config, which
        # cross-fails on a same-arch-required builder. We refresh here,
        # ahead of any eval, using the binary already present on the
        # installer media; that makes the install idempotent against stale
        # reports AND avoids the cross-build entirely.
        pre_refresh_done=false
        if [[ "$store_paths_mode" != true \
           && "$explicit_hardware_report" != true \
           && "$passthrough_help" != true \
           && "$hardware_backend" == "nixos-facter" \
           && -n "$hardware_path" ]]; then
          refresh_ssh_args=(-T -p "$target_port")
          while IFS= read -r option; do
            refresh_ssh_args+=(-o "$option")
          done < <(jq -r '.sshOptions[]?' <<<"$target_json")

          # shellcheck disable=SC2029
          if ! ssh "''${refresh_ssh_args[@]}" "$target_host" 'command -v nixos-facter >/dev/null'; then
            printf '%s\n' \
              "Target '$target_host' does not expose 'nixos-facter'." \
              "The selected media '$media' is expected to bundle nixos-facter for install fact refreshes." \
              'Rebuild or reflash that installer media (or pass a fresh report explicitly via --generate-hardware-config) and retry.' >&2
            exit 1
          fi

          mkdir -p "$(dirname "$hardware_path")"
          hardware_tmp=$(mktemp "''${hardware_path}.tmp.XXXXXX")
          # shellcheck disable=SC2064
          trap 'rm -f "'"$hardware_tmp"'"' EXIT

          echo "Pre-install hardware refresh: $hardware_backend -> $hardware_path"
          # shellcheck disable=SC2029
          ssh "''${refresh_ssh_args[@]}" "$target_host" nixos-facter > "$hardware_tmp"
          if [[ ! -s "$hardware_tmp" ]]; then
            echo "Remote nixos-facter produced an empty hardware report." >&2
            exit 1
          fi
          jq empty "$hardware_tmp" || {
            echo "Remote nixos-facter produced invalid JSON." >&2
            exit 1
          }
          mv "$hardware_tmp" "$hardware_path"
          trap - EXIT
          pre_refresh_done=true
        fi

        split_disko_script_path=""
        split_system_path=""
        if [[ "$build_on" == "split" && "$passthrough_help" != true ]]; then
          if [[ "$store_paths_mode" == true ]]; then
            echo "--build-on split cannot be combined with passthrough --store-paths." >&2
            exit 1
          fi
          if [[ "$explicit_flake" == true ]]; then
            install_flake_ref=$explicit_flake_value
          else
            install_flake_ref=''${flake_override:-$default_flake}
          fi
          build_split_store_paths "$install_flake_ref"
          store_paths_mode=true
        fi

        final_args=()
        if [[ "$build_on" == "split" && "$passthrough_help" != true ]]; then
          final_args+=(--store-paths "$split_disko_script_path" "$split_system_path")
        elif [[ "$store_paths_mode" != true && "$explicit_flake" != true ]]; then
          final_args+=(--flake "''${flake_override:-$default_flake}")
        fi

        if [[ -n "$build_on" && "$build_on" != "split" ]]; then
          final_args+=(--build-on "$build_on")
        fi

        final_args+=(--target-host "$target_host")

        # Only ask nixos-anywhere to generate the hardware config when we
        # didn't already do it above. Avoids redundant work and the
        # cross-build that nixos-anywhere's own facter step requires.
        if [[ -n "$hardware_backend" && -n "$hardware_path" \
           && "$explicit_hardware_report" != true \
           && "$pre_refresh_done" != true ]]; then
          mkdir -p "$(dirname "$hardware_path")"
          final_args+=(--generate-hardware-config "$hardware_backend" "$hardware_path")
        fi

        hardware_check_backend=""
        if [[ "$explicit_hardware_report" == true ]]; then
          hardware_check_backend=$explicit_hardware_backend
        elif [[ -n "$hardware_backend" && -n "$hardware_path" && "$pre_refresh_done" != true ]]; then
          hardware_check_backend=$hardware_backend
        fi

        check_declared_disko_disks=true
        if [[ -n "$hardware_check_backend" ]]; then
          check_declared_disko_disks=false
        fi

        final_args+=("''${passthrough_args[@]}")

        echo "Install target: $host_input"
        echo "  Route: $route_name"
        echo "  Media: $media"
        echo "  Target host: $target_host"
        if [[ "$store_paths_mode" != true && "$explicit_flake" != true ]]; then
          echo "  Flake: ''${flake_override:-$default_flake}"
        elif [[ "$explicit_flake" == true ]]; then
          echo "  Flake: provided explicitly in passthrough args"
        else
          echo "  Flake: provided via --store-paths"
        fi
        if [[ -n "$hardware_backend" && -n "$hardware_path" && "$explicit_hardware_report" != true ]]; then
          if [[ "$pre_refresh_done" == true ]]; then
            echo "  Hardware report: $hardware_backend -> $hardware_path (pre-refreshed)"
          else
            echo "  Hardware report: $hardware_backend -> $hardware_path"
          fi
        fi
        if [[ "$check_declared_disko_disks" != true && "$passthrough_help" != true ]]; then
          echo "  Disk preflight: skipped while hardware config generation is active"
        fi

        if [[ "$store_paths_mode" != true && "$passthrough_help" != true && "$check_declared_disko_disks" == true ]]; then
          if [[ "$explicit_flake" == true ]]; then
            install_flake_ref=$explicit_flake_value
          else
            install_flake_ref=''${flake_override:-$default_flake}
          fi
          ensure_declared_disko_disks_exist "$install_flake_ref"
        fi

        nix run ".#install-$media" -- "''${final_args[@]}"

        if [[ "$passthrough_help" != true ]]; then
          printf '%s\n' \
            "" \
            'Install wrapper note:' \
            '  If the machine comes back up in removable installer media, the install likely succeeded but firmware selected the installer again.' \
            '  Remove the installer media or select internal storage in firmware before the next boot.'

          if [[ "$media" == "rockpro64-installer" ]]; then
            printf '%s\n' \
              "  RockPro64 signature for this case: hostname 'rockpro64-installer' with root on '/dev/sda2' labeled 'NIXOS_SD'." \
              '  Treat that as "booted installer again", not "install failed".'
          fi
        fi
      '';
    };
  });

  smountWrapperPackages = genAttrs installMediaLib.supportedBuildSystems (buildSystem: let
    pkgs = inputs.nixpkgs.legacyPackages.${buildSystem};
    availableTargets = renderAvailableTargets cfg;
  in {
    smount = pkgs.writeShellApplication {
      name = "smount";
      runtimeInputs = [
        pkgs.coreutils
        pkgs.jq
        pkgs.nix
        pkgs.openssh
      ];
      text = ''
        set -euo pipefail

        resolved_targets_json=${escapeShellArg installTargetsJson}

        usage() {
          printf '%s\n' \
            'Usage: smount <route> <host> [wrapper args]' \
            "" \
            'Mount an existing disko installation through installer media.' \
            "" \
            'Wrapper args:' \
            '  --flake <flake-uri>   Override the default flake attr for the target' \
            '  --build-on local      Build mount artifacts locally before copying them' \
            '  -h, --help            Show this help' \
            "" \
            'Available targets:' \
            '${availableTargets}'
        }

        if [[ $# -eq 0 || "$1" == "--help" || "$1" == "-h" ]]; then
          usage
          exit 0
        fi

        if [[ $# -lt 2 ]]; then
          usage >&2
          exit 1
        fi

        route_input=$1
        shift
        host_input=$1
        shift

        flake_override=""
        build_on="local"

        while [[ $# -gt 0 ]]; do
          case "$1" in
            --help|-h)
              usage
              exit 0
              ;;
            --flake)
              if [[ $# -lt 2 ]]; then
                echo "Missing value for --flake" >&2
                exit 1
              fi
              flake_override=$2
              shift 2
              ;;
            --build-on)
              if [[ $# -lt 2 ]]; then
                echo "Missing value for --build-on" >&2
                exit 1
              fi
              build_on=$2
              shift 2
              ;;
            --)
              shift
              if [[ $# -gt 0 ]]; then
                echo "Smount does not accept passthrough arguments." >&2
                exit 1
              fi
              ;;
            *)
              echo "Unknown smount argument: $1" >&2
              usage >&2
              exit 1
              ;;
          esac
        done

        if [[ "$build_on" != "local" ]]; then
          echo "Smount currently supports only --build-on local." >&2
          exit 1
        fi

        target_json=$(jq -cer --arg host "$host_input" '.[$host]' <<<"$resolved_targets_json") || {
          echo "Unknown install target: $host_input" >&2
          usage >&2
          exit 1
        }

        route_name=$(jq -r --arg route "$route_input" '
          if .routes[$route] then
            $route
          else
            empty
          end
        ' <<<"$target_json")

        if [[ -z "$route_name" ]]; then
          echo "Unknown route '$route_input' for target '$host_input'" >&2
          usage >&2
          exit 1
        fi

        target_host=$(jq -r --arg route "$route_name" '.routes[$route].targetHost' <<<"$target_json")
        media=$(jq -r '.media' <<<"$target_json")
        target_port=$(jq -r '.targetPort' <<<"$target_json")
        default_flake=$(jq -r '.flakeUri' <<<"$target_json")
        smount_flake=''${flake_override:-$default_flake}

        normalize_nixos_config_flake() {
          local flake_ref=$1

          if [[ $flake_ref =~ ^(.*)\#([^\#\"]*)$ ]]; then
            eval_flake_root=''${BASH_REMATCH[1]}
            eval_flake_attr=''${BASH_REMATCH[2]}
          else
            echo "Smount needs a flake URI fragment, got '$flake_ref'" >&2
            exit 1
          fi

          if [[ -z "$eval_flake_attr" ]]; then
            echo "Smount needs a non-empty flake attribute in '$flake_ref'" >&2
            exit 1
          fi

          if [[ $eval_flake_attr != nixosConfigurations.* ]]; then
            eval_flake_attr="nixosConfigurations.\"$eval_flake_attr\".config"
          fi
        }

        normalize_nixos_config_flake "$smount_flake"

        ssh_args=(-T -p "$target_port")
        nix_ssh_opts="-p $target_port"
        while IFS= read -r option; do
          ssh_args+=(-o "$option")
          nix_ssh_opts+=" -o $option"
        done < <(jq -r '.sshOptions[]?' <<<"$target_json")

        if ! ssh "''${ssh_args[@]}" "$target_host" 'command -v nixos-install >/dev/null'; then
          printf '%s\n' \
            "Target '$target_host' does not expose 'nixos-install'." \
            "Boot into installer media '$media' and retry smount." >&2
          exit 1
        fi

        echo "Smount target: $host_input"
        echo "  Route: $route_name"
        echo "  Media: $media"
        echo "  Target host: $target_host"
        echo "  Flake: $smount_flake"
        echo "  Mode: mount existing disko layout"

        mount_script=$(
          nix build \
            --extra-experimental-features 'nix-command flakes' \
            --no-link \
            --print-out-paths \
            "$eval_flake_root#$eval_flake_attr.system.build.mountNoDeps"
        ) || {
          echo "Failed to build disko mount script for '$smount_flake'." >&2
          exit 1
        }

        echo "  Mount script: $mount_script"
        echo "Copying disko mount script to $target_host"
        NIX_SSHOPTS="$nix_ssh_opts" nix-copy-closure --to "$target_host" "$mount_script"

        printf -v remote_mount_script '%q' "$mount_script/bin/disko-mount"
        remote_mount=$(cat <<EOF
        set -euo pipefail
        mkdir -p /mnt
        $remote_mount_script
        test -d /mnt/nix/store
EOF
        )

        echo "Mounting existing disko layout on $target_host"
        # shellcheck disable=SC2029
        ssh "''${ssh_args[@]}" "$target_host" "$remote_mount"

        printf '%s\n' \
          "" \
          'Smount complete:' \
          '  Existing disko filesystems were mounted under /mnt.'
      '';
    };
  });

  rescueWrapperPackages = genAttrs installMediaLib.supportedBuildSystems (buildSystem: let
    pkgs = inputs.nixpkgs.legacyPackages.${buildSystem};
    availableTargets = renderAvailableTargets cfg;
  in {
    rescue = pkgs.writeShellApplication {
      name = "rescue";
      runtimeInputs = [
        pkgs.coreutils
        pkgs.jq
        pkgs.nix
        pkgs.openssh
      ];
      text = ''
        set -euo pipefail

        resolved_targets_json=${escapeShellArg installTargetsJson}
        smount_program=${escapeShellArg "${smountWrapperPackages.${buildSystem}.smount}/bin/smount"}

        usage() {
          printf '%s\n' \
            'Usage: rescue <route> <host> [wrapper args]' \
            "" \
            'Mount an existing disko installation and run nixos-install into it.' \
            "" \
            'Wrapper args:' \
            '  --flake <flake-uri>   Override the default flake attr for the target' \
            '  --build-on local      Build rescue artifacts locally before copying them' \
            '  -h, --help            Show this help' \
            "" \
            'Available targets:' \
            '${availableTargets}'
        }

        if [[ $# -eq 0 || "$1" == "--help" || "$1" == "-h" ]]; then
          usage
          exit 0
        fi

        if [[ $# -lt 2 ]]; then
          usage >&2
          exit 1
        fi

        route_input=$1
        shift
        host_input=$1
        shift

        flake_override=""
        build_on="local"

        while [[ $# -gt 0 ]]; do
          case "$1" in
            --help|-h)
              usage
              exit 0
              ;;
            --flake)
              if [[ $# -lt 2 ]]; then
                echo "Missing value for --flake" >&2
                exit 1
              fi
              flake_override=$2
              shift 2
              ;;
            --build-on)
              if [[ $# -lt 2 ]]; then
                echo "Missing value for --build-on" >&2
                exit 1
              fi
              build_on=$2
              shift 2
              ;;
            --)
              shift
              if [[ $# -gt 0 ]]; then
                echo "Rescue does not accept passthrough arguments." >&2
                exit 1
              fi
              ;;
            *)
              echo "Unknown rescue argument: $1" >&2
              usage >&2
              exit 1
              ;;
          esac
        done

        if [[ "$build_on" != "local" ]]; then
          echo "Rescue currently supports only --build-on local." >&2
          exit 1
        fi

        target_json=$(jq -cer --arg host "$host_input" '.[$host]' <<<"$resolved_targets_json") || {
          echo "Unknown install target: $host_input" >&2
          usage >&2
          exit 1
        }

        route_name=$(jq -r --arg route "$route_input" '
          if .routes[$route] then
            $route
          else
            empty
          end
        ' <<<"$target_json")

        if [[ -z "$route_name" ]]; then
          echo "Unknown route '$route_input' for target '$host_input'" >&2
          usage >&2
          exit 1
        fi

        target_host=$(jq -r --arg route "$route_name" '.routes[$route].targetHost' <<<"$target_json")
        media=$(jq -r '.media' <<<"$target_json")
        target_port=$(jq -r '.targetPort' <<<"$target_json")
        default_flake=$(jq -r '.flakeUri' <<<"$target_json")
        hardware_backend=$(jq -r '.hardwareReport.backend // empty' <<<"$target_json")
        hardware_path=$(jq -r '.hardwareReport.path // empty' <<<"$target_json")
        rescue_flake=''${flake_override:-$default_flake}

        normalize_nixos_config_flake() {
          local flake_ref=$1

          if [[ $flake_ref =~ ^(.*)\#([^\#\"]*)$ ]]; then
            eval_flake_root=''${BASH_REMATCH[1]}
            eval_flake_attr=''${BASH_REMATCH[2]}
          else
            echo "Rescue needs a flake URI fragment, got '$flake_ref'" >&2
            exit 1
          fi

          if [[ -z "$eval_flake_attr" ]]; then
            echo "Rescue needs a non-empty flake attribute in '$flake_ref'" >&2
            exit 1
          fi

          if [[ $eval_flake_attr != nixosConfigurations.* ]]; then
            eval_flake_attr="nixosConfigurations.\"$eval_flake_attr\".config"
          fi
        }

        normalize_nixos_config_flake "$rescue_flake"

        ssh_args=(-T -p "$target_port")
        nix_ssh_opts="-p $target_port"
        while IFS= read -r option; do
          ssh_args+=(-o "$option")
          nix_ssh_opts+=" -o $option"
        done < <(jq -r '.sshOptions[]?' <<<"$target_json")

        echo "Rescue target: $host_input"
        echo "  Route: $route_name"
        echo "  Media: $media"
        echo "  Target host: $target_host"
        echo "  Flake: $rescue_flake"
        echo "  Mode: mount existing disko layout and run nixos-install"

        if [[ -n "$hardware_backend" || -n "$hardware_path" ]]; then
          if [[ "$hardware_backend" != "nixos-facter" || -z "$hardware_path" ]]; then
            echo "Rescue supports only complete nixos-facter hardware reports." >&2
            exit 1
          fi

          if ! ssh "''${ssh_args[@]}" "$target_host" 'command -v nixos-facter >/dev/null'; then
            printf '%s\n' \
              "Target '$target_host' does not expose 'nixos-facter'." \
              "The selected media '$media' is expected to bundle nixos-facter for rescue fact refreshes." \
              'Rebuild or reflash that installer media and retry.' >&2
            exit 1
          fi

          mkdir -p "$(dirname "$hardware_path")"
          hardware_tmp=$(mktemp "''${hardware_path}.tmp.XXXXXX")
          trap 'rm -f "$hardware_tmp"' EXIT

          echo "Refreshing hardware report: $hardware_backend -> $hardware_path"
          # shellcheck disable=SC2029
          ssh "''${ssh_args[@]}" "$target_host" nixos-facter > "$hardware_tmp"
          if [[ ! -s "$hardware_tmp" ]]; then
            echo "Remote nixos-facter produced an empty hardware report." >&2
            exit 1
          fi
          jq empty "$hardware_tmp" || {
            echo "Remote nixos-facter produced invalid JSON." >&2
            exit 1
          }
          mv "$hardware_tmp" "$hardware_path"
          trap - EXIT
        fi

        system_path=$(
          nix build \
            --extra-experimental-features 'nix-command flakes' \
            --no-link \
            --print-out-paths \
            "$eval_flake_root#$eval_flake_attr.system.build.toplevel"
        ) || {
          echo "Failed to build NixOS system for '$rescue_flake'." >&2
          exit 1
        }

        echo "  System: $system_path"

        "$smount_program" "$route_input" "$host_input" --flake "$rescue_flake" --build-on "$build_on"

        printf -v remote_system_path '%q' "$system_path"

        remote_store_host=$target_host
        if [[ "$target_port" != "22" ]]; then
          remote_store_host="$target_host:$target_port"
        fi
        remote_store="ssh://$remote_store_host?remote-store=local%3Froot%3D%2Fmnt"
        echo "Copying system closure to mounted target store on $target_host"
        NIX_SSHOPTS="$nix_ssh_opts" nix copy \
          --extra-experimental-features nix-command \
          --no-check-sigs \
          --to "$remote_store" \
          "$system_path"

        remote_install=$(cat <<EOF
        set -euo pipefail
        nixos-install --root /mnt --system $remote_system_path --no-channel-copy --no-root-password
EOF
        )

        echo "Installing system into mounted root on $target_host"
        # shellcheck disable=SC2029
        ssh "''${ssh_args[@]}" "$target_host" "$remote_install"

        printf '%s\n' \
          "" \
          'Rescue complete:' \
          '  Existing disko filesystems were mounted under /mnt.' \
          '  The selected NixOS system was installed into that mounted root.'
      '';
    };
  });

  probeWrapperPackages = genAttrs installMediaLib.supportedBuildSystems (buildSystem: let
    pkgs = inputs.nixpkgs.legacyPackages.${buildSystem};
    availableTargets = renderAvailableTargets cfg;
  in {
    probe-hardware = pkgs.writeShellApplication {
      name = "probe-hardware";
      runtimeInputs = [
        pkgs.coreutils
        pkgs.jq
        pkgs.nix
        pkgs.openssh
      ];
      text = ''
        set -euo pipefail

        resolved_targets_json=${escapeShellArg installTargetsJson}

        usage() {
          printf '%s\n' \
            'Usage: probe-hardware <route> <host> -- [nixos-facter args]' \
            "" \
            'The hardware report destination comes from ignitix.installTargets.<host>.hardwareReport.' \
            "" \
            'Available targets:' \
            '${availableTargets}'
        }

        if [[ $# -eq 0 || "$1" == "--help" || "$1" == "-h" ]]; then
          usage
          exit 0
        fi

        if [[ $# -lt 2 ]]; then
          usage >&2
          exit 1
        fi

        route_input=$1
        shift
        host_input=$1
        shift

        facter_args=()
        if [[ $# -gt 0 ]]; then
          if [[ "$1" != "--" ]]; then
            echo "Unknown wrapper argument: $1" >&2
            usage >&2
            exit 1
          fi
          shift
          facter_args=("$@")
        fi

        target_json=$(jq -cer --arg host "$host_input" '.[$host]' <<<"$resolved_targets_json") || {
          echo "Unknown install target: $host_input" >&2
          usage >&2
          exit 1
        }

        route_name=$(jq -r --arg route "$route_input" '
          if .routes[$route] then
            $route
          else
            empty
          end
        ' <<<"$target_json")

        if [[ -z "$route_name" ]]; then
          echo "Unknown route '$route_input' for target '$host_input'" >&2
          usage >&2
          exit 1
        fi

        target_host=$(jq -r --arg route "$route_name" '.routes[$route].targetHost' <<<"$target_json")
        media=$(jq -r '.media' <<<"$target_json")
        target_port=$(jq -r '.targetPort' <<<"$target_json")
        hardware_backend=$(jq -r '.hardwareReport.backend // empty' <<<"$target_json")
        hardware_path=$(jq -r '.hardwareReport.path // empty' <<<"$target_json")

        if [[ "$hardware_backend" != "nixos-facter" || -z "$hardware_path" ]]; then
          echo "Target '$host_input' does not define a nixos-facter hardware report destination" >&2
          exit 1
        fi

        mkdir -p "$(dirname "$hardware_path")"

        ssh_args=(-T -p "$target_port")
        while IFS= read -r option; do
          ssh_args+=(-o "$option")
        done < <(jq -r '.sshOptions[]?' <<<"$target_json")

        if ! ssh "''${ssh_args[@]}" "$target_host" 'command -v nixos-facter >/dev/null'; then
          printf '%s\n' \
            "Target '$target_host' does not expose a remote 'nixos-facter' binary." \
            "The selected media '$media' is expected to bundle nixos-facter for offline probe/install flows." \
            'Rebuild or reflash that installer media and retry.' >&2
          exit 1
        fi

        remote_cmd=(nixos-facter)
        remote_cmd+=("''${facter_args[@]}")

        printf -v remote_shell '%q ' "''${remote_cmd[@]}"

        echo "Probing hardware target: $host_input"
        echo "  Route: $route_name"
        echo "  Target host: $target_host"
        echo "  Output: $hardware_path"

        # shellcheck disable=SC2029
        ssh "''${ssh_args[@]}" "$target_host" "$remote_shell" > "$hardware_path"
      '';
    };
  });

  installTargetApps = genAttrs installMediaLib.supportedBuildSystems (buildSystem: {
    install = {
      type = "app";
      program = "${targetWrapperPackages.${buildSystem}.install}/bin/install";
    };
    rescue = {
      type = "app";
      program = "${rescueWrapperPackages.${buildSystem}.rescue}/bin/rescue";
    };
    smount = {
      type = "app";
      program = "${smountWrapperPackages.${buildSystem}.smount}/bin/smount";
    };
    probe-hardware = {
      type = "app";
      program = "${probeWrapperPackages.${buildSystem}.probe-hardware}/bin/probe-hardware";
    };
  });

  installTargetPackages = genAttrs installMediaLib.supportedBuildSystems (
    buildSystem:
      recursiveUpdate
      {
        install = targetWrapperPackages.${buildSystem}.install;
        rescue = rescueWrapperPackages.${buildSystem}.rescue;
        smount = smountWrapperPackages.${buildSystem}.smount;
      }
      {
        probe-hardware = probeWrapperPackages.${buildSystem}.probe-hardware;
      }
  );
in {
  options.ignitix = {
    hostMetadata = mkOption {
      type = types.attrsOf types.anything;
      default = {};
      description = ''
        Consumer-provided host metadata used by hostField route resolvers.
      '';
    };

    installTargets = mkOption {
      type = types.attrsOf (types.submodule ({name, ...}: {
        options = {
          flakeAttr = mkOption {
            type = types.str;
            default = name;
            description = ''
              NixOS configuration attr installed for this target.
            '';
          };

          media = mkOption {
            type = types.str;
            description = ''
              Install-media name from ignitix.installMedia used to bootstrap this target.
            '';
          };

          routes = mkOption {
            type = types.attrsOf (types.submodule {
              options = {
                resolver = mkOption {
                  type = types.submodule {
                    options = {
                      type = mkOption {
                        type = types.enum [
                          "hostField"
                          "mediaEndpoint"
                        ];
                        description = ''
                          Resolver kind for this semantic route.
                        '';
                      };

                      field = mkOption {
                        type = types.nullOr types.str;
                        default = null;
                        description = ''
                          Dot-separated host field path when type = "hostField".
                        '';
                      };

                      endpoint = mkOption {
                        type = types.nullOr types.str;
                        default = null;
                        description = ''
                          Media endpoint name when type = "mediaEndpoint".
                        '';
                      };
                    };
                  };
                  description = ''
                    Resolver configuration for this route.
                  '';
                };
              };
            });
            default = {};
            description = ''
              Supported install routes keyed by semantic route name, such as lan or usb.
            '';
          };

          hardwareReport = mkOption {
            type = types.nullOr (types.submodule {
              options = {
                backend = mkOption {
                  type = types.enum [
                    "nixos-facter"
                    "nixos-generate-config"
                  ];
                  description = ''
                    Hardware-report backend to run for this install target.
                  '';
                };

                path = mkOption {
                  type = types.str;
                  description = ''
                    Local path where the generated hardware report is written.
                  '';
                };
              };
            });
            default = null;
            description = ''
              Optional hardware-report destination generated automatically during install.
            '';
          };
        };
      }));
      default = {};
      description = ''
        Host-first install targets for local nix run install/probe-hardware apps.
      '';
    };
  };

  config = mkMerge [
    {
      flake = {
        apps = installTargetApps;
        packages = installTargetPackages;
      };
    }
    (mkIf (cfg != {}) {
      flake.installTargetsResolved = resolvedTargets;
    })
  ];
}
