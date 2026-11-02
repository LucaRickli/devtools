# tools

The development tools and VS Code extensions, pinned, which the VS Code
Flatpak (in `/app`) and the dev container (in `/usr/local`) both install.

| File                                 | What                                                                            |
| ------------------------------------ | ------------------------------------------------------------------------------- |
| `tools.txt`                          | the tools: version, release file, checksum, licenses; its header has the format |
| `extensions.txt`                     | the VS Code extensions, in the same format                                      |
| `install.sh`                         | installs either list into a prefix, checking every download                     |
| `verify-pins.sh`                     | checks every pin against upstream's signatures and attestations                 |
| `test.sh`                            | every tool runs and the toolchains build, in both images                        |
| `claude-code.sh`                     | Claude Code's URL, sha256 and size, from the manifest Anthropic signs           |
| `mise-system.sh`, `mise-config.toml` | mise's system config; the pinned Go and Deno as mise's installs                 |

`install.sh` installs nothing unverified: each download matches upstream's
sha256 (from the release's checksum file, or pinned on its line where
upstream publishes none, or a minisign signature by the pinned key), `go
install` checks sum.golang.org, rustup the channel manifest. A release file
replaced together with its checksum file passes that, so `verify-pins.sh`
checks each pin against what upstream publishes beyond it: a cosign
signature, GitHub's provenance or release attestation, a GPG or minisign
signature by a pinned key, SLSA provenance, the publisher's copy of a
`.vsix`. A new tool needs its row there, or `none` with the reason. CI runs
it on every pull request that changes a pin and every Monday; locally, `just
verify-pins`. `claude-code.sh` checks Anthropic's manifest against
`keys/claude-code.asc` and that key's fingerprint. Renovate bumps the pins.

## mise

Other versions, and other languages, per project:

```sh
mise use go@1.26   # writes mise.toml, downloads Go 1.26
mise trust         # a cloned project's mise.toml, once you have read it
mise install       # what it names
```

Nothing else downloads them (`MISE_AUTO_INSTALL=0`, which a project cannot
change; set it to 1 in your shell for auto-install): until then the pinned
version runs, with a warning, and a project that names the pinned Go or Deno
gets it offline. A project's mise config applies only once trusted, file by
file and again after each change to it (`mise use` trusts what it writes).
fish switches versions per directory; in bash, `mise exec -- go build`. VS
Code's extensions keep the pinned Go and Deno (`go.goroot`, set to what `mise
where go` prints, changes the Go extension's); what only mise has, such as
node, reaches them through its shims. Rust stays with rustup: in the Flatpak
the pinned toolchain only, so another toolchain or target needs the dev
container. Installs: the Flatpak's in
`~/.var/app/io.github.lucarickli.Code/data/mise`, a toolbox's in
`~/.local/share/mise`, a Dev Container's inside it, gone with a rebuild.

## EDITOR

`EDITOR` and `VISUAL` are `code --wait` in a Dev Containers terminal and
`code-wait`, the same as one word, in the Flatpak: git, sops, kubectl and gh
edit in a VS Code tab and go on when it closes. A toolbox keeps nano. On the
host, `EDITOR="flatpak run --file-forwarding io.github.lucarickli.Code --wait
@@"` hands the file in through the document portal (the app does not see the
host's `/tmp`), and the app can write it until you log out: harmless for the
temporary files of sops, kubectl and crontab, not for one the host runs
(`flatpak document-unexport FILE` takes it back). A new profile of the
Flatpak keeps Local History out of `/tmp` and `/run/user`, where sops and
kubectl put the plaintext; in an existing one, add
`"workbench.localHistory.exclude": { "/tmp/**": true, "/run/user/**": true }`
to `settings.json`.

## bcvk

bcvk and the qemu it drives run on the host, from the VS Code terminal (with
host access) as from a toolbox. The host needs rootless podman, `/dev/kvm`,
qemu, qemu-img, virtiofsd, edk2-ovmf, binutils (objcopy), openssh-clients,
systemd and glibc 2.39 or newer, as fedora-bootc has them; on Arch, `sudo
pacman -S --needed podman qemu-base qemu-ui-gtk qemu-ui-opengl virtiofsd
edk2-ovmf binutils openssh`.

## Licenses

Each tool's license texts are in `share/licenses/<tool>/` beside it
(`/app/share/licenses` in the Flatpak, `/usr/local/share/licenses` in the
dev container), with a `SOURCES` file naming the source at the pinned
version for those under the GPL or MPL, or with MPL code built in. Each
`.vsix` carries its own.
