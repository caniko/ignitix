# Install Targets

Install targets describe hosts that can be reached through one or more install
routes. A target binds host metadata to a selected install medium and a target
NixOS configuration.

The install target module exposes host-first wrappers:

- `install` for `nixos-anywhere` installs
- `smount` for mounting an existing disko layout through installer media
- `rescue` for mounting and reinstalling into an existing layout
- `probe-hardware` for hardware report capture
- `unlock-luks` for a verified, local Iced passphrase prompt that unlocks an
  encrypted target through SSH without placing the passphrase in arguments,
  environment variables, or files
- `enroll-tpm2-pin` for guarded TPM2+pcrlock enrollment using masked local
  passphrase and PIN fields

Routes are semantic names such as `lan`, `usb`, or `vpn`. Each route resolves a
target host from explicit route data, media endpoints, or downstream host
metadata.

## Verified bootstrap identity

For public/cloud installation, set
`ignitix.installTargets.<name>.nixosAnywhere.bootstrapHostKey` to the installer's
one-line ED25519 public host key after verifying it through the provider console
or another independently authenticated channel. It is the bootstrap key, not the
future installed host's key. Verify a new installer identity again if that
environment generates new keys on reboot.

The resolved target pins that key under a route-independent host alias in an
immutable `known_hosts` file. Install preflights, the install engine, hardware
probes, mount/rescue connections and consumers of `installTargetsResolved` all
receive strict host-key checking, public-key-only authentication and fresh SSH
connections. Extra `nixosAnywhere.sshOptions` and media defaults follow the trust
options so they cannot replace the pin. The caller must already have a usable
administrative SSH key; pinning a server key does not supply login credentials.

Ignitix patches its pinned `nixos-anywhere` so caller SSH options precede its
insecure first-install defaults. The regression check uses the actual argument
parser and `ssh -G`; it verifies both the legacy defaults and the pinned policy
against later conflicting options. Bootstrap pinning fails closed if kexec
changes the server identity. Test that continuity with the chosen installer
before relying on unattended installation.

After installation, read and enroll the installed runtime key over the verified
bootstrap connection, rekey runtime secrets, install the refreshed generation,
and verify recovery before rebooting. A null bootstrap key retains the legacy
first-install policy.

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

Unlocking requires the target route, the expected ED25519 fingerprint shown on
the installer console, and the LUKS UUID:

```console
nix run .#unlock-luks -- usb thething -- \
  --host-key-sha256 SHA256:... \
  --device-uuid 00000000-0000-0000-0000-000000000000 \
  --mapper cryptroot
```

The expected fingerprint is intentionally supplied for each invocation because
installer media normally generates an ephemeral SSH host key at boot. Ignitix
compares it before showing the passphrase prompt and pins the matching key for
the SSH connection.

TPM2+PIN enrollment uses the same route and host-key pinning:

```console
nix run .#enroll-tpm2-pin -- usb thething -- \
  --host-key-sha256 SHA256:... \
  --device-uuid 00000000-0000-0000-0000-000000000000
```

Install `packages.ignitix-unlock-luks` on the target so the default helper path
`/run/current-system/sw/bin/ignitix-unlock-luks` exists. The helper refuses to
prompt unless Secure Boot is enabled in user mode, the pcrlock policy exists,
the UUID names a LUKS2 block device with a password slot, and no TPM token is
already enrolled.
