# io.github.lucarickli.Code

VS Code as a Flatpak with every tool of `tools/` inside, on the SDK
`io.github.lucarickli.Sdk` (the runtime with Fedora's C toolchain, gdb and
git), so that its terminal, fish with your `~/.config/fish`, is a development
environment of its own (outside VS Code: `flatpak run --command=fish
io.github.lucarickli.Code`). Unlike Flathub's `com.visualstudio.code`, which
downloads VS Code on each machine at install and runs on Flathub's runtime,
the image carries VS Code, Microsoft's RPM checked against Microsoft's
signature, as CI built and tested it, and host access is an opt-in.

Two variants of the one app, `io.github.lucarickli.Code//stable`: plain
(`ghcr.io/lucarickli/code:latest`) and `ai` (`:ai`), plain with Claude Code,
checked against the manifest Anthropic signs: `claude`, `claude-sandboxed`
and the Claude Code extension. The first start installs the language
extensions and Dev Containers from the Marketplace (offline, the language
ones from copies in the app). Each new image is a full download, in
November 2026 1.29 GB, 3.82 GB installed (`ai`: 1.40 GB, 4.06 GB); the SDK,
once, 435 MB, 1.24 GB.

## Sandbox

The `flatpak.finish-args.*` labels of the `Containerfile`, the same for both:

| What    | Granted                                                                         | Not granted                                     |
| ------- | ------------------------------------------------------------------------------- | ----------------------------------------------- |
| Files   | `~/Developer`; fish and git config, `~/.ssh/known_hosts` and `config` read-only | `host`, the host's `/tmp`, the rest of the home |
| Host    | `/run/docker.sock`: root on the host, where Docker runs                         | host commands (`org.freedesktop.Flatpak`)       |
| Devices | the GPU, `/dev/kvm`                                                             | the others (input, cameras, USB), sound         |
| Session | Wayland (X11 as fallback), the SSH agent, notifications                         | the login keyring (`org.freedesktop.secrets`)   |
| Other   | the host's network (`localhost` both ways), ptrace and perf                     | —                                               |

The rest of the home is new at each start, but for `~/go`, `~/.cargo`,
`~/.deno` and `~/.vscode`, kept in the app's directory.

## Overrides

Host access lets Dev Containers and the app's `podman`, `docker`, `qemu-img`,
`qemu-system-x86_64` and `bcvk` run on the host, through host-spawn (without
it they say how to grant it), and with them every extension, task and
terminal, as you: as trusted as a VS Code on the host. A new profile starts
with `"dev.containers.dockerPath": "podman"` and
`"dev.containers.mountWaylandSocket": false`; add them to an existing
`settings.json`.

```sh
flatpak override --user --talk-name=org.freedesktop.Flatpak io.github.lucarickli.Code   # host access
flatpak override --user --nofilesystem=/run/docker.sock io.github.lucarickli.Code       # no Docker socket
# kubectl's, talosctl's and sops' keys, read-only:
flatpak override --user --filesystem=~/.kube:ro --filesystem=~/.talos:ro --filesystem=~/.config/sops/age:ro io.github.lucarickli.Code
flatpak kill io.github.lucarickli.Code                                                   # then start it again
```

## claude-sandboxed (`ai`)

Claude Code without permission prompts, in a sandbox of its own inside the
app's (`flatpak-spawn --sandbox`; Claude Code's own cannot run in a Flatpak),
from a terminal profile of a new VS Code profile. It gets the git repository
it starts in, read-write but for `.git`, `.vscode`, `.devcontainer`,
`.devcontainer.json` and `.claude`, the network, `/dev/kvm` and the tools in
`/app`; no Docker socket, D-Bus, host commands, SSH agent or display. It logs
in on its own; `claude-sandboxed --shell` opens a shell in the same box. It
commits nothing: read `git status` and the diff before you build or commit,
as a new `.devcontainer.json`, `.cargo/config.toml` or (once trusted)
`mise.toml` runs outside the box.

## State

In `~/.var/app/io.github.lucarickli.Code`, kept across updates:

| Path                               | Holds                                                             |
| ---------------------------------- | ----------------------------------------------------------------- |
| `config/Code/User`                 | the VS Code profile: `settings.json`, keybindings, snippets       |
| `data/vscode/extensions`           | the extensions                                                    |
| `config/claude`                    | Claude Code's login, settings and history (`ai`)                  |
| `data/claude-sandboxed`            | `claude-sandboxed`'s login and caches (`ai`)                      |
| `config/fish`                      | links to your fish config, and fish's universal variables         |
| `go`, `.cargo`, `.deno`, `.vscode` | what `go install` and the like build, the module and crate caches |
| `data/mise`                        | the toolchains `mise install` adds                                |

## Install

```sh
# once: a token with read:packages in ~/.config/flatpak/oci-auth.json (or /etc/flatpak/), as {"auths":{"ghcr.io":{"auth":"<base64 of USER:TOKEN>"}}}
flatpak remote-add --user --if-not-exists packages oci+https://lucarickli.github.io/packages   # ai: .../packages/ai
flatpak install --user packages io.github.lucarickli.Code
# NVIDIA, unless a Flathub app brought its GL driver along:
flatpak install flathub org.freedesktop.Platform.GL.nvidia-$(tr . - </sys/module/nvidia/version)//1.4
```

`oci+https://lucarickli.github.io/packages/ai` is the same index with this
app's `ai` image. To switch a machine: `flatpak remote-modify --user
--url=<the other index> packages`, then `flatpak update`. Back from `ai`, the
Claude Code extension and the login in `config/claude` stay until you remove
them.
