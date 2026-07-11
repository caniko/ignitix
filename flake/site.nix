{
  lib,
  ...
}: {
  perSystem = {pkgs, ...}: let
    website = pkgs.stdenv.mkDerivation {
      pname = "ignitix-website";
      version = "0.1.0";
      src = lib.fileset.toSource {
        root = ../website;
        fileset = lib.fileset.maybeMissing ../website;
      };
      nativeBuildInputs = [pkgs.zola];
      phases = ["buildPhase" "installPhase"];
      buildPhase = ''
        cp -r --no-preserve=mode $src site
        cd site
        zola build
      '';
      installPhase = ''
        cp -r public $out
      '';
    };

    docs = pkgs.stdenv.mkDerivation {
      pname = "ignitix-docs";
      version = "0.1.0";
      src = lib.fileset.toSource {
        root = ../docs;
        fileset = lib.fileset.maybeMissing ../docs;
      };
      nativeBuildInputs = [pkgs.mdbook];
      phases = ["buildPhase" "installPhase"];
      buildPhase = ''
        cp -r --no-preserve=mode $src docs
        mdbook build docs
      '';
      installPhase = ''
        cp -r docs/book $out
      '';
    };
  in {
    packages = {
      inherit
        docs
        ;

      site = pkgs.runCommand "ignitix-site" {} ''
        mkdir -p $out
        mkdir -p $out/docs
        cp -r ${docs}/* $out/docs/
      '';
    };

    devShells.default = pkgs.mkShell {
      packages = [
        pkgs.mdbook
      ];

      shellHook = ''
        echo "Website: cd website && zola serve"
        echo "Documentation: cd docs && mdbook serve"
      '';
    };
  };
}
