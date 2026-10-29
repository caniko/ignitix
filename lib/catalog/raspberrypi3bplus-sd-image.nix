{
  inputs,
  installMediaLib,
  lib,
}: {
  extraModules ? [],
  hostname,
  packageName ? "${hostname}-sd-image",
  rootAuthorizedKeys ? [],
}: let
  inherit (lib) mkForce;
in
  installMediaLib.mkSdCardImage {
    inherit
      hostname
      packageName
      rootAuthorizedKeys
      ;

    system = "aarch64-linux";
    imageModule = inputs.nixpkgs + "/nixos/modules/installer/sd-card/sd-image-aarch64.nix";

    modules =
      [
        ../../nixos/modules/raspberrypi3bplus.nix
        ({pkgs, ...}: {
          image.baseName = mkForce packageName;

          # bootswain owns the board firmware (bootcode, start/fixup, DTBs,
          # U-Boot, config.txt). linkFarm entries are symlinks into the store,
          # so dereference and drop store modes for mcopy.
          sdImage.populateFirmwareCommands = mkForce ''
            cp -rL --no-preserve=mode ${inputs.bootswain.packages.${pkgs.stdenv.buildPlatform.system}.raspberrypi3bplus-firmware}/. firmware/
          '';
        })
      ]
      ++ extraModules;
  }
