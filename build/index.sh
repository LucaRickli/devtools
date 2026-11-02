#!/usr/bin/env bash
#
# Writes the published Flatpaks as a Flatpak remote: a static site for
# GitHub Pages. It works from the root of the checkout, as build.sh does.
#
#   build.sh names | index.sh OUT URL
#
# NAMES, on stdin, lists the Flatpaks as build.sh names does (NAME DIR ON).
# The site goes to OUT, which is made anew. URL is the site's base URL
# (configure-pages' base_url), which its .flatpakrepo files and its page
# name.
#
# How flatpak reads an oci+https remote:
# - It asks <remote>/index/static?label:org.flatpak.ref:exists=1&
#   architecture=amd64&os=linux&tag=latest (the tag that a #TAG at the end
#   of the URL names).
# - It makes the remote's summary of every image the answer lists, as
#   listed: its org.flatpak.ref and org.flatpak.metadata labels, and its
#   digest as the ref's commit (flatpak_oci_index_make_summary, in
#   flatpak's common/flatpak-oci-registry.c).
# - It filters nothing itself, and Pages serves the one file whatever the
#   query. So the file is the filter: one image for each ref.
#
# The root that a machine adds as its remote chooses the tag it follows:
#   URL/            every Flatpak's :latest.
#   URL/<variant>/  the same, but with each app that has that variant
#                   (build.sh names' <ID>-<variant>) as its :<variant>.
#                   URL/ai/ has the VS Code Flatpak with Claude Code.
# Each root has its index/static and <remote>.flatpakrepo. URL/ also has an
# index.html.
#
# Each image is read from the registry as it is now, whatever a run pushed
# or failed to push:
# - Its manifest (skopeo inspect --raw). Its sha256 is the digest that
#   flatpak pulls.
# - The config of that digest. Its labels must be those of the Flatpak its
#   name says: an org.flatpak.ref of its ID on the image's architecture,
#   and an org.flatpak.metadata (flatpak skips an image without it). The ID
#   of the runtime and the SDK is the first flatpak.id label of their
#   Containerfile.
# Each image is where build/ci.sh push puts it: ghcr.io/<owner>/<ID, lower
# case>, and the VS Code Flatpak at ghcr.io/<owner>/code. Its tag is
# :latest, or :<variant> for a variant.
#
# The site lists what is published, so that no Flatpak holds back the
# others' index:
# - A Flatpak that cannot be read is left out, with a warning. It may not
#   be pushed yet: a new app whose first pipeline failed.
# - So is an image that is not its Flatpak's.
# - So is an app whose runtime its root lacks: a remote never names an app
#   whose runtime it lacks.
# - A variant is never replaced by its plain app. While a variant's image
#   is left out, its root has neither.
# Nothing is written where nothing can be read (a token that reads
# nothing, ghcr.io down), or where all that can be read is left out (apps
# whose runtime cannot be read). The index deployed then stays.
#
# Where the registry answers that an image is not there, or not to be read
# (not pushed yet, denied), it is left out at once. So a run with nothing
# published is over in seconds. Any other failure gets three tries, 30
# seconds apart.
#
# The site has only the images' metadata. The images stay private: a
# machine pulls them with a token of its own (flatpak's OCI authenticator,
# from oci-auth.json). The same images give the same site, byte for byte.
#
# Needs bash, jq and skopeo. The environment:
#   REGISTRY           The registry's URL. Default: https://ghcr.io. It is
#                      the index's Registry, which flatpak pulls from:
#                      http:// for a local one, without TLS.
#   OWNER              The images' owner, made lower case. Default:
#                      GITHUB_REPOSITORY_OWNER.
#   GH_TOKEN           A token that reads the packages, with GITHUB_ACTOR,
#                      its user. Without it, the reads are anonymous.
#   REMOTE             The remote's name. Default: the repository's name
#                      (of GITHUB_REPOSITORY), else devtools.
#   GITHUB_REPOSITORY  Also gives the .flatpakrepo files their Homepage.
set -euo pipefail

# --- state ---

# The settings, of the arguments and the environment (main sets them).
url='' registry='' host='' owner='' repository='' remote=''
# Where the script works: a temporary directory, removed on exit.
work=''
# skopeo's options (use_registry sets them).
skopeo_opts=()
# Why the registry may deny a read, for that warning (use_registry).
denied_reason=''

# Each Flatpak of NAMES, in their order (read_names). Of each NAME: its
# kind (runtime or app), its ID, its variant (empty for the plain one), and
# its image's repository and tag.
names=()
declare -A kind=() id=() variant=() repo=() tag=()
# The remotes: "" for the plain one first, then each variant, sorted.
# has[ID/VARIANT] is set for each app that has that variant.
roots=()
declare -A has=() variants=()

# What could be read of each Flatpak's image (read_image): its ref, its
# digest, and for an app the runtime it runs on (runtime/ID/ARCH/BRANCH).
declare -A readable=() ref_of=() digest_of=() runs_on=()

# What the site leaves out, and why (warn).
left=()
# The site and its page's lines, as write_root makes them.
site='' page=''
# How many entries the remotes have, and each app the plain one lists.
listed=0
declare -A plain=()
# The step summary's table of what each remote lists.
summary="| Remote | Ref | Image |"$'\n'"| --- | --- | --- |"

# --- helpers ---

die() {
    echo "${GITHUB_ACTIONS:+::error::}$*" >&2
    exit 1
}

# warn TEXT: warns of TEXT, and adds it to what the site leaves out.
warn() {
    echo "${GITHUB_ACTIONS:+::warning::}$*" >&2
    left+=("$*")
}

# html TEXT: prints TEXT escaped for an HTML page.
html() {
    jq -Rr @html <<<"$1"
}

# repository_name ID: prints the name of the repository that holds ID's
# images: ID in lower case, but code for the VS Code Flatpak.
repository_name() {
    if [ "$1" = io.github.lucarickli.Code ]; then
        echo code
    else
        echo "${1,,}"
    fi
}

# flatpak_arch ARCH: prints flatpak's name for the OCI architecture ARCH.
flatpak_arch() {
    case $1 in
    amd64) echo x86_64 ;;
    arm64) echo aarch64 ;;
    *) printf '%s\n' "$1" ;;
    esac
}

# --- settings ---

# read_environment: sets the registry, the owner and the remote, of the
# environment.
read_environment() {
    registry=${REGISTRY:-https://ghcr.io}
    registry=${registry%/}
    [[ $registry =~ ^https?://[^/]+$ ]] || die "REGISTRY is not a registry's URL: $registry"
    host=${registry#*://}
    owner=${OWNER:-${GITHUB_REPOSITORY_OWNER:-}}
    owner=${owner,,}
    [ -n "$owner" ] || die "no OWNER (or GITHUB_REPOSITORY_OWNER)"
    repository=${GITHUB_REPOSITORY:-}
    remote=${REMOTE:-${repository##*/}}
    remote=${remote:-devtools}
    remote=${remote,,}
    [[ $remote =~ ^[a-z0-9][a-z0-9_.-]*$ ]] || die "not a remote's name: $remote"
}

# use_registry: sets skopeo's options. It reads with GH_TOKEN where that is
# set, and anonymously where not. A registry on http:// has no TLS.
use_registry() {
    skopeo_opts=(--retry-times 3)
    [[ $registry == https://* ]] || skopeo_opts+=(--tls-verify=false)
    if [ -n "${GH_TOKEN:-}" ]; then
        : "${GITHUB_ACTOR:?GITHUB_ACTOR, the user of GH_TOKEN}"
        printf '{"auths": {"%s": {"auth": "%s"}}}\n' "$host" "$(printf '%s:%s' "$GITHUB_ACTOR" "$GH_TOKEN" | base64 -w0)" >"$work/auth.json"
        skopeo_opts+=(--authfile "$work/auth.json")
        denied_reason="GH_TOKEN cannot read it"
    else
        denied_reason="it needs a token, GH_TOKEN"
    fi
}

# --- the Flatpaks of NAMES ---

# containerfile_id FILE: prints the first flatpak.id label of the
# Containerfile FILE, or nothing.
containerfile_id() {
    sed -nE '/^[[:space:]]*(LABEL[[:space:]]+)?flatpak\.id=/{s/^[[:space:]]*(LABEL[[:space:]]+)?flatpak\.id=([A-Za-z0-9_.-]+).*/\2/p;q;}' "$1"
}

# read_names: reads NAMES, on stdin, into names and the tables above.
read_names() {
    local name dir flatpak_id flatpak_variant
    while read -r name dir _; do
        [ -n "$name" ] || continue
        [ -z "${kind[$name]:-}" ] || die "$name twice in NAMES"
        case $name in
        runtime | sdk)
            [ -f "$dir/Containerfile" ] || die "no $dir/Containerfile, the $name's"
            flatpak_id=$(containerfile_id "$dir/Containerfile")
            [ -n "$flatpak_id" ] || die "$dir/Containerfile has no flatpak.id label, the $name's ID"
            kind[$name]=runtime
            flatpak_variant=''
            ;;
        *)
            [[ $dir == apps/?* ]] || die "$name is no app of apps/ (its directory: $dir)"
            flatpak_id=${dir#apps/}
            case $name in
            "$flatpak_id") flatpak_variant='' ;;
            "$flatpak_id"-?*) flatpak_variant=${name#"$flatpak_id"-} ;;
            *) die "$name is neither $flatpak_id nor a variant of it, <ID>-<variant>" ;;
            esac
            kind[$name]=app
            ;;
        esac
        if [ -n "$flatpak_variant" ]; then
            # A variant is a root of its own, beside the plain one's index/.
            [[ $flatpak_variant =~ ^[a-z0-9][a-z0-9_.-]*$ ]] && [ "$flatpak_variant" != index ] || die "$name: no root can be named $flatpak_variant"
            has[$flatpak_id/$flatpak_variant]=1
            variants[$flatpak_variant]=1
        fi
        id[$name]=$flatpak_id
        variant[$name]=$flatpak_variant
        repo[$name]=$owner/$(repository_name "$flatpak_id")
        tag[$name]=${flatpak_variant:-latest}
        names+=("$name")
    done
    [ "${#names[@]}" != 0 ] || die "no Flatpaks in NAMES (build.sh names)"
    roots=("")
    if [ "${#variants[@]}" != 0 ]; then
        mapfile -t -O 1 roots < <(printf '%s\n' "${!variants[@]}" | LC_ALL=C sort)
    fi
}

# --- reading the registry ---

# fetch FILE WHAT COMMAND...: runs COMMAND, a skopeo read, with its output
# into FILE. If it fails, it warns that it could not WHAT, and returns 1.
# Where the registry answers that the image is not there, or not to be
# read, that is at once, as no wait changes the answer. Such an answer is
# skopeo's exit status 2 (image not found), or an error that says manifest
# unknown, name unknown, not found, denied, unauthorized, invalid
# username/password or 403 Forbidden. Any other failure gets three tries,
# 30 seconds apart: the registry fails at times.
fetch() {
    local file=$1 what=$2 err=$work/stderr attempt rc
    shift 2
    for attempt in 1 2 3; do
        rc=0
        "$@" >"$file" 2>"$err" || rc=$?
        cat "$err" >&2
        if [ "$rc" = 0 ]; then
            return 0
        fi
        if [ "$rc" = 2 ] || grep -qiE 'manifest unknown|name unknown|not found|denied|unauthorized|invalid username/password|forbidden' "$err"; then
            warn "could not $what (skopeo, above): not published, or $denied_reason; left out"
            return 1
        fi
        if [ "$attempt" != 3 ]; then
            echo "$what failed (attempt $attempt), retrying in 30s" >&2
            sleep 30
        fi
    done
    warn "could not $what (skopeo, above), in three tries: the registry failed; left out"
    return 1
}

# app_runtime CONFIG: prints the runtime that an app's metadata names (the
# org.flatpak.metadata label of the image config CONFIG): the first
# runtime= of its [Application] group, ID/ARCH/BRANCH.
app_runtime() {
    jq -r '.config.Labels["org.flatpak.metadata"] | split("\n")
        | reduce .[] as $l ({g: "", v: ""};
            if ($l | test("^\\[.*\\]$")) then .g = $l[1:-1]
            elif .g == "Application" and .v == "" and ($l | startswith("runtime=")) then .v = $l[8:]
            else . end) | .v' "$1"
}

# index_entry NAME DIGEST MEDIA_TYPE CONFIG: prints NAME's entry of the
# index (one of its Results), of its image's config CONFIG.
index_entry() {
    jq -S --arg name "${repo[$1]}" --arg tag "${tag[$1]}" --arg digest "$2" --arg mt "$3" '
        {Name: $name, Lists: [], Images: [{Tags: [$tag], Digest: $digest, MediaType: $mt,
          OS: .os, Architecture: .architecture, Annotations: {}, Labels: .config.Labels}]}' \
        "$4"
}

# read_image NAME: reads NAME's image from the registry, and checks it. Its
# entry of the index goes to $work/NAME.json, and ref_of, digest_of and
# runs_on get its values. An image that cannot be read, or is not NAME's,
# gets a warning, and read_image returns 1.
#
# It runs as an if's condition, where a command that fails does not stop
# the script: each step that matters is checked.
read_image() {
    local name=$1 at=$host/${repo[$1]}:${tag[$1]} manifest=$work/$1.manifest config=$work/$1.config
    local digest media_type os arch ref want runtime
    fetch "$manifest" "read $at ($name)" skopeo inspect --raw "${skopeo_opts[@]}" "docker://$at" || return 1
    digest=sha256:$(sha256sum "$manifest" | cut -d' ' -f1)
    media_type=$(jq -r '.mediaType // (if .config then "application/vnd.oci.image.manifest.v1+json" else "" end)' "$manifest" 2>/dev/null) ||
        { warn "$at ($name): its manifest is not JSON; left out"; return 1; }
    case $media_type in
    application/vnd.oci.image.manifest.v1+json | application/vnd.docker.distribution.manifest.v2+json) ;;
    *)
        warn "$at ($name) is ${media_type:-no image}, not one image (an index lists single images); left out"
        return 1
        ;;
    esac

    at=$host/${repo[$name]}@$digest
    fetch "$config" "read the config of $at ($name)" skopeo inspect --config "${skopeo_opts[@]}" "docker://$at" || return 1
    IFS=$'\x1f' read -r os arch ref < <(jq -r '[.os // "", .architecture // "", (.config.Labels // {})["org.flatpak.ref"] // ""] | join("\u001f")' "$config")
    # The ref must be KIND/ID/ARCH/BRANCH, on linux.
    want=${kind[$name]}/${id[$name]}/$(flatpak_arch "$arch")/
    if [ "$os" != linux ] || [[ $ref != "$want"?* ]] || [[ ${ref#"$want"} == */* ]]; then
        warn "$at holds ${ref:-no Flatpak} (${os:-?}/${arch:-?}), not ${want}<branch>: it is not $name's; left out"
        return 1
    fi
    jq -e '(.config.Labels["org.flatpak.metadata"] // "") | length > 0' "$config" >/dev/null ||
        { warn "$at ($ref) has no org.flatpak.metadata label, which flatpak needs; left out"; return 1; }
    if [ "${kind[$name]}" = app ]; then
        runtime=$(app_runtime "$config")
        [[ $runtime == ?*/?*/?* ]] || { warn "$at ($ref) names no runtime in its metadata; left out"; return 1; }
        runs_on[$name]=runtime/$runtime
    fi

    index_entry "$name" "$digest" "$media_type" "$config" >"$work/$name.json"
    ref_of[$name]=$ref
    digest_of[$name]=$digest
}

# read_images: reads each Flatpak's image. Fails where none can be read,
# and so writes nothing.
read_images() {
    local name
    for name in "${names[@]}"; do
        if read_image "$name"; then
            readable[$name]=1
        fi
    done
    [ "${#readable[@]}" != 0 ] || die "no Flatpak of NAMES could be read from $host/$owner: nothing written"
}

# --- the site ---

# in_root NAME ROOT: succeeds if the remote ROOT lists NAME. A variant is
# in its own root alone. A plain Flatpak is in every root but that of a
# variant its app has.
in_root() {
    local name=$1 root=$2
    if [ -n "${variant[$name]}" ]; then
        [ "${variant[$name]}" = "$root" ]
    else
        [ -z "$root" ] || [ -z "${has[${id[$name]}/$root]:-}" ]
    fi
}

# flatpakrepo ROOT: prints the .flatpakrepo file of the remote ROOT.
flatpakrepo() {
    local root=$1
    echo "[Flatpak Repo]"
    echo "Title=$remote${root:+ ($root)}"
    echo "Url=oci+$url/${root:+$root/}"
    [ -z "$repository" ] || echo "Homepage=${GITHUB_SERVER_URL:-https://github.com}/$repository"
}

# page_lines ROOT NAME...: prints the page's lines for the remote ROOT,
# which lists NAME...: what it has that the plain one does not, and how to
# add it.
page_lines() {
    local root=$1 name
    shift
    if [ -z "$root" ]; then
        echo "<p>Every Flatpak's <code>latest</code>:</p>"
    else
        printf '<p>The same, but'
        for name; do
            [ -z "${variant[$name]}" ] || printf ' <code>%s</code>' "$(html "${id[$name]}")"
        done
        echo " as <code>$(html "$root")</code>:</p>"
    fi
    echo "<pre>flatpak remote-add --user --if-not-exists $(html "$remote") $(html "$url/${root:+$root/}$remote.flatpakrepo")</pre>"
}

# write_root ROOT: writes the remote ROOT ("" for the plain one) into the
# site: its index/static and its .flatpakrepo. Adds its lines to the page
# and to the step summary. Prints each image it lists: remote, ref, image.
write_root() {
    local root=$1 remote_url dir name refs=' ' members=() kept=()
    remote_url=$url/${root:+$root/}
    for name in "${names[@]}"; do
        if in_root "$name" "$root" && [ -n "${readable[$name]:-}" ]; then
            members+=("$name")
        fi
    done
    # A remote lists each ref once.
    for name in "${members[@]}"; do
        [[ $refs != *" ${ref_of[$name]} "* ]] || die "${ref_of[$name]} twice in the remote $remote_url"
        refs+="${ref_of[$name]} "
    done
    # An app is listed only where its runtime is.
    for name in "${members[@]}"; do
        if [ -n "${runs_on[$name]:-}" ] && [[ $refs != *" ${runs_on[$name]} "* ]]; then
            warn "$name runs on ${runs_on[$name]#runtime/}, which the remote $remote_url does not have; left out of it"
        else
            kept+=("$name")
        fi
    done
    members=("${kept[@]}")
    listed=$((listed + ${#members[@]}))
    if [ -z "$root" ]; then
        for name in "${members[@]}"; do
            plain[$name]=1
        done
    fi

    dir=$site${root:+/$root}
    mkdir -p "$dir/index"
    for name in "${members[@]}"; do
        cat "$work/$name.json"
    done | jq -S -s --arg registry "$registry/" '{Registry: $registry, Results: sort_by(.Name)}' >"$dir/index/static"
    flatpakrepo "$root" >"$dir/$remote.flatpakrepo"
    page_lines "$root" "${members[@]}" >>"$page"
    for name in "${members[@]}"; do
        printf '%s\t%s\t%s\n' "$remote_url" "${ref_of[$name]}" "$host/${repo[$name]}@${digest_of[$name]}"
        summary+=$'\n'"| \`$remote_url\` | \`${ref_of[$name]}\` | \`$host/${repo[$name]}@${digest_of[$name]}\` |"
    done
}

# plain_apps: prints, sorted, the ID of each app that the plain remote
# lists.
plain_apps() {
    local name
    for name in "${names[@]}"; do
        if [ "${kind[$name]}" = app ] && [ -z "${variant[$name]}" ] && [ -n "${plain[$name]:-}" ]; then
            echo "${id[$name]}"
        fi
    done | LC_ALL=C sort
}

# index_html: prints URL/index.html: the remotes, and the apps of the plain
# one.
index_html() {
    local app_id
    cat <<EOF
<!doctype html>
<html lang="en">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>$(html "$remote") Flatpaks</title>
<style>body{font:16px/1.5 system-ui,sans-serif;max-width:48rem;margin:2rem auto;padding:0 1rem}pre{overflow-x:auto}</style>
<h1>$(html "$remote") Flatpaks</h1>
<p>A Flatpak remote of private images on $(html "$host/$owner"): a machine pulls them with a token of its own that reads them, in <code>~/.config/flatpak/oci-auth.json</code>.</p>
EOF
    cat "$page"
    echo "<ul>"
    plain_apps | while read -r app_id; do
        echo "<li>$(html "$app_id")</li>"
    done
    echo "</ul>"
}

# step_summary: prints what each remote lists, and what the site leaves
# out.
step_summary() {
    echo "$summary"
    if [ "${#left[@]}" != 0 ]; then
        echo
        echo "Left out:"
        printf -- '- %s\n' "${left[@]}"
    fi
}

# --- main ---

main() {
    local out root
    { [ "$#" = 2 ] && [ ! -t 0 ]; } || die "usage: build.sh names | index.sh OUT URL"
    # OUT is relative to where the script is run from, before the cd below.
    out=$(realpath -m "$1")
    url=${2%/}
    [[ $url =~ ^https?://[^/]+(/.*)?$ ]] || die "not a site's URL: $2"
    # OUT goes, to be made anew: only a site of this script's.
    [ ! -e "$out" ] || [ -f "$out/index/static" ] || die "$out is there, and is no site of index.sh's: not replaced"
    cd "$(dirname "$0")/.."
    read_environment

    work=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/index.XXXXXX")
    trap 'rm -rf "$work"' EXIT
    use_registry
    read_names
    read_images

    site=$work/site
    page=$work/page
    for root in "${roots[@]}"; do
        write_root "$root"
    done
    # An empty index would replace the one deployed: none is written, as
    # where nothing can be read.
    [ "$listed" != 0 ] || die "every Flatpak read is left out (above), as its runtime is not: nothing to list, nothing written"
    index_html >"$site/index.html"

    # Only now, with the whole site written, does OUT go.
    rm -rf "$out"
    mkdir -p "$(dirname "$out")"
    mv "$site" "$out"
    step_summary >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
}

main "$@"
