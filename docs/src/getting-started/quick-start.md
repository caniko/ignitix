# Quick Start

Ignitix ships a fixture ROCKPro64 installer definition. Build it from the
repository root:

```sh
nix build .#example-rockpro64
```

Use the catalog helper from another flake when defining real installer media:

```nix
ignitix.installMedia.rockpro64-installer =
  inputs.ignitix.lib.catalog.rockpro64Installer {
    hostname = "rockpro64-installer";
    packageName = "rockpro64";
    rootAuthorizedKeys = [
      "ssh-ed25519 AAAA..."
    ];
  };
```

When `nixosAnywhere.enable` is true, Ignitix also exposes install wrapper
packages and apps for that media.

For a generic x86_64 rescue or installer ISO, use `mkInstallerMedia` with the
NixOS minimal CD module:

```nix
ignitix.installMedia.rescue = inputs.ignitix.lib.mkInstallerMedia {
  system = "x86_64-linux";
  imageModule = inputs.nixpkgs + "/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix";
  rootAuthorizedKeys = ["ssh-ed25519 AAAA..."];
  nixosAnywhere.enable = false;
};
```

The resulting package is an ISO exposed through `system.build.image`.
