#!/usr/bin/env bash
#
# The jobs of .github/workflows/flatpaks.yml (and of each Flatpak's
# pipeline, flatpak.yml) and of devcontainer.yml: what they decide, and how
# they build. It runs from the root of the checkout.
#
#   ci.sh plan           decides which Flatpaks this run builds and pushes:
#                        the plan job's outputs.
#   ci.sh build NAME     builds and tests the Flatpak NAME into
#                        output/flatpaks/NAME, as `build.sh flatpak NAME`
#                        does, on the run's cache (bake). An app is tested
#                        on the runtime that machines get (whence).
#   ci.sh push NAME      pushes output/flatpaks/NAME, in the job that built
#                        and tested it.
#   ci.sh devcontainer   builds the dev container's two images on the run's
#                        cache, into output/images/devcontainer and
#                        devcontainer-ai, and into rootless podman's storage
#                        as LOCAL and LOCAL_AI.
#
# Each Flatpak is a pipeline of its own: build.sh names lists them (the
# runtime, the SDK, then each app on one of them), and flatpak.yml has its
# build, sign and index jobs. So one that fails to build or test holds back
# none of the others. A broken app never delays the runtime's security
# updates, or another app's release.
#
# What the plan picks:
# - On a pull request (ci.yml): the jobs that the PR can affect, by its
#   changes against the base it merges into (affected). Nothing is pushed.
# - On main, by hand: everything, built and pushed.
# - On main, on the schedule: everything built and tested, and the runtime
#   and the SDK pushed, for Fedora's updates.
# - On main, on a push and on the schedule: each Flatpak whose sources
#   (content) changed since the last run on main that published it, pushed.
#   That run is the newest in which its build job succeeded and, where it
#   pushed, its sign job too. Each one whose job failed in the run before is
#   tested again, so that a failure stays in sight until a run fixes it.
# This goes per Flatpak, not per run: a run in which Remmina failed still
# published Firefox, and the next one pushes Remmina again, not Firefox.
# Every new image is a full download for every machine that follows it,
# which is why nothing else is pushed.
#
# Every image is baked on a cache in the registry: a private package of the
# owner's, ghcr.io/<owner>/packages-cache, with a tag for each target
# (bake). Every job reads it, and builds again only what changed since a
# job on main wrote it. The builder and the runtime are built on the Fedora
# image that the cache was built on, which is kept there too (fedora),
# whatever Fedora's tag points at that day. No image goes from one job to
# another but that way. The one artifact is what sign needs: the digests
# pushed.
#
# Needs:
# - plan: bash, git (the whole history), jq, docker with buildx (build.sh
#   names reads docker-bake.hcl), and on main gh with GH_TOKEN (the runs
#   before: actions read).
# - build and devcontainer: docker logged in to ghcr.io (the cache), skopeo
#   and curl, and for an app's build on main GH_TOKEN (packages read).
# - push: skopeo logged in to ghcr.io, and curl.
# The environment is the job's (GITHUB_*, RUNNER_TEMP), plus:
#   EVENT        github.event_name.
#   GH_REPO      the repository, for gh.
#   FRESH        for the runtime's build and the dev container's (bake).
#   DAY          for push: the plan's date, one for the whole run.
#   BASE_RESULT, BASE_READY, BASE_PUSH, BASE_DIGEST
#                for an app: its runtime's job and plan (whence, push).
#   BASE_BUILD   for an app on a pull request: whether this run builds its
#                runtime (whence).
set -euo pipefail

# --- state ---

# The directory of this script, with build.sh and private.sh.
here=$(cd "$(dirname "$0")" && pwd)
# This run is one on main: not a pull request's (whose ref is never main's),
# nor one on another branch. It alone pushes and writes the cache.
on_main=''
# The owner, in lower case, and the cache's package.
owner='' cache=''
# Where the script works: a temporary directory, removed on exit.
work=''

# The plan's Flatpaks (read_flatpaks): each NAME, in build.sh names' order,
# with its directory and the runtime it is built on (- for none).
names=()
declare -A dir_of=() on_of=()
# What the plan decides for each Flatpak: whether it is built, whether it is
# pushed, and why.
declare -A will_build=() will_push=() reason=()
# What lookup finds of each Flatpak, empty where nothing is known: the
# commit of the newest run that published it, and the result of its newest
# build job that ran to an end.
declare -A published_at=() last_result=()

# Main's head commit, as behind found it (empty where unknown).
tip=''
# The Fedora image kept in the cache's package, and the image of the day
# that the runtime's job builds on (fedora).
kept='' fresh=''
# The caches that the last bake wrote (bake).
wrote=''
# Where the runtime that an app's test runs on comes from (whence): how
# (fetch, try or make), at (a digest, or latest), and why.
how='' at='' why=''

# --- helpers ---

# fail MESSAGE: fails the job, with MESSAGE as an error annotation.
fail() {
    echo "::error::$*" >&2
    exit 1
}

# bool VALUE: prints true where VALUE is not empty, false where it is.
bool() {
    if [ -n "$1" ]; then echo true; else echo false; fi
}

# api ARG...: runs gh api ARG..., with three tries 30 seconds apart, as the
# API fails with a 5xx at times. Its output is passed on only from the try
# that succeeded, and whole: a paginated call can fail after its first
# pages.
api() {
    local attempt out
    for attempt in 1 2 3; do
        if out=$(gh api "$@"); then
            [ -z "$out" ] || printf '%s\n' "$out"
            return 0
        fi
        if [ "$attempt" != 3 ]; then
            echo "gh api $1 failed (attempt $attempt), retrying in 30s" >&2
            sleep 30
        fi
    done
    return 1
}

# tries WHAT COMMAND...: runs COMMAND, with three tries 30 seconds apart, as
# the registry fails at times. Its output is passed on.
tries() {
    local what=$1 attempt
    shift
    for attempt in 1 2 3; do
        if "$@"; then
            return 0
        fi
        if [ "$attempt" != 3 ]; then
            echo "$what failed (attempt $attempt), retrying in 30s" >&2
            sleep 30
        fi
    done
    echo "::error::could not $what" >&2
    return 1
}

# --- what goes into each Flatpak ---

# content NAME DIR [tests]: prints the git pathspecs of what goes into
# NAME's Flatpak, which is built from DIR. With tests, also what its job
# tests it with: its own test.sh, and tools/test.sh where it has tools/.
# - Each Flatpak: its directories, but for their README.md and test.sh,
#   which are not in it.
# - The runtime: runtime/ but the SDK's directory, and what makes a Flatpak
#   of an image (build/flatpak.sh, and build/Containerfile, the builder it
#   runs in).
# - The SDK: all of runtime/ (it is the runtime's image with more), and
#   those two.
# - The VS Code Flatpak: its directory, and what its build installs from
#   tools/ (all but the pin check). For ai alone: files-ai/,
#   tools/claude-code.sh, Claude Code's key and a new CLAUDE_VERSION
#   (diffopts). So Claude Code's weekly release is no new image for plain's
#   machines.
# - Another app: its directory, and tools/ and keys/ (but cosign.pub) where
#   its Containerfile copies from them.
# A runtime moves its apps along only through its branch, which changes
# their flatpak.runtime label.
content() {
    local name=$1 own_dir=$2 tests=${3:-} dirs=() more=() dir
    case $name in
    runtime)
        dirs=(runtime)
        more=(':(exclude)runtime/sdk' build/flatpak.sh build/Containerfile)
        ;;
    sdk)
        dirs=(runtime runtime/sdk)
        more=(build/flatpak.sh build/Containerfile)
        ;;
    io.github.lucarickli.Code)
        dirs=("$own_dir" tools)
        more=(":(exclude)$own_dir/files-ai" ':(exclude)tools/claude-code.sh')
        ;;
    io.github.lucarickli.Code-ai)
        dirs=("$own_dir" tools)
        more=(keys/claude-code.asc)
        ;;
    *)
        dirs=("$own_dir")
        if grep -q -- '--from=tools' "$own_dir/Containerfile"; then dirs+=(tools); fi
        if grep -q -- '--from=keys' "$own_dir/Containerfile"; then more+=(keys ':(exclude)keys/cosign.pub'); fi
        ;;
    esac
    for dir in "${dirs[@]}"; do
        printf '%s\n' "$dir" ":(exclude)$dir/README.md"
        # With tests, its own test and tools/test.sh (which a test stage
        # copies) stay in.
        if [ -z "$tests" ] || { [ "$dir" != "$own_dir" ] && [ "$dir" != tools ]; }; then
            printf '%s\n' ":(exclude)$dir/test.sh"
        fi
    done
    printf '%s\n' "${more[@]}" ':(exclude)tools/verify-pins.sh'
}

# diffopts NAME: prints git diff's options for NAME's content. For the
# plain VS Code Flatpak, a new CLAUDE_VERSION alone is no change.
diffopts() {
    case $1 in
    io.github.lucarickli.Code) printf '%s\n' -I '^ARG CLAUDE_VERSION=' ;;
    esac
}

# affected NAME DIR ON: succeeds if the pull request (HEAD^1 to HEAD) can
# break NAME, that is if it changes:
# - NAME's content or its test;
# - the content of ON, the runtime NAME is built on;
# - or what builds, tests and scans every Flatpak: build/ (the bake file,
#   the builder and these scripts, but the index's), the two workflows,
#   ci.yml (which counts as everything), the actions the jobs use, and the
#   pins the scan's trivy comes from.
# Each set is diffed on its own, as git applies an exclude to all of them.
affected() {
    local name=$1 dir=$2 on=$3 opts paths
    local shared=(build ':(exclude)build/index.sh' .github/workflows/flatpaks.yml
        .github/workflows/flatpak.yml .github/workflows/ci.yml .github/actions/prepare-runner
        .github/actions/buildx .github/actions/scan-image tools/install.sh tools/tools.txt)
    mapfile -t opts < <(diffopts "$name")
    mapfile -t paths < <(content "$name" "$dir" tests)
    git diff --quiet "${opts[@]}" 'HEAD^1' HEAD -- "${paths[@]}" || return 0
    case $on in
    runtime) mapfile -t paths < <(content runtime runtime) ;;
    sdk) mapfile -t paths < <(content sdk runtime/sdk) ;;
    *) paths=() ;;
    esac
    [ "${#paths[@]}" = 0 ] || git diff --quiet 'HEAD^1' HEAD -- "${paths[@]}" || return 0
    ! git diff --quiet 'HEAD^1' HEAD -- "${shared[@]}"
}

# --- plan ---

# branch REV FILE: prints the flatpak.branch that FILE names at REV, or
# nothing.
branch() {
    git show "$1:$2" 2>/dev/null | sed -n 's/.*flatpak\.branch=\([0-9][0-9]*\).*/\1/p' | head -n 1
}

# past_runs: prints the runs that lookup reads, ID ATTEMPT SHA, newest
# first. This run's earlier attempt comes first (Re-run all jobs). Then come
# the 100 newest runs on main that completed. Cancelled ones count too, as
# a job of one may have finished. A pull request's do not (the jq), as
# exclude_pull_requests only leaves their pull_requests field out of the
# answer.
past_runs() {
    if [ "${GITHUB_RUN_ATTEMPT:-1}" -gt 1 ]; then
        echo "$GITHUB_RUN_ID $((GITHUB_RUN_ATTEMPT - 1)) $GITHUB_SHA"
    fi
    api "repos/$GH_REPO/actions/workflows/flatpaks.yml/runs?branch=main&status=completed&exclude_pull_requests=true&per_page=100" \
        --jq '.workflow_runs[] | select(.event != "pull_request") | "\(.id) \(.run_attempt) \(.head_sha)"'
}

# job_results NAME: prints, of one attempt's jobs (JSON on stdin), the
# conclusion of NAME's build job, of its Push step and of its sign job:
# none for each one that is not there.
job_results() {
    jq -r --arg b "$1 / build" --arg s "$1 / sign" '
        ([.jobs[] | select(.name == $s) | .conclusion][0] // "none") as $sign
        | [.jobs[] | select(.name == $b)][0]
        | if . == null then "none none none"
          else "\(.conclusion) \([.steps[]? | select(.name == "Push") | .conclusion][0] // "none") \($sign)" end'
}

# lookup: reads, from the runs before (past_runs), what each Flatpak's
# pipeline (flatpak.yml) did:
# - published_at[NAME]: the head commit of the newest run that published
#   NAME. Its build job, `NAME / build`, succeeded, and if its Push step
#   ran, so did its sign job, `NAME / sign` (the signature).
# - last_result[NAME]: the conclusion of its newest build job that ran to
#   an end: success, failure or timed_out. A skipped job (the runtime's and
#   the SDK's, in a run that built nothing on them) or a cancelled one (a
#   run dropped while pending) says nothing about NAME's sources. It would
#   have the next run test NAME again for nothing.
# An attempt's jobs are its own and those it kept from the attempt before
# (Re-run failed jobs), every page of them (three jobs a Flatpak). The runs
# are read until every Flatpak has both.
lookup() {
    local id attempt sha json missing name job pushed sign
    past_runs >"$work/runs"
    while read -r id attempt sha; do
        json=$(api "repos/$GH_REPO/actions/runs/$id/attempts/$attempt/jobs?per_page=100" --paginate --jq '.jobs[]' | jq -s '{jobs: .}')
        missing=0
        for name in "${names[@]}"; do
            if [ -n "${published_at[$name]:-}" ] && [ -n "${last_result[$name]:-}" ]; then
                continue
            fi
            read -r job pushed sign < <(job_results "$name" <<<"$json")
            case $job in
            success | failure | timed_out) [ -n "${last_result[$name]:-}" ] || last_result[$name]=$job ;;
            esac
            if [ -z "${published_at[$name]:-}" ] && [ "$job" = success ] && { [ "$pushed" = skipped ] || [ "$sign" = success ]; }; then
                published_at[$name]=$sha
            fi
            if [ -z "${published_at[$name]:-}" ] || [ -z "${last_result[$name]:-}" ]; then
                missing=1
            fi
        done
        [ "$missing" = 1 ] || break
    done <"$work/runs"
}

# read_flatpaks: reads the Flatpaks that build.sh names lists into names,
# dir_of and on_of. Where it fails, it lists nothing, and so does the plan.
read_flatpaks() {
    local name dir on
    while read -r name dir on; do
        names+=("$name")
        dir_of[$name]=$dir
        on_of[$name]=$on
    done < <("$here/build.sh" names)
    [ "${#names[@]}" -gt 0 ] || fail "build.sh names listed nothing"
}

# plan_pull_request: builds what the pull request can break (affected). The
# PR's changes are those of its merge commit against the first parent, the
# base it merges into.
plan_pull_request() {
    local name
    git rev-parse --verify -q 'HEAD^1' >/dev/null || fail "no parent of the merge commit"
    for name in "${names[@]}"; do
        if affected "$name" "${dir_of[$name]}" "${on_of[$name]}"; then
            will_build[$name]=1 reason[$name]="the pull request changes it"
        fi
    done
}

# plan_branch: by hand on another branch, builds everything, and pushes
# nothing.
plan_branch() {
    local name
    for name in "${names[@]}"; do
        will_build[$name]=1 reason[$name]="by hand, not on main: nothing is pushed"
    done
}

# why_push NAME: prints why this run on main pushes NAME, or nothing where
# it does not.
why_push() {
    local name=$1 published=${published_at[$1]:-} opts paths
    mapfile -t opts < <(diffopts "$name")
    mapfile -t paths < <(content "$name" "${dir_of[$name]}")
    if [ "$EVENT" = workflow_dispatch ]; then
        echo "by hand: everything"
    elif [ "$EVENT" = schedule ] && { [ "$name" = runtime ] || [ "$name" = sdk ]; }; then
        echo "weekly: Fedora's updates"
    elif [ -z "$published" ] || ! git cat-file -e "$published^{commit}" 2>/dev/null; then
        echo "no run that published it${published:+ in this history (${published:0:7})}"
    elif ! git diff --quiet "${opts[@]}" "$published" HEAD -- "${paths[@]}"; then
        echo "changed since ${published:0:7}"
    fi
}

# plan_main: on main, pushes each Flatpak that why_push names. Of the rest,
# it builds and tests every one on the schedule, and each one whose last
# job failed.
plan_main() {
    local name why since
    lookup
    for name in "${names[@]}"; do
        why=$(why_push "$name")
        since=${published_at[$name]:-}
        since=${since:0:7}
        if [ -n "$why" ]; then
            will_push[$name]=1 will_build[$name]=1 reason[$name]=$why
        elif [ "$EVENT" = schedule ]; then
            will_build[$name]=1 reason[$name]="weekly: built and tested, unchanged since $since"
        elif [ "${last_result[$name]:-success}" != success ]; then
            will_build[$name]=1 reason[$name]="its last job ended ${last_result[$name]}: tested again, unchanged since $since"
        else
            reason[$name]="unchanged since $since"
        fi
    done
}

# plan_outputs: prints the plan job's outputs:
# - day: the run's date, for every push of it.
# - runtime-build, runtime-push, sdk-build, sdk-push.
# - runtime-ready, sdk-ready: the published runtime (or SDK) is on the
#   branch this commit names, whatever its job does in this run. Where it
#   is not (a new Fedora release), an app on it is pushed only once that
#   job pushed it (push, BASE_READY).
# - apps, sdk-apps: the apps built, on the runtime and on the SDK, as the
#   matrices of their pipelines: {name, push}.
# - push: whether anything is pushed.
plan_outputs() {
    local name entry runtime file ready apps=() sdk_apps=()
    for name in "${names[@]}"; do
        case $name in runtime | sdk) continue ;; esac
        [ -n "${will_build[$name]:-}" ] || continue
        entry=$(jq -cn --arg name "$name" --argjson push "$(bool "${will_push[$name]:-}")" '{name: $name, push: $push}')
        if [ "${on_of[$name]}" = sdk ]; then sdk_apps+=("$entry"); else apps+=("$entry"); fi
    done
    echo "day=$(date -u +%Y%m%d)"
    for runtime in runtime sdk; do
        echo "$runtime-build=$(bool "${will_build[$runtime]:-}")"
        echo "$runtime-push=$(bool "${will_push[$runtime]:-}")"
        file=runtime/Containerfile
        [ "$runtime" = runtime ] || file=runtime/sdk/Containerfile
        ready=false
        if [ -n "$on_main" ] && [ -n "${published_at[$runtime]:-}" ] &&
            [ "$(branch "${published_at[$runtime]}" "$file")" = "$(branch HEAD "$file")" ]; then
            ready=true
        fi
        echo "$runtime-ready=$ready"
    done
    echo "apps=$(printf '%s\n' "${apps[@]}" | jq -cs 'map(select(. != null))')"
    echo "sdk-apps=$(printf '%s\n' "${sdk_apps[@]}" | jq -cs 'map(select(. != null))')"
    if [ "${#will_push[@]}" -gt 0 ]; then echo "push=true"; else echo "push=false"; fi
}

# plan_summary: prints the plan's step summary: each Flatpak, whether it is
# built and pushed, and why.
plan_summary() {
    local name
    echo "### Flatpaks ($EVENT, ${GITHUB_SHA:0:7})"
    echo
    echo "| Flatpak | Built | Pushed | Why |"
    echo "|---|---|---|---|"
    for name in "${names[@]}"; do
        echo "| $name | ${will_build[$name]:+yes} | ${will_push[$name]:+yes} | ${reason[$name]:-not affected} |"
    done
    echo
}

# plan: decides which Flatpaks this run builds and pushes, as the plan
# job's outputs (also printed) and its step summary.
plan() {
    read_flatpaks
    if [ "$EVENT" = pull_request ]; then
        plan_pull_request
    elif [ -z "$on_main" ]; then
        plan_branch
    else
        plan_main
    fi
    # What an app is built on is not built for it. Its job builds that
    # runtime again of the cache, and its test runs on the Flatpak that
    # machines have, or on one it makes (build, whence). A runtime's job
    # runs only where the runtime itself is to be built, and the jobs on it
    # wait for it: for its image in the cache, and its push.
    plan_outputs | tee -a "${GITHUB_OUTPUT:-/dev/null}"
    plan_summary >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
}

# --- re-runs ---

# behind: succeeds if this run is a re-run (Re-run all jobs, or its failed
# jobs) and main has moved on from its commit, or the API cannot tell.
# What such a run pushed (push) or wrote to the cache (bake) would put back
# an older one. Sets tip.
behind() {
    tip=''
    [ "${GITHUB_RUN_ATTEMPT:-1}" -gt 1 ] || return 1
    tip=$(api "repos/${GH_REPO:-${GITHUB_REPOSITORY:?}}/git/ref/heads/main" --jq .object.sha) || tip=''
    [ "$tip" != "${GITHUB_SHA:?}" ]
}

# moved: prints where main is, as behind found it.
moved() {
    if [ -n "$tip" ]; then
        echo "main is at ${tip:0:7} now"
    else
        echo "the head of main is unknown (the API failed)"
    fi
}

# --- push ---

# check_base NAME: refuses to push the app NAME, tested on this run's
# runtime, where machines would not get that runtime: unless the runtime's
# job succeeded in this run (BASE_RESULT), which pushed it, it fails where
# - the runtime is not published on the branch NAME names (BASE_READY
#   false: a new Fedora release), as a remote never names an app whose
#   runtime it lacks;
# - or this run was to push the runtime (BASE_PUSH true).
check_base() {
    local name=$1
    if [ "${BASE_RESULT:-}" != success ] && [ "${BASE_READY:-}" != true ]; then
        fail "$name names a branch of its runtime that is not published, and that runtime's job ended ${BASE_RESULT:-unknown}: not pushed"
    fi
    if [ "${BASE_RESULT:-}" != success ] && [ "${BASE_PUSH:-}" = true ]; then
        fail "$name was tested on the runtime this run was to push, and that runtime's job ended ${BASE_RESULT:-unknown}: not pushed, as machines would run it on the one before"
    fi
}

# push_tag DIR TARGET: pushes the layout DIR to TARGET (REPO:TAG), with
# three tries 30 seconds apart. Its digest goes to $RUNNER_TEMP/digest.
push_tag() {
    local dir=$1 target=$2 attempt
    for attempt in 1 2 3; do
        if skopeo copy --retry-times 3 --digestfile "$RUNNER_TEMP/digest" "oci:$dir" "docker://$target"; then
            return 0
        fi
        [ "$attempt" != 3 ] || fail "could not push $target"
        echo "push of $target failed (attempt $attempt), retrying in 30s" >&2
        sleep 30
    done
}

# push NAME: pushes output/flatpaks/NAME to the repository that its
# Flatpak's ID names, read from the layout (the ref flatpak wrote into it).
# The VS Code Flatpak's stays where machines follow it,
# ghcr.io/<owner>/code. A variant (<ID>-<variant>, the same ref) goes as
# :<day>-<variant> and :<variant>, the others as :<day> and :latest.
#
# The dated tag goes first, then the moving one: a copy that fails leaves
# the moving tag where it was. skopeo copies the manifest byte for byte,
# so the digest in the summary is the one a remote's index names, and both
# tags are one digest. It goes to $RUNNER_TEMP/pushed/NAME for sign as soon
# as it is pushed (a dated tag alone is signed too), with the output
# pushed=true.
#
# Refused before anything is pushed, each failing the job so that the next
# run pushes it again:
# - a re-run of a run whose commit is no longer main's (behind): its push
#   would put back an older image, and the newer run's jobs publish it;
# - a repository that is public (private.sh);
# - an app whose runtime machines would not get (check_base).
push() {
    local name=$1 dir=output/flatpaks/$1 owner=${GITHUB_REPOSITORY_OWNER,,} day=${DAY:?}
    local ref id variant='' repo tags tag digest
    if behind; then
        fail "$(moved): a re-run of this run (${GITHUB_SHA:0:7}) pushes nothing, as it would put back an older $name; re-run the newest run instead"
    fi
    case $name in
    runtime | sdk) ;;
    *) check_base "$name" ;;
    esac

    # NAME must be the layout's: a runtime, or an app of apps/ as its ID or
    # a variant of it.
    [ -f "$dir/index.json" ] || fail "no Flatpak in $dir"
    ref=$(jq -r '.manifests[0].annotations["org.opencontainers.image.ref.name"] // empty' "$dir/index.json")
    id=$(cut -d/ -f2 <<<"$ref")
    case $name in
    runtime | sdk)
        [[ $ref == runtime/* ]] || fail "$dir holds $ref, not a runtime"
        ;;
    "$id" | "$id"-*)
        [ "$name" = "$id" ] || variant=${name#"$id"-}
        [ -d "apps/$id" ] || fail "$dir holds $ref, and there is no apps/$id"
        ;;
    *)
        fail "$dir holds $ref, not $name"
        ;;
    esac

    repo=ghcr.io/$owner/${id,,}
    [ "$id" != io.github.lucarickli.Code ] || repo=ghcr.io/$owner/code
    "$here/private.sh" "$repo"
    mkdir -p "$RUNNER_TEMP/pushed"
    tags=("$day" latest)
    [ -z "$variant" ] || tags=("$day-$variant" "$variant")
    for tag in "${tags[@]}"; do
        push_tag "$dir" "$repo:$tag"
        digest=$(cat "$RUNNER_TEMP/digest")
        # Recorded for its sign job at once, also where a later tag fails.
        echo "$repo@$digest" >>"$RUNNER_TEMP/pushed/$name"
        sort -u -o "$RUNNER_TEMP/pushed/$name" "$RUNNER_TEMP/pushed/$name"
        echo "pushed=true" >>"${GITHUB_OUTPUT:-/dev/null}"
        echo "Pushed \`$repo@$digest\` ($name) as :$tag" >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
    done
    # The moving tag's digest, the dated one's too: what the jobs on a
    # runtime test their apps on (whence).
    echo "digest=$digest" >>"${GITHUB_OUTPUT:-/dev/null}"
}

# --- baking on the run's cache ---

# bake WRITE ARG...: runs build.sh bake ARG... on the run's cache, CACHE
# (docker-bake.hcl's), which every bake of the run reads. It writes there
# the caches that WRITE names (docker-bake.hcl's CACHE_WRITE): the job's
# own targets, never the runtime it builds on, which that runtime's job
# wrote. It writes them only
# - where this run is main's: a pull request, or a run on another branch,
#   writes nothing, as main's builds take whatever they find there;
# - not in a re-run that main has moved on from (behind): it would put back
#   an older cache, as push refuses an older image;
# - and once private.sh found the cache's package private, as it holds
#   every image's layers.
# Sets wrote to the caches it wrote. FRESH, as the job sets it (the
# runtime's and the dev container's, weekly and by hand), goes to this bake
# alone. build.sh tries each bake three times.
bake() {
    local write=$1
    shift
    if [ -z "$on_main" ]; then
        write=''
    elif [ -n "$write" ] && behind; then
        echo "::notice::$(moved): this re-run of ${GITHUB_SHA:0:7} writes no cache" >&2
        write=''
    elif [ -n "$write" ]; then
        "$here/private.sh" "$cache"
    fi
    wrote=$write
    CACHE_WRITE=$write FRESH=${FRESH:-false} "$here/build.sh" bake "$@"
}

# again COMMAND...: runs build.sh COMMAND... after a bake, whose images are
# in the builder's own cache by then. So it is not fresh again, and writes
# no cache twice.
again() {
    FRESH=false CACHE_WRITE='' "$here/build.sh" "$@"
}

# bake_base RUNTIME: bakes RUNTIME, the runtime or the SDK that an app (or
# the SDK) is built on, first and alone. It comes out of the cache, which
# only its own job writes, on the Fedora image that cache was built on
# (fedora), into its layout, output/images/RUNTIME. Every bake after it
# builds FROM that layout (docker-bake.hcl's RUNTIME and SDK,
# oci-layout://). So it is as its job made it, digest for digest, and what
# is built on it finds its own cache. Built in the same bake
# (target:runtime), the steps on top of it would miss that cache on every
# new builder.
bake_base() {
    bake '' "$1"
    export "${1^^}=oci-layout://$PWD/output/images/$1"
}

# --- the Fedora image ---

# fedora [writer]: exports FEDORA_REF, the Fedora image that the builder
# and the runtime are built FROM (runtime/Containerfile's FROM), and
# FEDORA, the image that every bake of the job builds them on in its place
# (docker-bake.hcl's).
#
# FEDORA is the image their cache was built on, by its digest: the
# runtime's job on main keeps it in the cache's package as base-fedora-<N>
# (keep). Fedora replaces the image behind its tag every day or two, and a
# step on another base misses the cache. Every job would then build the
# runtime, the builder and what is on them again, each its own.
#
# The runtime's job (writer) takes the tag's image of the day instead
# (fresh): weekly and by hand (FRESH), and where none is kept yet (the
# first run, a new Fedora release). That is its amd64 manifest's digest,
# which BuildKit's cache goes by. Where none is kept, another job builds on
# the tag as it is (FEDORA empty).
fedora() {
    local role=${1:-} digest raw
    FEDORA_REF=$(sed -n 's|^FROM \(registry\.fedoraproject\.org/fedora:[0-9][0-9]*\)[[:space:]].*|\1|p' runtime/Containerfile | head -n 1)
    [ -n "$FEDORA_REF" ] || fail "runtime/Containerfile is not FROM registry.fedoraproject.org/fedora:<N>"
    kept=$cache:base-fedora-${FEDORA_REF##*:} fresh=''
    export FEDORA_REF FEDORA=
    # The kept image, unless the runtime's job takes the one of the day.
    if [ "$role" != writer ] || [ "${FRESH:-false}" != true ]; then
        if digest=$(skopeo inspect --retry-times 3 --format '{{.Digest}}' "docker://$kept") && [[ $digest =~ ^sha256:[0-9a-f]{64}$ ]]; then
            FEDORA=docker-image://${kept%:*}@$digest
            echo "Built on $FEDORA_REF as kept, \`${kept%:*}@$digest\`" >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
            return
        fi
        if [ "$role" != writer ]; then
            echo "::notice::no $kept to build on (the runtime's job keeps it): $FEDORA_REF as it is today" >&2
            return
        fi
    fi
    # The image of the day: the amd64 one of the tag's list, or the tag's
    # own where it names one image.
    raw=$(tries "read $FEDORA_REF" skopeo inspect --retry-times 3 --raw "docker://$FEDORA_REF")
    digest=$(jq -r '[.manifests[]? | select(.platform.os == "linux" and .platform.architecture == "amd64") | .digest][0] // empty' <<<"$raw")
    [ -n "$digest" ] || digest=$(tries "read $FEDORA_REF" skopeo inspect --retry-times 3 --format '{{.Digest}}' "docker://$FEDORA_REF")
    [[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || fail "$FEDORA_REF has no linux/amd64 digest"
    FEDORA=docker-image://${FEDORA_REF%:*}@$digest fresh=$digest
    echo "Built on $FEDORA_REF of today, \`${FEDORA_REF%:*}@$digest\`" >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
}

# keep: copies the image of the day that the runtime's job built on
# (fresh) to base-fedora-<N>, byte for byte (the same digest), for every
# job after it to build on. It runs once the bake wrote the cache (wrote).
# A copy that fails costs time, not a build: the jobs then build on the
# image kept before, and miss the cache of this one.
keep() {
    local digest
    if skopeo copy --retry-times 3 --quiet --digestfile "$work/kept" "docker://${FEDORA_REF%:*}@$fresh" "docker://$kept"; then
        digest=$(cat "$work/kept")
        if [ "$digest" = "$fresh" ]; then
            echo "Kept $FEDORA_REF@$fresh as \`$kept\`" >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
        else
            echo "::warning::$kept is $digest, not the $fresh it was copied from: the jobs on the runtime miss its cache" >&2
        fi
    else
        echo "::warning::could not keep $FEDORA_REF@$fresh as $kept: the jobs on the runtime build it again until a run keeps one" >&2
    fi
}

# --- the runtime that an app's test runs on ---

# label LAYOUT KEY: prints the label KEY of the one image of the OCI image
# layout LAYOUT (docker-bake.hcl's outputs), or nothing.
label() {
    local manifest config
    manifest=$(jq -er 'if (.manifests | length) == 1 then .manifests[0].digest else empty end' "$1/index.json") &&
        config=$(jq -er '.config.digest' "$1/blobs/${manifest/://}") &&
        jq -r --arg k "$2" '.config.Labels[$k] // empty' "$1/blobs/${config/://}"
}

# whence: decides where the Flatpak of the runtime that an app's test runs
# on comes from. Sets how, at and why.
# - On main: the runtime that machines run the app on, so that an app built
#   against a newer library than machines have fails here, not on them.
#   That is this run's, by its digest (BASE_DIGEST), where this run pushed
#   it (BASE_PUSH, and BASE_RESULT its job's success). Else the published
#   one (:latest), where it is on the branch this commit names
#   (BASE_READY).
# - On a pull request that does not change that runtime (BASE_BUILD
#   false): the published one too, where it can be read and is on the
#   branch this commit names (try).
# - Anywhere else, it is made here of this run's image, and tested: on a
#   branch, on a pull request that changes it or that comes from a fork
#   (whose token reads no package), and on main where neither is there
#   (push then refuses the app).
whence() {
    how=make at='' why="not a run on main"
    if [ -z "$on_main" ]; then
        if [ "$EVENT" = pull_request ] && [ "${BASE_BUILD:-}" = false ]; then
            how=try at=latest why="the published one, which this pull request does not change"
        fi
        return
    elif [ "${BASE_PUSH:-}" = true ]; then
        if [ "${BASE_RESULT:-}" = success ] && [[ ${BASE_DIGEST:-} =~ ^sha256:[0-9a-f]{64}$ ]]; then
            how=fetch at=$BASE_DIGEST why="this run's, which its job pushed"
        else
            why="its job, which was to push it, ended ${BASE_RESULT:-unknown}"
        fi
    elif [ "${BASE_READY:-}" = true ]; then
        how=fetch at=latest why="the published one, which machines have"
    else
        why="none is published on the branch this commit names"
    fi
}

# fetch RUNTIME APP AT [try]: writes output/flatpaks/RUNTIME, the Flatpak
# that APP's test runs on, as its repository has it at AT (a digest, or
# latest). The layout is as flatpak.sh build writes one: its index.json
# names its ref. It must be the runtime that APP's image names
# (flatpak.runtime), on that branch. With try, a runtime that cannot be
# read, or is not that one, gives a notice and 1 where it would fail the
# job. Needs skopeo, and GH_TOKEN (packages read), which it logs in with for
# its own calls alone.
fetch() {
    local dir=output/flatpaks/$1 app=$2 at=$3 try=${4:-}
    local want id ref repo src auth info digest got
    : "${GITHUB_ACTOR:?}" "${GH_TOKEN:?}"
    want=$(label "output/images/$app" flatpak.runtime) || want=''
    [[ $want == ?*//?* ]] || fail "output/images/$app names no runtime (flatpak.runtime ${want:-unset})"
    id=${want%%//*}
    ref=runtime/$id/$(uname -m)/${want#*//}
    repo=ghcr.io/$owner/${id,,}
    if [ "$at" = latest ]; then src=$repo:latest; else src=$repo@$at; fi
    auth=$(printf '%s:%s' "$GITHUB_ACTOR" "$GH_TOKEN" | base64 -w0)
    printf '{"auths": {"ghcr.io": {"auth": "%s"}}}\n' "$auth" >"$work/auth.json"

    # A try reads once: a fork's token reads nothing, and no wait changes
    # that.
    if [ -z "$try" ]; then
        info=$(REGISTRY_AUTH_FILE=$work/auth.json tries "read $src" skopeo inspect --retry-times 3 "docker://$src")
    elif ! info=$(REGISTRY_AUTH_FILE=$work/auth.json skopeo inspect --retry-times 3 "docker://$src"); then
        echo "::notice::could not read $src: $app is tested on one made here" >&2
        return 1
    fi
    digest=$(jq -r '.Digest // empty' <<<"$info")
    got=$(jq -r '.Labels["org.flatpak.ref"] // empty' <<<"$info")
    [[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || fail "$src has no digest"
    [ "$at" = latest ] || [ "$digest" = "$at" ] || fail "$src answered with $digest"
    if [ "$got" != "$ref" ] && [ -n "$try" ]; then
        echo "::notice::$src holds ${got:-no Flatpak}, not $ref: $app is tested on one made here" >&2
        return 1
    elif [ "$got" != "$ref" ]; then
        fail "$src holds ${got:-no Flatpak}, not $ref, which $app runs on: it is not tested on what machines have"
    fi

    rm -rf "$dir" "$dir.fetched"
    # A fresh checkout has no output/flatpaks/ yet, and skopeo creates only
    # the last directory of an oci: path.
    mkdir -p "$(dirname "$dir")" || return 1
    # Where try's caller tests it, a failing command does not stop the
    # script: each step is checked.
    REGISTRY_AUTH_FILE=$work/auth.json tries "fetch $repo@$digest" \
        skopeo copy --retry-times 3 "docker://$repo@$digest" "oci:$dir.fetched:$ref" || return 1
    mv "$dir.fetched" "$dir" || return 1
    echo "Tested on \`$repo@$digest\` ($ref), $why" >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
}

# --- build ---

# build_runtime: the runtime's job. One bake makes the builder, the runtime
# and its test, and writes the builder's cache and the runtime's. The image
# of the day it was built on is kept for the jobs after it (keep).
build_runtime() {
    bake builder,runtime builder runtime runtime-test
    if [ -n "$wrote" ] && [ -n "$fresh" ]; then keep; fi
    again flatpak runtime
}

# build_sdk: the SDK's job: the SDK on the runtime of the cache.
build_sdk() {
    bake_base runtime
    bake sdk builder sdk sdk-test
    again flatpak sdk
}

# build_app NAME ON: an app's job: NAME on the runtime ON (bake_base), its
# test on the runtime that whence picks. That one is fetched, or made here
# of this run's image and tested, also where a try fails.
build_app() {
    local name=$1 on=$2
    # A bake target's name has _ for each dot.
    local target=${name//./_}
    bake_base runtime
    [ "$on" = runtime ] || bake_base sdk
    bake "$name,$name-test" builder "$target" "$target-test"
    whence
    if [ "$how" = fetch ]; then
        fetch "$on" "$name" "$at"
    elif [ "$how" != try ] || ! fetch "$on" "$name" "$at" try; then
        [ "$how" != try ] || why="the published one could not be read, or is not on this commit's branch"
        echo "Tested on $on, made here of this run's image: $why" >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
        again flatpak "$on"
    fi
    again flatpak "$name"
}

# build NAME: builds and tests NAME (build.sh names lists it) into
# output/flatpaks/NAME, as `build.sh flatpak NAME` does:
# 1. The runtime it is built on first (bake_base), and for an app on the
#    SDK, the SDK on it.
# 2. Its images and its test's (bake), writing the job's own cache. The
#    runtime's job writes the builder's too.
# 3. For an app, the Flatpak of the runtime its test runs on (build_app).
# 4. NAME made and tested (build.sh flatpak), of what the bakes left in the
#    builder.
# The runtime and the SDK are tested on themselves.
build() {
    local name=$1 line on
    : "${EVENT:?}" "${GITHUB_REPOSITORY_OWNER:?}"
    line=$(awk -v n="$name" '$1 == n' < <("$here/build.sh" names))
    if [ -z "$line" ]; then
        echo "::error::no Flatpak $name (build.sh names lists them)" >&2
        exit 2
    fi
    read -r _ _ on <<<"$line"
    if [ "$name" = runtime ]; then fedora writer; else fedora; fi
    case $name in
    runtime) build_runtime ;;
    sdk) build_sdk ;;
    *) build_app "$name" "$on" ;;
    esac
}

# --- devcontainer ---

# devcontainer: bakes the dev container's two images (docker-bake.hcl's
# devcontainer group) as OCI image layouts: plain's
# output/images/devcontainer and ai's devcontainer-ai, which push copies
# byte for byte. Then it loads them into rootless podman's storage as LOCAL
# and LOCAL_AI, which the test and the scan run. Both are in one bake, as
# ai is plain with a few layers on top: on the same base, and fresh or not,
# of the same plain.
devcontainer() {
    : "${EVENT:?}" "${GITHUB_REPOSITORY_OWNER:?}" "${LOCAL:?}" "${LOCAL_AI:?}"
    bake devcontainer-plain,devcontainer-ai \
        --set devcontainer-plain.output=type=oci,dest=output/images/devcontainer,tar=false \
        --set devcontainer-ai.output=type=oci,dest=output/images/devcontainer-ai,tar=false \
        devcontainer
    skopeo copy --quiet oci:output/images/devcontainer "containers-storage:$LOCAL"
    skopeo copy --quiet oci:output/images/devcontainer-ai "containers-storage:$LOCAL_AI"
}

# --- main ---

main() {
    if [ "${EVENT:-}" != pull_request ] && [ "${GITHUB_REF:-}" = refs/heads/main ]; then
        on_main=1
    fi
    owner=${GITHUB_REPOSITORY_OWNER:-}
    owner=${owner,,}
    cache=ghcr.io/$owner/packages-cache
    # docker-bake.hcl's CACHE: a tag of the cache's package for each target.
    export CACHE="type=registry,ref=$cache:%s"
    work=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/ci.XXXXXX")
    trap 'rm -rf "$work"' EXIT
    case ${1:-} in
    plan) plan ;;
    build) build "${2:?usage: ci.sh build NAME}" ;;
    push) push "${2:?usage: ci.sh push NAME}" ;;
    devcontainer) devcontainer ;;
    *)
        echo "usage: ci.sh plan | build NAME | push NAME | devcontainer" >&2
        exit 2
        ;;
    esac
}

main "$@"
