{
  inputs,
  lib,
  self,
  ...
}: let
  fixtureAuthorizedKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA8LqsiluIJ6jpM2l46ELQ/V095NWnIVu5q2tw7F9C8L ignitix-fixture";
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

  ignitix.installMedia.example-x86_64-installer = ignitixLib.mkInstallerMedia {
    hostname = "example-x86_64-installer";
    packageName = "example-x86_64-installer";
    rootAuthorizedKeys = [fixtureAuthorizedKey];
    system = "x86_64-linux";
    imageModule =
      inputs.nixpkgs
      + "/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix";
    nixosAnywhere.enable = false;
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
    exampleRockpro64 = self.nixosConfigurations.example-rockpro64-installer.config;
    exampleX86_64 = self.nixosConfigurations.example-x86_64-installer.config;
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
    checks.install-media-image-contract = pkgs.runCommand "install-media-image-contract" {} ''
      test ${lib.escapeShellArg exampleX86_64.nixpkgs.hostPlatform.system} = x86_64-linux
      test ${lib.escapeShellArg exampleX86_64.image.extension} = iso
      test ${lib.escapeShellArg (builtins.unsafeDiscardStringContext exampleX86_64.system.build.image.drvPath)} = ${lib.escapeShellArg (builtins.unsafeDiscardStringContext exampleX86_64.system.build.isoImage.drvPath)}
      test ${lib.escapeShellArg (builtins.unsafeDiscardStringContext exampleRockpro64.system.build.image.drvPath)} = ${lib.escapeShellArg (builtins.unsafeDiscardStringContext exampleRockpro64.system.build.sdImage.drvPath)}
      test ${lib.escapeShellArg (lib.boolToString exampleX86_64.services.openssh.enable)} = true
      test ${lib.escapeShellArg (lib.boolToString exampleX86_64.services.openssh.openFirewall)} = true
      test ${lib.escapeShellArg exampleX86_64.services.openssh.settings.PermitRootLogin} = prohibit-password
      test ${lib.escapeShellArg (lib.boolToString exampleX86_64.services.openssh.settings.PasswordAuthentication)} = false
      test ${lib.escapeShellArg (lib.boolToString exampleX86_64.services.openssh.settings.KbdInteractiveAuthentication)} = false
      grep -F -- ${lib.escapeShellArg fixtureAuthorizedKey} <<< ${lib.escapeShellArg (builtins.toJSON exampleX86_64.users.users.root.openssh.authorizedKeys.keys)}
      touch "$out"
    '';

    checks.install-target-cross-flake-attr = pkgs.runCommand "install-target-cross-flake-attr" {
      nativeBuildInputs = [pkgs.jq];
    } ''
      resolved=${lib.escapeShellArg (builtins.toJSON self.installTargetsResolved.example-cross-install)}

      flake_uri=$(jq -r .flakeUri <<<"$resolved")
      test "$flake_uri" = ".#example-crossbow"

      route_host=$(jq -r .routes.usb.targetHost <<<"$resolved")
      test "$route_host" = "root@10.55.0.1"

      jq -e '.sshOptions == [
        "StrictHostKeyChecking=no",
        "UserKnownHostsFile=/dev/null",
        "GlobalKnownHostsFile=/dev/null"
      ]' <<<"$resolved" >/dev/null

      test -n ${lib.escapeShellArg contract.toplevelDrvPath}
      test -n ${lib.escapeShellArg contract.diskoScriptNoDepsDrvPath}
      test ${lib.escapeShellArg contract.rootDiskDevice} = /dev/vda

      wrapper=${self'.packages.install}/bin/install
      grep -F '.#example-crossbow' "$wrapper" >/dev/null
      grep -F 'final_args+=(--flake "''${flake_override:-$default_flake}")' "$wrapper" >/dev/null
      grep -F 'auto|local|remote|split)' "$wrapper" >/dev/null
      grep -F 'final_args+=(--store-paths "$split_disko_script_path" "$split_system_path")' "$wrapper" >/dev/null
      grep -F '[[ -n "$build_on" && "$build_on" != "split" ]]' "$wrapper" >/dev/null
      grep -F 'target_host_platform()' "$wrapper" >/dev/null
      grep -F 'reject_unsafe_bcache_phases' "$wrapper" >/dev/null
      grep -F 'cfg.disko.devices.bcache or {} != {}' "$wrapper" >/dev/null
      grep -F 'skips disko formatting' "$wrapper" >/dev/null
      grep -F 'apply_native_build_defaults "''${flake_override:-$default_flake}"' "$wrapper" >/dev/null
      grep -F 'ensure_local_binfmt_for "$target_system"' "$wrapper" >/dev/null
      grep -F "boot.binfmt.emulatedSystems" "$wrapper" >/dev/null
      grep -F 'passthrough_args=(--option extra-platforms "$target_system" "''${passthrough_args[@]}")' "$wrapper" >/dev/null
      grep -F 'verify_or_repair_remote_disko_closure "$disko_script_path"' "$wrapper" >/dev/null
      grep -F 'collect_remote_closure_mismatches()' "$wrapper" >/dev/null
      grep -F 'Refusing to derive expected hash from actual path contents.' "$wrapper" >/dev/null
      grep -F 'registered NAR hash:' "$wrapper" >/dev/null
      grep -F 'nix-store -qR %q' "$wrapper" >/dev/null
      grep -F 'nix-store --repair-path %q' "$wrapper" >/dev/null
      grep -F -- '--from "$remote_store_uri"' "$wrapper" >/dev/null

      unlock_wrapper=${self'.packages.unlock-luks}/bin/unlock-luks
      grep -F 'ignitix-unlock-luks' "$unlock_wrapper" >/dev/null
      grep -F 'target_host' "$unlock_wrapper" >/dev/null
      grep -F -- '--host-key-sha256' "$unlock_wrapper" >/dev/null

      enroll_wrapper=${self'.packages.enroll-tpm2-pin}/bin/enroll-tpm2-pin
      grep -F 'enroll-tpm2-pin' "$enroll_wrapper" >/dev/null
      grep -F 'target_host' "$enroll_wrapper" >/dev/null
      grep -F -- '--remote-helper' "$enroll_wrapper" >/dev/null

      touch "$out"
    '';

    checks.split-disko-trust-layer = pkgs.runCommand "split-disko-trust-layer" {
      nativeBuildInputs = [
        pkgs.bash
        pkgs.coreutils
        pkgs.gawk
        pkgs.gnugrep
        pkgs.jq
      ];
    } ''
      TRUST_LAYER=${./split-disko-trust-layer.sh} \
        bash ${./split-disko-trust-layer-test.sh}
    '';
  };
}
