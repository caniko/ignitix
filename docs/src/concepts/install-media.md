# Install Media

Install media definitions describe bootable NixOS installer systems. Each
entry declares the target architecture, hostname, base NixOS image module,
extra modules, package name, and optional `nixos-anywhere` metadata.

Ignitix expands those definitions into:

- NixOS configurations for the installer systems
- flake packages for generated installer images
- optional `install-<media>` apps and packages wrapping `nixos-anywhere`

The media layer is intentionally reusable. Board-specific catalog helpers, such
as `lib.catalog.rockpro64Installer`, produce ordinary install media entries
that downstream flakes can override through arguments and extra modules.

