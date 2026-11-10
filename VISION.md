# Ignitix vision

Ignitix is a reusable Nix flake for NixOS install media and install workflows.
Downstream flakes keep their own host metadata and installation policy; Ignitix
supplies the flake-parts modules, `nixos-anywhere` wrappers, and host-oriented
install targets so that bootstrapping a machine does not mean copying shell glue
between repositories. The documented first-class use case is fleet-style
infrastructure, with the ROCKPro64 installer (serial console plus USB-C gadget
networking) as the working board entry.

## Problem

Installing NixOS on real hardware, especially a headless board, needs
board-specific image definitions, a console and network path that works before
the OS is up, and a wrapper around `nixos-anywhere`. Those pieces usually live
per infrastructure repository, where they drift and are not tested together.
Downstream flakes need a shared place to declare installer media while their
own host facts stay local.

## Principles

- **Install policy belongs downstream.** Ignitix exposes modules, wrappers, and
  library helpers; the consuming flake supplies host metadata.
- **Headless bootstrap is a first-class path.** The ROCKPro64 entry provides a
  serial console and USB-C gadget networking, so a board without a display can
  be installed.
- **Board firmware comes from a pinned source.** Where a board needs firmware
  built from source, the installer builds it from a pinned revision rather than
  using whatever the build host happens to have; the Raspberry Pi 3 work takes
  it from bootswain.
- **Small composable outputs.** Install media modules, install targets, and
  library helpers stay separate so a consumer takes only what it needs.

## Scope

- flake-parts modules for install media and install targets
- ROCKPro64 installer catalog entry and NixOS module
- USB-C gadget networking helpers for headless board bootstrap
- install, mount, rescue, and hardware-probe wrapper outputs
- remote LUKS unlock operations (`ignitix-unlock-luks`)
- Raspberry Pi 3 image firmware built from bootswain, on the current branch

## Direction

The visible direction is broader board and bootstrap coverage: generic
installer images and secure remote LUKS operations were added recently, and the
current branch tracks bootswain trunk with Raspberry Pi 3 family firmware
alongside the existing ROCKPro64 entry.

## Place in the fleet

Canix declares Ignitix as a flake input and lists it among the registry input
names in `root/modules/config/nix.nix`, so registry-aware install flows can
resolve it.
