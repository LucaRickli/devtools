#!/usr/bin/env bash
#
# Prints where to download Claude Code VERSION for linux-x64, with its sha256
# and size, as "URL SHA256 SIZE". It reads them from the manifest that
# Anthropic signs for each release.
#
#   claude-code.sh [--zst] VERSION
#
# With --zst, it prints the zstd-compressed file instead, about a third of
# the size.
#
# The ai variants use it:
#   - The VS Code Flatpak's build downloads the file and carries Claude Code
#     in its image (the claude stage of
#     apps/io.github.lucarickli.Code/Containerfile). Those images are
#     private, for the owner's machines.
#   - The dev container's build bakes only the pin into its image. Its
#     `claude` downloads Claude Code by that pin (devcontainer/claude).
#
# The manifest's signature must be by Anthropic's release key, which
# keys/claude-code.asc holds (a copy of
# https://downloads.claude.ai/keys/claude-code.asc). The signing key must
# also have the fingerprint that Anthropic's setup docs give, so a different
# key in that file fails too. Without these checks, the hashes would be only
# as good as TLS to downloads.claude.ai.
#
# Needs bash, curl, gpg, jq.
set -euo pipefail

# --- Arguments ---
fingerprint=31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE
file=claude manifest=manifest.json
if [ "${1:-}" = --zst ]; then
    file=claude.zst manifest=manifest.zst.json
    shift
fi
version=${1:?usage: claude-code.sh [--zst] VERSION}
base=https://downloads.claude.ai/claude-code-releases/$version

# --- Check the manifest's signature ---
# A keyring of its own, removed on exit, so that no other key is trusted.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export GNUPGHOME=$work/gnupg
mkdir -m 700 "$GNUPGHOME"
gpg --batch --quiet --import "$(dirname "$0")/../keys/claude-code.asc"
curl -fsSL --retry 5 --retry-all-errors -o "$work/manifest" "$base/$manifest"
curl -fsSL --retry 5 --retry-all-errors -o "$work/manifest.sig" "$base/$manifest.sig"
# The signature must be good, and by the pinned key. gpg's VALIDSIG status
# line ends with the fingerprint of the signing key's primary key.
gpg --batch --status-fd 3 --verify "$work/manifest.sig" "$work/manifest" \
    3>"$work/status" 2>/dev/null || { echo "$manifest for $version: bad signature" >&2; exit 1; }
awk -v fpr="$fingerprint" '$1 == "[GNUPG:]" && $2 == "VALIDSIG" && $NF == fpr { ok = 1 } END { exit !ok }' \
    "$work/status" || { echo "$manifest for $version: not signed by $fingerprint" >&2; exit 1; }

# --- Print the download ---
# The manifest names its own version. Checking it means that an older
# manifest, signed as well, cannot stand in for this one.
jq -er --arg v "$version" --arg f "$file" --arg url "$base/linux-x64/$file" '
    select(.version == $v) | .platforms["linux-x64"]
    | select(.binary == $f and (.checksum | test("^[0-9a-f]{64}$")) and .size > 0)
    | "\($url) \(.checksum) \(.size)"' "$work/manifest" ||
    { echo "$manifest: no linux-x64 $file of $version in it" >&2; exit 1; }
