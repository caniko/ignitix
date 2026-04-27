{
  description = "ignitix: reusable install-media flake";

  inputs = {
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };

    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-anywhere.url = "github:nix-community/nixos-anywhere";

    nixos-hardware.url = "github:NixOS/nixos-hardware";
  };

  outputs = inputs:
    inputs.flake-parts.lib.mkFlake {inherit inputs;} {
      systems = [
        "aarch64-linux"
        "x86_64-linux"
      ];
      imports = [./flake];
    };
}
