{
  inputs,
  lib,
  ...
}: let
  ignitixLib = import ../lib {
    inherit
      inputs
      lib
      ;
  };
in {
  imports = [
    ./fixture.nix
    ./install-media.nix
    ./install-targets.nix
  ];

  flake = {
    flakeModules."install-media" = ./install-media.nix;
    flakeModules."install-targets" = ./install-targets.nix;
    lib = ignitixLib;
    nixosModules.rockpro64 = ../nixos/modules/rockpro64.nix;
  };
}
