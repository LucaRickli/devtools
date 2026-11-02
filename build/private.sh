#!/usr/bin/env bash
#
# Fails unless each image refuses an anonymous pull, that is, unless its
# package on ghcr.io is private. Run it before the first push to a package
# (ci.sh push, devcontainer.yml).
#
#   private.sh IMAGE...     each IMAGE is ghcr.io/<owner>/<name>, no tag
#
# Every image of this repository is the owner's alone. The VS Code
# Flatpak's images carry Microsoft's VS Code, and in `ai` Anthropic's
# Claude Code, which are not ours to hand out. So a package that someone
# made public, or that was public before, gets nothing until it is private
# again (its settings, Danger Zone, Change visibility).
#
# How ghcr.io tells:
# - It hands out an anonymous pull token only for a public package. It
#   answers 401 for a private one, and 403 where there is none yet. The
#   first push then creates that package private.
# - With a token, the tags list answering 200 settles it: public.
#
# Each image gets three tries, 30 seconds apart. One that cannot be told
# fails, as a push that might go public must not go ahead.
set -euo pipefail

# --- state ---

# Where ghcr.io's answers go (a temporary file, removed on exit).
answer=''
# What ask_ghcr found: private, public, or empty where it could not tell.
state=''
# The HTTP status of ghcr.io's last answer (000 where curl failed).
code=''

# --- helpers ---

# ask_ghcr REPO: asks ghcr.io once whether REPO (<owner>/<name>) is public.
# Sets state and code.
ask_ghcr() {
    local repo=$1 token
    state=''
    code=$(curl -sS -o "$answer" -w '%{http_code}' "https://ghcr.io/token?scope=repository:$repo:pull") || code=000
    case $code in
    401 | 403)
        state=private
        ;;
    200)
        # A token: try it on the tags list. No token in the answer settles
        # nothing.
        token=$(jq -r '.token // empty' "$answer" 2>/dev/null) || token=''
        if [ -n "$token" ]; then
            code=$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $token" \
                "https://ghcr.io/v2/$repo/tags/list?n=1") || code=000
            case $code in
            200) state=public ;;
            401 | 403 | 404) state=private ;;
            esac
        fi
        ;;
    esac
}

# check_private IMAGE: says that IMAGE is not public, or fails.
check_private() {
    local image=$1 repo attempt
    if ! [[ $image =~ ^ghcr\.io/([a-z0-9][a-z0-9._/-]*)$ ]]; then
        echo "::error::not a ghcr.io image without a tag: $image" >&2
        exit 2
    fi
    repo=${BASH_REMATCH[1]}
    for attempt in 1 2 3; do
        ask_ghcr "$repo"
        if [ -n "$state" ]; then
            break
        fi
        if [ "$attempt" != 3 ]; then
            echo "could not tell whether $image is public (ghcr.io answered $code, attempt $attempt), retrying in 30s" >&2
            sleep 30
        fi
    done
    case $state in
    private)
        echo "$image: not public"
        ;;
    public)
        echo "::error::$image is public, and its images are the owner's alone: make it private (its package settings, Danger Zone, Change visibility) before anything is pushed to it" >&2
        exit 1
        ;;
    *)
        echo "::error::could not tell whether $image is public (ghcr.io answered $code): nothing pushed" >&2
        exit 1
        ;;
    esac
}

# --- main ---

main() {
    local image
    answer=$(mktemp)
    trap 'rm -f "$answer"' EXIT
    if [ "$#" = 0 ]; then
        echo "usage: private.sh IMAGE..." >&2
        exit 2
    fi
    # One image after another: each is checked before the next is looked at.
    for image; do
        check_private "$image"
    done
}

main "$@"
