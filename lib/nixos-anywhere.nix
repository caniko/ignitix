# Carry the install engine fix at its source rather than masking ssh globally.
# Remove this patch when the pinned upstream implements caller-first trust.
package:
package.overrideAttrs (old: {
  patches = (old.patches or []) ++ [../patches/nixos-anywhere-ssh-option-precedence.patch];
})
