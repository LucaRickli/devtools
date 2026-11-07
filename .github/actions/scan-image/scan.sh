#!/usr/bin/env bash
#
# Scans a locally built image just before it is pushed, and fails on what
# must not be published. action.yml runs it from the root of the checkout,
# and it runs the same way locally:
#
#   UPSTREAM="usr/local/ var/home/dev/.vscode-server/" \
#       .github/actions/scan-image/scan.sh localhost/devcontainer:latest
#
# It fails on:
#   - a secret anywhere in the image (trivy's rules plus trivy-secret.yaml)
#   - a package or binary that a vulnerability database marks as malicious
#     (CWE-506, embedded malicious code). That is a compromised release, and
#     it fails wherever it is, fixed or not.
#   - a CRITICAL vulnerability with a fixed version, in a file the image adds
#     itself (see "who put each flagged file there" below)
#   - a Critical Fedora security update that the image lacks, although its
#     build's own dnf knew it. dnf could not install it, or a later step
#     replaced it. advisories.sh has the rule, and why.
#   - in a rebuild started for given updates (REQUIRE), an update it was
#     started for and does not contain
# A pull request pushes nothing, so there the Fedora updates only warn. An
# update that reached Fedora's mirrors after the build read them only warns
# too: the next build has it. Everything else goes into the step summary,
# and all of trivy's findings into the log.
#
# It reads from the environment, all optional:
#   TRIVY         the trivy binary, when it is not on PATH. tools/install.sh
#                 PREFIX trivy fetches the pinned one.
#   UPSTREAM      the path prefixes of upstream releases, separated by spaces
#                 or newlines, with no leading slash
#   SECRETS_ONLY  1 to scan for secrets alone. That is for an image that is
#                 a Flatpak's /app and nothing else (the VS Code Flatpak's).
#                 It holds upstream's releases, with no rpm database or dnf
#                 to ask, so all its vulnerabilities are upstream's to fix.
#   REQUIRE       the updates a rebuild was started for, from its `security`
#                 input (advisories.sh)
#   EVENT         the GitHub event of the run, such as pull_request
# It writes the files that the environment names, for action.yml:
#   SARIF         the findings that need action, as a code scanning report
#                 (sarif.jq)
#   RESULT        the verdict, "pass" or "fail". It is written only when the
#                 scan completed.
#
# Needs rootless podman and jq. trivy itself only ever runs in containers
# (see below).
# shellcheck disable=SC2016  # jq and awk programs, single-quoted on purpose
set -euo pipefail

# --- setup ---

image=${1:?usage: scan.sh <local image>}
here=$(cd "$(dirname "$0")" && pwd)
trivy=$(command -v "${TRIVY:-trivy}") || { echo "no trivy (PATH or \$TRIVY)" >&2; exit 1; }
summary=${GITHUB_STEP_SUMMARY:-/dev/stdout}
work=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/var/tmp}}/scan.XXXXXX")
trap 'rm -rf "$work"' EXIT
podman image exists "$image" || { echo "no local image $image" >&2; exit 1; }

# --- trivy: secrets and vulnerabilities ---

# trivy is a third-party binary, so it never runs on the host. There it would
# sit next to the job's secrets and tokens. A process on a GitHub runner can
# read every secret the job holds out of the runner's memory, and the runner
# has passwordless sudo.
#
# So each run of trivy is a rootless container of Fedora's minimal image.
# Only trivy, its database and this script's work directory are mounted in.
# The container has no secret and no token, and the scan itself has no
# network. A bad trivy release can then at most lie about one scan. The
# database download comes first, in a container of its own. That is the one
# run of trivy with network, and it is retried like the dnf metadata
# (advisories.sh).
#
# Only this script and trivy-secret.yaml configure trivy. trivy also reads
# TRIVY_* variables, and a trivy.yaml or .trivyignore in its working
# directory. Any of them could quietly drop findings. So the container gets
# none of the host's environment, and its working directory is the work
# directory, which holds only this script's own files.
test -s "$here/trivy-secret.yaml" || { echo "missing $here/trivy-secret.yaml" >&2; exit 1; }
# Renovate's Fedora PR moves this release with the others.
scanner=registry.fedoraproject.org/fedora-minimal:45
# Every run of trivy shares this cache, which holds its database.
mkdir -p "$work/cache"
# in_scanner runs trivy in a container of the scanner's image. Only the
# loop below pulls that image, with retries, so every run has --pull=never.
# label=disable lets the container read its mounts on an SELinux host.
in_scanner() {   # in_scanner [podman run options] -- trivy arguments
    local opts=()
    while [ "$1" != -- ]; do opts+=("$1"); shift; done
    shift
    podman run --rm --pull=never --security-opt label=disable \
        -v "$trivy":/trivy:ro -v "$work/cache":/cache -v "$work":/work -w /work \
        "${opts[@]}" "$scanner" /trivy --cache-dir /cache "$@"
}
# What trivy looks for. SECRETS_ONLY=1 is for an image of upstream's
# releases alone (see the top).
secrets_only=${SECRETS_ONLY:-}
scanners=vuln,secret
[ "$secrets_only" = 1 ] && scanners=secret
# The scanner's image and trivy's database, in three tries 30 s apart. The
# secret scan needs no database, only the image.
for attempt in 1 2 3; do
    podman pull --quiet "$scanner" >/dev/null &&
        { [ "$secrets_only" = 1 ] || in_scanner -- image --download-db-only --quiet; } && break
    [ "$attempt" = 3 ] && { echo "could not download the trivy DB" >&2; exit 1; }
    echo "trivy DB download failed (attempt $attempt), retrying in 30s" >&2
    sleep 30
done
# trivy's version, for the log.
in_scanner --network=none -- --version
# The scan. trivy reads the image's filesystem, mounted read-only, rather
# than an archive of its layers. From an archive, trivy reads only one path
# of a hardlinked file. It also skips the secret scan in layers whose
# history makes them look like a base image. A mounted tree has neither
# problem. The memory cache keeps an earlier run's result from being
# reused. The default timeout (5m) is too short for a 12 GB image.
in_scanner --network=none --mount type=image,src="$image",dst=/scan \
    -v "$here/trivy-secret.yaml":/trivy-secret.yaml:ro -- \
    rootfs --skip-db-update --cache-backend memory --quiet --timeout 60m \
    --scanners "$scanners" --secret-config /trivy-secret.yaml \
    --format json --output /work/trivy.json /scan
# All of trivy's findings, as a table, for the log.
in_scanner --network=none -- convert --format table /work/trivy.json

# --- the findings, one row each ---

# vulns.tsv has one row per vulnerability: path, id, severity, status,
# package, installed version, fixed version, and "malicious" when the
# advisory is one of embedded malicious code (CWE-506). secrets.tsv has one
# row per secret: path, rule, severity, title, line. Paths have no leading
# slash, the way trivy reports an image's paths.
jq -r '.Results[]? | .Target as $t | .Vulnerabilities[]?
       | [((.PkgPath // $t) | ltrimstr("/")), .VulnerabilityID, .Severity, .Status,
          .PkgName, .InstalledVersion, (.FixedVersion // ""),
          (if (.CweIDs // []) | any(. == "CWE-506") then "malicious" else "" end)] | @tsv' \
    "$work/trivy.json" > "$work/vulns.tsv"
jq -r '.Results[]? | .Target as $t | .Secrets[]?
       | [($t | ltrimstr("/")), .RuleID, .Severity, .Title, (.StartLine | tostring)] | @tsv' \
    "$work/trivy.json" > "$work/secrets.tsv"

# --- who put each flagged file there ---

# Each vulnerability gets a class, which decides whether it can fail the
# push:
#   rpm       A file that an RPM installed. Only known-malicious code fails
#             here. Fedora's own advisories judge the rest (the dnf section
#             below), because trivy has no Fedora vulnerability data
#             ("Unsupported os"). In a Fedora binary, trivy can only read the
#             Go or Python dependency versions compiled into it. Fedora ships
#             fixes as patches, which leave those versions unchanged. So
#             trivy's findings there are neither complete (it sees nothing in
#             C code, sshd or the kernel) nor reliable.
#   upstream  Any other file under one of the $UPSTREAM prefixes, such as
#             the dev container's tools and VS Code extensions. Each is
#             someone else's build, kept current by Renovate, by hand or by
#             its remote. Its vulnerabilities are for upstream to fix.
#             Failing on them would only hold back every other update until
#             upstream ships. Known-malicious code still fails: a release
#             found to be compromised must leave the image, whoever built it.
#   image     Any other file: one the image adds itself.
#
# An unsealed image carries its base's ostree repository (/sysroot/ostree).
# Its objects duplicate files that are also in the image under their real
# paths, so they are dropped. The image's own rpm database is asked about
# the rest.
# shellcheck disable=SC2086  # split into one prefix per line on purpose
printf '%s\n' ${UPSTREAM:-} > "$work/upstream.txt"
# grep fails when it keeps no line, as for an image without findings.
cut -f1 "$work/vulns.tsv" | grep -v '^sysroot/ostree/' | sort -u > "$work/paths.txt" || true
# owners.tsv: each flagged path and the RPM that owns it, or "-". A file
# that several RPMs own gets the first. rpm is asked only when trivy flagged
# a file, because an image of a Flatpak's /app alone (SECRETS_ONLY) has no
# bash or rpm to ask.
: > "$work/owners.tsv"
[ ! -s "$work/paths.txt" ] ||
podman run --rm -i --pull=never --network=none --entrypoint /usr/bin/bash "$image" -c '
    while IFS= read -r p; do
        if owner=$(rpm -qf --qf "%{NAME}\n" -- "/$p" 2>/dev/null); then
            printf "%s\t%s\n" "$p" "${owner%%[[:space:]]*}"
        else
            printf "%s\t-\n" "$p"
        fi
    done' < "$work/paths.txt" > "$work/owners.tsv"
# classified.tsv: each row of vulns.tsv, with its class as a new first
# column. An empty UPSTREAM leaves an empty line in upstream.txt, which is
# no prefix.
awk -F'\t' -v OFS='\t' '
    FILENAME == ARGV[1] { if ($1 != "") prefix[$1] = 1; next }
    FILENAME == ARGV[2] { owner[$1] = $2; next }
    $1 ~ /^sysroot\/ostree\// { next }
    {
        class = "image"
        if (owner[$1] != "" && owner[$1] != "-") class = "rpm"
        else for (p in prefix) if (index($1, p) == 1) class = "upstream"
        print class, $0
    }
' "$work/upstream.txt" "$work/owners.tsv" "$work/vulns.tsv" > "$work/classified.tsv"

# --- dnf: Fedora security updates the image lacks ---

# advisories.sh asks dnf inside the image, and applies the push gate's rule.
# gated.txt gets its lines, one per missing update with its reason (WHY).
# advisories.json gets dnf's full list, for the summary and the alerts. An
# image of SECRETS_ONLY has no dnf to ask.
rule=$("$here/advisories.sh" --rule)
if [ "$secrets_only" = 1 ]; then
    echo '[]' > "$work/advisories.json"
    : > "$work/gated.txt"
else
    JSON="$work/advisories.json" "$here/advisories.sh" "$image" > "$work/gated.txt"
fi

# --- the verdict ---

# count PATTERN FILE: prints how many rows of FILE match the awk PATTERN.
count() { awk -F'\t' "$1" "$2" | wc -l; }
n_secrets=$(wc -l < "$work/secrets.tsv")
n_malicious=$(count '$9 == "malicious"' "$work/classified.tsv")
n_image_crit=$(count '$1 == "image" && $4 == "CRITICAL" && $5 == "fixed"' "$work/classified.tsv")
n_image_high=$(count '$1 == "image" && $4 == "HIGH"' "$work/classified.tsv")
n_rpm=$(count '$1 == "rpm"' "$work/classified.tsv")
n_upstream=$(count '$1 == "upstream"' "$work/classified.tsv")
# fedora SEVERITY: prints how many security advisories of SEVERITY dnf lists
# for the image.
fedora() { jq -r --arg s "$1" '[.[] | select(.type == "security" and .severity == $s) | .name] | unique | length' "$work/advisories.json"; }
n_fedora_crit=$(fedora Critical)
n_fedora_imp=$(fedora Important)
# What fails the push, one message each.
failures=()
[ "$n_secrets" = 0 ] || failures+=("$n_secrets secret(s) in the image")
[ "$n_malicious" = 0 ] || failures+=("$n_malicious file(s) from a release known to carry malicious code (CWE-506)")
[ "$n_image_crit" = 0 ] || failures+=("$n_image_crit critical vulnerabilities with a fix in files the image adds itself")
# ids WHY: prints the missing updates that advisories.sh gives the reason
# WHY, separated by commas.
ids() { awk -v why="$1" '$4 == why { print $1 }' "$work/gated.txt" | paste -sd,; }
fedora_failures=()
[ -z "$(ids seen)" ] || fedora_failures+=("Fedora security update(s) the build's own dnf knew and the image lacks: $(ids seen). dnf could not install them, or a later step replaced them: the build log says which")
[ -z "$(ids unrecorded)" ] || fedora_failures+=("Fedora security update(s) ($rule) the image lacks: $(ids unrecorded). It has no record of what its build's dnf knew (/usr/share/fedora-bootc/advisories-at-build.json), so nothing says it could not have had them")
[ -z "$(ids required)" ] || fedora_failures+=("Fedora security update(s) this rebuild was started for and does not contain: $(ids required). Its build's dnf did not have them yet (a mirror behind) or could not install them (the build log says)")
# A pull request pushes nothing, so there these only warn.
for f in "${fedora_failures[@]}"; do
    if [ "${EVENT:-}" = pull_request ]; then
        echo "::warning::$f (fails a push)"
    else
        failures+=("$f")
    fi
done
# An update newer than the build only warns: the next build has it.
if [ -n "$(ids newer)" ]; then
    echo "::warning::Fedora security update(s) not in the image that reached Fedora's mirrors after its build read them: $(ids newer). The next build has them"
fi

# --- the step summary ---

# A table of the checks, then the details of anything found.
{
    echo "### Scan of \`$image\`"
    echo
    echo "| Check | Found | Fails the build |"
    echo "|---|---|---|"
    echo "| Secrets | $n_secrets | any |"
    if [ "$secrets_only" != 1 ]; then
        echo "| Known-malicious code (CWE-506), in any file | $n_malicious | any |"
        echo "| Vulnerabilities in files the image adds itself | $n_image_crit critical with a fix, $n_image_high high | critical with a fix |"
        echo "| Fedora security updates not in the image | $n_fedora_crit critical, $n_fedora_imp important | $rule, or one a rebuild was started for |"
        echo "| trivy on RPM binaries (Fedora's advisories are what counts) | $n_rpm | malicious only |"
        echo "| trivy on upstream releases (dev tools, extensions) | $n_upstream | malicious only |"
    fi
    if [ "$n_secrets" != 0 ]; then
        echo
        echo "**Secrets**"
        echo
        echo "| File | Rule | Severity | Line |"
        echo "|---|---|---|---|"
        awk -F'\t' '{ printf "| /%s | %s (%s) | %s | %s |\n", $1, $2, $4, $3, $5 }' "$work/secrets.tsv"
    fi
    if [ "$n_malicious" != 0 ]; then
        echo
        echo "**Known-malicious code**"
        echo
        echo "| File | Advisory | Package | Installed | Where |"
        echo "|---|---|---|---|---|"
        awk -F'\t' '$9 == "malicious" {
            printf "| /%s | %s | %s | %s | %s |\n", $2, $3, $6, $7, $1 }' "$work/classified.tsv"
    fi
    if [ "$n_image_crit" != 0 ]; then
        echo
        echo "**Critical, with a fix, in files the image adds itself**"
        echo
        echo "| File | Vulnerability | Package | Installed | Fixed |"
        echo "|---|---|---|---|---|"
        awk -F'\t' '$1 == "image" && $4 == "CRITICAL" && $5 == "fixed" {
            printf "| /%s | %s | %s | %s | %s |\n", $2, $3, $6, $7, $8 }' "$work/classified.tsv"
    fi
    if [ "$((n_fedora_crit + n_fedora_imp))" != 0 ] || [ -s "$work/gated.txt" ]; then
        echo
        echo "**Fedora security updates not in the image**"
        echo
        echo "| Advisory | Severity | Verdict | Packages |"
        echo "|---|---|---|---|"
        # One row per update: dnf's Critical and Important ones, and each
        # line of advisories.sh. An update that a rebuild was started for
        # can be missing from dnf's list, when the scan read a mirror as far
        # behind as the build's.
        jq -r --rawfile gated "$work/gated.txt" '
            ($gated | split("\n") | map(select(length > 0) | split(" ") | {(.[0]): .[3]}) | add // {}) as $why
            | {seen: "fails: its build knew it", unrecorded: "fails: no record of the build",
               required: "fails: the rebuild is for it", newer: "warns: newer than the build"} as $text
            | (map(select(.type == "security" and (.severity == "Critical" or .severity == "Important")))
               | group_by(.name) | map({name: .[0].name, severity: .[0].severity, packages: map(.nevra)}))
              + ($gated | split("\n") | map(select(length > 0) | split(" ")
                 | {name: .[0], severity: .[1], packages: (.[2] | split(","))}))
            | unique_by(.name)[]
            | "| \(.name) | \(.severity) | \($text[$why[.name] // ""] // "reported") | \(.packages | join(", ")) |"' "$work/advisories.json"
    fi
    echo
} >> "$summary"

# --- the code scanning report ---

if [ -n "${SARIF:-}" ]; then
    jq -n --rawfile secrets "$work/secrets.tsv" --rawfile vulns "$work/classified.tsv" \
        --slurpfile adv "$work/advisories.json" --rawfile gated "$work/gated.txt" --arg rule "$rule" \
        --arg repo "${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-lucarickli/packages}" \
        -f "$here/sarif.jq" > "$SARIF"
fi

# --- the result ---

# RESULT is written only here, at the end. A scan that stopped early leaves
# none, and action.yml then reports that the scan did not complete.
if [ "${#failures[@]}" != 0 ]; then
    for f in "${failures[@]}"; do echo "::error::$image: $f"; done
    if [ -n "${RESULT:-}" ]; then echo fail > "$RESULT"; fi
    exit 1
fi
if [ -n "${RESULT:-}" ]; then echo pass > "$RESULT"; fi
echo "$image: nothing that blocks a push"
