{
  inputs,
  lib,
}: let
  inherit (builtins) removeAttrs;
  inherit
    (lib)
    mkForce
    optionalAttrs
    ;

  supportedBuildSystems = [
    "aarch64-linux"
    "x86_64-linux"
  ];

  rockpro64UsbEthernetGadgetOverlayDtsText = ''
    /dts-v1/;
    /plugin/;

    / {
      compatible = "pine64,rockpro64-v2.1", "pine64,rockpro64", "rockchip,rk3399";
    };

    &vcc5v0_typec {
      /delete-property/ regulator-always-on;
    };

    &usbdrd3_0 {
      status = "okay";
    };

    &usbdrd_dwc3_0 {
      status = "okay";
      dr_mode = "peripheral";
    };

    &fusb0 {
      connector {
        compatible = "usb-c-connector";
        label = "USB-C";
        data-role = "device";
        power-role = "sink";
        pd-disable;
        typec-power-opmode = "default";
      };
    };

    &tcphy0 {
      status = "okay";
    };

    &tcphy0_usb3 {
      status = "okay";
    };
  '';

  mkUsbEthernetGadgetModule = {
    name,
    dtbFilter,
    controllerPath ? null,
    overlayDtsText ? null,
    interfaceName ? "usb0",
    ipv4Method ? "shared",
    ipv4Address ? "10.55.0.1/24",
    ipv4Gateway ? null,
    ipv4Dns ? null,
    ipv4RouteMetric ? null,
    deviceMac,
    hostMac,
  }: {
    pkgs,
    ...
  }: {
    hardware.deviceTree.overlays = [
      {
        inherit name;
        filter = dtbFilter;
        dtsText =
          if overlayDtsText != null
          then overlayDtsText
          else ''
            /dts-v1/;
            /plugin/;

            &{${controllerPath}} {
              dr_mode = "peripheral";
            };
          '';
      }
    ];

    networking.firewall.trustedInterfaces = [interfaceName];

    networking.networkmanager.ensureProfiles.profiles.usb-gadget = {
      connection = {
        id = "usb-gadget";
        type = "ethernet";
        interface-name = interfaceName;
        autoconnect = "true";
        autoconnect-priority = "100";
      };
      ipv4 =
        {
          method = ipv4Method;
          addresses = ipv4Address;
        }
        // lib.optionalAttrs (ipv4Gateway != null) {
          gateway = ipv4Gateway;
        }
        // lib.optionalAttrs (ipv4Dns != null) {
          dns = ipv4Dns;
        }
        // lib.optionalAttrs (ipv4RouteMetric != null) {
          route-metric = ipv4RouteMetric;
        };
      ipv6.method = "disabled";
    };

    systemd.services.usb-ether-gadget = {
      description = "Enable USB ethernet gadget";
      wantedBy = ["multi-user.target"];
      after = ["systemd-udev-settle.service"];
      wants = ["systemd-udev-settle.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        for module in \
          dwc3 \
          dwc3-of-simple \
          phy_rockchip_inno_usb2 \
          phy_rockchip_typec \
          fusb302 \
          tcpm \
          typec \
          roles \
          libcomposite \
          usb_f_ecm \
          usb_f_rndis; do
          ${pkgs.kmod}/bin/modprobe "$module" 2>/dev/null || true
        done

        udc_names=""
        for _ in $(${pkgs.coreutils}/bin/seq 1 20); do
          udc_names="$(${pkgs.coreutils}/bin/ls -A /sys/class/udc 2>/dev/null || true)"
          if [ -n "$udc_names" ]; then
            break
          fi
          ${pkgs.coreutils}/bin/sleep 1
        done

        if [ -z "$udc_names" ]; then
          echo "No USB device controller found for gadget mode" >&2
          echo "Available USB role-switch devices:" >&2
          ${pkgs.coreutils}/bin/find /sys/class/usb_role -maxdepth 2 -type f -print -exec ${pkgs.coreutils}/bin/cat {} \; 2>/dev/null >&2 || true
          echo "Recent USB gadget kernel messages:" >&2
          ${pkgs.systemd}/bin/journalctl -k -b --no-pager 2>/dev/null \
            | ${pkgs.gnugrep}/bin/grep -Ei 'dwc3|udc|g_ether|usb-role|role-switch|typec|fusb|tcpm|configfs|libcomposite' >&2 || true
          exit 1
        fi

        echo "USB gadget UDC(s): $udc_names"

        ${pkgs.kmod}/bin/modprobe g_ether \
          dev_addr=${deviceMac} \
          host_addr=${hostMac}

        for _ in $(${pkgs.coreutils}/bin/seq 1 20); do
          if [ -d /sys/class/net/${interfaceName} ]; then
            break
          fi
          ${pkgs.coreutils}/bin/sleep 1
        done

        if [ ! -d /sys/class/net/${interfaceName} ]; then
          echo "Loaded g_ether but ${interfaceName} did not appear. Check OTG role-switch wiring and the USB-C data path." >&2
          echo "Current network interfaces:" >&2
          ${pkgs.iproute2}/bin/ip -br link >&2 || true
          exit 1
        fi
      '';
    };

    systemd.services.usb-ether-gadget-network = {
      description = "Bring up USB ethernet gadget networking";
      wantedBy = ["multi-user.target"];
      after = [
        "usb-ether-gadget.service"
        "NetworkManager.service"
      ];
      wants = [
        "usb-ether-gadget.service"
        "NetworkManager.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        for _ in $(${pkgs.coreutils}/bin/seq 1 20); do
          if [ -d /sys/class/net/${interfaceName} ]; then
            break
          fi
          ${pkgs.coreutils}/bin/sleep 1
        done

        if [ ! -d /sys/class/net/${interfaceName} ]; then
          echo "No ${interfaceName} interface found for USB gadget networking" >&2
          exit 1
        fi

        ${pkgs.iproute2}/bin/ip link set dev ${interfaceName} up

        ${pkgs.networkmanager}/bin/nmcli connection reload
        if ! ${pkgs.networkmanager}/bin/nmcli connection up usb-gadget ifname ${interfaceName}; then
          ${pkgs.iproute2}/bin/ip addr replace ${ipv4Address} dev ${interfaceName}
${lib.optionalString (ipv4Gateway != null) ''
          ${pkgs.iproute2}/bin/ip route replace default via ${ipv4Gateway} dev ${interfaceName}${lib.optionalString (ipv4RouteMetric != null) " metric ${ipv4RouteMetric}"}
''}${lib.optionalString (ipv4Dns != null) ''
          ${pkgs.systemd}/bin/resolvectl dns ${interfaceName} ${ipv4Dns}
''}
        fi
      '';
    };
  };

  mkRockpro64UsbEthernetGadgetModule = {
    name ? "rockpro64-usb-c-gadget",
    interfaceName ? "usb0",
    ipv4Address ? "10.55.0.1/24",
    ipv4Gateway ? "10.55.0.2",
    ipv4Dns ? "10.55.0.2",
    ipv4RouteMetric ? "2048",
    deviceMac ? "02:63:61:6e:00:01",
    hostMac ? "02:63:61:6e:00:02",
  }:
    mkUsbEthernetGadgetModule {
      inherit
        deviceMac
        hostMac
        interfaceName
        ipv4Address
        ipv4Dns
        ipv4Gateway
        ipv4RouteMetric
        name
        ;
      dtbFilter = "rk3399-rockpro64.dtb";
      ipv4Method = "manual";
      overlayDtsText = rockpro64UsbEthernetGadgetOverlayDtsText;
    };

  mkInstallerMedia = {
    extraPackages ? [],
    modules ? [],
    nixosAnywhere ? {},
    rootAuthorizedKeys ? [],
    imageModule ? inputs.nixpkgs + "/nixos/modules/installer/sd-card/sd-image-aarch64-installer.nix",
    ...
  } @ args:
    (removeAttrs args [
      "extraPackages"
      "imageModule"
      "modules"
      "nixosAnywhere"
      "rootAuthorizedKeys"
    ])
    // {
      inherit imageModule;
      modules =
        [
          ({pkgs, ...}: {
            environment.defaultPackages = [pkgs.nixos-facter] ++ extraPackages;

            users.users.root = {
              initialHashedPassword = mkForce "!";
              openssh.authorizedKeys.keys = rootAuthorizedKeys;
            };

            users.users.nixos.initialHashedPassword = mkForce "!";

            services.getty = {
              autologinUser = mkForce null;
              helpLine = mkForce ''
                Login as "root" locally or over SSH using an authorized public key.
                Wired networking is managed by NetworkManager and should come up via DHCP automatically.
              '';
            };

            services.openssh = {
              openFirewall = true;
              settings = {
                PasswordAuthentication = mkForce false;
                KbdInteractiveAuthentication = mkForce false;
                PermitRootLogin = mkForce "prohibit-password";
              };
            };
          })
        ]
        ++ modules;

      nixosAnywhere =
        {
          enable = true;
          targetUser = "root";
          targetPort = 22;
          phases = [
            "disko"
            "install"
            "reboot"
          ];
          noDiskoDeps = true;
          sshOptions = [
            "StrictHostKeyChecking=no"
            "UserKnownHostsFile=/dev/null"
          ];
          endpoints = {};
        }
        // nixosAnywhere
        // optionalAttrs (nixosAnywhere ? endpoints) {
          endpoints = nixosAnywhere.endpoints;
        };
    };
in {
  inherit
    mkInstallerMedia
    mkRockpro64UsbEthernetGadgetModule
    mkUsbEthernetGadgetModule
    rockpro64UsbEthernetGadgetOverlayDtsText
    supportedBuildSystems
    ;
}
