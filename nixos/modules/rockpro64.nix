{
  config,
  inputs,
  lib,
  ...
}: let
  cfg = config.ignitix.hardware.rockpro64;
  towBootSerialKernelParams = [
    "console=ttyS2,115200n8"
    "earlycon=uart8250,mmio32,0xff1a0000,115200n8"
  ];
in {
  imports = [
    inputs.nixos-hardware.nixosModules.pine64-rockpro64
  ];

  options.ignitix.hardware.rockpro64 = {
    towBootSerialHandoff = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to force the local Tow-Boot-compatible 115200 serial handoff
        instead of relying on the board's default Rockchip serial console path.
      '';
    };

    serialKernelParams = lib.mkOption {
      type = with lib.types; listOf str;
      readOnly = true;
      default =
        if cfg.towBootSerialHandoff
        then towBootSerialKernelParams
        else [];
      description = ''
        Shared RockPro64 serial kernel parameters for the selected installer
        console handoff mode.
      '';
    };
  };

  config = {
    hardware.rockpro64.console = "serial";

    hardware.deviceTree.overlays = lib.mkIf cfg.towBootSerialHandoff [
      {
        name = "rockpro64-serial-console";
        filter = "rk3399-rockpro64.dtb";
        dtsText = ''
          /dts-v1/;
          /plugin/;

          / {
            compatible = "pine64,rockpro64-v2.1", "pine64,rockpro64", "rockchip,rk3399";
          };

          &{/chosen} {
            stdout-path = "serial2:115200n8";
          };
        '';
      }
    ];

    boot.kernelParams = lib.mkIf cfg.towBootSerialHandoff (
      lib.mkBefore cfg.serialKernelParams
    );
  };
}
