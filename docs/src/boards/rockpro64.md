# RockPro64

Ignitix includes ROCKPro64 support for headless NixOS installer workflows.

The ROCKPro64 module imports the upstream `nixos-hardware` profile, selects a
serial console, and can force a Tow-Boot-compatible serial handoff using:

```text
console=ttyS2,115200n8
earlycon=uart8250,mmio32,0xff1a0000,115200n8
```

The catalog installer also:

- disables optional desktop and wireless paths that are not needed for the
  headless installer
- disables PCIe probing for the focused installer image
- configures USB-C gadget networking through NetworkManager
- exposes a USB endpoint for `nixos-anywhere` routes

The default catalog helper is:

```nix
inputs.ignitix.lib.catalog.rockpro64Installer {
  rootAuthorizedKeys = [
    "ssh-ed25519 AAAA..."
  ];
}
```

