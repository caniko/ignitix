# Installation

Add Ignitix as a flake input:

```nix
{
  inputs.ignitix.url = "git+https://github.com/caniko/ignitix.git";
}
```

Import the flake-parts modules you need:

```nix
{
  inputs,
  ...
}: {
  imports = [
    inputs.ignitix.flakeModules."install-media"
    inputs.ignitix.flakeModules."install-targets"
  ];
}
```

Downstream flakes usually also pass host metadata into Ignitix install target
definitions. The downstream host metadata is the source of truth for LAN, VPN,
and hardware-specific fields.

