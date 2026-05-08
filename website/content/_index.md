+++
title = "Ignitix"

[extra]
tagline = "Reusable NixOS install media and host-first install workflows."
subtitle = "Ignitix turns board-specific installer images, nixos-anywhere wrappers, and route-aware install targets into composable flake outputs."
install = "nix develop\nnix build .#example-rockpro64\nnix build .#site"

[[extra.features]]
title = "Compose Install Media"
body = "Define bootable NixOS installer systems once and expose image packages plus nixos-anywhere wrappers from the same flake."

[[extra.features]]
title = "Target Hosts By Route"
body = "Model install routes such as LAN, USB gadget, or VPN and generate host-first install, mount, rescue, and probe commands."

[[extra.features]]
title = "RockPro64 Ready"
body = "Ship focused ROCKPro64 installer media with serial console handoff, USB-C gadget networking, and headless bootstrap defaults."

[[extra.features]]
title = "Bootswain Serial Friendly"
body = "Document bidirectional RockPro64 serial workflows that read board TXD and send U-Boot commands through board RXD."

[[extra.features]]
title = "Canix Metadata Friendly"
body = "Keep host facts in downstream infrastructure data while Ignitix supplies reusable install-media and target machinery."

[[extra.features]]
title = "Publish The Project"
body = "Build the landing page and mdBook documentation as a single Codeberg Pages output with Nix."
+++

