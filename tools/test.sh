#!/usr/bin/env bash
#
# Tests that every tool from tools.txt runs, and that the toolchains build
# something.
#
#   test.sh
#
# Run it inside the dev container or the VS Code Flatpak, as the user who
# will use the tools, with tools.txt next to this file. devcontainer.yml and
# apps/io.github.lucarickli.Code/test.sh run it that way.
set -euxo pipefail

# --- Every tool runs ---
kubectl version --client
kubectl-oidc_login --version
kubectl-radar --version
helm version
helmfile version
flux --version
talosctl version --client
talhelper --version
crane version
trivy --version
certinfo --version
sops --version
cosign version
# bcvk runs on the host where it can reach it, and in place where it cannot
# (the Flatpak's files/bin/bcvk, devcontainer/host-command). --version
# works either way.
bcvk --version
age --version
rg --version
fd --version
just --version
gh --version
yq --version
shellcheck --version
actionlint -version
host-spawn --version
fish --version
mise --version

# These come from the distribution in the dev container, and from the
# runtime in the Flatpak.
gcc --version
git --version
git lfs version
jq --version
strace -V

go version
gopls version
dlv version
staticcheck -version
gofumpt -version
golangci-lint version
deno --version
rustc --version
cargo --version
cargo clippy --version
rustfmt --version
rust-analyzer --version
protoc --version
buf --version
protoc-gen-go --version
protoc-gen-go-grpc --version

# --- The toolchains build something ---
cd "$(mktemp -d)"
printf 'package main\n\nfunc main() { println("go ok") }\n' >main.go
go mod init example.com/hello
go build
./hello
cargo new --vcs none hello-rs
cargo run --manifest-path hello-rs/Cargo.toml
deno eval 'console.log("deno ok")'
# A service that uses a well-known type. protoc must find
# google/protobuf/*.proto next to itself. The Go plugins generate code from
# it, and buf lints and builds the same file.
cd "$(mktemp -d)"
mkdir -p proto/hello/v1
cat >proto/hello/v1/hello.proto <<'PROTO'
syntax = "proto3";
package hello.v1;
option go_package = "example.com/hello/hellov1";
import "google/protobuf/timestamp.proto";
message SayHelloRequest { google.protobuf.Timestamp at = 1; }
message SayHelloResponse { string text = 1; }
service HelloService { rpc SayHello(SayHelloRequest) returns (SayHelloResponse); }
PROTO
protoc -I proto --go_out=. --go_opt=paths=source_relative \
    --go-grpc_out=. --go-grpc_opt=paths=source_relative proto/hello/v1/hello.proto
test -s hello/v1/hello.pb.go && test -s hello/v1/hello_grpc.pb.go
printf 'version: v2\nmodules:\n  - path: proto\n' >buf.yaml
buf lint
buf build
fish -c 'echo fish ok'

# --- mise ---
# mise as mise-system.sh and mise-config.toml set it up, with its network
# off. It checks that:
#   - The Go and Deno here are mise's installs of their versions. A trusted
#     project that names them gets them without the rest of PATH, and so
#     does fish there.
#   - `mise use` finds nothing to change in the read-only system part.
#   - GOBIN and DENO_INSTALL_ROOT stay in $HOME.
#   - A version that is not installed is not downloaded, and the pinned one
#     runs. That holds even in a trusted project whose settings ask for
#     downloads, ask for the versions host and turn paranoid off, because
#     the environment's MISE_* settings win. (Offline, mise exec would fail
#     if it tried a download.)
export MISE_OFFLINE=1
prefix=$(dirname "$(dirname "$(command -v mise)")")
go=$(go env GOVERSION) deno=$(deno --version | awk 'NR == 1 { print $2 }')
cd "$(mktemp -d)"
printf '[tools]\ngo = "%s"\ndeno = "%s"\n' "${go#go}" "$deno" >mise.toml
mise trust -q
test "$(PATH=$prefix/bin mise exec -- go env GOVERSION)" = "$go"
test "$(PATH=$prefix/bin mise exec -- deno --version | awk 'NR == 1 { print $2 }')" = "$deno"
mise ls --json go | jq -e --arg dir "$prefix/share/mise/installs/go/${go#go}" \
    'any(.[]; .install_path == $dir and .installed)'
test "$(fish -c 'go env GOROOT')" = "$prefix/share/mise/installs/go/${go#go}"
mise use "go@${go#go}" "deno@$deno"
test "$(mise exec -- go env GOBIN)" = "$(go env GOBIN)"
test "$(mise exec -- printenv DENO_INSTALL_ROOT)" = "$HOME/.deno"
printf '[settings]\nauto_install = true\nuse_versions_host = true\nuse_versions_host_track = true\nparanoid = false\n[tools]\ngo = "1.20.0"\n' >mise.toml
mise trust
for s in auto_install use_versions_host use_versions_host_track; do test "$(mise settings get "$s")" = false; done
test "$(mise settings get paranoid)" = true
test "$(mise exec -- go env GOVERSION)" = "$go"
test "$(fish -c 'go env GOVERSION')" = "$go"
# Paranoid mode: a trusted project's mise config runs nothing new until it
# is trusted again. That covers a file added next to it (as claude-sandboxed
# can add one) and a change to it. Here both use an exec() template that
# makes a file, which must run only after `mise trust`.
cat >mise.local.toml <<'TOML'
[env]
RAN = "{{ exec(command='touch ran') }}"
TOML
if mise env >/dev/null 2>&1; then exit 1; fi
fish -c true 2>/dev/null
rm mise.local.toml
printf '[env]\nRAN = "{{ exec(command=%s) }}"\n' "'touch ran'" >mise.toml
if mise env >/dev/null 2>&1; then exit 1; fi
fish -c true 2>/dev/null
test ! -e ran
mise trust -q
mise env >/dev/null
test -e ran

# --- Licenses ---
# Each tool's license texts are installed next to the tools (in /app or
# /usr/local). Every line of tools.txt has them, and has SOURCES when it
# names a source.
licenses=$(dirname "$(dirname "$(command -v rg)")")/share/licenses
test -d "$licenses"
for d in "$licenses"/*/; do test -n "$(ls -A "$d")"; done
while read -r name _ _ _ _ _ source; do
    case $name in '' | '#'*) continue ;; esac
    test -n "$(ls -A "$licenses/$name")"
    if [ -n "$source" ]; then test -s "$licenses/$name/SOURCES"; else test ! -e "$licenses/$name/SOURCES"; fi
done <"$(dirname "$0")/tools.txt"
