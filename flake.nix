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
    nixos-anywhere.url = "github:nix-community/nixos-anywhere";

    nixos-hardware.url = "github:NixOS/nixos-hardware";
    plinth = {
      url = "git+https://codeberg.org/caniko/plinth.git?ref=refs/heads/trunk";
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
        system,
        ...
      }: let
        website = inputs.plinth.lib.${system}.mkProjectSite {
          pname = "ignitix-website";
          domain = "ignitix.tartanoglu.com";
          configPath = ./website/plinth-project.toml;
        };
      in {
        packages.website = website;
        packages.site = lib.mkForce website;
        apps.deploy-pages = inputs.plinth.lib.${system}.mkDeployPagesApp {
          domain = "ignitix.tartanoglu.com";
        };
      };
    };
}
