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

`flakeAttr` may name any entry under `nixosConfigurations`, not only the
install target name. This is useful for downstream flakes that expose a
separate build-oriented configuration for the same host, such as a cross-build
configuration used from a faster native builder.

The selected configuration must be install-compatible with `nixos-anywhere`.
At minimum it needs:

- `config.system.build.toplevel`
- `config.system.build.diskoScript` or `config.system.build.diskoScriptNoDeps`,
  depending on the selected install-media wrapper options
- `config.disko.devices.disk` for Ignitix's disk preflight

For example, a target named `thething` can install `.#thething-crossbow` by
setting:

```nix
ignitix.installTargets.thething.flakeAttr = "thething-crossbow";
```
