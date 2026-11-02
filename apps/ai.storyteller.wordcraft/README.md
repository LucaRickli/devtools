# ai.storyteller.wordcraft

WordCraft, ArtCraft's word processor, and its command line
(`flatpak run --command=wordcraft-cli ai.storyteller.wordcraft`): the
`linux-x86_64` tarball of storytold/wordcraft's GitHub release, as upstream's
Flatpak ships it, on `io.github.lucarickli.Platform`. Checked against the
release's `SHA256SUMS.txt` only: upstream signs nothing.

Upstream's permissions: Wayland (X11 where there is none), the GPU, the
network (its update check), printing through the host's CUPS and Avahi,
`~/.cups` and the ArtCraft Launcher's versions read-only, Documents and
Pictures; other files through the file chooser and drag and drop.

```sh
# once: a token with read:packages in ~/.config/flatpak/oci-auth.json (or /etc/flatpak/), as {"auths":{"ghcr.io":{"auth":"<base64 of USER:TOKEN>"}}}
flatpak remote-add --user --if-not-exists packages oci+https://lucarickli.github.io/packages
flatpak install --user packages ai.storyteller.wordcraft
# NVIDIA, unless a Flathub app brought its GL driver along:
flatpak install flathub org.freedesktop.Platform.GL.nvidia-$(tr . - </sys/module/nvidia/version)//1.4
```
