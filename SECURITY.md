# Security

## Supported versions

Only the newest images get fixes: `ghcr.io/lucarickli/devcontainer:latest`
and `ghcr.io/lucarickli/code:latest`. Dated tags get none.

## Reporting a vulnerability

Privately, through GitHub: this repository's Security tab, "Report a
vulnerability". Not in an issue, a pull request or a discussion, where it
would be public before it is fixed. Say what is affected (an image tag, a
file of this repository), how to reproduce or see it, and what it allows; a
patch is welcome. The advisory is where you hear back.

## How fixes ship

- Every dev container build applies Fedora's stable updates first and is
  scanned before it is pushed: a secret, known-malicious code or a critical
  Fedora security update the build's own dnf knew stops the push. The VS
  Code Flatpak's build runs the same secret scan.
- The dev container is rebuilt every Monday and on every change, the
  Flatpak on every change.
- Pinned tools, extensions, actions and images are kept current by
  Renovate, and a pull request that changes a pin checks it against what
  upstream signs or attests (`verify-pins.sh`).

## Verifying what you run

Both images are signed with cosign and verify against `keys/cosign.pub`
(`cosign verify --key keys/cosign.pub --insecure-ignore-tlog=true <image>`),
fedora-bootc's key: a machine running it pulls only a dev container that key
signed.

## Scope

The dev container, the VS Code Flatpak, and the CI that builds, scans and
signs them. A bug in Fedora, VS Code, an upstream tool or extension belongs
to that project; what this repository can fix is how it builds, configures,
signs and ships them.
