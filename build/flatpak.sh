#!/usr/bin/env bash
#
# Builds a Flatpak from a container image, and tests a Flatpak in a
# throwaway installation. build.sh runs this script in the builder container
# (build/Containerfile).
#
#   flatpak.sh build OUT IMAGE < FILES.tar
#   flatpak.sh test [--offline] TEST RUNTIME...
#
# build: builds the Flatpak described by IMAGE's labels, from IMAGE's files.
#   IMAGE is an OCI image layout of one image, as docker-bake.hcl writes it.
#   The image's files come on stdin as one tar (build.sh has BuildKit make
#   it). The Flatpak goes to OUT, also an OCI image layout: the form a
#   registry takes. OUT must be absent, empty or an earlier layout, which
#   gets replaced. A build that fails leaves nothing in OUT.
#
# test: installs TEST and RUNTIME... into a throwaway installation, then runs
#   TEST in its sandbox. TEST is an app as `build` writes it, and its command
#   is the test: the test passes when the command exits 0. RUNTIME... must
#   include TEST's runtime, and runtimes go first. The sandbox has the
#   network, or none with --offline, whatever the app itself asks for. Run
#   it as an ordinary user: the Flatpak runs as the user who runs the test.
#
# The labels, from the image's config:
#   flatpak.id        The Flatpak's ID. Required.
#   flatpak.branch    Its branch. Default: stable.
#   flatpak.runtime   ID//BRANCH of the app's runtime. When set, the image is
#                     an app, made of its /app. When not set, the image is a
#                     runtime, made of its /usr, with its /etc as /usr/etc.
#   flatpak.sdk       ID//BRANCH of the SDK. Default: the app's runtime, or
#                     the runtime itself.
#   flatpak.command   What `flatpak run` starts: a name in /app/bin or an
#                     absolute path. An app needs one; a runtime has none.
#   flatpak.finish-args, flatpak.finish-args.GROUP
#                     Options for build-finish, separated by whitespace.
#                     flatpak.finish-args comes first, then each group,
#                     sorted by GROUP (a-z, 0-9 and -).
# A label set to the empty string counts as not set. Any other flatpak.*
# label is an error, so that a typo cannot silently drop a permission.
# Labels outside flatpak.* (a base image's, say) are ignored.
set -euo pipefail

# --- flatpak's naming rules ---

# An ID has three or more parts, separated by dots. A part is letters,
# digits and _, and does not start with a digit. Only the last part may
# also contain -.
id_re='^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)+\.[A-Za-z_-][A-Za-z0-9_-]*$'
# A branch is letters, digits, _, . and -, and starts with a letter, a
# digit or _.
branch_re='^[A-Za-z0-9_][A-Za-z0-9_.-]*$'

# --- helpers ---

usage() {
    echo "usage: flatpak.sh build OUT IMAGE < FILES.tar | flatpak.sh test [--offline] TEST RUNTIME..." >&2
    exit 2
}

die() {
    echo "flatpak.sh: $*" >&2
    exit 1
}

# is_one_of WORD LIST...: succeeds if WORD is one of LIST.
is_one_of() {
    local word=$1 item
    shift
    for item; do
        [ "$item" != "$word" ] || return 0
    done
    return 1
}

# valid_id ID: succeeds if ID is a valid Flatpak ID.
valid_id() {
    [ "${#1}" -le 255 ] && [[ $1 =~ $id_re ]]
}

# check_ref LABEL VALUE: dies unless VALUE is empty or ID//BRANCH.
check_ref() {
    local label=$1 value=$2
    if [ -z "$value" ]; then
        return 0
    fi
    [[ $value == *//* ]] && valid_id "${value%%//*}" && [[ ${value#*//} =~ $branch_re ]] ||
        die "$label: \"$value\" is not ID//BRANCH"
}

# full_ref ID//BRANCH: prints the full ref, ID/ARCH/BRANCH.
full_ref() {
    echo "${1%%//*}/$arch/${1#*//}"
}

# --- OCI image layouts ---

# blob_path LAYOUT DIGEST: prints where LAYOUT keeps the blob DIGEST
# (sha256:123... is blobs/sha256/123...).
blob_path() {
    echo "$1/blobs/${2/://}"
}

# layout_ref LAYOUT: prints the name that LAYOUT's index gives its one
# image, or nothing. build-bundle names it after the Flatpak's ref.
layout_ref() {
    jq -r 'if (.manifests | length) == 1 then .manifests[0].annotations["org.opencontainers.image.ref.name"] // "" else "" end' \
        "$1/index.json" 2>/dev/null || :
}

# image_config LAYOUT: prints the config of the one image in LAYOUT.
image_config() {
    local layout=$1 manifest config
    if ! manifest=$(jq -er 'if (.manifests | length) == 1 then .manifests[0].digest else empty end' "$layout/index.json" 2>/dev/null) ||
        ! config=$(jq -er '.config.digest' "$(blob_path "$layout" "$manifest")" 2>/dev/null) ||
        [ ! -f "$(blob_path "$layout" "$config")" ]; then
        die "$layout: not an OCI image layout of one image"
    fi
    cat "$(blob_path "$layout" "$config")"
}

# --- cleanup and signals ---

# Temporary directories, removed when the script exits.
temp_dirs=()
# The OUT of a build, removed if the script fails, so that a failed build
# leaves nothing there.
out_dir=''
# The command running now (see spawn), which a signal stops.
child=''

# remove_dir DIR: removes DIR, or says that it is left behind.
remove_dir() {
    local dir=$1
    if rm -rf "$dir" 2>/dev/null; then
        return 0
    fi
    # A test can leave read-only directories behind (Go's module cache is
    # one), which an ordinary user cannot empty. Make them writable first.
    chmod -R u+rwx "$dir" 2>/dev/null || :
    rm -rf "$dir" || echo "flatpak.sh: $dir is left behind" >&2
}

# cleanup: runs when the script exits.
cleanup() {
    local status=$? dir
    for dir in "${temp_dirs[@]}"; do
        remove_dir "$dir"
    done
    if [ "$status" != 0 ] && [ -n "$out_dir" ]; then
        rm -rf "$out_dir"
    fi
}

# stop STATUS: on a signal, stops the running command and exits with
# STATUS. The command's process group gets TERM, and KILL 10 seconds later.
stop() {
    # A second signal is not caught again.
    trap - INT TERM HUP
    if [ -n "$child" ]; then
        kill -TERM -- "-$child" 2>/dev/null || :
        { sleep 10 && kill -KILL -- "-$child" 2>/dev/null; } &
        wait "$child" 2>/dev/null || :
    fi
    exit "$1"
}

# spawn COMMAND...: runs COMMAND in a process group of its own, and waits
# for it. A signal can then stop it at once, together with what it started
# (dbus-run-session's bus, the sandbox). bash would wait for a command in
# the foreground to end before it handles the signal.
spawn() {
    echo "flatpak.sh: + $*" >&2
    # <&0 keeps stdin: bash gives a command in the background /dev/null.
    setsid "$@" <&0 &
    child=$!
    wait "$child"
}

# --- paths in the sandbox ---

# resolve FILES MOUNT PATH: prints where PATH leads in the sandbox. FILES
# holds the Flatpak's files, which the sandbox mounts at MOUNT: /app for an
# app, /usr for a runtime (whose etc is /usr/etc). Each symlink on the way
# is followed as it would be in the sandbox. Parts that do not exist are
# kept as they are. A path that leads out of MOUNT stops at the first path
# outside it.
#
# In an app, an absolute symlink into /app leads back into the files. In a
# runtime, every absolute symlink leads out of the files, and resolve prints
# an empty line: a runtime's files are looked up in its own tree, which no
# absolute symlink stays in.
resolve() {
    local files=$1 mount=$2 path=$3
    local dir=$mount part on_disk target links=0 rest=() link_parts=()
    case $path in
    "$mount" | "$mount"/*) ;;
    *) echo "$path" && return ;;
    esac
    IFS=/ read -ra rest <<<"${path#"$mount"}"
    while [ "${#rest[@]}" -gt 0 ]; do
        part=${rest[0]}
        rest=("${rest[@]:1}")
        case $part in
        '' | .) continue ;;
        ..)
            # Going up from MOUNT leaves the files.
            if [ "$dir" = "$mount" ]; then
                dirname "$mount"
                return
            fi
            dir=${dir%/*}
            continue
            ;;
        esac
        on_disk=$files${dir#"$mount"}/$part
        if [ ! -L "$on_disk" ]; then
            dir=$dir/$part
            continue
        fi
        links=$((links + 1))
        [ "$links" -le 40 ] || die "$path: too many levels of symbolic links"
        target=$(readlink "$on_disk")
        if [[ $target == /* ]]; then
            case $mount:$target in
            /app:/app | /app:/app/*)
                dir=$mount
                target=${target#"$mount"}
                ;;
            /app:*) echo "$target" && return ;;
            *) echo && return ;;
            esac
        fi
        # Walk the link's target next, then the rest of the path.
        IFS=/ read -ra link_parts <<<"$target"
        rest=("${link_parts[@]}" "${rest[@]}")
    done
    echo "$dir"
}

# within DIR PATH: succeeds if PATH is DIR or inside it. Both must be
# absolute, with symlinks resolved.
within() {
    case $2/ in "${1%/}"/*) return 0 ;; *) return 1 ;; esac
}

# --- build ---

# flatpak_labels IMAGE: prints the flatpak.* labels of IMAGE's config, as
# a JSON object.
flatpak_labels() {
    image_config "$1" | jq -c '.config.Labels // {} | with_entries(select(.key | startswith("flatpak.")))'
}

# label_value LABELS NAME: prints the value of label NAME, or nothing if it
# is not set.
label_value() {
    jq -r --arg k "$2" '.[$k] // ""' <<<"$1"
}

# check_label_names LABELS: dies on a flatpak.* label that this script does
# not know, so that a typo cannot silently drop a permission.
check_label_names() {
    local unknown
    unknown=$(jq -r 'keys[] | select(test("^flatpak\\.(id|branch|runtime|sdk|command|finish-args(\\.[a-z0-9][a-z0-9-]*)?)$") | not)' <<<"$1" | head -n 1)
    [ -z "$unknown" ] || die "label $unknown is not one of flatpak.sh's: flatpak.id, flatpak.branch, flatpak.runtime, flatpak.sdk, flatpak.command, flatpak.finish-args and flatpak.finish-args.GROUP (GROUP of a-z, 0-9 and -); a typo must not drop a permission silently"
}

# check_labels ID BRANCH RUNTIME SDK COMMAND: dies unless the labels
# describe an app (RUNTIME set) or a runtime (RUNTIME empty).
check_labels() {
    local id=$1 branch=$2 runtime=$3 sdk=$4 command=$5
    [ -n "$id" ] || die "the image has no flatpak.id label: it names the Flatpak, and is the one label every image needs"
    valid_id "$id" || die "flatpak.id \"$id\" is not a flatpak ID: three or more parts separated by dots, of letters, digits and _ (and - in the last), none starting with a digit"
    [[ $branch =~ $branch_re ]] || die "flatpak.branch \"$branch\" is not a flatpak branch: letters, digits, _, . and -, starting with a letter, a digit or _"
    check_ref flatpak.runtime "$runtime"
    check_ref flatpak.sdk "$sdk"
    if [ -n "$runtime" ]; then
        [ -n "$command" ] || die "an app needs flatpak.command, what flatpak run starts"
        [[ $command == /* || $command != */* ]] || die "flatpak.command \"$command\" is neither a name in /app/bin nor an absolute path"
    else
        [ -z "$command" ] || die "flatpak.command is set but flatpak.runtime is not: an app has both, a runtime neither"
    fi
}

# finish_arg_words LABELS: prints each option of the flatpak.finish-args
# labels as LABEL<tab>OPTION. flatpak.finish-args comes first, then each
# group, sorted by label.
finish_arg_words() {
    jq -r 'to_entries | sort_by(.key)[] | select(.key | startswith("flatpak.finish-args"))
        | .key as $k | .value | splits("\\s+") | select(. != "") | "\($k)\t\(.)"' <<<"$1"
}

# check_finish_arg LABEL OPTION: dies unless OPTION is a build-finish option
# that the labels leave to the finish-args.
check_finish_arg() {
    local label=$1 word=$2
    local option=${word%%=*} value='' group key=''
    if [[ $word == *=* ]]; then
        value=${word#*=}
    fi
    # For --metadata=GROUP=KEY=VALUE: the metadata's group and key.
    group=${value%%=*}
    if [[ $value == *=* ]]; then
        key=${value#*=}
        key=${key%%=*}
    fi
    # Each option is one word, --name=value. A lone -- would end flatpak's
    # options, and build-finish would silently drop every option after it.
    [[ $option =~ ^--[A-Za-z] ]] ||
        die "$label: \"$word\" is not a build-finish option: each is one word, --name=value, and they are separated by whitespace"
    # The labels set --command, the runtime and the SDK, and with them the
    # metadata's name, runtime, sdk and command.
    case $option in
    --command | --runtime | --sdk) die "$label: \"$word\": flatpak.${option#--} sets that" ;;
    esac
    if [ "$option" = --metadata ] && [[ $group =~ ^(Application|Runtime)$ && $key =~ ^(name|runtime|sdk|command)$ ]]; then
        die "$label: \"$word\": the labels set the metadata's name, runtime, sdk and command"
    fi
}

# is_layout_or_empty DIR: succeeds if DIR is a directory (not a symlink to
# one) that holds an OCI image layout, or nothing.
is_layout_or_empty() {
    local dir=$1
    if [ ! -d "$dir" ] || [ -L "$dir" ]; then
        return 1
    fi
    [ -f "$dir/index.json" ] || [ -z "$(ls -A "$dir")" ]
}

# check_out OUT IMAGE: dies unless OUT may be replaced with the Flatpak.
# OUT gets emptied with rm -rf, so it must be a directory of its own: not
# IMAGE, not the current directory, and not one that holds either.
check_out() {
    local out=$1 image=$2 out_path
    out_path=$(realpath -m -- "$out")
    if within "$out_path" "$(realpath -e -- "$image")"; then
        die "$out is or holds the image, $image: the Flatpak goes to a directory of its own"
    fi
    if within "$out_path" "$(pwd -P)"; then
        die "$out is or holds the current directory: the Flatpak goes to a directory of its own"
    fi
    if [ -e "$out" ] && ! is_layout_or_empty "$out"; then
        die "$out exists and is not an OCI image layout"
    fi
}

# unpack_files KIND ROOT FILES: unpacks the image's files (the tar on
# stdin) into ROOT. Then it moves what the Flatpak is made of to FILES: an
# app's /app, or a runtime's /usr and /etc. The rest is dropped.
unpack_files() {
    local kind=$1 root=$2 files=$3
    # --no-same-owner: the files belong to whoever runs tar, as they would
    # for an ordinary user.
    tar -x -C "$root" --no-same-owner -f -
    if [ "$kind" = app ]; then
        [ -d "$root/app" ] && [ ! -L "$root/app" ] || die "the image has nothing in /app, all flatpak.sh takes of an app"
        mv "$root/app" "$files"
    else
        # A runtime's /etc becomes its etc, which the sandbox has at /usr/etc.
        [ ! -e "$root/usr/etc" ] && [ ! -L "$root/usr/etc" ] || die "the image has a /usr/etc, which would be its /etc"
        [ -d "$root/usr" ] || [ -d "$root/etc" ] || die "the image has nothing in /usr or /etc, all flatpak.sh takes of a runtime"
        if [ -d "$root/usr" ]; then
            mv "$root/usr" "$files"
        else
            mkdir "$files"
        fi
        if [ -d "$root/etc" ]; then
            mv "$root/etc" "$files/etc"
        fi
    fi
    rm -rf "$root"
}

# normalize_files FILES: leaves FILES as an ostree commit with canonical
# permissions has them: no device nodes, fifos or sockets, and modes 0755
# (directories and anything executable) or 0644.
normalize_files() {
    local files=$1
    find "$files" \( -type b -o -type c -o -type p -o -type s \) -delete
    find "$files" -type d -exec chmod 0755 {} + \
        -o -type f -perm /111 -exec chmod 0755 {} + \
        -o -type f -exec chmod 0644 {} +
}

# check_app_command FILES COMMAND: dies unless the app's command is an
# executable file in its /app. A command outside /app is the runtime's, and
# is not checked here.
check_app_command() {
    local files=$1 command=$2 path target file
    path=$command
    if [[ $command != /* ]]; then
        path=/app/bin/$command
    fi
    target=$(resolve "$files" /app "$path")
    file=$files${target#/app}
    case $target in
    /app | /app/*)
        [ -e "$file" ] || die "flatpak.command $command: $target is not in the image"
        [ -f "$file" ] && [ -x "$file" ] ||
            die "flatpak.command $command: $target is not an executable file in the image"
        ;;
    esac
}

# check_runtime_ld_so FILES: dies unless the runtime lets flatpak set up
# the dynamic linker. flatpak writes its own ld.so.conf (with /app/lib, the
# app's /app/etc/ld.so.conf, and the libraries of the app's and the
# runtime's extensions, the GL driver's among them) only where the
# runtime's is an empty file. Then it builds the ld.so cache with the
# runtime's ldconfig. With any other ld.so.conf the GL driver does not load.
# ld.so.conf.d would not be read either: only Fedora's ld.so.conf included it.
check_runtime_ld_so() {
    local files=$1 target file
    target=$(resolve "$files" /usr /usr/etc/ld.so.conf)
    file=$files${target#/usr}
    [[ $target == /usr/* ]] && [ -f "$file" ] && [ ! -s "$file" ] ||
        die "a runtime's /etc/ld.so.conf must be an empty file (\`: >/etc/ld.so.conf\` in the Containerfile): only then does flatpak write its own, with the libraries of extensions such as the GL drivers"

    target=$(resolve "$files" /usr /usr/etc/ld.so.conf.d)
    file=$files${target#/usr}
    if [[ $target != /usr/* ]] || [ -e "$file" ]; then
        [[ $target == /usr/* ]] && [ -d "$file" ] ||
            die "a runtime's /etc/ld.so.conf.d must be an empty directory or absent, and this one is not a directory: with /etc/ld.so.conf empty nothing reads it"
        [ -z "$(ls -A "$file")" ] ||
            die "a runtime's /etc/ld.so.conf.d must be empty or absent: with /etc/ld.so.conf empty nothing reads it, and the libraries it names ($(find "$file" -mindepth 1 -maxdepth 1 -printf "%f\n" | head -n 1), ...) would not be found"
    fi

    target=$(resolve "$files" /usr /usr/bin/ldconfig)
    file=$files${target#/usr}
    [[ $target == /usr/* ]] && [ -f "$file" ] || die "a runtime needs /usr/bin/ldconfig: flatpak builds its ld.so cache with it"
}

# cmd_build OUT IMAGE: builds the Flatpak described by IMAGE's labels, from
# the files on stdin, into OUT.
cmd_build() {
    local out=$1 image=$2
    local labels flatpak_id branch runtime sdk command kind label word
    local finish_args=() work build_dir files repo on group got

    labels=$(flatpak_labels "$image")
    check_label_names "$labels"
    flatpak_id=$(label_value "$labels" flatpak.id)
    branch=$(label_value "$labels" flatpak.branch)
    runtime=$(label_value "$labels" flatpak.runtime)
    sdk=$(label_value "$labels" flatpak.sdk)
    command=$(label_value "$labels" flatpak.command)
    branch=${branch:-stable}
    check_labels "$flatpak_id" "$branch" "$runtime" "$sdk" "$command"
    if [ -n "$runtime" ]; then
        kind=app
        finish_args=("--command=$command")
    else
        kind=runtime
    fi
    while IFS=$'\t' read -r label word; do
        check_finish_arg "$label" "$word"
        finish_args+=("$word")
    done < <(finish_arg_words "$labels")

    check_out "$out" "$image"
    # From here on, a failure removes OUT (see cleanup).
    out_dir=$out
    rm -rf "$out"

    # A build directory, as flatpak build-init makes one: the metadata,
    # files/ and var/.
    work=$(mktemp -d)
    temp_dirs+=("$work")
    build_dir=$work/build
    files=$build_dir/files
    repo=$work/repo
    mkdir -p "$work/root" "$build_dir/var"
    unpack_files "$kind" "$work/root" "$files"
    normalize_files "$files"
    echo "flatpak.sh: $(find "$files" | wc -l) files and directories from the image" >&2

    # Check now what flatpak would only notice when the Flatpak runs.
    if [ "$kind" = app ]; then
        check_app_command "$files" "$command"
    else
        check_runtime_ld_so "$files"
    fi

    # An app's metadata names its runtime. A runtime's names the runtime
    # itself. The SDK defaults to that runtime.
    if [ "$kind" = app ]; then
        group=Application
        on=$runtime
    else
        group=Runtime
        on=$flatpak_id//$branch
    fi
    printf '[%s]\nname=%s\nruntime=%s\nsdk=%s\n' "$group" "$flatpak_id" "$(full_ref "$on")" "$(full_ref "${sdk:-$on}")" >"$build_dir/metadata"

    spawn flatpak build-finish "$build_dir" "${finish_args[@]}"
    if [ "$kind" = app ]; then
        spawn flatpak build-export --arch="$arch" --subject="$flatpak_id" "$repo" "$build_dir" "$branch"
        spawn flatpak build-bundle --oci --arch="$arch" "$repo" "$out" "$flatpak_id" "$branch"
    else
        # build-export looks for a runtime's files in usr/ unless told
        # otherwise.
        spawn flatpak build-export --arch="$arch" --subject="$flatpak_id" --runtime --files=files "$repo" "$build_dir" "$branch"
        spawn flatpak build-bundle --oci --arch="$arch" --runtime "$repo" "$out" "$flatpak_id" "$branch"
    fi

    got=$(layout_ref "$out")
    [ "$got" = "$kind/$flatpak_id/$arch/$branch" ] || die "$out holds ${got:-no Flatpak}, not $kind/$flatpak_id/$arch/$branch"
    # As root (docker runs the builder as root), give OUT to the owner of
    # its directory, the caller, rather than leave it root's.
    if [ "$(id -u)" = 0 ]; then
        chown -R --reference="$(dirname "$out")" "$out"
    fi
    echo "flatpak.sh: $out: $got" >&2
}

# --- test ---

# app_runtime LAYOUT: prints the runtime that the app in LAYOUT runs on, as
# its metadata (its image's org.flatpak.metadata label) names it.
app_runtime() {
    image_config "$1" | jq -r '.config.Labels["org.flatpak.metadata"] // ""' |
        awk '/^\[/ { app = $0 == "[Application]"; next } app && sub(/^runtime=/, "") { print; exit }'
}

# use_throwaway_installation: points flatpak, and the test, at throwaway
# directories. flatpak's user installation is a new one. The machine's own
# installations (the system-wide one, and those that /etc/flatpak names)
# are replaced by empty ones, so that nothing installed there stands in for
# what the images lack. HOME and the XDG base directories are new ones too:
# --filesystem=xdg-config and the like would give the test the caller's own.
use_throwaway_installation() {
    local dir rundir
    dir=$(mktemp -d)
    temp_dirs+=("$dir")
    mkdir -m 0700 "$dir/user" "$dir/system" "$dir/config" "$dir/home"
    # flatpak run makes sockets in XDG_RUNTIME_DIR (its D-Bus proxy's among
    # them), and a socket's path takes 107 bytes at most. /tmp is short,
    # where TMPDIR need not be.
    rundir=$(mktemp -d /tmp/flatpak-run.XXXXXX)
    temp_dirs+=("$rundir")
    export FLATPAK_USER_DIR=$dir/user FLATPAK_SYSTEM_DIR=$dir/system FLATPAK_CONFIG_DIR=$dir/config \
        HOME=$dir/home XDG_CONFIG_HOME=$dir/home/.config XDG_DATA_HOME=$dir/home/.local/share \
        XDG_CACHE_HOME=$dir/home/.cache XDG_STATE_HOME=$dir/home/.local/state XDG_RUNTIME_DIR=$rundir
}

# cmd_test [--offline] TEST RUNTIME...: installs TEST and RUNTIME... into a
# throwaway installation, and runs TEST's command in its sandbox.
cmd_test() {
    local offline='' layouts=() refs=() arg layout ref i kind runtime run=() status=0
    if [ "${1:-}" = --offline ]; then
        offline=1
        shift
    fi
    [ "$#" -ge 2 ] || usage

    for arg; do
        layout=$(realpath -e "$arg") || die "no Flatpak at $arg"
        ref=$(layout_ref "$layout")
        [[ $ref =~ ^(app|runtime)/[^/]+/$arch/[^/]+$ ]] || die "$layout holds ${ref:-no Flatpak}, not a Flatpak for $arch"
        for i in "${!refs[@]}"; do
            [ "${refs[i]}" != "$ref" ] || die "${layouts[i]} and $layout both hold $ref"
        done
        layouts+=("$layout")
        refs+=("$ref")
    done
    [[ ${refs[0]} == app/* ]] || die "$1 holds ${refs[0]}: the test is an app, whose command is the test"
    runtime=runtime/$(app_runtime "${layouts[0]}")
    is_one_of "$runtime" "${refs[@]}" || die "${refs[0]} runs on ${runtime#runtime/}, which none of the images is"
    [ "$(id -u)" != 0 ] || die "run flatpak.sh test as an ordinary user: the Flatpak runs as the user who runs the test, and as root it does not run as it will for its users"

    use_throwaway_installation
    # The runtimes first, then the apps, each in the order given.
    for kind in runtime app; do
        for i in "${!refs[@]}"; do
            if [[ ${refs[i]} == "$kind"/* ]]; then
                spawn flatpak --user install -y --noninteractive "oci:${layouts[i]}" </dev/null
            fi
        done
    done

    # --die-with-parent ends the sandbox with flatpak run, which a signal
    # stops (see spawn).
    run=(flatpak --user run --die-with-parent)
    if [ -n "$offline" ]; then
        run+=(--unshare=network)
    else
        run+=(--share=network)
    fi
    run+=("${refs[0]}")
    # Start a session bus where none runs, as in a container. flatpak runs
    # without one, but then nothing in the sandbox could use D-Bus, the
    # portal that flatpak-spawn asks among them.
    if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
        run=(dbus-run-session -- "${run[@]}")
    fi
    spawn "${run[@]}" </dev/null || status=$?
    # The test has ended: a signal now has nothing to stop.
    child=
    [ "$status" = 0 ] || die "${refs[0]}: the test failed (exit status $status)"
    echo "flatpak.sh: ${refs[0]}: the test passed" >&2
}

# --- main ---

main() {
    arch=$(flatpak --default-arch)
    # A commit keeps each file's mode, and a file that others cannot read is
    # no use in a system-wide installation. normalize_files sets the modes of
    # the image's files. umask 022 gives the files flatpak writes itself the
    # modes it means them to have.
    umask 022
    # build-bundle writes the image's layer with libarchive, which fails on
    # a file name that is not ASCII in the C locale.
    export LANG=C.UTF-8
    trap cleanup EXIT
    trap 'stop 130' INT
    trap 'stop 143' TERM
    trap 'stop 129' HUP

    case ${1:-} in
    build)
        [ "$#" = 3 ] || usage
        cmd_build "$2" "$3"
        ;;
    test)
        shift
        cmd_test "$@"
        ;;
    *) usage ;;
    esac
}

main "$@"
