# Ignitix

Ignitix is a reusable Nix flake for NixOS install media and host-oriented
install workflows. It gives downstream flakes a place to define bootable
installer images, `nixos-anywhere` wrappers, and route-aware host install
commands without copying shell glue between repositories.

The first-class use case is canix-style infrastructure: host metadata lives in
the downstream flake, while Ignitix supplies the reusable modules and wrapper
machinery.

Ignitix currently provides:

- flake-parts modules for install media and install targets
- a ROCKPro64 installer catalog entry
- a ROCKPro64 NixOS module for serial-console installer handoff
- USB-C gadget networking helpers for headless board bootstrap
- install, mount, rescue, and hardware-probe wrapper outputs

Source: <https://codeberg.org/caniko/ignitix>

