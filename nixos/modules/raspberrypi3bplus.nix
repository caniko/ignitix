{
  inputs,
  lib,
  pkgs,
  ...
}: {
  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";

  hardware.enableRedistributableFirmware = lib.mkDefault true;
  hardware.firmware = lib.mkDefault [
    (pkgs.callPackage "${inputs.nixos-hardware}/raspberry-pi/common/raspberry-pi-wireless-firmware.nix" {})
  ];

  boot.loader.grub.enable = lib.mkDefault false;
  boot.loader.systemd-boot.enable = lib.mkDefault false;
  boot.loader.generic-extlinux-compatible.enable = lib.mkDefault true;

  boot.kernelParams = lib.mkForce [
    "console=ttyAMA0,115200n8"
    "console=tty0"
  ];
}
