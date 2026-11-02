#!/bin/sh
# Tests ai.storyteller.deckcraft from inside its sandbox, as installed.
#
#   deckcraft-test      (as build/flatpak.sh test runs it)
#
# The Containerfile's test stage makes the test app: the app, with this
# script as /app/bin/deckcraft-test. It checks that:
#   - DeckCraft and deckcraft-cli start, and are the metainfo's version.
#   - Every library they link loads from the runtime. So does every one that
#     DeckCraft loads by name when it starts (each soname it names).
#   - The desktop file starts the app and has its icon.
#   - deckcraft-cli works without a display. A deck made here with a new
#     titled slide, saved as DeckCraft's own file, has that slide second
#     (after the title slide). Saved as PowerPoint and read back, it still
#     does. Its slide, drawn, is a PNG of 960x540 pt at 2 px/pt.
set -eu

# --- The app, its libraries, its desktop file ---
id=ai.storyteller.deckcraft
bins="/app/bin/deckcraft /app/bin/deckcraft-cli"
version=$(sed -n 's|.*<release version="\([^"]*\)".*|\1|p' "/app/share/metainfo/$id.metainfo.xml" | head -n 1)
for bin in $bins; do
    # shellcheck disable=SC2046  # the words of its first line
    set -- $("$bin" --version | head -n 1)
    test "${2-}" = "$version" || { echo "$bin --version: $*, not $version" >&2; exit 1; }
done
# shellcheck disable=SC2086  # the binaries
missing=$(ldd $bins | grep 'not found' || :)
test -z "$missing" || { echo "$missing" >&2; exit 1; }
# Each soname the binaries name must load, because DeckCraft loads some by
# name when it starts.
# shellcheck disable=SC2046,SC2086  # one soname a word
python3 -c '
import ctypes, sys
missing = []
for name in sys.argv[1:]:
    try:
        ctypes.CDLL(name)
    except OSError as e:
        missing.append(str(e))
sys.exit("\n".join(missing) or None)' $(grep -aohE 'lib[A-Za-z0-9_+-]+\.so\.[0-9]+' $bins | sort -u)
desktop=/app/share/applications/$id.desktop
test "$(sed -n 's/^Exec=\([^ ]*\).*/\1/p' "$desktop")" = deckcraft
test "$(sed -n 's/^Icon=//p' "$desktop")" = "$id"
test -s "/app/share/icons/hicolor/scalable/apps/$id.svg"

# --- deckcraft-cli without a display ---
cd "$(mktemp -d)"
# titles FILE: prints FILE's slide titles, one per line.
titles() {
    deckcraft-cli info "$1" | python3 -c '
import json, sys
print("\n".join(slide["title"] for slide in json.load(sys.stdin)["slides"]))'
}
# size PNG: prints the PNG's width x height, in pixels.
size() {
    python3 -c '
import struct, sys
head = open(sys.argv[1], "rb").read(24)
assert head[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
print("%dx%d" % struct.unpack(">II", head[16:]))' "$1"
}
deckcraft-cli run --cmd 'slide.new={"title":"Q3 results"}' --save deck.deckcraft
test "$(titles deck.deckcraft)" = "$(printf '\nQ3 results')"
deckcraft-cli convert deck.deckcraft deck.pptx >/dev/null
test "$(head -c 2 deck.pptx)" = PK
test "$(titles deck.pptx)" = "$(printf '\nQ3 results')"
deckcraft-cli render deck.pptx --slide 1 slide.png >/dev/null
test "$(size slide.png)" = 1920x1080
echo "deckcraft $version: libraries, desktop file; a deck made, saved as DeckCraft and PowerPoint, read back, drawn"
