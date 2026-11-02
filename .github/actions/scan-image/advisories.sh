#!/usr/bin/env bash
#
# Lists the Fedora security updates that a local image lacks, and says which
# of them count against it. scan.sh runs it as part of the scan before a
# push.
#
#   advisories.sh IMAGE           the push gate: one line per update,
#                                 ADVISORY SEVERITY PACKAGES WHY
#   advisories.sh --due IMAGE     for a published image: the updates that a
#                                 build started now would get, one per line,
#                                 ADVISORY SEVERITY PACKAGES
#   advisories.sh [--due] --rule  the rule in words, for summaries
#   JSON=FILE advisories.sh ...   also writes dnf's full list (every
#                                 severity) to FILE, for scan.sh's summary
#                                 and sarif.jq
#
# dnf inside the image says what the image lacks. It asks Fedora's updates
# repository as it is now, which carries an update from the day it goes
# stable. The lines are the lacking updates of a gated severity (GATE,
# below), and the push gate adds those that REQUIRE makes count. PACKAGES
# are an update's packages, separated by commas.
#
# The push gate needs no clock. Every build applies Fedora's updates. Then,
# from the same dnf metadata, it records every security advisory for the
# packages it installed ($record below, which the Containerfile writes). WHY
# says how an update stands against that record:
#   seen        The record has it. So the build's dnf knew it, and still the
#               image lacks it: dnf could not install it, or a later step
#               replaced the package. It counts.
#   newer       The record does not have it. It reached Fedora's mirrors
#               after the build read them, and the next build has it. It
#               does not count.
#   unrecorded  The image has no record. Nothing says it could not have had
#               the update, so it counts.
#   required    REQUIRE makes it count (below).
#
# REQUIRE is the `security` input of a rebuild that was started for given
# updates: ADVISORY SEVERITY PACKAGES, one per line or separated by ";". An
# update it lists is "required" when the image has one of its packages, and
# either lacks the update or its build did not record it. So the rebuild
# contains the updates it was started for, or it fails.
#
# --due has no record to go by, because a published image was built days
# ago. So it asks Bodhi when each lacking update went stable. It counts an
# update that has been stable for 12 hours (SLACK_HOURS). That is the time
# an update takes to reach the mirrors a build reads. dnf's `buildtime` is
# no such time. On an update's first stable day, it still holds when the
# update went to testing. A mirror slower than that makes a rebuild for the
# update fail on REQUIRE.
#
# Exits 0 whether or not anything counts. Exits 1 when dnf or Bodhi could
# not answer, or when REQUIRE is malformed.
set -euo pipefail

# --- settings ---

# GATE is the one place to tune how much a missing Fedora update weighs. It
# is one severity, or several separated by spaces. The default is Critical.
# About one Critical advisory a month touches the image, and an Important
# one several a week.
gate=${GATE:-Critical}
# How many hours after it went stable --due counts an update.
slack=${SLACK_HOURS:-12}
# Where every build writes its record. It is dnf's JSON of every security
# advisory in the updates repository for the packages installed then.
record=/usr/share/fedora-bootc/advisories-at-build.json

# --- arguments ---

due=
if [ "${1:-}" = --due ]; then due=1; shift; fi
if [ "${1:-}" = --rule ]; then
    if [ -n "$due" ]; then
        echo "$gate, stable in Bodhi for ${slack} h"
    else
        echo "$gate, known to the build's dnf"
    fi
    exit 0
fi
image=${1:?usage: advisories.sh [--due] <local image> | [--due] --rule}
work=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/var/tmp}}/advisories.XXXXXX")
trap 'rm -rf "$work"' EXIT
json=${JSON:-$work/dnf.json}
podman image exists "$image" || { echo "no local image $image" >&2; exit 1; }

# --- helpers ---

# retry WHAT COMMAND...: runs COMMAND up to three times, 30 s apart, like
# every other download in these scripts. WHAT names it in the messages.
retry() {
    local what=$1 attempt
    shift
    for attempt in 1 2 3; do
        "$@" && return 0
        [ "$attempt" = 3 ] || { echo "$what failed (attempt $attempt), retrying in 30s" >&2; sleep 30; }
    done
    echo "could not read $what" >&2
    return 1
}

# --- what the image lacks ---

# lacking: writes dnf's list of the security updates that the image lacks to
# $json. It has one row per advisory and package that the image has an
# older version of. dnf asks the updates repository only. That one carries
# Fedora's advisories, and a third-party repository that is down must not
# fail the check.
lacking() {
    podman run --rm --pull=never --entrypoint /usr/bin/dnf "$image" \
        -q advisory list --security --repo=updates --json > "$json"
}
retry "Fedora's advisories for $image" lacking || exit 1
# gated.txt: one line per lacking advisory of a gated severity, ADVISORY
# SEVERITY PACKAGES.
jq -r --arg gate "$gate" '
    ($gate | split(" ") | map(select(length > 0))) as $gated
    | map(select(.type == "security" and (.severity | IN($gated[]))))
    | group_by(.name)[]
    | "\(.[0].name) \(.[0].severity) \(map(.nevra) | join(","))"' "$json" > "$work/gated.txt"

# --- --due: a published image ---

if [ -n "$due" ]; then
    # stable: writes Bodhi's date_stable of an update to $work/stable, in
    # UTC as "YYYY-MM-DD HH:MM:SS". It takes the update's ID from $id, which
    # the loop below sets.
    # shellcheck disable=SC2329  # called through retry
    stable() {
        curl -fsS --max-time 60 "https://bodhi.fedoraproject.org/updates/${id}" \
            | jq -er '.update.date_stable' > "$work/stable"
    }
    now=$(date -u +%s)
    while read -r id severity packages; do
        retry "Bodhi's stable date of $id" stable || exit 1
        since=$(date -u -d "$(cat "$work/stable") UTC" +%s)
        if [ "$((now - since))" -ge "$((slack * 3600))" ]; then
            echo "$id $severity $packages"
        else
            echo "$id: stable since $(cat "$work/stable") UTC, due ${slack} h after that" >&2
        fi
    done < "$work/gated.txt"
    exit 0
fi

# --- the push gate: the build's record ---

# The record, or the word "none" when the image has none. known.json then
# says whether there is a record, and which advisories it has.
podman run --rm --pull=never --network=none --entrypoint /usr/bin/bash "$image" \
    -c '[ -e "$1" ] || { echo none; exit 0; }; cat "$1"' _ "$record" > "$work/record"
if [ "$(cat "$work/record")" = none ]; then
    echo '{"recorded": false, "names": []}' > "$work/known.json"
else
    jq '{recorded: true, names: (map(.name) | unique)}' "$work/record" > "$work/known.json"
fi

# --- the push gate: REQUIRE ---

# REQUIRE comes from a workflow's input, so each of its lines is checked
# before any of it reaches a command. A line is one update, its first three
# words.
tr ';' '\n' <<<"${REQUIRE:-}" | awk 'NF { print $1, $2, $3 }' > "$work/require.txt"
while read -r id severity packages; do
    [[ $id =~ ^FEDORA-[0-9]{4}-[0-9a-f]+$ && $severity =~ ^[A-Za-z]+$ &&
       $packages =~ ^[A-Za-z0-9._+~^:-]+(,[A-Za-z0-9._+~^:-]+)*$ ]] ||
        { echo "REQUIRE is not ADVISORY SEVERITY PACKAGES: $id $severity $packages" >&2; exit 1; }
done < "$work/require.txt"
# installed.txt: rpm's answer for each name of REQUIRE's packages. A name
# that the image has comes back as itself.
: > "$work/installed.txt"
if [ -s "$work/require.txt" ]; then
    # Each package's name, from its name-[epoch:]version-release.arch.
    names=$(cut -d' ' -f3 "$work/require.txt" | tr ',' '\n' \
        | sed -E 's/\.[^.]+$//; s/-[^-]+-[^-]+$//' | sort -u)
    # rpm exits non-zero for a name that is not installed. That is an answer
    # here, not an error.
    # shellcheck disable=SC2086  # one argument per name, on purpose
    podman run --rm --pull=never --network=none --entrypoint /usr/bin/rpm "$image" \
        -q --qf '%{NAME}\n' $names > "$work/installed.txt" || true
fi

# --- the push gate: the verdict ---

# One line per update, with the first reason that applies. The reasons that
# count come first, so an update that is both "required" and "newer" is
# "required".
jq -rn --rawfile gated "$work/gated.txt" --rawfile require "$work/require.txt" \
    --rawfile installed "$work/installed.txt" --slurpfile known "$work/known.json" \
    --slurpfile dnf "$json" '
    def lines: split("\n") | map(select(length > 0) | split(" "));
    def name: sub("\\.[^.]+$"; "") | sub("-[^-]+-[^-]+$"; "");
    $known[0] as $k
    | ($installed | split("\n") | map(select(length > 0))) as $have
    | ($dnf[0] | map(.name) | unique) as $lacking
    | ($gated | lines
       | map(. + [if $k.recorded | not then "unrecorded"
                  elif .[0] | IN($k.names[]) then "seen"
                  else "newer" end])) as $gated
    | [ ($gated[] | select(.[3] != "newer")),
        ($require | lines[]
         | select(.[2] | split(",") | any(name | IN($have[])))
         | select((.[0] | IN($lacking[])) or (.[0] | IN($k.names[]) | not))
         | . + ["required"]),
        ($gated[] | select(.[3] == "newer")) ]
    | unique_by(.[0])[] | join(" ")'
