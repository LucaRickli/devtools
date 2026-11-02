#!/bin/sh
# Tests org.mozilla.firefox from inside its sandbox, as installed.
#
#   firefox-test      (as build/flatpak.sh test runs it)
#
# The Containerfile's test stage makes the test app: the app, with this
# script as /app/bin/firefox-test. It checks that:
#   - Firefox, started through the launcher, is the tarball's version. The
#     launcher ran the prestart, so the Pywalfox host's manifest and
#     user-dirs.dirs are in place.
#   - The Pywalfox host passes `pywalfox self-test`, which tests its
#     protocol against scratch homes.
#   - Every library Firefox links is its own or the runtime's.
#   - Firefox renders a page without a display. The screenshot of a red page
#     with black text is a PNG of the window's size. Its first rows are that
#     red, with the text in them.
#   - A font was found and drawn. In the lines below, ten W's are well over
#     twice as wide as ten i's. That is not so for the boxes Firefox draws
#     for a glyph it has no font for: each box shows the glyph's code point,
#     and all have one width.
set -eu

# --- Version, prestart and libraries ---
test "$(firefox --version)" = "Mozilla Firefox $(sed -n 's/^Version=//p' /app/lib/firefox/application.ini)"
cmp /app/share/pywalfox/pywalfox.json "$HOME/.mozilla/native-messaging-hosts/pywalfox.json"
# shellcheck disable=SC2016  # the line as firefox-prestart writes it, $HOME unexpanded
grep -qx 'XDG_DOWNLOAD_DIR="$HOME/Downloads"' "$XDG_CONFIG_HOME/user-dirs.dirs"
pywalfox self-test
missing=$(find /app/lib/firefox -type f \( -name '*.so' -o -perm -u+x \) \
    -exec env LD_LIBRARY_PATH=/app/lib/firefox ldd {} + 2>/dev/null | grep 'not found' || :)
test -z "$missing" || { echo "$missing" >&2; exit 1; }

# --- Firefox renders a page ---
out=$(mktemp -d)
printf '%s\n' '<!doctype html><meta charset="utf-8">' \
    '<body style="margin:0;background:#f00;color:#000;font:96px/160px sans-serif">' \
    '<div>Grüße</div><div>iiiiiiiiii</div><div>WWWWWWWWWW</div>' > "$out/page.html"
firefox --headless --screenshot "$out/shot.png" "file://$out/page.html"
python3 - "$out/shot.png" <<'EOF'
import struct, sys, zlib
png = open(sys.argv[1], "rb").read()
assert png[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
chunks, pos = {}, 8
while pos < len(png):
    n, kind = struct.unpack(">I4s", png[pos:pos + 8])
    chunks[kind] = chunks.get(kind, b"") + png[pos + 8:pos + 8 + n]
    pos += 12 + n
width, height, depth, color = struct.unpack(">IIBB", chunks[b"IHDR"][:10])
assert width >= 800 and height >= 600 and depth == 8 and color in (2, 6), (width, height, depth, color)
bpp, raw = 3 if color == 2 else 4, zlib.decompress(chunks[b"IDAT"])
stride, prev, red, dark = width * bpp, bytearray(width * bpp), 0, 0
# each 160-row line's dark columns: Grüße, the i's, the W's
cols = [set(), set(), set()]
for y in range(480):
    f, line = raw[y * (stride + 1)], bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
    for x in range(stride):
        a, b = line[x - bpp] if x >= bpp else 0, prev[x]
        c = prev[x - bpp] if x >= bpp else 0
        pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
        paeth = a if pa <= pb and pa <= pc else b if pb <= pc else c
        line[x] = (line[x] + (0, a, b, (a + b) // 2, paeth)[f]) & 255
    for x in range(0, stride, bpp):
        r, g, bl = line[x:x + 3]
        if r < 80 and g < 80 and bl < 80:
            cols[y // 160].add(x)
            dark += y < 160
        red += y < 160 and r > 200 and g < 60 and bl < 60
    prev = line
i, w = ((max(c) - min(c)) // bpp + 1 if c else 0 for c in cols[1:])
assert red > 80 * width and dark > 1000, ("red", red, "dark", dark)
assert i and w > 2 * i, ("i", i, "W", w)
print("screenshot: %dx%d, its first 160 rows %d red and %d dark pixels; ten i's %d, ten W's %d pixels wide" % (width, height, red, dark, i, w))
EOF
