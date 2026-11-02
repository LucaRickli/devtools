#!/bin/sh
# Tests ai.storyteller.wordcraft from inside its sandbox, as installed.
#
#   wordcraft-test      (as build/flatpak.sh test runs it)
#
# The Containerfile's test stage makes the test app: the app, with this
# script as /app/bin/wordcraft-test. It checks that:
#   - WordCraft and wordcraft-cli start, and are the metainfo's version.
#   - Every library they link loads from the runtime. So does every one that
#     WordCraft loads by name when it starts (each soname it names).
#   - Printing works. lp, lpstat and lpoptions are there and run, and the
#     socket their libcups dials is the one flatpak mounts,
#     /var/run/cups/cups.sock.
#   - The desktop file starts the app and has its icon.
#   - wordcraft-cli works without a display, in en_US (US Letter). Markdown
#     with a heading and a line, made here and saved as a Word document,
#     has that text in two paragraphs on one page. Saved as a PDF, it is a
#     PDF. Drawn, it is a PNG of the page, 612x792 pt at 2 px/pt.
set -eu

# --- The app, its libraries, printing, its desktop file ---
id=ai.storyteller.wordcraft
bins="/app/bin/wordcraft /app/bin/wordcraft-cli"
version=$(sed -n 's|.*<release version="\([^"]*\)".*|\1|p' "/app/share/metainfo/$id.metainfo.xml" | head -n 1)
for bin in $bins; do
    # shellcheck disable=SC2046  # the words of its first line
    set -- $("$bin" --version | head -n 1)
    test "${2-}" = "$version" || { echo "$bin --version: $*, not $version" >&2; exit 1; }
done
# shellcheck disable=SC2086  # the binaries
missing=$(ldd $bins | grep 'not found' || :)
test -z "$missing" || { echo "$missing" >&2; exit 1; }
# Each soname the binaries name must load, because WordCraft loads some by
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
# The printing tools run, and libcups dials the socket that flatpak mounts.
for tool in lp lpstat lpoptions; do
    command -v "$tool" >/dev/null || { echo "no $tool" >&2; exit 1; }
done
lpstat -r | grep -q '^scheduler is'
sock=$(grep -aoE '/[a-z/]*/cups\.sock' /usr/lib64/libcups.so.2 | sort -u)
test "$(readlink -m "$sock")" = "$(readlink -m /var/run/cups/cups.sock)"
desktop=/app/share/applications/$id.desktop
test "$(sed -n 's/^Exec=\([^ ]*\).*/\1/p' "$desktop")" = wordcraft
test "$(sed -n 's/^Icon=//p' "$desktop")" = "$id"
test -s "/app/share/icons/hicolor/scalable/apps/$id.svg"

# --- wordcraft-cli without a display ---
cd "$(mktemp -d)"
# A new document's page size is the locale's paper.
export LC_ALL=en_US.UTF-8
# size PNG: prints the PNG's width x height, in pixels.
size() {
    python3 -c '
import struct, sys
head = open(sys.argv[1], "rb").read(24)
assert head[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
print("%dx%d" % struct.unpack(">II", head[16:]))' "$1"
}
printf '# Hello WordCraft\n\nThe quick brown fox 42.\n' > in.md
wordcraft-cli convert in.md doc.docx >/dev/null
test "$(head -c 2 doc.docx)" = PK
test "$(wordcraft-cli text doc.docx)" = "$(printf 'Hello WordCraft\nThe quick brown fox 42.')"
test "$(wordcraft-cli info doc.docx | python3 -c '
import json, sys
info = json.load(sys.stdin)
print(info["pages"], info["paragraphs"])')" = '1 2'
wordcraft-cli convert doc.docx doc.pdf >/dev/null
test "$(head -c 5 doc.pdf)" = %PDF-
wordcraft-cli render doc.docx page.png >/dev/null
test "$(size page.png)" = 1224x1584
echo "wordcraft $version: libraries, printing tools, desktop file; Markdown to Word, text, info, PDF and PNG"
