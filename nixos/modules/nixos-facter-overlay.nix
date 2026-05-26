{lib, ...}: {
  nixpkgs.overlays = [
    (_final: prev: {
      nixos-facter = prev.nixos-facter.overrideAttrs (old: let
        needsDownstreamUdevBusPatch = (old.version or "") == "0.4.3";
      in {
        patches =
          (old.patches or [])
          ++ lib.optionals needsDownstreamUdevBusPatch [
            ./nixos-facter-ignore-unknown-udev-bus.patch
          ];
      });
    })
  ];
}
