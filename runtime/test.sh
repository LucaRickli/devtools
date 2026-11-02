#!/bin/sh
# Tests the runtime as every app sees it: what an app relies on, in the
# sandbox as flatpak sets it up.
#
#   platform-test      (as build/flatpak.sh test runs it)
#
# It is the command of the runtime's test app,
# io.github.lucarickli.Platform.Test, which the Containerfile's test stage
# makes, with this script as /app/bin/platform-test. build/flatpak.sh test
# runs it in that app's sandbox.
#
# It checks:
#   - the Fedora release of the branch
#   - flatpak's own ld.so.conf, which flatpak writes only when the
#     runtime's is empty, and the libraries an app links, in its cache
#   - the fonts, from caches that are valid as deployed (fontconfig writes
#     none of its own)
#   - Python and the shell's tools
#   - xdg-open and xdg-email, which are the portal's
#   - glibc's English locale
#   - GL's dirs, and Mesa's EGL and GBM
#   - the CA bundle, and the schemas and themes GTK reads
#   - an SVG icon loaded as GTK loads it: by gdk-pixbuf through glycin,
#     whose loader runs sandboxed under prlimit
set -eu
# shellcheck source=/dev/null  # the runtime's, in the sandbox
. /etc/os-release

# --- Release and libraries ---
test "$ID" = fedora
test "$VERSION_ID" = "$(sed -n 's|^runtime=runtime/io\.github\.lucarickli\.Platform/[^/]*/||p' /.flatpak-info)"
test "$LD_LIBRARY_PATH" = /app/lib64
test -f /usr/etc/ld.so.conf && test ! -s /usr/etc/ld.so.conf
grep -qxF 'include /run/flatpak/ld.so.conf.d/runtime-*.conf' /etc/ld.so.conf
cache=$(ldconfig -p)
for lib in libEGL.so.1 libGL.so.1 libgbm.so.1 libvulkan.so.1 libva.so.2 libgtk-3.so.0 \
    libgtk-4.so.1 libadwaita-1.so.0 libatspi.so.0 libdbus-1.so.3 libasound.so.2 libpulse.so.0 \
    libpipewire-0.3.so.0 libspeechd.so.2 libnotify.so.4 libsecret-1.so.0 libfontconfig.so.1; do
    printf '%s\n' "$cache" | grep -q "^[[:space:]]$lib " || { echo "not in the ld.so cache: $lib" >&2; exit 1; }
done

# --- Fonts ---
# The fonts must come from the runtime's caches, valid as deployed. With the
# user's cache removed first, fontconfig must write none of its own.
fccache=${XDG_CACHE_HOME:-$HOME/.cache}/fontconfig
rm -rf "$fccache"
for family in 'Noto Sans' 'Noto Serif' 'Noto Sans Mono' 'Noto Color Emoji' 'Liberation Sans' Cantarell; do
    fc-list : family | grep -qxF "$family" || { echo "no font $family" >&2; exit 1; }
done
test "$(fc-match -f '%{family}' sans-serif)" = 'Noto Sans'
test "$(fc-match -f '%{family}' Arial)" = 'Liberation Sans'
test -z "$(ls -A "$fccache" 2>/dev/null)"

# --- Tools, locale, GL and what GTK reads ---
python3 -V
for tool in sh cmp diff find grep sed awk prlimit; do command -v "$tool" >/dev/null || { echo "no $tool" >&2; exit 1; }; done
test "$(command -v xdg-open)" = /usr/bin/xdg-open
test "$(readlink -f /usr/bin/xdg-open)" = /usr/bin/flatpak-xdg-open
test "$(readlink -f /usr/bin/xdg-email)" = /usr/bin/flatpak-xdg-email
locale -a | grep -qx en_US.utf8
test -d /usr/lib64/GL && test "$(readlink /etc/glvnd)" = ../lib64/GL/glvnd && test "$(readlink /etc/vulkan)" = ../lib64/GL/vulkan
test -s /usr/share/glvnd/egl_vendor.d/50_mesa.json && test -f /usr/lib64/gbm/dri_gbm.so
test "$(grep -c 'BEGIN CERTIFICATE' /etc/ssl/certs/ca-certificates.crt)" -gt 100
test -s /usr/share/glib-2.0/schemas/gschemas.compiled
test -f /usr/share/icons/Adwaita/index.theme && test -d /usr/share/icons/Adwaita/cursors

# --- An SVG icon, loaded as GTK loads it ---
# Adwaita's icon for a missing icon, which GTK 3 aborts without. GTK loads
# every SVG this way: gdk-pixbuf hands it to glycin, which in a Flatpak runs
# its loader with flatpak-spawn --sandbox, under prlimit (util-linux's).
python3 - /usr/share/icons/Adwaita/scalable/status/image-missing.svg <<'EOF'
import ctypes, sys
class GError(ctypes.Structure):
    _fields_ = [("domain", ctypes.c_uint32), ("code", ctypes.c_int), ("message", ctypes.c_char_p)]
pixbuf = ctypes.CDLL("libgdk_pixbuf-2.0.so.0")
pixbuf.gdk_pixbuf_new_from_file_at_size.restype = ctypes.c_void_p
pixbuf.gdk_pixbuf_new_from_file_at_size.argtypes = [
    ctypes.c_char_p, ctypes.c_int, ctypes.c_int, ctypes.POINTER(ctypes.POINTER(GError))]
pixbuf.gdk_pixbuf_get_width.argtypes = pixbuf.gdk_pixbuf_get_height.argtypes = [ctypes.c_void_p]
error = ctypes.POINTER(GError)()
image = pixbuf.gdk_pixbuf_new_from_file_at_size(sys.argv[1].encode(), 48, 48, ctypes.byref(error))
if not image:
    sys.exit("%s: %s" % (sys.argv[1], error.contents.message.decode() if error else "not loaded"))
size = pixbuf.gdk_pixbuf_get_width(image), pixbuf.gdk_pixbuf_get_height(image)
assert size == (48, 48), size
print("%s: %dx%d" % (sys.argv[1], *size))
EOF
