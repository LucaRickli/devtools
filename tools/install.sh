#!/usr/bin/env bash
#
# Installs the tools pinned in tools.txt into PREFIX, checking every download
# first. tools.txt describes its own format.
#
#   install.sh PREFIX [NAME...]
#   install.sh --list FILE PREFIX [NAME...]
#
# With NAMEs, it installs only the lines of those tools. With --list, it
# reads FILE instead of tools.txt. FILE has the same format (extensions.txt,
# the VS Code extensions, is one).
#
# Where things go:
#   PREFIX/bin                    the executables
#   PREFIX/go                     Go
#   PREFIX/rustup, PREFIX/cargo   Rust
#   PREFIX/share/licenses/NAME    each tool's license texts
#
# Nothing is installed unverified:
#   - A download must match upstream's sha256, or the sha256 pinned on its
#     line.
#   - A license text fetched by URL must match the sha256 pinned with it.
#   - go install checks every module against sum.golang.org.
#   - rustup checks what it installs against the channel manifest.
#
# Needs bash, curl, sha256sum, tar with gzip and xz, unzip, and openssl (for
# minisign signatures).
set -euo pipefail

# --- Setup ---
pins=$(dirname "$0")/tools.txt
list=
if [ "${1:-}" = --list ]; then
    pins=${2:?usage: install.sh [--list FILE] PREFIX [NAME...]}
    list=1
    shift 2
fi
prefix=${1:?usage: install.sh [--list FILE] PREFIX [NAME...]}
shift
only=" $* "
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# Go tools are built with the Go that this script installs. Its bin comes
# first on PATH, and GOTOOLCHAIN=local stops go from switching to another
# toolchain. The caches are in the work directory, removed on exit.
# -modcacherw keeps the module cache deletable (go writes it read-only).
export PATH="$prefix/go/bin:$PATH" GOTOOLCHAIN=local GOFLAGS=-modcacherw \
    GOPATH="$work/gopath" GOCACHE="$work/gocache"
mkdir -p "$prefix/bin"

# --- Helpers ---
# fetch URL FILE: downloads URL into FILE. It retries, because GitHub resets
# release downloads often enough to matter.
fetch() { curl -fsSL --retry 5 --retry-all-errors -o "$2" "$1"; }

# pick NAME: prints the sha256 for file NAME from the checksum file on stdin.
# A checksum file is one of:
#   HASH          a bare hash, maybe without a trailing newline (kubectl and
#                 go publish these)
#   HASH  NAME    a line per asset of the release
#   HASH *NAME    the same with a "*" (rustup writes "*./NAME")
pick() {
    local h f
    while read -r h f _ || [ -n "$h" ]; do
        f=${f#\*} f=${f#./}
        if [[ $h =~ ^[0-9a-f]{64}$ ]] && { [ -z "$f" ] || [ "$f" = "$1" ]; }; then
            echo "$h"
            return 0
        fi
    done
    return 1
}

# minisig FILE KEY: succeeds when FILE.minisig is a valid minisign signature
# of FILE by KEY, a public key in base64 as minisign prints it. It checks
# what `minisign -V` checks, with openssl:
#   - The signature is Ed25519 over FILE's BLAKE2b-512 hash. That is
#     minisign's default kind, "ED". The legacy unhashed kind fails.
#   - The signature names the key's id.
#   - The global signature covers the signature and the trusted comment.
minisig() {
    local t=$1.check
    mkdir -p "$t"
    # A .minisig file has four lines: an untrusted comment, the signature,
    # the trusted comment and the global signature.
    base64 -d <<<"$2" >"$t/key" &&
        sed -n 2p "$1.minisig" | base64 -d >"$t/sig" &&
        sed -n 4p "$1.minisig" | base64 -d >"$t/global" || return 1
    # The key starts with "Ed" and the signature with "ED". The same 8-byte
    # key id follows in both.
    [ "$(head -c 2 "$t/key")" = Ed ] && [ "$(head -c 2 "$t/sig")" = ED ] &&
        [ "$(head -c 10 "$t/key" | tail -c 8 | base64)" = "$(head -c 10 "$t/sig" | tail -c 8 | base64)" ] ||
        return 1
    # openssl takes the key as DER: the fixed header of an Ed25519 public
    # key, then the key's last 32 bytes.
    { printf '\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00'; tail -c 32 "$t/key"; } >"$t/key.der"
    tail -c 64 "$t/sig" >"$t/sig.raw"
    openssl dgst -blake2b512 -binary "$1" >"$t/hash"
    { cat "$t/sig.raw"; sed -n 's/^trusted comment: //p' "$1.minisig" | tr -d '\n'; } >"$t/comment"
    openssl pkeyutl -verify -pubin -keyform DER -inkey "$t/key.der" -rawin \
        -in "$t/hash" -sigfile "$t/sig.raw" >/dev/null &&
        openssl pkeyutl -verify -pubin -keyform DER -inkey "$t/key.der" -rawin \
            -in "$t/comment" -sigfile "$t/global" >/dev/null
}

# notices DIR: copies the license texts that the current line names into
# PREFIX/share/licenses/NAME. It reads the line's fields from the main loop.
# Each license entry is one of:
#   - A path under DIR: the unpacked release, the Go module or the Rust
#     toolchain. A path ending in "/" copies that directory's files.
#   - A URL of upstream's file at the tag, followed by "#sha256:HEX".
#     Releases publish no checksum for these files, so the line pins one.
#     When the text changes (a new copyright year, a new notice), the
#     version bump fails until someone has read it and pinned the new one.
# A copyleft license also needs a way to the source next to the binary.
# That is the line's source URL, written to SOURCES. A copyleft license on a
# line without one fails.
notices() {
    local dir=$prefix/share/licenses/$name files l url hash
    [ "$license" != - ] || return 0
    mkdir -p "$dir"
    IFS=, read -ra files <<<"$license"
    for l in "${files[@]}"; do
        case $l in
        https://*)
            url=${l%%#*} hash=${l#"$url"}
            [[ $hash =~ ^#sha256:[0-9a-f]{64}$ ]] || { echo "$name: no #sha256:<hex> after $url" >&2; exit 1; }
            fetch "$url" "$dir/${url##*/}"
            echo "${hash#\#sha256:}  $dir/${url##*/}" | sha256sum -c --quiet - || {
                echo "$name: $url differs from the sha256 on the line; read it, then pin its sha256sum" >&2
                exit 1
            }
            ;;
        */) cp -R "$1/$l." "$dir" ;;
        *) install -m0644 "$1/$l" -t "$dir" ;;
        esac
    done
    if [ -n "$source" ]; then
        # Check that the URL exists, so that a pointer to nothing fails the
        # build.
        curl -fsSIL --retry 5 --retry-all-errors -o /dev/null "$source"
        printf '%s %s is built from the source at\n%s\n' "$name" "$ver" "$source" >"$dir/SOURCES"
    elif grep -rqiE 'GNU (General|Lesser|Library|Affero) Public License|Mozilla Public License' "$dir"; then
        echo "$name: a copyleft license, but no source on the line" >&2
        exit 1
    fi
    echo "$name $ver: $dir"
}

# --- Install each line ---
# The list is read on fd 3, so that no command in the loop can read from it
# by accident.
found=" "
while read -r name ver asset sum members license source <&3; do
    case $name in '' | '#'*) continue ;; esac
    # With NAMEs, skip the other lines.
    [ "$only" = "  " ] || [[ $only == *" $name "* ]] || continue
    found+="$name "
    # Every line needs a license. Only a --list file may say "-" for none,
    # because a .vsix carries its own.
    [[ -n $license && ($license != - || -n $list) ]] || { echo "$name: no license on the line" >&2; exit 1; }
    # In the fields, {v} is the version as written and {n} the version
    # without a leading "v".
    n=${ver#v}
    sub() { local s=${1//\{v\}/$ver}; printf '%s' "${s//\{n\}/$n}"; }
    asset=$(sub "$asset") sum=$(sub "$sum") members=$(sub "$members")
    license=$(sub "$license") source=$(sub "$source")
    # A work directory per tool. x/ receives what gets installed.
    d=$work/$name
    mkdir -p "$d/x"

    # The asset is one of:
    #   go:PACKAGE   built with go install
    #   rustup       the Rust toolchain, installed by rustup-init
    #   a URL        a release file, downloaded and checked
    case $asset in
    go:*)
        # CGO_ENABLED=0 builds static binaries. They run on any glibc,
        # including the Flatpak runtime's. dlv only loses its eBPF tracing
        # backend. The module proxy can fail like any download, so there are
        # three tries, 30 s apart.
        for attempt in 1 2 3; do
            GOBIN=$d/x CGO_ENABLED=0 go install "${asset#go:}@$ver" && break
            [ "$attempt" != 3 ] || exit 1
            echo "$name: go install failed (attempt $attempt), retrying in 30s" >&2
            sleep 30
        done
        # The license is in the module's source, which go just downloaded.
        # The asset may name a package rather than a module, so the binary
        # says which main module it was built from.
        bins=("$d"/x/*)
        from=$(go list -m -f '{{.Dir}}' \
            "$(go version -m "${bins[0]}" | awk '$1 == "mod" { print $2 "@" $3 }')")
        ;;
    rustup)
        # Installed system-wide, as in the official rust image: the
        # toolchains in PREFIX/rustup, and the rustup proxies (cargo, rustc
        # and the rest) in PREFIX/cargo/bin. rustup-init comes from the
        # rustup line before this one, and is removed once it has run.
        RUSTUP_HOME=$prefix/rustup CARGO_HOME=$prefix/cargo "$prefix/bin/rustup-init" -y \
            --no-modify-path --profile minimal --default-toolchain "$ver" --component "$members"
        rm "$prefix/bin/rustup-init"
        echo "$name $ver: $prefix/rustup, $prefix/cargo"
        notices "$prefix/rustup/toolchains/$ver-x86_64-unknown-linux-gnu"
        rm -rf "$d"
        continue
        ;;
    *)
        # A URL: download it, and check its sha256 before unpacking it.
        from=$d/x
        f=$d/${asset##*/}
        fetch "$asset" "$f"
        # The checksum column is one of:
        #   sha256:HEX   the sha256 itself, pinned on the line
        #   URL          a checksum file
        #   .EXT         a checksum file at the asset's URL plus .EXT
        # "URL,minisign:KEY" also requires KEY's signature on the checksum
        # file, in URL.minisig.
        key=
        if [[ $sum == *,minisign:* ]]; then key=${sum#*,minisign:} sum=${sum%%,*}; fi
        case $sum in
        sha256:*) want=${sum#sha256:} ;;
        http*) fetch "$sum" "$d/sums" && want=$(pick "${f##*/}" <"$d/sums") ;;
        .*) fetch "$asset$sum" "$d/sums" && want=$(pick "${f##*/}" <"$d/sums") ;;
        *) echo "$name: no checksum for $asset" >&2; exit 1 ;;
        esac || { echo "$name: no sha256 for ${f##*/} in $sum" >&2; exit 1; }
        if [ -n "$key" ]; then
            fetch "$sum.minisig" "$d/sums.minisig"
            minisig "$d/sums" "$key" || { echo "$name: $sum is not signed by the key on the line" >&2; exit 1; }
        fi
        echo "$want  $f" | sha256sum -c --quiet - || { echo "$name: sha256 mismatch" >&2; exit 1; }
        case $f in
        *.tar.gz) tar -xzf "$f" -C "$d/x" ;;
        *.tar.xz) tar -xJf "$f" -C "$d/x" ;;
        *.zip) unzip -q "$f" -d "$d/x" ;;
        *) mv "$f" "$d/x/" ;;
        esac
        ;;
    esac

    # The members column lists what to install, comma separated, each as SRC
    # or SRC:DST. SRC is a path in x/. DST says where it goes:
    #   DIR/   merged into PREFIX/DIR/
    #   a/b    the file PREFIX/a/b
    #   NAME   the executable PREFIX/bin/NAME (by default SRC's base name)
    IFS=, read -ra ms <<<"$members"
    for m in "${ms[@]}"; do
        if [[ $m == *:* ]]; then src=${m%%:*} dst=${m#*:}; else src=$m dst=${m##*/}; fi
        case $dst in
        */)
            # Merged into what is already there, because other tools share
            # the directory (include/, for one).
            mkdir -p "$prefix/$dst"
            cp -a "$d/x/$src." "$prefix/$dst"
            echo "$name $ver: $prefix/$dst"
            ;;
        */*)
            install -Dm0644 "$d/x/$src" "$prefix/$dst"
            echo "$name $ver: $prefix/$dst"
            ;;
        *)
            install -Dm0755 "$d/x/$src" "$prefix/bin/$dst"
            echo "$name $ver: $prefix/bin/$dst"
            ;;
        esac
    done
    notices "$from"
    rm -rf "$d"
done 3<"$pins"

# --- Check the names asked for ---
# A NAME without a line would install nothing, and that would go unnoticed
# until a command is missing.
for name in $only; do
    [[ $found == *" $name "* ]] || { echo "$name: not in $pins" >&2; exit 1; }
done
