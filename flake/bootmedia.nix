{inputs, ...}: {
  perSystem = {pkgs, ...}: let
    craneLib = inputs.crane.mkLib pkgs;
    src = pkgs.lib.fileset.toSource {
      root = ../.;
      fileset = pkgs.lib.fileset.unions [
        (craneLib.fileset.commonCargoSources ../.)
        ../bootmedia/tests/disk-diagnose-v1.json
      ];
    };
    commonArgs = {
      inherit src;
      pname = "ignitix-bootmedia";
      version = "0.1.0";
      strictDeps = true;
      cargoExtraArgs = "--locked -p ignitix-bootmedia";
    };
    cargoArtifacts = craneLib.buildDepsOnly commonArgs;
    package = craneLib.buildPackage (commonArgs
      // {
        inherit cargoArtifacts;
        nativeBuildInputs = [pkgs.makeWrapper];
        postInstall = ''
          wrapProgram "$out/bin/ignitix-bootmedia" \
            --prefix PATH : ${pkgs.lib.makeBinPath [pkgs.nix]}
        '';
        meta.mainProgram = "ignitix-bootmedia";
      });
  in {
    packages.ignitix-bootmedia = package;
    apps.ignitix-bootmedia = {
      type = "app";
      program = "${package}/bin/ignitix-bootmedia";
    };
    checks.ignitix-bootmedia-tests = craneLib.cargoTest (commonArgs // {inherit cargoArtifacts;});
  };
}
