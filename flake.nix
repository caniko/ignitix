{
  description = "ignitix: reusable install-media flake";

  inputs = {
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };

    crane = {
      url = "github:ipetkov/crane";
    };

    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    treefmt-nix.follows = "bootswain/harbor-rs/treefmt-nix";
    nixos-anywhere.url = "github:nix-community/nixos-anywhere";

    nixos-hardware.url = "github:NixOS/nixos-hardware";
    bootswain = {
      url = "github:caniko/bootswain";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.plinth.follows = "plinth";
    };
    plinth = {
      url = "git+https://github.com/caniko/plinth.git?ref=refs/heads/trunk";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs:
    inputs.flake-parts.lib.mkFlake {inherit inputs;} {
      systems = [
        "aarch64-linux"
        "x86_64-linux"
      ];
      imports = [./flake];
      perSystem = {
        lib,
        pkgs,
        system,
        ...
      }: let
        website = inputs.plinth.lib.${system}.mkProjectSite {
          pname = "ignitix-website";
          domain = "ignitix.tartanoglu.com";
          configPath = ./website/plinth-project.toml;
        };
      in {
        formatter = (inputs.treefmt-nix.lib.evalModule pkgs (import ./nix/treefmt.nix {rustfmtPackage = pkgs.rustfmt;})).config.build.wrapper;
        packages.website = website;
        packages.site = lib.mkForce website;
        apps.deploy-pages = inputs.plinth.lib.${system}.mkDeployPagesApp {
          domain = "ignitix.tartanoglu.com";
        };
      };
    };
}
