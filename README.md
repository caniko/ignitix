# Ignitix

<!-- simit:badges:start -->

[![CI](https://img.shields.io/badge/CI-drift-2088ff)](https://github.com/caniko/fleet/actions) [![docs](https://img.shields.io/badge/docs-enabled-6f42c1)](docs)

<!-- simit:badges:end -->

`ignitix` is a reusable Nix flake for building install media and install
workflows around NixOS. It packages board-specific installer images,
`nixos-anywhere` wrappers, and host-oriented install targets so downstream
flakes can keep installation policy close to their infrastructure code.

The current focus is pragmatic:

- reusable install-media definitions exposed through flake-parts modules
- ROCKPro64 installer media with serial console and USB-C gadget networking
- host-first install target wrappers for install, mount, rescue, and hardware
  probing workflows
- library helpers for downstream flakes

## Quick Start

Add `ignitix` to a flake and import the install-media module:

```nix
{
  inputs.ignitix.url = "git+https://github.com/caniko/ignitix.git";

  outputs = {
    ignitix,
    ...
  }: {
    imports = [
      ignitix.flakeModules."install-media"
    ];
  };
}
```

Build the bundled fixture image:

```sh
nix build .#example-rockpro64
```

## ROCKPro64

Ignitix includes a ROCKPro64 NixOS module and installer catalog entry. The
installer is designed for headless bootstrap with serial console visibility,
USB-C gadget networking, and `nixos-anywhere` wrappers.

`lib.catalog.rockpro64Installer` ships USB-C gadget defaults for a single
point-to-point `10.55.0.0/24` install link. The default synthetic MAC addresses
use locally administered `02:63:61:6e:*` values and are safe for one installer
per USB link; override `usbGadget` fields when a different link layout is
needed.

Install-target wrappers default their first-install SSH options to skip host-key
files. For cloud/public bootstrap, set
`ignitix.installTargets.<name>.nixosAnywhere.bootstrapHostKey` to the installer's
ED25519 public key verified through the provider console or another independently
authenticated channel. The resolved target supplies an immutable `known_hosts`
file, strict key checking, key-only authentication and fresh SSH connections for
install, probe, mount and downstream key-reading clients. One identity covers all
declared bootstrap routes and ports. The installed runtime key is enrolled
separately after reading it over that verified bootstrap connection.

`nixosAnywhere.sshOptions` remains available for additional options; bootstrap
trust takes precedence. Media-specific install wrappers honor explicit caller
trust ahead of their first-install defaults. Ignitix carries a source patch for
the pinned `nixos-anywhere`: its original default SSH options preceded caller
options, so OpenSSH ignored an explicit `StrictHostKeyChecking=yes`. The
`nixos-anywhere-ssh-options` check runs the real argument parser and verifies
OpenSSH's effective configuration; `install-target-bootstrap-trust` checks the
resolved target and public-key file. Null bootstrap identity retains the legacy
first-install behavior. These checks do not prove an actual install, kexec
identity continuity or runtime-key enrollment; those require an integration VM.

Bootswain fully supports bidirectional ROCKPro64 serial workflows: it can read
boot logs from board `TXD` and send U-Boot commands through board `RXD`.

## Development

```sh
nix develop
nix flake check
nix build .#site
```

The project website builds with Zola and the documentation builds with mdBook.
The combined static-site output is exposed as `.#site`.

## License

Licensed under either of:

- Apache License, Version 2.0
- MIT license

at your option.
