{inputs, ...}: {
  perSystem = {pkgs, ...}: let
    craneLib = inputs.crane.mkLib pkgs;
    src = craneLib.cleanCargoSource ../.;
    guiRuntimeLibs = [
      pkgs.fontconfig
      pkgs.freetype
      pkgs.libx11
      pkgs.libxcb
      pkgs.libxcursor
      pkgs.libxi
      pkgs.libxkbcommon
      pkgs.libxrandr
      pkgs.wayland
    ];
    commonArgs = {
      inherit src;
      pname = "ignitix-unlock-luks";
      version = "0.1.0";
      strictDeps = true;
      nativeBuildInputs = [pkgs.pkg-config];
      buildInputs = guiRuntimeLibs ++ [pkgs.wayland-protocols];
    };
    cargoArtifacts = craneLib.buildDepsOnly commonArgs;
    package = craneLib.buildPackage (commonArgs
      // {
        inherit cargoArtifacts;
        nativeBuildInputs = commonArgs.nativeBuildInputs ++ [pkgs.makeWrapper];
        postInstall = ''
          wrapProgram "$out/bin/ignitix-unlock-luks" \
            --prefix LD_LIBRARY_PATH : ${pkgs.lib.makeLibraryPath guiRuntimeLibs} \
            --prefix PATH : ${pkgs.lib.makeBinPath [pkgs.cryptsetup pkgs.openssh pkgs.systemd]}
        '';
        meta.mainProgram = "ignitix-unlock-luks";
      });
  in {
    packages.ignitix-unlock-luks = package;
    apps.ignitix-unlock-luks = {
      type = "app";
      program = "${package}/bin/ignitix-unlock-luks";
    };
    checks = {
      ignitix-unlock-luks-tests = craneLib.cargoTest (commonArgs // {inherit cargoArtifacts;});
      ignitix-unlock-luks-clippy = craneLib.cargoClippy (commonArgs
        // {
          inherit cargoArtifacts;
          cargoClippyExtraArgs = "--all-targets -- --deny warnings";
        });
      ignitix-unlock-luks-fmt = craneLib.cargoFmt {inherit src;};
    };
  };
}
