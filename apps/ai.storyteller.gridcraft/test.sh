#!/bin/sh
# Tests ai.storyteller.gridcraft from inside its sandbox, as installed.
#
#   gridcraft-test      (as build/flatpak.sh test runs it)
#
# The Containerfile's test stage makes the test app: the app, with this
# script as /app/bin/gridcraft-test. It checks that:
#   - GridCraft and gridcraft-cli start, and are the metainfo's version.
#   - Every library they link loads from the runtime. So does every one that
#     GridCraft loads by name when it starts (each soname it names).
#   - Printing works. lp, lpstat and lpoptions are there and run, and the
#     socket their libcups dials is the one flatpak mounts,
#     /var/run/cups/cups.sock.
#   - The desktop file starts the app and has its icon.
#   - gridcraft-cli works without a display. A CSV made here, saved as a
#     workbook, reads back as the same CSV. A formula over its cells gives
#     the right value. The workbook saved as a PDF, which is what printing
#     sends to lp, is a PDF.
set -eu

# --- The app, its libraries, printing, its desktop file ---
id=ai.storyteller.gridcraft
bins="/app/bin/gridcraft /app/bin/gridcraft-cli"
version=$(sed -n 's|.*<release version="\([^"]*\)".*|\1|p' "/app/share/metainfo/$id.metainfo.xml" | head -n 1)
for bin in $bins; do
    # shellcheck disable=SC2046  # the words of its first line
    set -- $("$bin" --version | head -n 1)
    test "${2-}" = "$version" || { echo "$bin --version: $*, not $version" >&2; exit 1; }
done
# shellcheck disable=SC2086  # the binaries
missing=$(ldd $bins | grep 'not found' || :)
test -z "$missing" || { echo "$missing" >&2; exit 1; }
# Each soname the binaries name must load, because GridCraft loads some by
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
test "$(sed -n 's/^Exec=\([^ ]*\).*/\1/p' "$desktop")" = gridcraft
test "$(sed -n 's/^Icon=//p' "$desktop")" = "$id"
test -s "/app/share/icons/hicolor/scalable/apps/$id.svg"

# --- gridcraft-cli without a display ---
cd "$(mktemp -d)"
printf 'name,qty,price\napple,3,1.5\npear,4,2.25\n' > in.csv
gridcraft-cli convert in.csv book.xlsx >/dev/null
test "$(head -c 2 book.xlsx)" = PK
test "$(gridcraft-cli cat book.xlsx --csv)" = "$(cat in.csv)"
test "$(gridcraft-cli eval '=SUMPRODUCT(B2:B3,C2:C3)' --in book.xlsx)" = 13.5
gridcraft-cli convert book.xlsx book.pdf >/dev/null
test "$(head -c 5 book.pdf)" = %PDF-
echo "gridcraft $version: libraries, printing tools, desktop file; CSV to workbook and back, a formula, PDF"
