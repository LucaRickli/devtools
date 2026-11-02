#!/bin/sh
# Tests org.remmina.Remmina from inside its sandbox, as installed.
#
#   remmina-test      (as build/flatpak.sh test runs it)
#
# The Containerfile's test stage makes the test app: the app, with this
# script as /app/bin/remmina-test. It checks that:
#   - Remmina starts, and is the release its metainfo names.
#   - Every plugin it ships loads, and none fails to. Each one is there: RDP
#     (with its file handler and preferences), VNC (and its listener),
#     SPICE (and its .vv files), EXEC and the secret plugin.
#   - Every library Remmina and the plugins link resolves in the sandbox,
#     which has nothing but the runtime and /app.
#   - The sandbox is the tightened one. It has the files and D-Bus names the
#     labels grant and no more (/.flatpak-info), and a read-only home. It
#     has no command on the host (org.freedesktop.Flatpak), so
#     flatpak-spawn --host is refused. flatpak.sh test's throwaway home has
#     no ~/.ssh/known_hosts or download dir to show writable, so those two
#     are checked as grants only.
#   - Each protocol talks to a server (see below).
set -eu

# --- Remmina, its plugins and libraries ---
release=$(sed -n 's/.*<release version="\([^"]*\)".*/\1/p' /app/share/metainfo/org.remmina.Remmina.appdata.xml | head -n 1)
version=$(remmina --version)
case "$version" in
    *" $release (git "*) ;;
    *) echo "remmina --version: $version, not $release" >&2; exit 1 ;;
esac
plugins=$(remmina --full-version 2>&1)
for name in RDP RDPF RDPS VNC VNCI SPICE SPICEF EXEC glibsecret; do
    printf '%s\n' "$plugins" | grep -q "^$name " || { printf '%s\n' "$plugins" "no plugin $name" >&2; exit 1; }
done
if printf '%s\n' "$plugins" | grep -q '^Failed'; then printf '%s\n' "$plugins" >&2; exit 1; fi
missing=$(find /app -type f \( -name '*.so' -o -perm -u+x \) -exec ldd {} + 2>/dev/null |
    awk '/:$/ { file = $1 } /not found/ { print file, $1 }')
test -z "$missing" || { echo "$missing" >&2; exit 1; }

# --- The tightened sandbox ---
# section NAME: prints the lines of /.flatpak-info's [NAME] section.
# list KEY: prints the values of [Context]'s KEY, one per line, sorted,
# because flatpak keeps no order.
# sorted WORD...: prints the words sorted the same way, to compare with list.
section() { awk -v g="[$1]" '/^\[/ { on = $0 == g; next } on && NF' /.flatpak-info; }
list() { section Context | sed -n "s/^$1=//p" | tr ';' '\n' | sed '/^$/d' | LC_ALL=C sort; }
sorted() { printf '%s\n' "$@" | LC_ALL=C sort; }
# shellcheck disable=SC2088  # flatpak's spelling of the path, unexpanded
if ! { test "$(list filesystems)" = "$(sorted home:ro '~/.ssh/known_hosts' xdg-download xdg-run/gvfsd)" &&
    test "$(list sockets)" = "$(sorted wayland fallback-x11 pulseaudio cups pcsc ssh-auth)" &&
    test "$(section 'Session Bus Policy' | LC_ALL=C sort)" = "$(sorted org.freedesktop.secrets=talk \
        org.kde.StatusNotifierWatcher=talk com.canonical.indicator.application=talk \
        org.ayatana.indicator.application=talk 'org.gtk.vfs.*=talk')" &&
    test "$(section 'System Bus Policy')" = org.freedesktop.Avahi=talk; }; then
    echo "not the permissions of the Containerfile's labels:" >&2
    cat /.flatpak-info >&2
    exit 1
fi
ls "$HOME" >/dev/null
if touch "$HOME/remmina-test" 2>/dev/null; then echo "the home is writable" >&2; exit 1; fi
command -v flatpak-spawn >/dev/null
if flatpak-spawn --host true 2>/dev/null; then echo "a host command ran" >&2; exit 1; fi

# --- Each protocol talks to a server ---
# Remmina runs on a display of GTK's Broadway backend (the runtime's
# broadwayd). It connects to five servers on localhost, written in the
# runtime's Python, which check what it sends:
#   - VNC: a session's start. After RFB 3.8's handshake, Remmina requests
#     the screen. The server sends it as a raw rectangle and a new size.
#     Remmina then asks for the screen at that size, so it took the update.
#   - RDP: the client's first message, an X.224 Connection Request with
#     RDP's negotiation request (FreeRDP).
#   - SPICE: the link message of SPICE's main channel (spice-gtk).
#   - SSH and SFTP: the SSH version banner (libssh, for each). These two are
#     Remmina's own. It registers them only when it starts in earnest, so
#     --full-version above does not list them.
work=$(mktemp -d)
broadwayd :5 >"$work/broadwayd.log" 2>&1 &
display=$!
python3 - "$work" >"$work/servers.log" 2>&1 <<'EOF' &
import os, socket, struct, sys, threading

work = sys.argv[1]
done, results, lock = threading.Event(), {}, threading.Lock()


def recv(c, n):
    b = b""
    while len(b) < n:
        d = c.recv(n - len(b))
        if not d:
            raise EOFError("closed after %d of %d bytes" % (len(b), n))
        b += d
    return b


def vnc(c):
    c.sendall(b"RFB 003.008\n")
    assert recv(c, 12) == b"RFB 003.008\n", "client version"
    c.sendall(b"\x01\x01")  # one security type, None
    assert recv(c, 1) == b"\x01", "security type"
    c.sendall(struct.pack(">I", 0))
    recv(c, 1)  # ClientInit
    # 64x48, 32 bits per pixel, depth 24, little-endian true colour
    c.sendall(struct.pack(">HHBBBBHHHBBB3xI", 64, 48, 32, 24, 0, 1, 255, 255, 255, 16, 8, 0, 4) + b"test")
    bpp, encodings, sent = 32, (), False
    for _ in range(100):
        kind = recv(c, 1)[0]
        if kind == 0:  # SetPixelFormat
            bpp = recv(c, 19)[3]
        elif kind == 2:  # SetEncodings
            n = struct.unpack(">xH", recv(c, 3))[0]
            encodings = struct.unpack(">%di" % n, recv(c, 4 * n))
        elif kind == 3:  # FramebufferUpdateRequest
            incremental, x, y, w, h = struct.unpack(">BHHHH", recv(c, 9))
            if sent and (w, h) == (80, 60):
                return "RFB 3.8, no security, %d bits per pixel; sent a 64x48 raw rectangle and the size 80x60, asked for 80x60" % bpp
            if not sent:
                assert -223 in encodings, ("no DesktopSize among the encodings", encodings)
                c.sendall(struct.pack(">BxH", 0, 2) + struct.pack(">HHHHi", 0, 0, 64, 48, 0)
                          + b"\xff" * (64 * 48 * bpp // 8) + struct.pack(">HHHHi", 0, 0, 80, 60, -223))
                sent = True
        elif kind == 4:  # KeyEvent
            recv(c, 7)
        elif kind == 5:  # PointerEvent
            recv(c, 5)
        elif kind == 6:  # ClientCutText
            recv(c, struct.unpack(">3xI", recv(c, 7))[0])
        else:
            raise AssertionError("client message %d" % kind)
    raise AssertionError("no request for 80x60")


def rdp(c):
    tpkt = recv(c, 4)
    assert tpkt[:2] == b"\x03\x00", ("not TPKT", tpkt)
    tpdu = recv(c, struct.unpack(">H", tpkt[2:])[0] - 4)
    assert tpdu[1] == 0xE0, ("not an X.224 Connection Request", tpdu[:2])
    kind, _, length, protocols = struct.unpack("<BBHI", tpdu[-8:])
    assert (kind, length) == (1, 8), ("no RDP_NEG_REQ", tpdu)
    return "X.224 Connection Request, RDP_NEG_REQ for protocols 0x%x" % protocols


def spice(c):
    magic, major, minor, size = struct.unpack("<4sIII", recv(c, 16))
    assert (magic, major) == (b"REDQ", 2), (magic, major)
    channel = recv(c, size)[4]
    assert channel == 1, ("channel type", channel)
    return "SpiceLinkMess, protocol %d.%d, main channel" % (major, minor)


def ssh(c):
    c.sendall(b"SSH-2.0-RemminaTest\r\n")
    banner = b""
    while not banner.endswith(b"\n") and len(banner) < 255:
        banner += recv(c, 1)
    assert banner.startswith(b"SSH-2.0-libssh"), banner
    return banner.decode().strip()


checks = ("vnc", vnc), ("rdp", rdp), ("spice", spice), ("ssh", ssh), ("sftp", ssh)


def serve(name, check, s):
    c, _ = s.accept()
    c.settimeout(30)
    try:
        result = "%s: %s" % (name, check(c))
    except Exception as e:
        result = "%s FAILED: %r" % (name, e)
    with lock:
        results[name] = result
        if len(results) == len(checks):
            done.set()
    while True:  # what reconnects: closed at once
        c.close()
        c, _ = s.accept()


ports = []
for name, check in checks:
    s = socket.create_server(("127.0.0.1", 0))
    ports.append(str(s.getsockname()[1]))
    threading.Thread(target=serve, args=(name, check, s), daemon=True).start()
with open(work + "/ports.tmp", "w") as f:
    f.write(" ".join(ports) + "\n")
os.rename(work + "/ports.tmp", work + "/ports")
ok = done.wait(90)
print("\n".join(results[name] for name, _ in checks if name in results) or "no connection")
sys.exit(0 if ok and not any("FAILED" in r for r in results.values()) else 1)
EOF
servers=$!
# Wait up to 10 s for the servers' ports and for broadwayd.
i=0
until [ -s "$work/ports" ] && grep -q '^Listening on' "$work/broadwayd.log"; do
    i=$((i + 1))
    [ "$i" -lt 100 ] || { cat "$work/broadwayd.log" "$work/servers.log" >&2; exit 1; }
    sleep 0.1
done
read -r vnc rdp spice ssh sftp <"$work/ports"
# SFTP has no URI scheme, so it gets a profile file.
printf '%s\n' '[remmina]' name=sftp protocol=SFTP "server=127.0.0.1:$sftp" username=tester >"$work/sftp.remmina"
GDK_BACKEND=broadway BROADWAY_DISPLAY=:5 remmina -c "vnc://127.0.0.1:$vnc" -c "rdp://127.0.0.1:$rdp" \
    -c "spice://127.0.0.1:$spice" -c "ssh://tester@127.0.0.1:$ssh" -c "$work/sftp.remmina" \
    >"$work/remmina.log" 2>&1 &
client=$!
# The servers' exit status is the verdict. Remmina and the display are
# stopped after it.
status=0
wait "$servers" || status=$?
kill "$client" "$display" 2>/dev/null || :
cat "$work/servers.log"
[ "$status" = 0 ] || { cat "$work/remmina.log" >&2; exit 1; }
