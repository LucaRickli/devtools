# Packages

Personal development tools, dev containers and Flatpaks.

> [!NOTE]
> Due to licensing concerns, most packages built from these recipes are private and not intended for redistribution.

Every download is checked against upstream's checksum or signature, or a
sha256 pinned here where upstream publishes none; every image is tested
before it is pushed, and signed with a private cosign key.

## Building

Needs docker with buildx, `just` and `jq`; everything else runs in
containers.

```sh
just devcontainer       # localhost/devcontainer:latest and :ai
just flatpaks           # the runtime, the SDK and every app, built and tested: output/flatpaks/
just flatpak NAME       # one of them (just flatpak-names)
just flatpaks-install   # install the local build for your user (or one: just flatpaks-install ID)
just check              # every shell script's syntax, and a README.md in every app
just verify-pins        # every pin against upstream's signatures
```

CI does the same on every pull request, and on `main` pushes and signs
what changed: [building.md](docs/building.md).
