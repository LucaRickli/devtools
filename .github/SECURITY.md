# Security

## Supported versions

Only the newest images get fixes: the `latest` and `ai` tags of
`ghcr.io/lucarickli/devcontainer` and `ghcr.io/lucarickli/code`, and the
`latest` tag of each Flatpak built on the runtime
(`ghcr.io/lucarickli/io.github.lucarickli.platform`,
`ghcr.io/lucarickli/org.mozilla.firefox`). Dated tags get none.

## Reporting a vulnerability

Privately, through GitHub: this repository's Security tab, "Report a
vulnerability". Not in an issue, a pull request or a discussion, where it
would be public before it is fixed. Say what is affected (an image tag, a
file of this repository), how to reproduce or see it, and what it allows; a
patch is welcome. The advisory is where you hear back.

## How fixes ship

- Every dev container and runtime build applies Fedora's stable updates
  first and is scanned before it is pushed: a secret, known-malicious code
  or a critical Fedora security update the build's own dnf knew stops the
  push. The VS Code Flatpak's build runs the same secret scan.
- The dev container and the runtime are rebuilt every Monday and on every
  change, the apps on every change.
- Pinned tools, extensions, apps, actions and images are kept current by
  Renovate, and a pull request that changes a pin of the development tools
  checks it against what upstream signs or attests (`tools/verify-pins.sh`),
  as CI does for every pin each Monday before the weekly builds.
  The builds check each pinned download against upstream's checksum, or
  the pin's where upstream publishes none, and only Claude Code's, Firefox's,
  mise's and VS Code's against upstream's signature as well: by Anthropic's
  key in `keys/`, by Mozilla's key and signing subkey pinned in Firefox's
  `Containerfile`, by mise's minisign key in `tools/tools.txt`, VS Code's RPM
  by Microsoft's key, pinned by its fingerprint in the VS Code Flatpak's
  `Containerfile`.

## Verifying what you run

Every image is signed with cosign and verifies against `keys/cosign.pub`
(`cosign verify --key keys/cosign.pub --insecure-ignore-tlog=true <image>`),
fedora-bootc's key: a machine running it pulls only a dev container that key
signed.

## Scope

The dev container, the VS Code Flatpak, the runtime, the SDK and the apps
on them, and the CI that builds, scans and signs them. A bug in Fedora, VS
Code, Firefox, an upstream tool or extension belongs to that project; what this
repository can fix is how it builds, configures, signs and ships them.
