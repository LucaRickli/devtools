# devcontainer

`ghcr.io/lucarickli/devcontainer`: the tools and extensions of `tools/` on
Fedora toolbox, for VS Code Dev Containers and toolbox; `:latest`, and `:ai`
with Claude Code, whose `claude` downloads it from Anthropic on first use
(240 MB, into `~/.local/share/claude-code/`) and checks it against the pin
taken from Anthropic's signed manifest. `just devcontainer` builds both
locally.

The image is private: log in once with a classic personal access token that
may read packages, `docker login ghcr.io` (for toolbox, `podman login
--authfile ~/.config/containers/auth.json ghcr.io`, which podman reads after
a reboot too). In a project:

```jsonc
// .devcontainer/devcontainer.json
{ "image": "ghcr.io/lucarickli/devcontainer:latest" }
```

Where docker on an SELinux host denies the workspace mount, add
`"runArgs": ["--security-opt", "label=disable"]` (podman does that itself).
As a toolbox: `toolbox create --image ghcr.io/lucarickli/devcontainer:latest
dev`. For Claude Code, `:ai` in place of `:latest`. A toolbox shares your
home, so Claude Code's login, settings and history in `~/.claude` are the
host's; a Dev Container's home goes with each rebuild, so keep them in a
volume:

```jsonc
"mounts": ["source=claude-code,target=/var/home/dev/.claude,type=volume"],
"containerEnv": { "CLAUDE_CONFIG_DIR": "/var/home/dev/.claude" }
```

The image has no podman, docker or qemu of its own: in a toolbox those
commands, and `bcvk`, run on the host (host-spawn); in a Dev Container they
say so, unless you install them (`sudo dnf install podman`), and `bcvk` runs
inside. Kernel modules build in it, against the host's kernel where that is
Fedora's:

```sh
sudo dnf install fedora-repos-archive       # also the kernels Fedora has since replaced
sudo dnf install kernel-devel-$(uname -r)
make -C /usr/src/kernels/$(uname -r) M=$PWD modules
```

Offline, the image works once it is local (`docker save`, `docker load`),
but for the VS Code Server, which comes from the client: put the one for your
VS Code's commit (Help, About), from
`https://update.code.visualstudio.com/commit:<commit>/server-linux-x64/stable`,
at `<folder>/<commit>/vscode-server-linux-x64.tar.gz` and set
`"remote.serverDownloadFolder": "<folder>"` (absolute) in your user settings;
Dev Containers itself (0.447.0 or newer) installs from its `.vsix`.
