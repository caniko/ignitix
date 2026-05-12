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
  splitDiskoTrustLayerShell = builtins.readFile ./split-disko-trust-layer.sh;

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

        local_system() {
          case "$(uname -m)" in
            x86_64)
              echo x86_64-linux
              ;;
            aarch64|arm64)
              echo aarch64-linux
              ;;
            *)
              return 1
              ;;
          esac
        }

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

        target_host_platform() {
          local flake_ref=$1
          normalize_nixos_anywhere_flake "$flake_ref"

          nix eval \
            --extra-experimental-features 'nix-command flakes' \
            --raw \
            "''${eval_flake_root}#''${eval_flake_attr}.nixpkgs.hostPlatform.system"
        }

        target_has_bcache() {
          local flake_ref=$1
          normalize_nixos_anywhere_flake "$flake_ref"

          nix eval \
            --extra-experimental-features 'nix-command flakes' \
            --json \
            --apply 'cfg: cfg.disko.devices.bcache or {} != {}' \
            "''${eval_flake_root}#''${eval_flake_attr}"
        }

        passthrough_has_extra_platforms() {
          local i=0
          while (( i < ''${#passthrough_args[@]} )); do
            if [[ "''${passthrough_args[$i]}" == "--option" \
               && $((i + 1)) -lt ''${#passthrough_args[@]} \
               && "''${passthrough_args[$((i + 1))]}" == "extra-platforms" ]]; then
              return 0
            fi
            i=$((i + 1))
          done
          return 1
        }

        phases_include_install_without_disko() {
          local phases=$1
          local has_install=false
          local has_disko=false
          local phase

          IFS=',' read -ra phase_list <<<"$phases"
          for phase in "''${phase_list[@]}"; do
            case "$phase" in
              install)
                has_install=true
                ;;
              disko)
                has_disko=true
                ;;
            esac
          done

          [[ "$has_install" == true && "$has_disko" != true ]]
        }

        reject_unsafe_bcache_phases() {
          local install_flake_ref=$1
          local has_bcache
          local i=0
          local phases=""

          has_bcache=$(target_has_bcache "$install_flake_ref") || {
            echo "Failed to evaluate whether '$install_flake_ref' uses disko bcache." >&2
            exit 1
          }
          [[ "$has_bcache" == true ]] || return 0

          while (( i < ''${#passthrough_args[@]} )); do
            case "''${passthrough_args[$i]}" in
              --phases)
                if [[ $((i + 1)) -ge ''${#passthrough_args[@]} ]]; then
                  echo "Missing value for --phases" >&2
                  exit 1
                fi
                phases="''${passthrough_args[$((i + 1))]}"
                ;;
              --phases=*)
                phases="''${passthrough_args[$i]#--phases=}"
                ;;
            esac

            if [[ -n "$phases" ]] && phases_include_install_without_disko "$phases"; then
              printf '%s\n' \
                "Refusing unsafe bcache install phases '$phases' for '$install_flake_ref'." \
                "--phases install,reboot skips disko formatting, so bcache members are left without superblocks and /dev/bcache0 cannot assemble." \
                "Omit --phases or use: --phases kexec,disko,install,reboot" >&2
              exit 1
            fi

            i=$((i + 1))
          done
        }

        passthrough_requests_remote_build() {
          local i=0
          while (( i < ''${#passthrough_args[@]} )); do
            case "''${passthrough_args[$i]}" in
              --build-on-remote)
                return 0
                ;;
              --build-on)
                if [[ $((i + 1)) -lt ''${#passthrough_args[@]} \
                   && "''${passthrough_args[$((i + 1))]}" == "remote" ]]; then
                  return 0
                fi
                i=$((i + 2))
                continue
                ;;
            esac
            i=$((i + 1))
          done
          return 1
        }

        binfmt_handler_for() {
          case "$1" in
            aarch64-linux)
              echo aarch64-linux
              ;;
            *)
              return 1
              ;;
          esac
        }

        ensure_local_binfmt_for() {
          local target_system=$1
          local handler
          local handler_path

          handler=$(binfmt_handler_for "$target_system") || return 0
          handler_path="/proc/sys/fs/binfmt_misc/$handler"

          if [[ ! -e "$handler_path" ]]; then
            printf '%s\n' \
              "Local build for $target_system requires binfmt handler '$handler', but $handler_path is missing." \
              "Rebuild this local builder with boot.binfmt.emulatedSystems = [\"$target_system\"]; then verify: cat $handler_path" >&2
            exit 1
          fi

          if ! grep -Fx enabled "$handler_path" >/dev/null; then
            printf '%s\n' \
              "Local build for $target_system requires enabled binfmt handler '$handler', but $handler_path is disabled." \
              "Rebuild this local builder with boot.binfmt.emulatedSystems = [\"$target_system\"]; then verify: cat $handler_path" >&2
            exit 1
          fi
        }

        apply_native_build_defaults() {
          local install_flake_ref=$1
          local target_system
          local current_system

          target_system=$(target_host_platform "$install_flake_ref") || {
            echo "Failed to evaluate target platform for '$install_flake_ref'." >&2
            exit 1
          }
          current_system=$(local_system) || {
            echo "Unsupported local architecture: $(uname -m)" >&2
            exit 1
          }

          if [[ "$target_system" == "$current_system" ]]; then
            return
          fi

          if [[ "$build_on" == "remote" || "$build_on" == "split" ]] || passthrough_requests_remote_build; then
            return
          fi

          build_on=local
          if [[ "$passthrough_help" != true ]]; then
            ensure_local_binfmt_for "$target_system"
          fi

          if ! passthrough_has_extra_platforms; then
            passthrough_args=(--option extra-platforms "$target_system" "''${passthrough_args[@]}")
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

        ${splitDiskoTrustLayerShell}

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

        if [[ "$store_paths_mode" != true && "$explicit_flake" != true ]]; then
          apply_native_build_defaults "''${flake_override:-$default_flake}"
        fi

        if [[ "$store_paths_mode" != true ]]; then
          if [[ "$explicit_flake" == true ]]; then
            reject_unsafe_bcache_phases "$explicit_flake_value"
          else
            reject_unsafe_bcache_phases "''${flake_override:-$default_flake}"
          fi
        fi

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

  diskDiagnoseWrapperPackages = genAttrs installMediaLib.supportedBuildSystems (buildSystem: let
    pkgs = inputs.nixpkgs.legacyPackages.${buildSystem};
    availableTargets = renderAvailableTargets cfg;
  in {
    disk-diagnose = pkgs.writeShellApplication {
      name = "disk-diagnose";
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
            'Usage: disk-diagnose <route> <host> [wrapper args]' \
            "" \
            'Collect a schema-v1 disk diagnosis report from boot media.' \
            "" \
            'Wrapper args:' \
            '  --with-smount        Run smount before probing (default)' \
            '  --no-mount           Skip smount and probe live media only' \
            '  --flake <flake-uri>  Override the default flake attr for the target' \
            '  --build-on local     Build mount artifacts locally before copying them' \
            '  -h, --help           Show this help' \
            "" \
            'Available targets:' \
            '${availableTargets}'
        }

        build_failure_report() {
          local probe_log=$1
          local message=$2
          local generated_at
          generated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
          jq -nc \
            --arg generated_at "$generated_at" \
            --arg target_host "$host_input" \
            --arg target_route "$route_name" \
            --arg probe_log "$probe_log" \
            --arg message "$message" \
            '{
              schema_version: "1",
              generated_at: $generated_at,
              tool: {
                name: "disk-diagnose",
                version: "0.1.0"
              },
              target: {
                host: $target_host,
                route: $target_route
              },
              context: {
                mode: "live-only",
                mounted_system_root: "/mnt"
              },
              bootmedia: {
                kernel: {
                  ok: false,
                  error: $message
                }
              },
              installed: {
                kernel: {
                  ok: false,
                  error: $message
                },
                bcache_module: {
                  path: {
                    ok: false,
                    error: $message
                  },
                  modinfo: {
                    ok: false,
                    error: $message
                  }
                },
                modprobe_d: [
                  {
                    path: "/mnt/etc/modprobe.d",
                    ok: false,
                    error: $message
                  }
                ],
                bcache_super: [],
                system_profile: {
                  ok: false,
                  error: $message
                }
              },
              live: {
                modprobe: {
                  bcache: {
                    ok: false,
                    error: $message
                  }
                },
                dmesg: {
                  bcache: {
                    ok: false,
                    error: $message
                  }
                }
              },
              disks: {
                lsblk: {
                  ok: false,
                  error: $message
                },
                by_partlabel: {
                  ok: false,
                  error: $message
                },
                gpt: [
                  {
                    device: "/dev/mmcblk0",
                    ok: false,
                    error: $message
                  },
                  {
                    device: "/dev/mmcblk1",
                    ok: false,
                    error: $message
                  }
                ],
                blkid: []
              },
              probe_log: $probe_log
            }'
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
        with_smount=true
        no_mount=false

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
              if [[ "$2" != "local" ]]; then
                echo "Disk-diagnose currently supports only --build-on local." >&2
                exit 1
              fi
              build_on=$2
              shift 2
              ;;
            --with-smount)
              with_smount=true
              no_mount=false
              shift
              ;;
            --no-mount)
              no_mount=true
              with_smount=false
              shift
              ;;
            --)
              echo "Disk-diagnose does not accept passthrough arguments." >&2
              exit 1
              ;;
            *)
              echo "Unknown disk-diagnose argument: $1" >&2
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
        disk_diagnose_flake=''${flake_override:-$default_flake}

        ssh_args=(-T -p "$target_port")
        while IFS= read -r option; do
          ssh_args+=(-o "$option")
        done < <(jq -r '.sshOptions[]?' <<<"$target_json")

        echo "Disk-diagnose target: $host_input" >&2
        echo "  Route: $route_name" >&2
        echo "  Media: $media" >&2
        echo "  Target host: $target_host" >&2
        echo "  Flake: $disk_diagnose_flake" >&2

        if [[ "$with_smount" == true && "$no_mount" == false ]]; then
          echo "Running smount preflight" >&2
          if ! "$smount_program" "$route_input" "$host_input" --flake "$disk_diagnose_flake" --build-on "$build_on" >&2; then
            echo "smount preflight failed; rerun with --no-mount to inspect live media only." >&2
            build_failure_report "" "smount preflight failed"
            exit 1
          fi
        fi

        remote_cmd=$(printf 'TARGET_HOST=%q TARGET_ROUTE=%q TARGET_VERSION=%q bash -s' "$host_input" "$route_name" "0.1.0")
        remote_stderr_file=$(mktemp)
        trap 'rm -f "$remote_stderr_file"' EXIT

        if remote_json=$(
          # shellcheck disable=SC2029
          ssh "''${ssh_args[@]}" "$target_host" "$remote_cmd" 2>"$remote_stderr_file" <<'EOF'
        set -uo pipefail
        export PATH=/run/current-system/sw/bin:/run/wrappers/bin

        json_fail() {
          jq -nc --arg error "$1" '{ok:false,error:$error}'
        }

        mounted_system_root=/mnt
        target_host=''${TARGET_HOST:-}
        target_route=''${TARGET_ROUTE:-}
        tool_version=''${TARGET_VERSION:-0.1.0}
        generated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

        if [[ -e /mnt/run/booted-system/kernel && -d /mnt/nix/store ]]; then
          context_mode=mounted
        else
          context_mode=live-only
        fi

        by_partlabel_entries_json=$(
          if [[ -d /dev/disk/by-partlabel ]]; then
            find /dev/disk/by-partlabel -mindepth 1 -maxdepth 1 -printf '%f\t%l\n' |
              while IFS=$'\t' read -r label target; do
                [[ -n "$label" ]] || continue
                path="/dev/disk/by-partlabel/$label"
                resolved_device=$(readlink -f "$path" 2>/dev/null || true)
                jq -nc --arg label "$label" --arg path "$path" --arg target "$target" --arg resolved_device "$resolved_device" '{
                  name: $label,
                  path: $path,
                  target: $target,
                  resolved_device: $resolved_device
                }'
              done | jq -cs '.'
          else
            echo '[]'
          fi
        )

        probe_bootmedia_kernel() {
          if command -v uname >/dev/null 2>&1; then
            if release=$(uname -r 2>/dev/null); then
              jq -nc --arg release "$release" '{ok:true,release:$release}'
              return
            fi
          fi
          json_fail "uname -r failed"
        }

        probe_installed_kernel() {
          if [[ "$context_mode" != mounted ]]; then
            json_fail "installed system not mounted at /mnt"
            return
          fi

          if ! kernel_path=$(readlink -f /mnt/run/booted-system/kernel 2>/dev/null); then
            json_fail "installed kernel path unavailable"
            return
          fi

          modules_dir=$(find /mnt/run/booted-system/kernel-modules/lib/modules -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | head -n1)
          if [[ -z "$modules_dir" ]]; then
            json_fail "installed kernel release unavailable"
            return
          fi

          release=$(basename "$modules_dir")
          builtin_first_line=""
          if [[ -f "$modules_dir/modules.builtin" ]]; then
            builtin_first_line=$(head -n1 "$modules_dir/modules.builtin" 2>/dev/null || true)
          fi

          jq -nc \
            --arg kernel_path "$kernel_path" \
            --arg release "$release" \
            --arg modules_builtin_first_line "$builtin_first_line" \
            '{
              ok: true,
              kernel_path: $kernel_path,
              release: $release,
              modules_builtin_first_line: $modules_builtin_first_line
            }'
        }

        probe_installed_bcache_module_path() {
          if [[ "$context_mode" != mounted ]]; then
            json_fail "installed system not mounted at /mnt"
            return
          fi

          modules_dir=$(find /mnt/run/booted-system/kernel-modules/lib/modules -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | head -n1)
          if [[ -z "$modules_dir" ]]; then
            json_fail "bcache module path missing"
            return
          fi

          module_dir="$modules_dir/kernel/drivers/md/bcache"
          module_path=""
          for candidate in "$module_dir/bcache.ko" "$module_dir/bcache.ko.xz" "$module_dir/bcache.ko.zst"; do
            if [[ -e "$candidate" ]]; then
              module_path=$candidate
              break
            fi
          done

          if [[ -z "$module_path" ]]; then
            json_fail "bcache module path missing"
            return
          fi

          jq -nc \
            --arg module_dir "$module_dir" \
            --arg module_path "$module_path" \
            --argjson exists true \
            '{
              ok: true,
              module_dir: $module_dir,
              module_path: $module_path,
              exists: $exists
            }'
        }

        probe_installed_bcache_module_modinfo() {
          if [[ "$context_mode" != mounted ]]; then
            json_fail "installed system not mounted at /mnt"
            return
          fi

          modules_dir=$(find /mnt/run/booted-system/kernel-modules/lib/modules -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | head -n1)
          if [[ -z "$modules_dir" ]]; then
            json_fail "modinfo failed for /mnt/run/booted-system/kernel-modules/lib/modules/*/kernel/drivers/md/bcache/bcache.ko"
            return
          fi

          module_dir="$modules_dir/kernel/drivers/md/bcache"
          module_path=""
          for candidate in "$module_dir/bcache.ko" "$module_dir/bcache.ko.xz" "$module_dir/bcache.ko.zst"; do
            if [[ -e "$candidate" ]]; then
              module_path=$candidate
              break
            fi
          done

          if [[ -z "$module_path" ]]; then
            json_fail "modinfo failed for /mnt/run/booted-system/kernel-modules/lib/modules/*/kernel/drivers/md/bcache/bcache.ko"
            return
          fi

          if ! modinfo_output=$(modinfo --file "$module_path" 2>/dev/null); then
            json_fail "modinfo failed for $module_path"
            return
          fi

          raw_json=$(jq -Rn --arg text "$modinfo_output" '
            [($text | split("\n")[] | select(length > 0))
             | capture("^(?<k>[^:]+):[[:space:]]*(?<v>.*)$")]
            | reduce .[] as $kv ({alias: [], parm: []};
                if $kv.k == "alias" or $kv.k == "parm" then
                  .[$kv.k] += [$kv.v]
                else
                  .[$kv.k] = $kv.v
                end
              )
            | {
                filename: (.filename // ""),
                name: (.name // ""),
                license: (.license // ""),
                description: (.description // ""),
                author: (.author // ""),
                alias: (.alias // []),
                depends: (.depends // ""),
                retpoline: (.retpoline // ""),
                intree: (.intree // ""),
                vermagic: (.vermagic // ""),
                parm: (.parm // []),
                srcversion: (.srcversion // "")
              }
          ')

          depends_json=$(jq -nc --arg depends "$(jq -r '.depends' <<<"$raw_json")" '$depends | split(",") | map(select(length > 0))')

          jq -nc \
            --arg file "$module_path" \
            --argjson raw "$raw_json" \
            --argjson depends "$depends_json" \
            --arg srcversion "$(jq -r '.srcversion' <<<"$raw_json")" \
            '{
              ok: true,
              file: $file,
              vermagic: $raw.vermagic,
              depends: $depends,
              srcversion: $srcversion,
              raw: $raw
            }'
        }

        probe_live_modprobe_bcache() {
          if ! command -v modprobe >/dev/null 2>&1; then
            json_fail "tool-missing"
            return
          fi

          stdout_file=$(mktemp)
          stderr_file=$(mktemp)
          if modprobe bcache >"$stdout_file" 2>"$stderr_file"; then
            status=0
          else
            status=$?
          fi

          stdout=$(cat "$stdout_file" 2>/dev/null || true)
          stderr=$(cat "$stderr_file" 2>/dev/null || true)
          rm -f "$stdout_file" "$stderr_file"

          if [[ $status -ne 0 ]]; then
            jq -nc \
              --arg error "modprobe returned non-zero" \
              --argjson exit_status "$status" \
              --arg stdout "$stdout" \
              --arg stderr "$stderr" \
              '{
                ok: false,
                error: $error,
                exit_status: $exit_status,
                stdout: $stdout,
                stderr: $stderr
              }'
            return
          fi

          jq -nc \
            --argjson exit_status "$status" \
            --arg stdout "$stdout" \
            --arg stderr "$stderr" \
            '{
              ok: true,
              exit_status: $exit_status,
              stdout: $stdout,
              stderr: $stderr
            }'
        }

        probe_live_dmesg_bcache() {
          if ! command -v dmesg >/dev/null 2>&1; then
            json_fail "dmesg unavailable"
            return
          fi

          if ! lines=$(
            dmesg 2>/dev/null | grep -i 'bcache' || true
          ); then
            json_fail "dmesg unavailable"
            return
          fi

          if [[ -z "$lines" ]]; then
            json_fail "dmesg unavailable"
            return
          fi

          jq -nc --arg lines "$lines" '
            {
              ok: true,
              lines: ($lines | split("\n") | map(select(length > 0)))
            }
          '
        }

        probe_disks_lsblk() {
          if ! payload=$(lsblk -J -O 2>/dev/null); then
            json_fail "lsblk -J -O failed"
            return
          fi

          if [[ -z "$payload" ]]; then
            json_fail "lsblk -J -O failed"
            return
          fi

          jq -nc --argjson payload "$payload" '{
            ok: true,
            devices: $payload
          }'
        }

        probe_disks_by_partlabel() {
          if [[ ! -d /dev/disk/by-partlabel ]]; then
            json_fail "cannot read /dev/disk/by-partlabel"
            return
          fi

          jq -nc --argjson entries "$by_partlabel_entries_json" '{
            ok: true,
            entries: $entries
          }'
        }

        probe_disks_gpt() {
          local devices_json=()
          for device in /dev/mmcblk0 /dev/mmcblk1; do
            if [[ ! -b "$device" ]]; then
              devices_json+=("$(jq -nc --arg device "$device" --arg error "sgdisk -p failed" '{device:$device,ok:false,error:$error}')")
              continue
            fi

            if ! sgdisk_output=$(sgdisk -p "$device" 2>&1); then
              devices_json+=("$(jq -nc --arg device "$device" --arg error "sgdisk -p failed" --arg raw "$sgdisk_output" '{device:$device,ok:false,error:$error,raw:$raw}')")
              continue
            fi

            disk_identifier=$(grep -m1 '^Disk identifier (GUID):' <<<"$sgdisk_output" | sed 's/^.*: //')
            main_table_sectors=$(grep -m1 '^The main partition table begins at sector ' <<<"$sgdisk_output" | sed -E 's/^The main partition table begins at sector ([0-9]+) and ends at sector ([0-9]+).*/\1-\2/')
            first_usable_sector=$(grep -m1 '^First usable sector is ' <<<"$sgdisk_output" | sed -E 's/^First usable sector is ([0-9]+), last usable sector is ([0-9]+).*/\1/')
            last_usable_sector=$(grep -m1 '^First usable sector is ' <<<"$sgdisk_output" | sed -E 's/^First usable sector is ([0-9]+), last usable sector is ([0-9]+).*/\2/')
            holds=$(grep -m1 '^Number of partition entries:' <<<"$sgdisk_output" | sed 's/^Number of partition entries: /')
            partitions_free_space_json=$(
              grep -E '^Total free space is ' <<<"$sgdisk_output" | jq -Rcs 'split("\n") | map(select(length > 0))'
            )
            partitions_json=$(
              awk '
                /^[[:space:]]*[0-9]+[[:space:]]/ {
                  num=$1
                  start=$2
                  end=$3
                  size=$4" "$5
                  code=$6
                  $1=$2=$3=$4=$5=$6=""
                  sub(/^[[:space:]]+/, "", $0)
                  name=$0
                  gsub(/"/, "\\\"", name)
                  printf "{\"number\":%s,\"start\":\"%s\",\"end\":\"%s\",\"size\":\"%s\",\"code\":\"%s\",\"name\":\"%s\"}\n", num, start, end, size, code, name
                }
              ' <<<"$sgdisk_output" | jq -cs '.'
            )

            header_json=$(jq -nc \
              --arg disk_identifier "$disk_identifier" \
              --arg holds "$holds" \
              --arg main_table_sectors "$main_table_sectors" \
              --arg first_usable_sector "$first_usable_sector" \
              --arg last_usable_sector "$last_usable_sector" \
              --argjson partitions_free_space "$partitions_free_space_json" '{
                disk_identifier: $disk_identifier,
                holds: $holds,
                main_table_sectors: $main_table_sectors,
                first_usable_sector: $first_usable_sector,
                last_usable_sector: $last_usable_sector,
                partitions_free_space: $partitions_free_space
              }')

            devices_json+=("$(jq -nc \
              --arg device "$device" \
              --arg raw "$sgdisk_output" \
              --argjson header "$header_json" \
              --argjson partitions "$partitions_json" '{
                device: $device,
                ok: true,
                header: $header,
                partitions: $partitions,
                raw: $raw
              }')")
          done

          printf '%s\n' "''${devices_json[@]}" | jq -cs '.'
        }

        probe_disks_blkid() {
          local items_json=()

          while IFS= read -r item; do
            label=$(jq -r '.name' <<<"$item")
            resolved_device=$(jq -r '.resolved_device' <<<"$item")
            if [[ -z "$resolved_device" || "$resolved_device" == "null" ]]; then
              items_json+=("$(jq -nc --arg device "$label" --arg error "blkid failed for $label" '{device:$device,ok:false,error:$error}')")
              continue
            fi

            if ! blkid_output=$(blkid -o export -p "$resolved_device" 2>/dev/null); then
              items_json+=("$(jq -nc --arg device "$resolved_device" --arg label "$label" --arg error "blkid failed for $resolved_device" '{device:$device,ok:false,label:$label,error:$error}')")
              continue
            fi

            if [[ -z "$blkid_output" ]]; then
              items_json+=("$(jq -nc --arg device "$resolved_device" --arg label "$label" --arg error "blkid failed for $resolved_device" '{device:$device,ok:false,label:$label,error:$error}')")
              continue
            fi

            properties_json=$(jq -Rn --arg text "$blkid_output" '
              [($text | split("\n")[] | select(length > 0))
               | capture("^(?<key>[^=]+)=(?<value>.*)$")]
              | map({key: .key, value: .value})
              | from_entries
            ')

            items_json+=("$(jq -nc \
              --arg device "$resolved_device" \
              --arg label "$label" \
              --argjson properties "$properties_json" '{
                device: $device,
                resolved_device: $device,
                label: $label,
                ok: true,
                properties: $properties
              }')")
            done < <(jq -c '.[]' <<<"$by_partlabel_entries_json")

          printf '%s\n' "''${items_json[@]}" | jq -cs '.'
        }

        probe_installed_modprobe_d() {
          if [[ "$context_mode" != mounted ]]; then
            jq -nc --arg path "/mnt/etc/modprobe.d" --arg error "installed system not mounted at /mnt" '[
              {
                path: $path,
                ok: false,
                error: $error
              }
            ]'
            return
          fi

          if [[ ! -d /mnt/etc/modprobe.d ]]; then
            jq -nc '[]'
            return
          fi

          local items_json=()
          while IFS= read -r file; do
            [[ -n "$file" ]] || continue
            contents=$(cat "$file" 2>/dev/null || true)
            items_json+=("$(jq -nc --arg path "$file" --arg contents "$contents" '{path:$path,ok:true,contents:$contents}')")
          done < <(find /mnt/etc/modprobe.d -type f | sort)

          printf '%s\n' "''${items_json[@]}" | jq -cs '.'
        }

        probe_installed_bcache_super() {
          local items_json=()
          if ! command -v bcache-super-show >/dev/null 2>&1; then
            while IFS= read -r item; do
              label=$(jq -r '.name' <<<"$item")
              resolved_device=$(jq -r '.resolved_device' <<<"$item")
              items_json+=("$(jq -nc --arg device "$resolved_device" --arg resolved_device "$resolved_device" --arg role "unknown" --arg error "tool-missing" '{device:$device,resolved_device:$resolved_device,role:$role,ok:false,error:$error}')")
            done < <(jq -c '.[]' <<<"$by_partlabel_entries_json")

            printf '%s\n' "''${items_json[@]}" | jq -cs '.'
            return
          fi

          while IFS= read -r item; do
            label=$(jq -r '.name' <<<"$item")
            resolved_device=$(jq -r '.resolved_device' <<<"$item")
            role="unknown"
            case "$label" in
              *cache*) role="cache" ;;
              *back*) role="backing" ;;
            esac

            if [[ -z "$resolved_device" || "$resolved_device" == "null" ]]; then
              items_json+=("$(jq -nc --arg device "$label" --arg resolved_device "" --arg role "$role" --arg error "bcache-super-show failed for $label" '{device:$device,resolved_device:$resolved_device,role:$role,ok:false,error:$error}')")
              continue
            fi

            if ! super_output=$(bcache-super-show "$resolved_device" 2>&1); then
              items_json+=("$(jq -nc --arg device "$resolved_device" --arg resolved_device "$resolved_device" --arg role "$role" --arg error "bcache-super-show failed for $resolved_device" --arg raw "$super_output" '{device:$device,resolved_device:$resolved_device,role:$role,ok:false,error:$error,raw:$raw}')")
              continue
            fi

            items_json+=("$(jq -nc --arg device "$resolved_device" --arg resolved_device "$resolved_device" --arg role "$role" --arg raw "$super_output" '{device:$device,resolved_device:$resolved_device,role:$role,ok:true,raw:$raw}')")
          done < <(jq -c '.[]' <<<"$by_partlabel_entries_json")

          printf '%s\n' "''${items_json[@]}" | jq -cs '.'
        }

        probe_installed_system_profile() {
          if [[ "$context_mode" != mounted ]]; then
            json_fail "installed system not mounted at /mnt"
            return
          fi

          link=/mnt/nix/var/nix/profiles/system
          if [[ ! -e "$link" ]]; then
            json_fail "cannot resolve /mnt/nix/var/nix/profiles/system"
            return
          fi

          if ! target=$(readlink -f "$link" 2>/dev/null); then
            json_fail "cannot resolve /mnt/nix/var/nix/profiles/system"
            return
          fi

          jq -nc --arg link "$link" --arg target "$target" '{
            ok: true,
            link: $link,
            target: $target
          }'
        }

        bootmedia_kernel_json=$(probe_bootmedia_kernel)
        installed_kernel_json=$(probe_installed_kernel)
        installed_bcache_module_path_json=$(probe_installed_bcache_module_path)
        installed_bcache_module_modinfo_json=$(probe_installed_bcache_module_modinfo)
        live_modprobe_bcache_json=$(probe_live_modprobe_bcache)
        live_dmesg_bcache_json=$(probe_live_dmesg_bcache)
        disks_lsblk_json=$(probe_disks_lsblk)
        disks_by_partlabel_json=$(probe_disks_by_partlabel)
        disks_gpt_json=$(probe_disks_gpt)
        disks_blkid_json=$(probe_disks_blkid)
        installed_modprobe_d_json=$(probe_installed_modprobe_d)
        installed_bcache_super_json=$(probe_installed_bcache_super)
        installed_system_profile_json=$(probe_installed_system_profile)

        jq -nc \
          --arg generated_at "$generated_at" \
          --arg target_host "$target_host" \
          --arg target_route "$target_route" \
          --arg context_mode "$context_mode" \
          --argjson bootmedia_kernel "$bootmedia_kernel_json" \
          --argjson installed_kernel "$installed_kernel_json" \
          --argjson installed_bcache_module_path "$installed_bcache_module_path_json" \
          --argjson installed_bcache_module_modinfo "$installed_bcache_module_modinfo_json" \
          --argjson live_modprobe_bcache "$live_modprobe_bcache_json" \
          --argjson live_dmesg_bcache "$live_dmesg_bcache_json" \
          --argjson disks_lsblk "$disks_lsblk_json" \
          --argjson disks_by_partlabel "$disks_by_partlabel_json" \
          --argjson disks_gpt "$disks_gpt_json" \
          --argjson disks_blkid "$disks_blkid_json" \
          --argjson installed_modprobe_d "$installed_modprobe_d_json" \
          --argjson installed_bcache_super "$installed_bcache_super_json" \
          --argjson installed_system_profile "$installed_system_profile_json" '{
            schema_version: "1",
            generated_at: $generated_at,
            tool: {
              name: "disk-diagnose",
              version: "0.1.0"
            },
            target: {
              host: $target_host,
              route: $target_route
            },
            context: {
              mode: $context_mode,
              mounted_system_root: "/mnt"
            },
            bootmedia: {
              kernel: $bootmedia_kernel
            },
            installed: {
              kernel: $installed_kernel,
              bcache_module: {
                path: $installed_bcache_module_path,
                modinfo: $installed_bcache_module_modinfo
              },
              modprobe_d: $installed_modprobe_d,
              bcache_super: $installed_bcache_super,
              system_profile: $installed_system_profile
            },
            live: {
              modprobe: {
                bcache: $live_modprobe_bcache
              },
              dmesg: {
                bcache: $live_dmesg_bcache
              }
            },
            disks: {
              lsblk: $disks_lsblk,
              by_partlabel: $disks_by_partlabel,
              gpt: $disks_gpt,
              blkid: $disks_blkid
            }
          }'
EOF
        ); then
          remote_status=0
        else
          remote_status=$?
        fi

        probe_log=$(tail -c 4096 "$remote_stderr_file" 2>/dev/null || true)

        if [[ $remote_status -ne 0 || -z "$remote_json" ]]; then
          echo "disk-diagnose remote helper did not produce a report." >&2
          build_failure_report "$probe_log" "remote helper failed before report generation"
          exit 1
        fi

        if ! jq -e . >/dev/null 2>&1 <<<"$remote_json"; then
          echo "disk-diagnose remote helper produced invalid JSON." >&2
          build_failure_report "$probe_log" "remote helper produced invalid JSON"
          exit 1
        fi

        jq -c --arg probe_log "$probe_log" '. + {probe_log: $probe_log}' <<<"$remote_json"
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
    disk-diagnose = {
      type = "app";
      program = "${diskDiagnoseWrapperPackages.${buildSystem}.disk-diagnose}/bin/disk-diagnose";
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
        disk-diagnose = diskDiagnoseWrapperPackages.${buildSystem}.disk-diagnose;
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
