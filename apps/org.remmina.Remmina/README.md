# org.remmina.Remmina

Remmina, the remote desktop client (RDP with FreeRDP 3, VNC, SPICE, SSH,
SFTP), built from the release's tag at its pinned commit (upstream signs
nothing) against the runtime's libraries. English only; not built: WWW,
X2Go, KWallet, GVNC, the Python plugins, news, statistics and tips.

Tighter than Flathub's: the home is read-only but for `~/.ssh/known_hosts`
(where it exists: `touch` it once) and the download dir, SSH keys come from
the agent, and there are no host commands, so the exec plugin, a profile's
pre- and post-connect commands and SSH's X11 forwarding fail. The app ID is
Flathub's: uninstall that one without `--delete-data` and its profiles stay.

```sh
# once: a token with read:packages in ~/.config/flatpak/oci-auth.json (or /etc/flatpak/), as {"auths":{"ghcr.io":{"auth":"<base64 of USER:TOKEN>"}}}
flatpak remote-add --user --if-not-exists packages oci+https://lucarickli.github.io/packages
flatpak install --user packages org.remmina.Remmina
# host commands back, then restart it (--filesystem=home: the home read-write, as on Flathub):
flatpak override --user --talk-name=org.freedesktop.Flatpak org.remmina.Remmina
```
