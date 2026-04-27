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
  ignitix.installMedia.example-rockpro64-installer =
    ignitixLib.catalog.rockpro64Installer {
      hostname = "example-rockpro64-installer";
      packageName = "example-rockpro64";
      rootAuthorizedKeys = [];
    };
}
