# The dev container, and the runtime and the SDK with their apps (the VS
# Code Flatpak on the SDK), built and tested the way CI does
# (.github/workflows/devcontainer.yml, flatpaks.yml): every image with
# docker buildx bake (build/docker-bake.hcl), the rest in build/build.sh.

default:
    @just --list

# Build the dev container: localhost/devcontainer:latest and :ai
devcontainer:
    build/build.sh devcontainer

# List the Flatpaks: NAME DIR ON
flatpak-names:
    build/build.sh names

# Build and test one Flatpak into output/flatpaks/: runtime, sdk, an app's ID or <ID>-<variant>
flatpak name:
    build/build.sh flatpak {{ quote(name) }}

# Build and test the runtime, the SDK and the apps into output/flatpaks/
flatpaks:
    build/build.sh flatpaks

# Install the local runtime and apps build for your user (one app, or all)
flatpaks-install app="":
    build/build.sh install {{ quote(app) }}

# CI's lint job runs this one as it is (needs only bash).
#
# Check every shell script's syntax, and that every app has a README.md
check:
    # one at a time: `bash -n a.sh b.sh` parses only a.sh (b.sh becomes $1)
    for f in build/*.sh tools/*.sh .github/actions/*/*.sh devcontainer/claude devcontainer/host-command; do bash -n "$f" || exit 1; done
    # the runtime's and the apps' scripts, POSIX sh (sh -n) or bash, as their first line says
    for f in runtime/test.sh runtime/sdk/test.sh apps/*/test.sh apps/org.mozilla.firefox/files/bin/firefox apps/org.mozilla.firefox/files/libexec/firefox-prestart apps/io.github.lucarickli.Code/files/bin/* apps/io.github.lucarickli.Code/files/libexec/* apps/io.github.lucarickli.Code/files-ai/bin/*; do case "$(head -n 1 "$f")" in '#!/bin/sh'*) sh -n "$f" ;; *) bash -n "$f" ;; esac || exit 1; done
    # every app (a directory of apps/ with a Containerfile) has its README.md: what it is, how to install it
    for d in apps/*/; do if [ -f "${d}Containerfile" ] && [ ! -f "${d}README.md" ]; then echo "check: ${d}README.md is missing" >&2; exit 1; fi; done

# CI runs it on every pull request that changes a pin, and every Monday
# (ci.yml, `pins`).
# Needs cosign, gh (logged in, or GH_TOKEN), gpg, minisign and
# slsa-verifier.
#
# Check every pin against what upstream signs or attests for it
verify-pins:
    tools/verify-pins.sh

# Remove build outputs
clean:
    rm -rf output
