# The dev container and the VS Code Flatpak, built and tested the way CI
# does (.github/workflows/devcontainer.yml, flatpak.yml).

default:
    @just --list

# CI builds and pushes the same thing (.github/workflows/devcontainer.yml).
# The build context is the checkout, and .containerignore lets only the
# files the Containerfile copies into it.
#
# Build the dev container: localhost/devcontainer:latest
devcontainer:
    podman build --pull=newer -t localhost/devcontainer:latest .

# Runs flatpak/build.sh inside a Fedora container, which then installs the
# app and runs test.sh in it (VS Code itself is downloaded from Microsoft
# for that). Privileged for flatpak's own sandbox. Nothing touches your own
# Flatpak installations, and only the files it reads are mounted, read-only:
# the build runs downloaded code, which sees no .git and no file that git
# ignores. CI runs exactly this recipe (.github/workflows/flatpak.yml) and
# pushes output/flatpak/oci.
#
# Build and test the VS Code Flatpak into output/flatpak/
flatpak:
    mkdir -p output/flatpak
    podman run --rm --privileged --security-opt label=disable \
        -v "$(pwd)/flatpak":/src/flatpak:ro \
        -v "$(pwd)/install.sh":/src/install.sh:ro \
        -v "$(pwd)/tools.txt":/src/tools.txt:ro \
        -v "$(pwd)/extensions.txt":/src/extensions.txt:ro \
        -v "$(pwd)/mise-system.sh":/src/mise-system.sh:ro \
        -v "$(pwd)/mise-config.toml":/src/mise-config.toml:ro \
        -v "$(pwd)/claude-code.sh":/src/claude-code.sh:ro \
        -v "$(pwd)/claude-code.asc":/src/claude-code.asc:ro \
        -v "$(pwd)/test.sh":/src/test.sh:ro \
        -v "$(pwd)/.github/actions/scan-image":/src/.github/actions/scan-image:ro \
        -v "$(pwd)/output/flatpak":/out \
        quay.io/fedora/fedora:latest /src/flatpak/build.sh

# What `just flatpak` built, the same OCI image CI pushes, into your own user
# installation; VS Code itself is downloaded from Microsoft at install, as on
# any machine. Run it again after a new build to replace it. The runtime
# comes from Flathub, added as a user remote if it is not one yet. Remove
# with `flatpak uninstall --user io.github.lucarickli.Code`.
#
# Install the local VS Code Flatpak build for your user
flatpak-install:
    test -d output/flatpak/oci || { echo "Nothing built yet: run just flatpak first"; exit 1; }
    flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
    flatpak install --user -y --reinstall "oci:$(pwd)/output/flatpak/oci"

# CI's lint job runs this one as it is (needs only bash).
#
# Check every script's syntax
check:
    # one at a time: `bash -n a.sh b.sh` parses only a.sh (b.sh becomes $1)
    for f in *.sh flatpak/*.sh .github/actions/*/*.sh host-command claude flatpak/code flatpak/apply_extra flatpak/host-command flatpak/fish flatpak/bcvk flatpak/claude flatpak/claude-sandboxed; do bash -n "$f" || exit 1; done

# CI runs it on every pull request that changes a pin (ci.yml, `pins`).
# Needs cosign, gh (logged in, or GH_TOKEN), gpg, minisign and
# slsa-verifier.
#
# Check every pin against what upstream signs or attests for it
verify-pins:
    ./verify-pins.sh

# Remove build outputs
clean:
    rm -rf output
