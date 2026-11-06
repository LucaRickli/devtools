#!/usr/bin/env bash
#
# Builds and tests the images and the Flatpaks, for just's recipes and for
# CI alike. It works from the root of the checkout, wherever it is run from.
#
#   build.sh names            lists the Flatpaks: NAME DIR ON
#   build.sh flatpak NAME...  builds and tests each Flatpak NAME
#   build.sh flatpaks         builds and tests every Flatpak
#   build.sh install [APP]    installs the apps built so, for your user
#   build.sh devcontainer     builds the dev container
#   build.sh bake ARG...      runs docker buildx bake on the builder
#
# names lists the Flatpaks in the order they build: runtime, sdk, then each
# app of docker-bake.hcl's APPS, named by its ID, and after it each of its
# variants, <ID>-<variant>. DIR is the directory of its Containerfile, ON
# the runtime it is built on (- for none).
#
# flatpak bakes the images of every NAME at once. Then, one NAME after
# another, it makes the Flatpak and runs its test side by side. The Flatpak
# goes to output/flatpaks/NAME, an OCI image layout, which is what CI
# pushes. flatpaks does the same for every Flatpak, all images at once.
#
# install installs APP, or each app's plain Flatpak (not its variants), with
# its runtime first, into your own user installation.
#
# devcontainer builds the dev container, localhost/devcontainer:latest and
# :ai, into docker's image store. bake runs docker buildx bake ARG... with
# docker-bake.hcl, on the builder described below.
#
# How it builds:
# - Every image is baked (docker-bake.hcl) on a docker-container builder of
#   its own, `packages`. It is made where it is missing, and made again
#   where its BuildKit is not the one pinned below. Its cache, a volume,
#   stays.
# - The builder image goes into docker's image store. Each Flatpak's image
#   and its test's go to output/images/<NAME> and <NAME>-test, as OCI image
#   layouts.
# - A Flatpak is made from its image's files in a container of the builder
#   image (flatpak.sh build), into output/flatpaks/<NAME>.
# - Its test's Flatpak is made in a second container, and only there. The
#   test runs in it as an ordinary user, tester (flatpak.sh test). It is
#   installed with the runtime it runs on, output/flatpaks/<ON>; the runtime
#   and the SDK run on themselves. That runtime must be there already, or
#   be built earlier in the same run.
# - Both containers are privileged, for flatpak's sandbox (build-export
#   checks icons in one). They see only output/ (the test's container
#   read-only) and the image's files.
#
# Needs docker with buildx, and jq. Nothing but install touches your own
# Flatpak installations.
set -euo pipefail

# --- settings ---

# The BuildKit that the `packages` builder runs. Renovate updates the line
# under its comment, and .github/actions/buildx reads it: keep both lines
# as they are.
# renovate: datasource=docker depName=moby/buildkit
buildkit=moby/buildkit:v0.34.2@sha256:c5f8862f52499773af85bc07695b2379ef08e8002352b0df2c4864c91d78dabe

# The script that the test's container runs, as root at first:
# - It makes a socket at /run/docker.sock, for the VS Code Flatpak's Docker
#   permission. Nothing listens on it: with CODE_TEST_DOCKER=1, that app's
#   test checks that the permission brings the socket into the sandbox.
# - It makes the test's Flatpak, as every Flatpak is made.
# - It runs the test as tester, with TMPDIR in tester's home. flatpak.sh
#   test puts the test's home in TMPDIR. In /tmp, which flatpak shares
#   between an app's instances, that home would not start empty in each.
# (read -d '' reads the whole text, and fails at its end: hence || :.)
read -r -d '' tester <<'EOF' || :
python3 -c 'import socket; socket.socket(socket.AF_UNIX).bind("/run/docker.sock")'
chmod 0666 /run/docker.sock
flatpak.sh build /home/tester/test "$1"
install -d -m 0700 -o tester -g tester /home/tester/tmp
cd /home/tester
exec setpriv --reuid=tester --regid=tester --init-groups \
    env HOME=/home/tester USER=tester LOGNAME=tester TMPDIR=/home/tester/tmp flatpak.sh test /home/tester/test "$2"
EOF

# What names printed (NAME DIR ON lines): main sets it, built_on reads it.
all_flatpaks=''

# --- helpers ---

die() {
    echo "$*" >&2
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

# ensure_builder: makes the `packages` builder where it is missing, and
# makes it again where it runs another BuildKit than the pinned one.
ensure_builder() {
    local image
    # The builder's image: empty where there is no builder, "none" where it
    # has no pin.
    image=$(docker buildx ls --format json | jq -r 'select(.Name == "packages") | .Nodes[0].DriverOpts.image // "none"')
    if [ "$image" != "$buildkit" ]; then
        # --keep-state keeps the cache, a volume, for the new builder.
        [ -z "$image" ] || docker buildx rm --keep-state packages >/dev/null
        docker buildx create --name packages --driver docker-container --driver-opt "image=$buildkit" --bootstrap >/dev/null
    fi
}

# bake ARG...: docker buildx bake on the builder, made first where needed.
# Every bake (CI's, a recipe's) gets three tries, 30 seconds apart. BuildKit
# looks each base image up again (pull), with no copy of its own to fall
# back on, and a registry or a download failing for a moment must not fail
# the build. A try resumes from what the one before built.
bake() {
    local attempt
    ensure_builder
    for attempt in 1 2 3; do
        if docker buildx bake --builder packages -f build/docker-bake.hcl "$@"; then
            return 0
        fi
        if [ "$attempt" != 3 ]; then
            echo "bake $* failed (attempt $attempt), retrying in 30s" >&2
            sleep 30
        fi
    done
    die "${GITHUB_ACTIONS:+::error::}could not bake $*"
}

# --- the list of Flatpaks ---

# baked_flatpaks: prints each Flatpak of the bake file, NAME DIR ON, in the
# order they build.
baked_flatpaks() {
    docker buildx bake --progress=quiet -f build/docker-bake.hcl --print flatpaks | jq -r '
        [.target[] | select((.target // "") | startswith("flatpak"))
         | {name: ((.context | split("/") | last) + (.target | ltrimstr("flatpak"))), dir: .context,
            on: ([.contexts // {} | keys[] | select(. == "runtime" or . == "sdk")][0] // "-")}]
        | sort_by(.name != "runtime", .name != "sdk", .name)[] | "\(.name) \(.dir) \(.on)"'
}

# tree_flatpaks: prints, sorted, the name of each app in apps/ (a directory
# with a Containerfile), its ID, and of each of its variants, <ID>-<variant>.
tree_flatpaks() {
    local containerfile id variant
    for containerfile in apps/*/Containerfile; do
        [ -f "$containerfile" ] || continue
        id=${containerfile#apps/}
        id=${id%/Containerfile}
        echo "$id"
        # A variant is a stage FROM ... AS flatpak-<variant>, where FROM, AS
        # and the stage's name may be in any case.
        sed -n 's/^[[:space:]]*[Ff][Rr][Oo][Mm][[:space:]].*[[:space:]][Aa][Ss][[:space:]][[:space:]]*[Ff][Ll][Aa][Tt][Pp][Aa][Kk]-\([A-Za-z0-9_.-]*\).*/\1/p' "$containerfile" |
            while read -r variant; do echo "$id-${variant,,}"; done
    done | LC_ALL=C sort
}

# only_in A B: prints the lines of A that B does not have, each after a
# space, on one line.
only_in() {
    LC_ALL=C comm -23 <(echo "$1") <(echo "$2") | sed 's/^/ /' | tr -d '\n'
}

# names: prints each Flatpak, NAME DIR ON, of the bake file. Every app in
# apps/ and each of its flatpak-<variant> stages must be a Flatpak of the
# bake file's APPS, and each of those an app in apps/. Otherwise names
# fails, and with it every recipe and CI's plan, rather than silently leave
# unbuilt a Flatpak whose line was forgotten.
names() {
    local list tree baked
    list=$(baked_flatpaks)
    tree=$(tree_flatpaks)
    baked=$(awk '$1 != "runtime" && $1 != "sdk" { print $1 }' <<<"$list" | LC_ALL=C sort)
    if [ "$tree" != "$baked" ]; then
        die "${GITHUB_ACTIONS:+::error::}build/docker-bake.hcl's APPS and apps/ differ: each app, apps/<ID>/Containerfile, is a line of APPS, with a variant for each flatpak-<variant> stage it has. In apps/ alone:$(only_in "$tree" "$baked"); in APPS alone:$(only_in "$baked" "$tree")"
    fi
    echo "$list"
}

# built_on NAME: prints the runtime NAME is built on (names' ON, - for
# none).
built_on() {
    local on
    read -r _ _ on < <(awk -v n="$1" '$1 == n' <<<"$all_flatpaks") || die "No Flatpak $1 (build.sh names lists them)"
    echo "$on"
}

# tested_on NAME: prints the Flatpak that NAME's test runs on: the runtime
# NAME is built on, except that the runtime and the SDK run on themselves.
tested_on() {
    local on
    # Callers run tested_on in $(...), where bash turns set -e off. So it
    # passes built_on's failure on itself.
    on=$(built_on "$1") || return 1
    case $1 in runtime | sdk) echo "$1" ;; *) echo "$on" ;; esac
}

# --- making and testing a Flatpak ---

# image_files NAME: writes the files of output/images/NAME, the image that
# bake made, to stdout as one tar. BuildKit makes the tar from a build FROM
# that image, on the builder that made it: it applies the image's layers as
# a container runtime does.
image_files() {
    docker buildx build --builder packages --progress=quiet --provenance=false \
        --build-context "image=oci-layout://$PWD/output/images/$1" -o type=tar,dest=- - <<<'FROM image'
}

# run_in_builder [DOCKER RUN OPTIONS] -- COMMAND...: runs COMMAND in a
# container of the builder image, with stdin passed on (an image's files).
# A signal stops it: docker-init passes it on to the command's process
# group.
run_in_builder() {
    local opts=()
    while [ "$1" != -- ]; do
        opts+=("$1")
        shift
    done
    shift
    docker run --rm -i --init -e TINI_KILL_PROCESS_GROUP=1 --privileged --security-opt label=disable \
        "${opts[@]}" localhost/packages/builder "$@"
}

# make_flatpak NAME: makes output/flatpaks/NAME, the Flatpak of
# output/images/NAME.
make_flatpak() {
    image_files "$1" |
        run_in_builder --name "packages-$$-flatpak" -v "$PWD/output:/output" -- \
            flatpak.sh build "/output/flatpaks/$1" "/output/images/$1"
}

# test_flatpak NAME ON: runs NAME's test, of output/images/NAME-test, on
# output/flatpaks/ON. The container gets a caller's values for what the VS
# Code Flatpak sets itself (SHELL, EDITOR, VISUAL, Claude Code's DISABLE_*):
# its test checks that the app's own values win.
test_flatpak() {
    image_files "$1-test" |
        run_in_builder --name "packages-$$-test" -v "$PWD/output:/output:ro" -e CODE_TEST_DOCKER=1 \
            -e SHELL=/bin/sh -e EDITOR=vi -e VISUAL=vi -e DISABLE_UPDATES=0 -e DISABLE_INSTALLATION_CHECKS=0 -- \
            sh -ec "$tester" sh "/output/images/$1-test" "/output/flatpaks/$2"
}

# stop STATUS: stops the containers of build_flatpaks (docker stop sends
# TERM, and KILL 10 seconds later), then exits with STATUS.
stop() {
    docker stop "packages-$$-flatpak" "packages-$$-test" >/dev/null 2>&1 || :
    wait
    exit "$1"
}

# --- commands ---

# build_flatpaks NAME...: bakes the images of every NAME, then makes each
# Flatpak and runs its test.
build_flatpaks() {
    local name on earlier=() targets=() made tested failed
    for name; do
        on=$(tested_on "$name")
        [ "$on" = "$name" ] || [ -f "output/flatpaks/$on/index.json" ] || is_one_of "$on" "${earlier[@]}" ||
            die "No output/flatpaks/$on, which $name's test runs on: build.sh flatpak $on"
        earlier+=("$name")
        # A bake target's name has _ for each dot.
        targets+=("${name//./_}" "${name//./_}-test")
    done

    # What a Flatpak is built on (the runtime, the SDK), when it is not
    # built in this run, is its image from before: output/images/<ON>,
    # which the Flatpak its test runs on was made of. The bake file takes it
    # as RUNTIME or SDK; CI builds on it the same way. Without it, the bake
    # file's target would silently build it again, of Fedora's image of the
    # day, in this bake.
    for name; do
        on=$(built_on "$name")
        if [ "$on" = - ] || is_one_of "$on" "$@"; then
            continue
        fi
        [ -f "output/images/$on/index.json" ] || die "No output/images/$on, which $name is built on: build.sh flatpak $on"
        export "${on^^}=oci-layout://$PWD/output/images/$on"
    done

    bake builder "${targets[@]}"
    mkdir -p output/flatpaks
    # One Flatpak after another, each made in one container while its test
    # runs in another. Where the test runs on that Flatpak itself (the
    # runtime's, the SDK's), the test starts once the Flatpak is made. Both
    # containers run to their end before the next Flatpak, and a failure
    # stops it all. They run in the background and are waited for, so that
    # a signal stops them at once: bash would wait for a command in the
    # foreground to end first.
    trap 'stop 130' INT
    trap 'stop 143' TERM
    for name; do
        on=$(tested_on "$name")
        make_flatpak "$name" &
        made=$!
        if [ "$on" = "$name" ]; then
            wait "$made" || die "$name failed (above)"
        fi
        test_flatpak "$name" "$on" &
        tested=$!
        failed=
        wait "$tested" || failed=1
        wait "$made" || failed=1
        [ -z "$failed" ] || die "$name failed (above)"
    done
}

# install_flatpaks [APP]: installs APP, or each app's plain Flatpak, with
# the runtimes they run on first, into your own user installation.
install_flatpaks() {
    local app=${1:-} flatpaks name dir on apps=() runtimes=()
    flatpaks=$(names)
    while read -r name dir on; do
        case $name in runtime | sdk) continue ;; esac
        # By default, each app's plain Flatpak: the one named after its
        # directory.
        if [ -z "$app" ]; then
            [ "$name" = "${dir##*/}" ] || continue
        else
            [ "$name" = "$app" ] || continue
        fi
        [ -d "output/flatpaks/$name" ] || continue
        [ -d "output/flatpaks/$on" ] || die "No output/flatpaks/$on, which $name runs on: build.sh flatpak $on"
        apps+=("$name")
        is_one_of "$on" "${runtimes[@]}" || runtimes+=("$on")
    done <<<"$flatpaks"
    [ "${#apps[@]}" != 0 ] || die "No app ${app:-at all} in output/flatpaks: build.sh flatpaks first"
    for name in "${runtimes[@]}" "${apps[@]}"; do
        flatpak install --user -y --reinstall "oci:$PWD/output/flatpaks/$name"
    done
}

# --- main ---

main() {
    local every_name=()
    cd "$(dirname "$0")/.."
    case ${1:-} in
    names) names ;;
    flatpak)
        [ "$#" -ge 2 ] || die "usage: build.sh flatpak NAME... (build.sh names lists them)"
        shift
        all_flatpaks=$(names)
        build_flatpaks "$@"
        ;;
    flatpaks)
        all_flatpaks=$(names)
        mapfile -t every_name < <(cut -d' ' -f1 <<<"$all_flatpaks")
        build_flatpaks "${every_name[@]}"
        ;;
    install) install_flatpaks "${2:-}" ;;
    devcontainer) bake devcontainer ;;
    bake)
        shift
        bake "$@"
        ;;
    *) die "usage: build.sh names | flatpak NAME... | flatpaks | install [APP] | devcontainer | bake ARG..." ;;
    esac
}

main "$@"
