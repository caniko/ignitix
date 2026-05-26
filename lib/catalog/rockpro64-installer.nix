{
  inputs,
  installMediaLib,
  lib,
}:
{
  extraModules ? [],
  hostname ? "rockpro64-installer",
  packageName ? "rockpro64",
  towBootSerialHandoff ? true,
  minimalHeadlessInitrd ? true,
  rootAuthorizedKeys,
  usbGadget ? {},
}: let
  usbGadgetDefaults = {
    endpointHost = "10.55.0.1";
    ipv4Address = "10.55.0.1/24";
    ipv4Gateway = "10.55.0.2";
    ipv4Dns = "1.1.1.1";
    ipv4RouteMetric = "2048";

    # 02 marks locally administered MACs; 63:61:6e is ASCII "can".
    # These defaults are intended for one point-to-point USB-C OTG link.
    deviceMac = "02:63:61:6e:00:01";
    hostMac = "02:63:61:6e:00:02";
  };
  resolvedUsbGadget = usbGadgetDefaults // usbGadget;

  commonKernelParams = [
    "keep_bootcon"
    "ignore_loglevel"
    "nohibernate"
    "loglevel=7"
    "lsm=landlock,yama,bpf"
  ];
in
installMediaLib.mkInstallerMedia {
  inherit
    hostname
    packageName
    rootAuthorizedKeys
    ;

  system = "aarch64-linux";
  imageModule =
    inputs.nixpkgs + "/nixos/modules/installer/sd-card/sd-image-aarch64-installer.nix";
  nixosAnywhere = {
    enable = true;
    targetUser = "root";
    targetPort = 22;
    phases = [
      "disko"
      "install"
      "reboot"
    ];
    noDiskoDeps = true;
    endpoints.usb.host = resolvedUsbGadget.endpointHost;
  };

  modules =
    [
      ../../nixos/modules/nixos-facter-overlay.nix
      ../../nixos/modules/rockpro64.nix
      ({config, lib, ...}:
        lib.mkMerge [
          {
            ignitix.hardware.rockpro64.towBootSerialHandoff = towBootSerialHandoff;

            system.installer.channel.enable = false;
            boot.zfs.forceImportRoot = false;
            programs.fuse.enable = lib.mkForce false;
            hardware.bluetooth.enable = lib.mkForce false;
            hardware.fancontrol.enable = lib.mkForce false;

            boot.blacklistedKernelModules = [
              "bluetooth"
              "btbcm"
              "hci_uart"
              "brcmfmac"
              "cfg80211"
              "rfkill"
            ];

            hardware.deviceTree.overlays = [
              {
                name = "rockpro64-disable-pcie";
                filter = "rk3399-rockpro64.dtb";
                dtsText = ''
                  /dts-v1/;
                  /plugin/;

                  / {
                    compatible = "pine64,rockpro64-v2.1", "pine64,rockpro64", "rockchip,rk3399";
                  };

                  &{/pcie@f8000000} {
                    status = "disabled";
                  };
                '';
              }
            ];

            boot.kernelParams =
              if towBootSerialHandoff
              then
                lib.mkForce (
                  config.ignitix.hardware.rockpro64.serialKernelParams
                  ++ commonKernelParams
                )
              else
                lib.mkAfter commonKernelParams;
          }
          (lib.mkIf minimalHeadlessInitrd {
            # Keep the installer focused on headless bootstrap over Ethernet/USB-C
            # rather than probing optional desktop/NVMe hardware during initrd.
            boot.initrd.kernelModules = lib.mkForce [
              "dm_mod"
              "dwmac_rk"
            ];
          })
        ])
      (installMediaLib.mkRockpro64UsbEthernetGadgetModule {
        name = "rockpro64-usb-c-gadget";
        inherit (resolvedUsbGadget)
          deviceMac
          hostMac
          ipv4Address
          ipv4Dns
          ipv4Gateway
          ipv4RouteMetric
          ;
      })
    ]
    ++ extraModules;
}
