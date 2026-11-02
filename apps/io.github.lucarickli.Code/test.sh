#!/usr/bin/env bash
#
# Tests the VS Code Flatpak (io.github.lucarickli.Code) from inside its
# sandbox, as installed: its permissions, extensions, window, sandbox and
# terminal, and in the ai variant Claude Code and claude-sandboxed.
#
#   code-test      (as build/flatpak.sh test runs it, with the network)
#
# The Containerfile's test and test-ai stages install this script as
# /app/bin/code-test in each variant, with tools/test.sh, tools.txt and
# extensions.txt in /app/lib/code-test. The variant is ai where
# /app/bin/claude exists, the same test the launcher makes.
#
# A second instance of the app, which the portal starts (flatpak-spawn),
# stands in for another `flatpak run`. With --no-network it is offline, like
# a machine without a connection, and it has a home of its own.
#
# What it checks, in order:
#   - The permissions and environment the sandbox has (/.flatpak-info), the
#     variant's files, and that every library VS Code links is found.
#   - A new profile's extensions and settings.
#   - VS Code's window: it starts without a display and loads the workbench.
#   - The sandbox: what of the host is in here, and what is not.
#   - The terminal: fish, the editor variables, tools/test.sh, mise, what
#     persists, and host commands refused.
#   - ai only: Claude Code, and claude-sandboxed's box.
#
# Not checked, because the test's sandbox cannot have what they need:
#   - The read-only grants, and what stays out of sight. The throwaway home
#     has no ~/.gitconfig, ~/.ssh or ~/.config/fish to show, and nothing to
#     hide.
#   - Host commands with the permission (flatpak run's --talk-name, or an
#     override).
#   - A server in the app, reached from outside.
#   - plain against ai, file for file and in the metadata. That takes both
#     variants, so it is outside any one test.
#
# Run it as `just flatpaks` does (build/build.sh):
#   - With TMPDIR outside /tmp and /var/tmp (see below).
#   - With a socket at /run/docker.sock and CODE_TEST_DOCKER=1, which then
#     requires the socket. Without a socket, the Docker check passes without
#     exercising the grant.
#   - With a SHELL, EDITOR, VISUAL, DISABLE_UPDATES and
#     DISABLE_INSTALLATION_CHECKS of the caller's that differ from the app's.
#     The checks of the app's own values then show them winning.
set -euxo pipefail

# --- Setup ---
here=/app/lib/code-test
ai=
if [ -x /app/bin/claude ]; then ai=1; fi
version=$(jq -r .version /app/lib/vscode/resources/app/package.json)
bundled=$(awk '!/^#/ && NF { print $1 }' "$here/extensions.txt")
test -n "$bundled"
data=$XDG_DATA_HOME/vscode
offered=$data/extensions-offered
settings=$XDG_CONFIG_HOME/Code/User/settings.json
installed=$(mktemp)
kvm=no
if [ -e /dev/kvm ]; then kvm=yes; fi

# flatpak.sh test's home is a directory in its TMPDIR. flatpak shares /tmp
# and /var/tmp between the instances of an app. A home in there would not
# start empty in each instance, as a user's does, and the --persist check
# below needs that.
case $HOME in
/tmp/* | /var/tmp/*)
    echo "code-test: HOME is $HOME: run flatpak.sh test with TMPDIR outside /tmp and /var/tmp" >&2
    exit 1
    ;;
esac
# CODE_TEST_DOCKER=1 means the caller made a socket at /run/docker.sock.
# The grant must bring it in at both paths (see the sandbox's checks), so a
# run that lost it fails here, at once.
if [ "${CODE_TEST_DOCKER:-}" = 1 ] && ! { test -S /run/docker.sock && test /var/run/docker.sock -ef /run/docker.sock; }; then
    echo "code-test: CODE_TEST_DOCKER=1, but no socket at /run/docker.sock and /var/run/docker.sock" >&2
    exit 1
fi

# --- Permissions, environment and files ---
# section NAME: prints the lines of /.flatpak-info's [NAME] section.
# list KEY: prints the values of [Context]'s KEY, one per line, sorted,
# because flatpak keeps no order.
# sorted WORD...: prints the words sorted the same way, to compare with list.
section() { awk -v g="[$1]" '/^\[/ { on = $0 == g; next } on && NF' /.flatpak-info; }
list() { section Context | sed -n "s/^$1=//p" | tr ';' '\n' | sed '/^$/d' | LC_ALL=C sort; }
sorted() { printf '%s\n' "$@" | LC_ALL=C sort; }
test "$(section Context | cut -d= -f1 | LC_ALL=C sort)" = "$(sorted devices features filesystems persistent shared sockets)"
test "$(list shared)" = network
test "$(list sockets)" = "$(sorted fallback-x11 ssh-auth wayland)"
test "$(list devices)" = "$(sorted dri kvm)"
test "$(list features)" = devel
# shellcheck disable=SC2088  # flatpak's spelling of the paths, unexpanded
test "$(list filesystems)" = "$(sorted /run/docker.sock '~/Developer:create' '~/.config/fish:ro' \
    '~/.gitconfig:ro' xdg-config/git:ro '~/.ssh/known_hosts:ro' '~/.ssh/config:ro')"
test "$(list persistent)" = "$(sorted go .cargo .deno .vscode)"
test "$(section 'Session Bus Policy')" = org.freedesktop.Notifications=talk
test -z "$(section 'System Bus Policy')"
environment=$(section Environment)
envs=(PATH=/app/bin:/app/go/bin:/app/cargo/bin:/usr/bin RUSTUP_HOME=/app/rustup DENO_NO_UPDATE_CHECK=1
    LD_LIBRARY_PATH=/app/lib XCURSOR_PATH=/run/host/user-share/icons:/run/host/share/icons
    SHELL=/app/bin/fish EDITOR=code-wait VISUAL=code-wait
    MISE_SYSTEM_CONFIG_DIR=/app/etc/mise MISE_SYSTEM_DATA_DIR=/app/share/mise MISE_AUTO_INSTALL=0
    MISE_USE_VERSIONS_HOST=0 MISE_USE_VERSIONS_HOST_TRACK=0 MISE_PARANOID=1)
if [ -n "$ai" ]; then envs+=(DISABLE_UPDATES=1 DISABLE_INSTALLATION_CHECKS=1); fi
for e in "${envs[@]}"; do grep -qxF "$e" <<<"$environment"; done
# The ai variant has Claude Code's files. The plain one has none of them,
# and no mention of Claude in its metadata.
if [ -n "$ai" ]; then
    test -x /app/bin/claude-sandboxed && test -x /app/libexec/claude
else
    test ! -e /app/bin/claude-sandboxed && test ! -e /app/libexec/claude
    if grep -qi claude /.flatpak-info; then exit 1; fi
fi
# Every library that VS Code, its native modules and zypak link must be
# found: their own, or the SDK's. VS Code's dir is on the path because VS
# Code loads its own libraries from there. The Microsoft Account
# extension's broker is left out, because it links WebKitGTK (see the
# Containerfile).
missing=$(find /app/lib/vscode /app/lib/libzypak-*.so /app/bin/zypak-helper /app/bin/zypak-sandbox \
    -type f \( -name '*.so*' -o -name '*.node' -o -perm -u+x \) \
    ! -path '/app/lib/vscode/resources/app/extensions/microsoft-authentication/dist/*' \
    -exec env LD_LIBRARY_PATH=/app/lib/vscode:/app/lib ldd {} + 2>/dev/null | grep 'not found' || :)
test -z "$missing"

# --- A new profile's extensions ---
# fresh: starts over with a new profile.
# first_start ID...: checks a new profile's first starts. ID... are the
# extensions that the variant installs from the Marketplace only. The
# bundled ones (extensions.txt) are checked too.
#   - Offline, a first start installs the bundled ones, and leaves the
#     others for later.
#   - Called as an editor (code-wait), it installs nothing. Offline, it does
#     not even try.
#   - Online, a first start installs all of them from the Marketplace. So
#     none is pinned (VS Code updates them), each is recorded once, and one
#     that is removed stays removed.
#   - The new profile keeps Local History out of /tmp and /run/user, where
#     sops and kubectl edit plaintext. It gives containers no Wayland
#     socket.
fresh() { rm -rf "$XDG_CONFIG_HOME/Code" "$data"; }
first_start() {
    local id said v
    fresh
    flatpak-spawn --no-network code --list-extensions >"$installed"
    for id in $bundled; do grep -qixF "$id" "$installed"; done
    for id; do if grep -qxF "$id" "$offered"; then exit 1; fi; done
    fresh
    said=$(flatpak-spawn --no-network code-wait --version 2>&1)
    if grep -q 'Installing extensions' <<<"$said"; then exit 1; fi
    test ! -e "$offered"
    fresh
    v=$(code --version)
    test "${v%%$'\n'*}" = "$version"
    jq -e '."workbench.localHistory.exclude" == { "/tmp/**": true, "/run/user/**": true } and
        ."dev.containers.mountWaylandSocket" == false' "$settings"
    code --list-extensions >"$installed"
    for id in $bundled "$@"; do
        grep -qixF "$id" "$installed"
        test "$(grep -cxF "$id" "$offered")" = 1
    done
    jq -e '[.[] | select(.metadata.pinned == true)] | length == 0' "$data/extensions/extensions.json"
    code --uninstall-extension golang.go
    code --list-extensions >"$installed"
    if grep -qixF golang.go "$installed"; then exit 1; fi
}
# The ai variant also installs Claude Code's extension, and has the
# claude-sandboxed terminal profile. The plain one has neither.
if [ -n "$ai" ]; then
    first_start ms-vscode-remote.remote-containers anthropic.claude-code
    jq -e '."terminal.integrated.profiles.linux"."claude-sandboxed".path == "/app/bin/claude-sandboxed"' "$settings"
else
    first_start ms-vscode-remote.remote-containers
    if grep -qixF anthropic.claude-code "$installed" || grep -qxF anthropic.claude-code "$offered"; then exit 1; fi
    jq -e 'has("terminal.integrated.profiles.linux") | not' "$settings"
fi

# --- VS Code's window ---
# VS Code starts through the launcher, as from the desktop file, with no
# display (Chromium's headless platform) and no GPU. Its renderer runs in
# the sandbox that zypak has the portal make (Chromium refuses to start a
# renderer without a sandbox). The workbench must load, as the DevTools
# protocol on a local port shows. Then the window's processes are stopped.
code --ozone-platform=headless --disable-gpu --remote-debugging-port=9223 --new-window ~/Developer
loaded=
for _ in $(seq 90); do
    if curl -fsS http://127.0.0.1:9223/json/list 2>/dev/null |
        jq -e 'any(.[]; .type == "page" and (.url | test("/workbench/workbench\\.html")))' >/dev/null; then
        loaded=1
        break
    fi
    sleep 1
done
if [ -z "$loaded" ]; then
    curl -sS http://127.0.0.1:9223/json/list >&2 || :
    cat "$XDG_CONFIG_HOME"/Code/logs/*/main.log >&2 || :
    exit 1
fi
pkill -f '^/app/lib/vscode/code' || :
for _ in $(seq 30); do pgrep -f '^/app/lib/vscode/code' >/dev/null || break; sleep 1; done

# --- The sandbox ---
# The grants, and nothing else of the host:
#   - ~/Developer is writable.
#   - There is no host file system.
#   - There is no device but the GPU and /dev/kvm (where the host has one,
#     as $kvm records).
#   - The Docker daemon's socket is at both its paths, where the host has
#     one.
test -w ~/Developer
test ! -e /run/host/root
for d in /dev/fuse /dev/net/tun /dev/loop-control /dev/uinput /dev/input /dev/snd /dev/hidraw0 /dev/video0; do
    test ! -e "$d"
done
if [ -e /run/docker.sock ]; then
    test -S /run/docker.sock && test /var/run/docker.sock -ef /run/docker.sock
else
    test ! -e /var/run/docker.sock
fi

# --- The terminal ---
# fish reads your config, which is read-only in here. This test's home has
# none from the host, so it makes a stand-in. fish keeps universal
# variables of its own. A link to the whole directory, as the wrapper made
# before, becomes links to its entries.
mkdir -p ~/.config/fish
echo 'set -g devtools_dotfiles yes' >~/.config/fish/config.fish
rm -rf "$XDG_CONFIG_HOME/fish"
ln -s ~/.config/fish "$XDG_CONFIG_HOME/fish"
test "$SHELL" = /app/bin/fish
fish -c 'set -q devtools_dotfiles && set -U devtools_universal yes'
test -L "$XDG_CONFIG_HOME/fish/config.fish"
grep -q devtools_universal "$XDG_CONFIG_HOME/fish/fish_variables"
test ! -e ~/.config/fish/fish_variables
# EDITOR and VISUAL come from the app, whatever the caller's are, and git
# resolves to them. In ai, Claude Code's updates are off for every process.
test "$EDITOR" = code-wait && test "$VISUAL" = code-wait
test "$(cd / && git var GIT_EDITOR)" = code-wait
if [ -n "$ai" ]; then
    test "$DISABLE_UPDATES" = 1 && test "$DISABLE_INSTALLATION_CHECKS" = 1
    [[ $(claude --version) =~ ^[0-9]+\.[0-9]+\.[0-9]+\ \(Claude\ Code\)$ ]]
fi
# Every tool from tools.txt (tools/test.sh, with tools.txt next to it).
(bash "$here/test.sh")
# mise takes /app's Go as its install of that version, with no network at
# all, in mise exec and in fish. (tools/test.sh only turns off mise's own
# network.)
# shellcheck disable=SC2016  # the second instance's variables
flatpak-spawn --no-network bash -c \
    'set -e; cd "$(mktemp -d)" && go=$(go env GOVERSION) &&
     printf "[tools]\ngo = \"%s\"\n" "${go#go}" >mise.toml && mise trust -q &&
     test "$(PATH=/app/bin mise exec -- go env GOVERSION)" = "$go" &&
     test "$(fish -c "go env GOROOT")" = "/app/share/mise/installs/go/${go#go}"'
# What `go install` builds stays, in the app's own ~/go (--persist) with the
# module cache. The rest of the home starts empty in each instance.
(
    cd "$(mktemp -d)"
    printf 'package main\n\nfunc main() {}\n' >main.go
    go mod init example.com/persisted
    go install
)
touch ~/gone
# shellcheck disable=SC2016
flatpak-spawn sh -c 'test -x ~/go/bin/persisted && test ! -e ~/gone && test "$(go env GOMODCACHE)" = "$HOME/go/pkg/mod"'
test -x ~/.var/app/"$FLATPAK_ID"/go/bin/persisted
# Host commands are refused. host-command says how to allow them, and exits
# with 125, podman's own code for a failure.
rc=0
said=$(podman --version 2>&1) || rc=$?
test "$rc" = 125
grep -qxF '  flatpak override --user --talk-name=org.freedesktop.Flatpak io.github.lucarickli.Code' <<<"$said"

# --- ai: claude-sandboxed's box ---
# claude-sandboxed --shell runs a shell in the box, here to run probe.sh.
# In the box:
#   - The repository is read-write.
#   - Its .git, .vscode, .devcontainer, .devcontainer.json and .claude are
#     read-only. The directories are made where missing.
#   - Claude has a config of its own. None of the app's is there: not its
#     CLAUDE_CONFIG_DIR, not its D-Bus, not its Docker socket.
#   - The app's /dev/kvm is there, where the app has one. claude-sandboxed
#     asks the portal for it.
# The box does not start outside a repository. Nor does it start when
# CLAUDE_CONFIG_DIR is inside the repository, also when spelled through a
# link.
# The plain variant has no box, so its test ends here.
if [ -z "$ai" ]; then exit 0; fi
repo=~/Developer/agent
git init -q "$repo"
echo '{}' >"$repo/.devcontainer.json"
cat >"$repo/probe.sh" <<'PROBE'
set -eu
touch file
for d in .git .vscode .devcontainer .claude; do
    if touch "$d/x" 2>/dev/null; then echo "$d is writable" >&2; exit 1; fi
done
if echo '{"initializeCommand": "x"}' >.devcontainer.json 2>/dev/null; then exit 1; fi
if rm -f .devcontainer.json 2>/dev/null; then exit 1; fi
test ! -e "$1"
test "$CLAUDE_CONFIG_DIR" != "$1"
mkdir -p "$CLAUDE_CONFIG_DIR" && touch "$CLAUDE_CONFIG_DIR/inner"
test ! -e /run/flatpak/bus
test ! -e "$XDG_RUNTIME_DIR/bus"
test ! -e /run/docker.sock
if [ "$2" = yes ]; then test -c /dev/kvm; else test ! -e /dev/kvm; fi
PROBE
mkdir -p "$XDG_CONFIG_HOME/claude"
(cd "$repo" && SHELL=/bin/sh claude-sandboxed --shell probe.sh "$XDG_CONFIG_HOME/claude" "$kvm")
ln -s ~/Developer ~/link
if (cd "$repo" && CLAUDE_CONFIG_DIR=~/link/agent/.claude claude-sandboxed --shell -c true 2>/dev/null); then exit 1; fi
if (cd ~/Developer && claude-sandboxed --shell -c true 2>/dev/null); then exit 1; fi
test -e "$repo/file"
test "$(cat "$repo/.devcontainer.json")" = '{}'
test -e "$XDG_DATA_HOME/claude-sandboxed/claude/inner"
test -z "$(ls -A "$XDG_CONFIG_HOME/claude")"
# In a worktree, .git is a file that names the repository. git must work in
# the box, where that repository is read-only and its other files are out of
# sight.
(
    cd "$repo"
    git add probe.sh
    git -c user.name=t -c user.email=t@example.invalid commit -q -m probe
    git worktree add -q ../agent-wt
    cd ../agent-wt
    # shellcheck disable=SC2016  # the box's shell expands it
    SHELL=/bin/sh claude-sandboxed --shell -c '
        git status --porcelain >/dev/null && git log -1 --format=%s | grep -qx probe &&
        ! touch ../agent/.git/x 2>/dev/null &&
        ! touch "$(git rev-parse --git-dir)/x" 2>/dev/null &&
        test ! -e ../agent/probe.sh'
)
