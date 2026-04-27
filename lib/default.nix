{
  inputs,
  lib,
}: let
  installMediaLib = import ./install-media.nix {inherit inputs lib;};
in
  installMediaLib
  // {
    catalog = {
      rockpro64Installer =
        import ./catalog/rockpro64-installer.nix {
          inherit
            inputs
            installMediaLib
            lib
            ;
        };
    };
  }
