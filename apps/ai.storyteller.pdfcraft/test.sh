#!/bin/sh
# Tests ai.storyteller.pdfcraft from inside its sandbox, as installed.
#
#   pdfcraft-test      (as build/flatpak.sh test runs it)
#
# The Containerfile's test stage makes the test app: the app, with this
# script as /app/bin/pdfcraft-test. It checks that:
#   - PdfCraft and pdfcraft-cli start, and are the metainfo's version.
#   - Every library they link loads from the runtime. So does every one that
#     PdfCraft loads by name when it starts (each soname it names).
#   - Printing works. lp, lpstat and lpoptions are there and run, and the
#     socket their libcups dials is the one flatpak mounts,
#     /var/run/cups/cups.sock.
#   - The desktop file starts the app and has its icon.
#   - pdfcraft-cli works without a display. A one-page PDF with a line of
#     text, made here, is one 612x792 pt page with that text. It renders as
#     a PNG of 612x792 at 72 dpi, and has two pages once a blank one is
#     inserted. Its page as an image, made a PDF and OCR'd with the models
#     in /app/share/pdfcraft/models, has the text again.
set -eu

# --- The app, its libraries, printing, its desktop file ---
id=ai.storyteller.pdfcraft
bins="/app/bin/pdfcraft /app/bin/pdfcraft-cli"
version=$(sed -n 's|.*<release version="\([^"]*\)".*|\1|p' "/app/share/metainfo/$id.metainfo.xml" | head -n 1)
for bin in $bins; do
    # shellcheck disable=SC2046  # the words of its first line
    set -- $("$bin" --version | head -n 1)
    test "${2-}" = "$version" || { echo "$bin --version: $*, not $version" >&2; exit 1; }
done
# shellcheck disable=SC2086  # the binaries
missing=$(ldd $bins | grep 'not found' || :)
test -z "$missing" || { echo "$missing" >&2; exit 1; }
# Each soname the binaries name must load, because PdfCraft loads some by
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
test "$(sed -n 's/^Exec=\([^ ]*\).*/\1/p' "$desktop")" = pdfcraft
test "$(sed -n 's/^Icon=//p' "$desktop")" = "$id"
test -s "/app/share/icons/hicolor/scalable/apps/$id.svg"

# --- pdfcraft-cli without a display ---
cd "$(mktemp -d)"
# A PDF of one US Letter page with the line in Helvetica, 48 pt.
python3 - in.pdf 'Hello PdfCraft 42' <<'EOF'
import sys
objs = [
    b"<< /Type /Catalog /Pages 2 0 R >>",
    b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
    b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
]
content = b"BT /F1 48 Tf 72 680 Td (" + sys.argv[2].encode() + b") Tj ET"
objs.append(b"<< /Length %d >>\nstream\n" % len(content) + content + b"\nendstream")
out, offsets = bytearray(b"%PDF-1.4\n"), []
for i, obj in enumerate(objs, 1):
    offsets.append(len(out))
    out += b"%d 0 obj\n" % i + obj + b"\nendobj\n"
xref = len(out)
out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1)
out += b"".join(b"%010d 00000 n \n" % off for off in offsets)
out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, xref)
open(sys.argv[1], "wb").write(out)
EOF
# pages FILE: prints FILE's page count, and its first page's size in pt.
pages() {
    pdfcraft-cli info "$1" | python3 -c '
import json, sys
info = json.load(sys.stdin)
print(info["pages"], "%gx%g" % tuple(info["first_page_pt"]))'
}
# size PNG: prints the PNG's width x height, in pixels.
size() {
    python3 -c '
import struct, sys
head = open(sys.argv[1], "rb").read(24)
assert head[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
print("%dx%d" % struct.unpack(">II", head[16:]))' "$1"
}
test "$(pages in.pdf)" = '1 612x792'
test "$(pdfcraft-cli text in.pdf)" = 'Hello PdfCraft 42'
pdfcraft-cli render in.pdf --page 1 --dpi 72 --out page.png >/dev/null
test "$(size page.png)" = 612x792
pdfcraft-cli edit in.pdf --out two.pdf --insert-blank 1
test "$(pages two.pdf)" = '2 612x792'
pdfcraft-cli render in.pdf --page 1 --dpi 150 --out scan.png >/dev/null
pdfcraft-cli batch scan.png --steps convert,ocr --out-dir ocr >/dev/null
pdfcraft-cli text ocr/scan.pdf | grep -q 'Hello PdfCraft 42'
echo "pdfcraft $version: libraries, printing tools, desktop file; PDF info, text, render, edit and OCR"
