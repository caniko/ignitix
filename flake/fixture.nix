{
  inputs,
  lib,
  self,
  ...
}: let
  ignitixLib = import ../lib {
    inherit
      inputs
      lib
      ;
  };
in {
  flake.nixosConfigurations.example-crossbow = inputs.nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [
      inputs.nixos-anywhere.inputs.disko.nixosModules.disko
      {
        boot.loader.grub.devices = ["/dev/vda"];
        disko.devices.disk.root = {
          type = "disk";
          device = "/dev/vda";
          content = {
            type = "gpt";
            partitions.root = {
              size = "100%";
              content = {
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
              };
            };
          };
        };
        system.stateVersion = "25.11";
      }
    ];
  };

  ignitix.installMedia.example-rockpro64-installer =
    ignitixLib.catalog.rockpro64Installer {
      hostname = "example-rockpro64-installer";
      packageName = "example-rockpro64";
      rootAuthorizedKeys = [];
    };

  ignitix.installTargets.example-cross-install = {
    flakeAttr = "example-crossbow";
    media = "example-rockpro64-installer";
    routes.usb.resolver = {
      type = "mediaEndpoint";
      endpoint = "usb";
    };
  };

  perSystem = {
    pkgs,
    self',
    ...
  }: let
    exampleCrossbow = self.nixosConfigurations.example-crossbow.config;
    contract = {
      toplevelDrvPath =
        builtins.unsafeDiscardStringContext
        exampleCrossbow.system.build.toplevel.drvPath;
      diskoScriptNoDepsDrvPath =
        builtins.unsafeDiscardStringContext
        exampleCrossbow.system.build.diskoScriptNoDeps.drvPath;
      rootDiskDevice = exampleCrossbow.disko.devices.disk.root.device;
    };
  in {
    checks.install-target-cross-flake-attr = pkgs.runCommand "install-target-cross-flake-attr" {
      nativeBuildInputs = [pkgs.jq];
    } ''
      resolved=${lib.escapeShellArg (builtins.toJSON self.installTargetsResolved.example-cross-install)}

      flake_uri=$(jq -r .flakeUri <<<"$resolved")
      test "$flake_uri" = ".#example-crossbow"

      route_host=$(jq -r .routes.usb.targetHost <<<"$resolved")
      test "$route_host" = "root@10.55.0.1"

      test -n ${lib.escapeShellArg contract.toplevelDrvPath}
      test -n ${lib.escapeShellArg contract.diskoScriptNoDepsDrvPath}
      test ${lib.escapeShellArg contract.rootDiskDevice} = /dev/vda

      wrapper=${self'.packages.install}/bin/install
      grep -F '.#example-crossbow' "$wrapper" >/dev/null
      grep -F 'final_args+=(--flake "''${flake_override:-$default_flake}")' "$wrapper" >/dev/null
      grep -F 'auto|local|remote|split)' "$wrapper" >/dev/null
      grep -F 'final_args+=(--store-paths "$split_disko_script_path" "$split_system_path")' "$wrapper" >/dev/null
      grep -F '[[ -n "$build_on" && "$build_on" != "split" ]]' "$wrapper" >/dev/null
      grep -F 'verify_or_repair_remote_disko_closure "$disko_script_path"' "$wrapper" >/dev/null
      grep -F 'collect_remote_closure_mismatches()' "$wrapper" >/dev/null
      grep -F 'Refusing to derive expected hash from actual path contents.' "$wrapper" >/dev/null
      grep -F 'registered NAR hash:' "$wrapper" >/dev/null
      grep -F 'nix-store -qR %q' "$wrapper" >/dev/null
      grep -F 'nix-store --repair-path %q' "$wrapper" >/dev/null
      grep -F -- '--from "$remote_store_uri"' "$wrapper" >/dev/null

      touch "$out"
    '';
  };
}
