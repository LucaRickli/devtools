#!/bin/sh
# Tests the SDK as every app sees it: what the VS Code Flatpak relies on.
#
#   sdk-test      (as build/flatpak.sh test runs it)
#
# It is the command of the SDK's test app, io.github.lucarickli.Sdk.Test,
# which the Containerfile's test stage makes, with this script as
# /app/bin/sdk-test. build/flatpak.sh test runs it in that app's sandbox.
#
# It checks:
#   - the Fedora release of the branch
#   - the runtime's environment, which the SDK's image has from the
#     runtime's labels
#   - flatpak's own ld.so.conf, and the libraries VS Code links, in its cache
#   - the fonts, from the runtime's caches, still valid as deployed
#     (fontconfig writes none)
#   - the rpm database, which the scan asks
#   - the tools at work: compilers and build systems, gdb and strace, git
#     with LFS, the shell's and the terminal's tools, Perl, Python, sqlite3
#     and the archivers (see below)
set -eu
# shellcheck source=/dev/null  # the SDK's, in the sandbox
. /etc/os-release

# --- The SDK as an app sees it ---
test "$ID" = fedora
test "$VERSION_ID" = "$(sed -n 's|^runtime=runtime/io\.github\.lucarickli\.Sdk/[^/]*/||p' /.flatpak-info)"
# Every variable of the runtime's environment (runtime/Containerfile's
# labels).
test "$PATH" = /app/bin:/usr/bin
test "$LD_LIBRARY_PATH" = /app/lib64
test "$XDG_DATA_DIRS" = /app/share:/usr/share:/run/host/user-share:/run/host/share
test "$GI_TYPELIB_PATH" = /app/lib64/girepository-1.0
test "$GST_PLUGIN_SYSTEM_PATH" = /app/lib64/gstreamer-1.0:/usr/lib64/gstreamer-1.0
test "$XCURSOR_PATH" = /run/host/user-share/icons:/run/host/share/icons:/usr/share/icons
test "$__EGL_EXTERNAL_PLATFORM_CONFIG_DIRS" = /etc/egl/egl_external_platform.d:/usr/lib64/GL/egl/egl_external_platform.d:/usr/share/egl/egl_external_platform.d
test "$GBM_BACKENDS_PATH" = /usr/lib64/GL/lib/gbm:/usr/lib64/gbm
test -f /usr/etc/ld.so.conf && test ! -s /usr/etc/ld.so.conf
grep -qxF 'include /run/flatpak/ld.so.conf.d/runtime-*.conf' /etc/ld.so.conf
test -d /usr/lib64/GL && test "$(readlink /etc/glvnd)" = ../lib64/GL/glvnd && test "$(readlink /etc/vulkan)" = ../lib64/GL/vulkan
cache=$(ldconfig -p)
for lib in libnss3.so libnssutil3.so libsmime3.so libnspr4.so libplc4.so libplds4.so libxkbfile.so.1 \
    libgtk-3.so.0 libgbm.so.1 libasound.so.2 libdbus-1.so.3 libsecret-1.so.0 libsystemd.so.0 \
    libstdc++.so.6 libssl.so.3; do
    # Not grep -q, which would stop reading and leave printf a broken pipe.
    printf '%s\n' "$cache" | grep "^[[:space:]]$lib " >/dev/null || { echo "not in the ld.so cache: $lib" >&2; exit 1; }
done
# The fonts must come from the runtime's caches, still valid as deployed.
# With the user's cache removed first, fontconfig must write none of its own.
fccache=${XDG_CACHE_HOME:-$HOME/.cache}/fontconfig
rm -rf "$fccache"
test "$(fc-match -f '%{family}' sans-serif)" = 'Noto Sans'
test "$(fc-match -f '%{family}' monospace)" = 'Noto Sans Mono'
test -z "$(ls -A "$fccache" 2>/dev/null)"
# The rpm database, which the image scan asks, lists the SDK's packages.
for pkg in gcc gcc-c++ cmake ninja-build meson autoconf automake libtool bison flex gettext \
    gdb git-core git-lfs nss libxkbfile ncurses util-linux-script perl-interpreter \
    python3-pip python3-devel sqlite bsdtar wget2-wget; do
    rpm -q --quiet "$pkg"
done
test -s /usr/share/fedora-bootc/advisories-at-build.json
# Translations are English only, also for what the SDK added (git's and
# gdb's).
test -z "$(find /usr/share/locale -name '*.mo' ! -path '/usr/share/locale/en*' | head -n 1)"
for tool in cc c++ make pkg-config cmake ninja meson autoconf automake autoreconf libtoolize m4 \
    bison flex msgfmt xgettext autopoint envsubst \
    gdb strace git git-lfs ssh less jq which file ps pgrep patch unzip \
    openssl xz zstd tar curl gpg python3 \
    clear reset tput infocmp tic hostname zip script perl shasum python pip pip3 python3-config \
    sqlite3 cpio bsdtar wget nano; do
    command -v "$tool" >/dev/null || { echo "no $tool" >&2; exit 1; }
done

# --- The tools at work ---
# A C program built against OpenSSL's headers and run, and a C++ one built
# with make. gdb and strace run them, which needs the test app's devel
# feature.
cd "$(mktemp -d)"
cat >ssl.c <<'C'
#include <openssl/crypto.h>
#include <stdio.h>
int main(void) { puts(OpenSSL_version(OPENSSL_VERSION)); return 0; }
C
# shellcheck disable=SC2046  # pkg-config's words, split
cc -g -o ssl ssl.c $(pkg-config --cflags --libs openssl)
./ssl | grep -q '^OpenSSL 3\.'
cat >hello.cc <<'CXX'
#include <iostream>
int main() { std::cout << "c++ ok" << std::endl; }
CXX
# shellcheck disable=SC2016  # make's variables
printf 'hello: hello.cc\n\t$(CXX) -g -o $@ $<\n' >Makefile
make -s CXX=c++
test "$(./hello)" = "c++ ok"
gdb -q -batch -ex 'break main' -ex run -ex 'info frame' ./hello | grep -q 'hello.cc'
strace -f -e trace=execve -o trace ./ssl >/dev/null
grep -q 'execve("./ssl"' trace
# The same C++ program built with CMake and Ninja, with Meson, and with the
# autotools (automake, libtool's macros and a configure script run). Then a
# flex scanner is run, a bison parser written, a gettext catalog compiled,
# and envsubst tried.
printf 'cmake_minimum_required(VERSION 3.20)\nproject(hello CXX)\nadd_executable(hello hello.cc)\n' >CMakeLists.txt
cmake -S . -B cmake -G Ninja >/dev/null && ninja -C cmake >/dev/null && test "$(cmake/hello)" = "c++ ok"
printf "project('hello', 'cpp')\nexecutable('hello', 'hello.cc')\n" >meson.build
meson setup mesonbuild >/dev/null && meson compile -C mesonbuild >/dev/null && test "$(mesonbuild/hello)" = "c++ ok"
mkdir auto && cp hello.cc auto/ && (
    cd auto
    printf 'AC_INIT([hello], [1])\nAM_INIT_AUTOMAKE([foreign])\nAC_PROG_CXX\nLT_INIT\nAC_CONFIG_FILES([Makefile])\nAC_OUTPUT\n' >configure.ac
    printf 'bin_PROGRAMS = hello\nhello_SOURCES = hello.cc\n' >Makefile.am
    autoreconf -fi >/dev/null 2>&1 && test -f ltmain.sh
    ./configure -q && test -x libtool && make -s >/dev/null && test "$(./hello)" = "c++ ok"
)
printf '%%option noyywrap\n%%%%\n.|\\n ECHO;\n%%%%\nint main(void) { return yylex(); }\n' >scan.l
flex -o scan.c scan.l && cc -o scan scan.c && test "$(printf flex | ./scan)" = flex
printf '%%%%\ns: ;\n%%%%\n' >p.y && bison -o p.c p.y && grep -q yyparse p.c
printf 'msgid "a"\nmsgstr "b"\n' >t.po && msgfmt -o t.mo t.po && test -s t.mo
# shellcheck disable=SC2016  # envsubst's variable
test "$(printf '$X' | X=42 envsubst)" = 42
ssh -V 2>&1 | grep -q '^OpenSSH_'
printf '{"a": [1, 2]}' | jq -e '.a | length == 2' >/dev/null
file -b ./hello | grep -q '^ELF 64-bit LSB .*x86-64'
ps -o pid= -p $$ >/dev/null
printf 'a\n' >a && printf 'b\n' >b && ! diff -u a b >ab.patch && patch -s a ab.patch && cmp a b
# The terminal's commands, without a terminal: terminfo's xterm, the escapes
# clear writes, script on a pty of its own, and the host name.
test "$(tput -T xterm colors)" = 8
infocmp xterm >/dev/null
TERM=xterm clear >cleared && test -s cleared
script -qec 'printf scripted' /dev/null | grep -q scripted
test -n "$(hostname)"
# Perl and shasum. Python, its pip, a venv with pip (offline), and the
# headers pip builds against. sqlite3. zip and unzip, and cpio and bsdtar,
# each reading the other's archive.
test "$(perl -e 'print 6 * 7')" = 42
test "$(printf abc | shasum -a 256 | cut -d' ' -f1)" = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
python --version | grep -q '^Python 3\.'
pip --version | grep -q '^pip '
python3 -m venv venv && venv/bin/pip --version | grep -q '^pip '
printf '#include <Python.h>\n' >py.c
# shellcheck disable=SC2046  # python3-config's words, split
cc -fsyntax-only $(python3-config --includes) py.c
test "$(sqlite3 :memory: 'select 6 * 7')" = 42
zip -q a.zip a && test "$(unzip -p a.zip a)" = b
printf 'a\n' | cpio -o --quiet -H newc >a.cpio && test "$(bsdtar -tf a.cpio)" = a
bsdtar -cf b.cpio --format=newc b && test "$(cpio -it --quiet <b.cpio)" = b
wget --version | grep -q 'Wget'
nano --version | grep -q 'nano'

# A git repository with a file in LFS.
git init -q repo && cd repo
git lfs install --local >/dev/null
git lfs track '*.bin' >/dev/null
head -c 4096 /dev/urandom >blob.bin
git add .gitattributes blob.bin
git -c user.name=t -c user.email=t@example.invalid commit -q -m lfs
test "$(git lfs ls-files -n)" = blob.bin
git cat-file -p HEAD:blob.bin | grep -q '^version https://git-lfs.github.com/spec/v1$'
