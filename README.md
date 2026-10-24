# Development tools

[`tools.txt`](tools.txt) pins them: Go, Deno, Rust and Protocol Buffers
(protoc, buf) with their language servers and linters, kubectl, helm, flux,
talosctl, sops, age, cosign, trivy, gh, yq, shellcheck, actionlint, just,
bcvk, fish, mise and more; [`extensions.txt`](extensions.txt) the VS Code
extensions for those languages. [`install.sh`](install.sh) installs both
lists, checking every download, and [`test.sh`](test.sh) is the test both
builds pass. They are not on the host: the VS Code Flatpak
(`ghcr.io/lucarickli/code`) and the dev container
(`ghcr.io/lucarickli/devcontainer`) carry them, and Claude Code, which each
machine downloads from Anthropic.

## VS Code

`io.github.lucarickli.Code` ([`flatpak/`](flatpak/build.sh))
is a Flatpak on Flathub's Freedesktop Sdk (gcc, git, gdb) with every tool, so
its terminal (fish, with your `~/.config/fish`) is a development environment
of its own. Its first start installs the language extensions, Dev
Containers and Claude Code into your profile from the Marketplace (offline,
the language ones from copies in the app); from then on they are ordinary
extensions. VS Code itself is downloaded from Microsoft, and Claude Code
from Anthropic, when the app is installed or updated. CI publishes it to
`ghcr.io/lucarickli/code`, an OCI image for a Flatpak remote to point at;
nothing installs it on its own. To try a build without CI:

```sh
just flatpak           # build and test it in a container: output/flatpak/
just flatpak-install   # install that build for your user (again to update)
flatpak run io.github.lucarickli.Code
```

Outside VS Code, the same shell: `flatpak run --command=fish
io.github.lucarickli.Code`. Rust is the pinned toolchain only; a project that
needs another toolchain or target uses the dev container.

With host access (below), Dev Containers runs your rootless podman through
host-spawn. A new VS Code profile starts with
`"dev.containers.dockerPath": "podman"` and
`"dev.containers.mountWaylandSocket": false`; add them to an existing
`settings.json`. `podman`, `docker`, `qemu-img` and `qemu-system-x86_64` in
the app are the host's, and its `bcvk` runs on the host too (see VMs);
without host access they say how to grant it.

## Sandbox

The VS Code Flatpak sees `~/Developer` (read-write, made if missing), your
`~/.config/fish`, `~/.gitconfig`, `~/.config/git`, `~/.ssh/known_hosts` and
`~/.ssh/config` (read-only), and its own directory,
`~/.var/app/io.github.lucarickli.Code`: profile, sign-ins, Claude Code's
login, fish's universal variables, and `go`, `.cargo` and `.deno` for what
`go install` and the like build. The rest of the home is empty in there,
and new at each start. It has the network, the GPU and the display, no
other device, no sound, nothing of the host's system. Git over SSH signs
with the session's agent and never reads a key: run `ssh-add` once after
login (a key without a passphrase is offered without it). A new SSH host
goes into `known_hosts` from a host shell (`ssh` it once), as the app cannot
write there. Other files come in through the file chooser, or the host's
`EDITOR` (below).

Host access, for Dev Containers, `podman`, `docker` and the recipes that
use them or run VMs:

```sh
flatpak override --user --talk-name=org.freedesktop.Flatpak io.github.lucarickli.Code
```

Every extension, task and terminal in VS Code can then run any command as
you, and as root through docker: as trusted as a VS Code installed on the
host. `--no-talk-name` in its place undoes it; restart VS Code after
either. More, each an option to the same `flatpak override --user`:

| For                           | Option                                                                                     |
| ----------------------------- | ------------------------------------------------------------------------------------------ |
| another projects directory    | `--filesystem=~/src`                                                                       |
| USB drives                    | `--filesystem=/run/media`                                                                  |
| kubectl, talosctl, sops       | `--filesystem=~/.kube:ro --filesystem=~/.talos:ro --filesystem=~/.config/sops/age:ro`      |
| `/dev/kvm`, or every device   | `--device=kvm`, `--device=all`                                                             |
| sound and the microphone      | `--socket=pulseaudio`                                                                      |
| sign-ins in the login keyring | `--talk-name=org.freedesktop.secrets` (it hands over every item there; sign in again once) |

`claude-sandboxed` (a terminal profile in a new VS Code profile) runs Claude
Code with `--dangerously-skip-permissions` in a sandbox inside the app's:
the git repository it starts in, read-write except `.git`, `.vscode`,
`.devcontainer`, `.devcontainer.json` and `.claude` (the directories made
empty where missing; in a worktree, the repository it belongs to,
read-only), the network (the host's, localhost included) and the tools; no
other files, no host commands, no ssh-agent. It logs in on its own and
commits nothing: read `git status` and its diff before you build, reopen in
a container or commit, as a new `.devcontainer.json` or `.cargo/config.toml`
runs outside the box, and so does a `mise.toml` once you trust it.
`claude-sandboxed --shell` opens a shell in the same box.

Keys kept outside `~/Developer`, such as signing keys in `~/.local/share`,
are out of the app's and its agents' reach: what needs them runs from a host
shell or a toolbox. Two ways out remain, on the host's side: on
a wayfire session (0.10, no Wayland security context) the app can use
wayfire's privileged protocols (virtual keyboard and pointer, the
clipboard), and the host's Xwayland accepts the app and its
`claude-sandboxed` box as X11 clients through the network they share with
the host.

## The dev container

`ghcr.io/lucarickli/devcontainer` ([`Containerfile`](Containerfile),
CI weekly and on change, `just devcontainer` locally): Fedora toolbox with the
same tools and extensions. In a project:

```jsonc
// .devcontainer/devcontainer.json
{ "image": "ghcr.io/lucarickli/devcontainer:latest" }
```

If docker on an SELinux host denies the workspace mount, add
`"runArgs": ["--security-opt", "label=disable"]` (podman does that itself). As
a toolbox: `toolbox create --image ghcr.io/lucarickli/devcontainer:latest dev`.

The image has no podman, docker or qemu of its own. In a toolbox those
commands are the host's and `bcvk` runs on the host, as in VS Code. A Dev
Container has no session bus to reach the host: there they say so, unless
you install them in the container (`sudo dnf install podman`), and `bcvk`
runs inside it.

Kernel modules build in it (not in the Flatpak, which has no kernel
headers), against the host's kernel when that is Fedora's, as on a
fedora-bootc machine:

```sh
sudo dnf install fedora-repos-archive       # also the kernels Fedora has since replaced
sudo dnf install kernel-devel-$(uname -r)   # the headers, and the tools they need
make -C /usr/src/kernels/$(uname -r) M=$PWD modules
```

## Claude Code

`claude` is in the Flatpak and the container, at the version pinned in
[`flatpak/build.sh`](flatpak/build.sh) and the
Containerfile (Anthropic's stable channel), with its own updates off.
Neither published image holds it: it is not open source, so each machine
downloads it from Anthropic and checks it against the manifest Anthropic
signs ([`claude-code.sh`](claude-code.sh)). The Flatpak gets it
with VS Code; the container's `claude` downloads it on first use, into
`~/.local/share/claude-code/` (240 MB). The VS Code extension
(`anthropic.claude-code`, with a copy of Claude Code of its own version)
comes from the Marketplace: at the Flatpak's first start, and when Dev
Containers opens the container.

A toolbox uses your home, so the login, settings and history in `~/.claude`
are the host's (where `claude` may be another version). The Flatpak keeps
its own, in `~/.var/app/io.github.lucarickli.Code/config/claude`: one login
for its terminal and the extension. A Dev Container's home goes with each
rebuild; keep them in a volume, in the project's `devcontainer.json`:

```jsonc
"mounts": ["source=claude-code,target=/var/home/dev/.claude,type=volume"],
"containerEnv": { "CLAUDE_CONFIG_DIR": "/var/home/dev/.claude" }
```

Claude's own sandbox (`/sandbox`) works in neither: the Flatpak allows no
nested user namespaces, the container has no bubblewrap. In the Flatpak,
`claude-sandboxed` takes its place (see Sandbox).

## Other versions

[mise](https://mise.jdx.dev) installs other versions of the toolchains, and
other languages, per project:

```sh
mise use go@1.26   # in the project: writes mise.toml, downloads Go 1.26
mise trust         # a cloned project's mise.toml, once you have read it
mise install       # what it names
```

Nothing else downloads them: until you run one of those, the project gets
the pinned version, with a warning (`MISE_AUTO_INSTALL=0` in the
environment, which a project's settings cannot change; set it to 1 in your
shell for auto-install). A project that names the pinned Go or Deno gets
the image's, offline. fish switches versions as you change directory; in
bash, `mise exec -- go build`. VS Code's extensions keep the pinned Go and
Deno (`go.goroot` in the project's settings, set to what `mise where go`
prints, changes the Go extension's); what only mise has, such as node,
reaches them through mise's shims. A project's mise config applies only
once you trust it, file by file and again after each change to it (`mise
use` trusts what it writes); until then fish warns and the pinned versions
run. Rust stays with rustup (above). The settings:
[`mise-config.toml`](mise-config.toml).

Each environment keeps its own installs: the Flatpak in
`~/.var/app/io.github.lucarickli.Code/data/mise`, a toolbox in
`~/.local/share/mise` (shared by all toolboxes), a Dev Container inside the
container (gone with a rebuild).

## EDITOR

`EDITOR` and `VISUAL` are `code --wait` in the Flatpak and in a Dev
Containers terminal: git, sops, kubectl and gh edit in a VS Code tab and go
on when it closes. On the host, with
`EDITOR="flatpak run --file-forwarding io.github.lucarickli.Code --wait @@"`,
the document portal hands VS Code the file a tool adds, wherever it is (the
app does not see the host's `/tmp`). The app can write each file handed in
that way until you log out: harmless for the temporary files of sops,
kubectl and crontab, not for one the host runs, such as
`~/.config/niri/config.kdl`; `flatpak document-unexport FILE` takes it
back. A file the app already sees goes in as it is: `~/.gitconfig` and
your fish config stay read-only. A toolbox keeps vim or Fedora's nano.
A new VS Code profile keeps Local History out of `/tmp` and `/run/user`,
where sops and kubectl put the plaintext; in an existing one, add
`"workbench.localHistory.exclude": { "/tmp/**": true, "/run/user/**": true }`
to `settings.json`.

## VMs

bcvk, and the qemu it drives, run on the host, from the VS Code terminal
(with host access) as from a toolbox: the host needs rootless podman,
`/dev/kvm`, qemu, qemu-img, virtiofsd, edk2-ovmf, binutils (objcopy),
openssh-clients, systemd and glibc 2.39 or newer. A fedora-bootc machine has
them. On Arch:

```sh
sudo pacman -S --needed podman qemu-base qemu-ui-gtk qemu-ui-opengl virtiofsd edk2-ovmf binutils openssh
```

## Licenses

Each tool's license texts are in `share/licenses/<tool>/` next to it
(`/app/share/licenses` in the Flatpak, `/usr/local/share/licenses` in the
container). For those under the GPL or MPL, or with MPL code built in, a
`SOURCES` file there names their source at the pinned version (the
`source` column in `tools.txt`). The VS Code extensions carry theirs in
the `.vsix`.

## Ports

A server started in the VS Code Flatpak, or in a toolbox, is on the host's
network: `localhost:<port>` reaches it. Dev Containers forwards the ports a
container listens on to `localhost` (or list them in `forwardPorts`).

## Offline

For no internet for VS Code or the container:

- Move the image with `podman save` / `podman load`; the name stays the same.
- Install Dev Containers (0.447.0 or newer) from a `.vsix` (Extensions, `...`,
  Install from VSIX):
  `curl -fsSL --compressed -o dev-containers.vsix https://marketplace.visualstudio.com/_apis/public/gallery/publishers/ms-vscode-remote/vsextensions/remote-containers/0.469.0/vspackage`
- Put the VS Code Server for your VS Code's commit (Help, About) at
  `<folder>/<commit>/vscode-server-linux-x64.tar.gz`, from
  `https://update.code.visualstudio.com/commit:<commit>/server-linux-x64/stable`,
  and set `"remote.serverDownloadFolder": "<folder>"` (absolute path) in your
  user settings.

## Building it

Needs rootless `podman` and `just`:

```sh
just devcontainer      # localhost/devcontainer:latest
just flatpak           # build and test the VS Code Flatpak into output/flatpak/
just check             # every script's syntax
just verify-pins       # every pin against upstream's signatures
```

`just verify-pins` also needs cosign, gh (logged in, or `GH_TOKEN`), gpg,
minisign, slsa-verifier, curl, unzip and jq.

On every pull request that can affect them, CI builds, tests and scans both
(`ci.yml`, whose `ci-ok` is the one required check, with lint and the pin
checks); on `main` it also pushes and signs them: `devcontainer.yml` on
change and every Monday, `flatpak.yml` on change only, because every new
Flatpak is a full download of about 950 MB for each machine that follows
it. A failed run on `main` opens an issue assigned to you (`notify.yml`).
Renovate ([`renovate.json`](renovate.json)) gathers the minor, patch and
digest updates into one weekly PR that merges itself once `ci-ok` is green;
majors and moved action tags wait for you. By hand, once a year: the
Flatpak's Freedesktop runtime (`RUNTIME` in `flatpak/build.sh`), once
Flathub's Electron BaseApp exists for the new branch.

Both images are signed with fedora-bootc's cosign key: a machine running
fedora-bootc refuses a dev container that key did not sign. The `sign` jobs
take it from the `SIGNING_SECRET` secret of a `release` environment limited
to `main`; [`keys/cosign.pub`](keys/cosign.pub) is its public half, which
they verify against.

A new copy of this repository also needs, in its settings: auto-merge
allowed, and [`.github/rulesets/main.json`](.github/rulesets/main.json)
imported (Rules, Rulesets, New ruleset, Import a ruleset), which makes
`ci-ok` required; private vulnerability reporting on (Code security), where
[`SECURITY.md`](SECURITY.md) sends reporters. Where
`ghcr.io/<owner>/devcontainer` or `ghcr.io/<owner>/code` already exists,
pushed from another repository, give this one Write in that package's
settings (Manage Actions access) before its first push.
