{
  inputs,
  installMediaLib,
  lib,
}:
{
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
        {
          image.baseName = mkForce packageName;
        }
      ]
      ++ extraModules;
  }
