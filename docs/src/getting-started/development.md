# Development

Enter the development shell:

```sh
nix develop
```

Build and check the flake:

```sh
nix flake check
nix build .#website
nix build .#docs
nix build .#site
```

Run the local documentation servers:

```sh
cd website && zola serve
```

```sh
cd docs && mdbook serve
```

Generated `docs/book/`, `website/public/`, and `result` paths are ignored by
Git.

