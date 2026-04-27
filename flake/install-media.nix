{
  config,
  inputs,
  lib,
  self,
  withSystem,
  ...
}: let
  inherit
    (lib)
    concatMapStringsSep
    escapeShellArg
    foldl'
    genAttrs
    mapAttrs
    mapAttrsToList
    mkIf
    mkMerge
    mkOption
    recursiveUpdate
    types
    ;

  cfg = config.ignitix.installMedia;
  installMediaLib = import ../lib {
    inherit lib;
    inherit inputs;
  };

  mediaConfigurations = mapAttrs
    (
      name: value:
        withSystem value.system (
          {
            inputs',
            self',
            ...
          }:
            inputs.nixpkgs.lib.nixosSystem {
              modules =
                [
                  value.imageModule
                  {
                    system.stateVersion = "25.11";

                    networking.hostName = lib.mkForce value.hostname;
                    nixpkgs.hostPlatform = value.system;

                    image.baseName = name;
                  }
                ]
                ++ value.modules;

              specialArgs = {
                inherit
                  inputs
                  inputs'
                  self
                  self'
                  ;
                hostname = value.hostname;
              };
            }
        )
    )
    cfg;

  mediaPackages =
    foldl'
    recursiveUpdate
    {}
    (mapAttrsToList (
      name: value:
        genAttrs installMediaLib.supportedBuildSystems (_: {
          ${value.packageName} = mediaConfigurations.${name}.config.system.build.sdImage;
        })
    )
    cfg);

  nixosAnywherePackages = genAttrs installMediaLib.supportedBuildSystems (
    buildSystem: {
      nixos-anywhere = inputs.nixos-anywhere.packages.${buildSystem}.default;
    }
  );

  mediaInstallPackages =
    foldl'
    recursiveUpdate
    {}
    (mapAttrsToList (
      name: value:
        if !value.nixosAnywhere.enable
        then {}
        else
          genAttrs installMediaLib.supportedBuildSystems (
            buildSystem: let
              pkgs = inputs.nixpkgs.legacyPackages.${buildSystem};
              nixosAnywherePkg =
                if inputs ? nixos-anywhere
                then inputs.nixos-anywhere.packages.${buildSystem}.default
                else inputs.ignitix.packages.${buildSystem}.nixos-anywhere;
              nixosAnywhereCfg = value.nixosAnywhere;
              phasesCsv = lib.concatStringsSep "," nixosAnywhereCfg.phases;
              sshOptionLines = concatMapStringsSep "\n" (
                option: ''
                  ssh_option=${escapeShellArg option}
                  args+=(--ssh-option)
                  args+=("$ssh_option")
                ''
              ) nixosAnywhereCfg.sshOptions;
            in {
              ${"install-${name}"} = pkgs.writeShellApplication {
                name = "install-${name}";
                runtimeInputs = [nixosAnywherePkg];
                text = ''
                  set -euo pipefail

                  target_port=${escapeShellArg (toString nixosAnywhereCfg.targetPort)}
                  phases_csv=${escapeShellArg phasesCsv}

                  args=()
                  args+=(--ssh-port)
                  args+=("$target_port")
                  args+=(--phases)
                  args+=("$phases_csv")

                  ${lib.optionalString nixosAnywhereCfg.noDiskoDeps ''
                    args+=(--no-disko-deps)
                  ''}
                  ${sshOptionLines}

                  exec nixos-anywhere "''${args[@]}" "$@"
                '';
              };
            }
          )
    )
    cfg);

  mediaInstallApps =
    foldl'
    recursiveUpdate
    {}
    (mapAttrsToList (
      name: value:
        if !value.nixosAnywhere.enable
        then {}
        else
          genAttrs installMediaLib.supportedBuildSystems (buildSystem: {
            ${"install-${name}"} = {
              type = "app";
              program = "${mediaInstallPackages.${buildSystem}.${"install-${name}"}}/bin/install-${name}";
            };
          })
    )
    cfg);
in {
  options.ignitix.installMedia = mkOption {
    type = types.attrsOf (types.submodule ({name, ...}: {
      options = {
        system = mkOption {
          type = types.enum lib.systems.flakeExposed;
          example = "aarch64-linux";
          description = ''
            Target system architecture for this bootable media.
          '';
        };

        hostname = mkOption {
          type = types.str;
          default = name;
          description = ''
            Runtime hostname configured inside the media image.
          '';
        };

        imageModule = mkOption {
          type = types.deferredModule;
          description = ''
            Upstream NixOS image/profile module used as the base image.
          '';
        };

        modules = mkOption {
          type = with types; listOf deferredModule;
          default = [];
          description = ''
            NixOS modules layered on top of the base image module.
          '';
        };

        packageName = mkOption {
          type = types.str;
          default = "${name}-image";
          description = ''
            Flake package attribute name that exposes this media image.
          '';
        };

        nixosAnywhere = mkOption {
          type = types.submodule {
            options = {
              enable = mkOption {
                type = types.bool;
                default = false;
                description = ''
                  Whether to expose nixos-anywhere wrapper outputs for this media.
                '';
              };

              targetUser = mkOption {
                type = types.str;
                default = "root";
                description = ''
                  Default SSH user for nixos-anywhere installs through this media.
                '';
              };

              targetPort = mkOption {
                type = types.port;
                default = 22;
                description = ''
                  Default SSH port for nixos-anywhere installs through this media.
                '';
              };

              phases = mkOption {
                type = with types; listOf str;
                default = [];
                description = ''
                  Default nixos-anywhere phases for this media wrapper.
                '';
              };

              noDiskoDeps = mkOption {
                type = types.bool;
                default = false;
                description = ''
                  Whether to pass --no-disko-deps by default.
                '';
              };

              sshOptions = mkOption {
                type = with types; listOf str;
                default = [];
                description = ''
                  Default SSH options forwarded to nixos-anywhere.
                '';
              };

              endpoints = mkOption {
                type = types.attrsOf (types.submodule {
                  options.host = mkOption {
                    type = types.str;
                    description = ''
                      Resolved host or IP for a named installer endpoint.
                    '';
                  };
                });
                default = {};
                description = ''
                  Named installer endpoints published by this media.
                '';
              };
            };
          };
          default = {};
          description = ''
            Optional nixos-anywhere wrapper metadata for this media entry.
          '';
        };
      };
    }));
    default = {};
    description = ''
      Bootable media definitions expanded into flake NixOS configurations and
      image packages.
    '';
  };

  config = mkMerge (
    (map (buildSystem: {
        flake.packages.${buildSystem}.nixos-anywhere = nixosAnywherePackages.${buildSystem}.nixos-anywhere;
      })
      installMediaLib.supportedBuildSystems)
    ++ [
      (mkIf (cfg != {}) {
        flake = {
          apps = mediaInstallApps;
          installMediaResolved = cfg;
          nixosConfigurations = mediaConfigurations;
          packages = recursiveUpdate mediaPackages mediaInstallPackages;
        };
      })
    ]
  );
}
