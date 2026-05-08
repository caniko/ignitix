# Install Targets

Install targets describe hosts that can be reached through one or more install
routes. A target binds host metadata to a selected install medium and a target
NixOS configuration.

The install target module exposes host-first wrappers:

- `install` for `nixos-anywhere` installs
- `smount` for mounting an existing disko layout through installer media
- `rescue` for mounting and reinstalling into an existing layout
- `probe-hardware` for hardware report capture

Routes are semantic names such as `lan`, `usb`, or `vpn`. Each route resolves a
target host from explicit route data, media endpoints, or downstream host
metadata.

