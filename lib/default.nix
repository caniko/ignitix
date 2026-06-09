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
      raspberryPi3BPlusSdImage =
        import ./catalog/raspberrypi3bplus-sd-image.nix {
          inherit
            inputs
            installMediaLib
            lib
            ;
        };
    };
  }
