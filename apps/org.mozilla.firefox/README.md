# org.mozilla.firefox

Mozilla's en-US `linux-x86_64` release on `io.github.lucarickli.Platform`,
checked against `SHA512SUMS` and its signature by the Mozilla subkey pinned
in the `Containerfile`. English only; no H.264 or HEVC video (Fedora has no
FFmpeg with them). The app ID is Flathub's: uninstall that one without
`--delete-data` and its profile stays in use.

Flathub's permissions, less smart cards and Kerberos' KCM, plus the host's
`~/Downloads` and, read-only, what Noctalia v5 writes for Pywalfox (its host
is `/app/bin/pywalfox`): turn on Noctalia's `pywalfox` template, apply a theme
before Firefox starts, then install the extension and "Fetch Pywal colors".

```sh
# once: a token with read:packages in ~/.config/flatpak/oci-auth.json (or /etc/flatpak/), as {"auths":{"ghcr.io":{"auth":"<base64 of USER:TOKEN>"}}}
flatpak remote-add --user --if-not-exists packages oci+https://lucarickli.github.io/packages
flatpak install --user packages org.mozilla.firefox
# NVIDIA, unless a Flathub app brought its GL driver along:
flatpak install flathub org.freedesktop.Platform.GL.nvidia-$(tr . - </sys/module/nvidia/version)//1.4
```
