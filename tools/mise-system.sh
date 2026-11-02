#!/bin/sh
#
# Sets up the system part of mise in a PREFIX that install.sh filled: mise's
# settings, and tools.txt's Go and Deno as mise's own installs.
#
#   mise-system.sh PREFIX ETC [AT]
#
# What it writes:
#   - mise-config.toml, mise's settings, as ETC/config.toml.
#   - tools.txt's Go and Deno as mise's installs of their versions, in
#     PREFIX/share/mise. A project that names those versions gets them
#     offline, with no download, and `mise ls` lists them.
#
# AT is where PREFIX will be when the image runs. It defaults to PREFIX, as
# in both builds. The dev container uses mise's default dirs (/etc/mise and
# /usr/local/share/mise). The Flatpak names its own with MISE_SYSTEM_*, in
# the labels of apps/io.github.lucarickli.Code/Containerfile.
set -eu

usage='usage: mise-system.sh PREFIX ETC [AT]'
here=$(dirname "$0")
prefix=${1:?$usage}
etc=${2:?$usage}
at=${3:-$prefix}
data=$prefix/share/mise

# --- Settings ---
install -Dm644 "$here/mise-config.toml" "$etc/config.toml"
# mise looks for this file two levels above its binary. It turns off
# `mise self-update`, so the image's mise changes only with the image.
install -Dm644 /dev/null "$prefix/lib/mise/.disable-self-update"

# --- Go and Deno as mise installs ---
# version NAME: prints the version on NAME's line of tools.txt, without a
# leading "v".
version() { awk -v n="$1" '$1 == n { sub(/^v/, "", $2); print $2 }' "$here/tools.txt"; }
go=$(version go) deno=$(version deno)

# The links are relative, so they stay right wherever PREFIX ends up.
# Go is linked whole, because mise sets GOROOT to the install. Deno gets a
# bin directory of its own, because mise puts the install's bin first on
# PATH, and PREFIX/bin would bring every tool along.
mkdir -p "$data/installs/go" "$data/installs/deno/$deno/bin" "$data/shims"
ln -s ../../../../go "$data/installs/go/$go"
ln -s ../../../../../../bin/deno "$data/installs/deno/$deno/bin/deno"

# finish TOOL VERSION: adds what mise adds next to an install of its own,
# and checks on every `mise use`:
#   - a link for each shorter version (1.27 and 1 for 1.27.1), and latest
#   - a shim per executable: a link to mise, at its path when the image runs
# They are made here because mise cannot change a read-only PREFIX (in a
# container it asks for sudo). Without them, every `mise use` fails.
finish() {
    short=$2
    while [ "${short%.*}" != "$short" ]; do
        short=${short%.*}
        ln -s "./$2" "$data/installs/$1/$short"
    done
    ln -s "./$2" "$data/installs/$1/latest"
    for bin in "$data/installs/$1/$2/bin/"*; do
        ln -s "$at/bin/mise" "$data/shims/${bin##*/}"
    done
}
finish go "$go"
finish deno "$deno"
