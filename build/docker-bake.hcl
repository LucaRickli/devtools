# Every image of this repository, for Docker Buildx Bake, run from the root
# of the checkout (`docker buildx bake -f build/docker-bake.hcl TARGET...`):
# bake takes every path here, contexts and outputs alike, from the directory
# it runs in, not from this file's. build/build.sh runs it on a builder of
# its own (the docker-container builder `packages`), for just's recipes and
# CI alike.
#
# - devcontainer-plain and devcontainer-ai: the dev container's two images
#   (devcontainer/Containerfile), into docker's image store as
#   localhost/devcontainer:latest and :ai (CI writes them as OCI image
#   layouts instead, output/images/devcontainer and devcontainer-ai, which
#   it tests, scans and pushes: build/ci.sh).
# - builder: localhost/packages/builder (build/Containerfile), into docker's
#   image store, which build.sh makes and tests every Flatpak in.
# - Each Flatpak's image, the flatpak stage of its Containerfile, and its
#   test's, the test stage: runtime and runtime-test, sdk and sdk-test, and
#   for each app in APPS, by its ID with _ for each dot,
#   org_mozilla_firefox and org_mozilla_firefox-test, and one pair more for
#   each variant, io_github_lucarickli_Code-ai and
#   io_github_lucarickli_Code-ai-test (the flatpak-ai and test-ai stages).
#   Each goes to output/images/<NAME>, the Flatpak's name (`build.sh
#   names`) and -test for the test, an OCI image layout: what build.sh
#   makes the Flatpak of (flatpak.sh), and what CI scans. Its layers are
#   zstd, quick to write, and its name localhost/packages/<NAME, lower
#   case> where it is loaded.
#
# Groups: devcontainer, flatpaks (the builder and every Flatpak's two
# images) and default, both.

# The runtime's image (runtime/Containerfile), the named context `runtime`
# of the SDK's and of each app's on it, which their Containerfiles build
# FROM: built here, or another, as oci-layout://DIR or docker-image://REF.
# CI bakes the runtime first and alone, of its cache, and builds on its
# layout (build/ci.sh): on a runtime built here, in the same bake, what is
# built on it misses its cache on every new builder.
variable "RUNTIME" {
  default = "target:runtime"
}

# The SDK's (runtime/sdk/Containerfile), the named context `sdk` of each
# app on it; in CI its layout, as the runtime's.
variable "SDK" {
  default = "target:sdk"
}

# The Fedora image the builder and the runtime are built FROM, FEDORA_REF
# (the reference of their FROM lines, registry.fedoraproject.org/fedora:N),
# as another image, FEDORA (a source as contexts take one,
# docker-image://REF@DIGEST): empty, the default, for the reference's own
# image of the day. CI builds them on the one their cache was built on
# (build/ci.sh, fedora): Fedora replaces the image behind its tag every few
# days, and a step on another base misses the cache.
variable "FEDORA_REF" {
  default = ""
}

variable "FEDORA" {
  default = ""
}

# true for CI's weekly runs and those by hand, in the runtime's job and the
# dev container's: what installs Fedora's updates (the runtime, the dev
# container's plain stage and the builder) is built again without the
# cache, so that it has Fedora's newest packages; whatever is built on them
# follows.
variable "FRESH" {
  type    = bool
  default = false
}

# CI's cache, empty for none (the builder's own alone): a cache backend as
# cache-from takes it, with %s for the target's name, which keeps each
# target's apart, as type=registry,ref=ghcr.io/OWNER/packages-cache:%s
# (build/ci.sh). Every target reads it.
variable "CACHE" {
  default = ""
}

# The targets whose cache this bake writes to CACHE, by the name %s takes
# (runtime, sdk, builder, devcontainer-plain, devcontainer-ai, an app's
# Flatpak name, and NAME-test for its test's), separated by commas; empty,
# the default, for none. Each in full (mode=max), and a failed export
# fails no build. A list, not every target built: a job in CI bakes the
# runtime it builds on too, which only the runtime's own job writes (and
# bake builds a target another names as a context, target:runtime, with
# its own cache-to); build/ci.sh writes only on main, each job its own.
variable "CACHE_WRITE" {
  default = ""
}

# The dev container's two images, by name (CI's are of its run).
variable "DEVCONTAINER" {
  default = "localhost/devcontainer:latest"
}

variable "DEVCONTAINER_AI" {
  default = "localhost/devcontainer:ai"
}

# The apps, apps/<id>/: on the runtime or the SDK (on, the one its
# flatpak.runtime names, which its build stages are FROM), with the build
# contexts its Containerfile copies from (tools/ and keys/), and a variant
# for each flatpak-<variant> stage it has. Adding an app is a line here
# (build/build.sh names fails, and with it CI's plan, where apps/ and this
# list differ).
variable "APPS" {
  default = [
    { id = "ai.storyteller.deckcraft", on = "runtime" },
    { id = "ai.storyteller.gridcraft", on = "runtime" },
    { id = "ai.storyteller.pdfcraft", on = "runtime" },
    { id = "ai.storyteller.wordcraft", on = "runtime" },
    { id = "io.github.lucarickli.Code", on = "sdk", contexts = ["tools", "keys"], variants = ["ai"] },
    { id = "org.mozilla.firefox", on = "runtime" },
    { id = "org.remmina.Remmina", on = "runtime" },
  ]
}

# Each app's Flatpaks, the app's and one for each variant: its name, the
# stages of the Flatpak's image and of its test's, and the app's own.
variable "FLATPAKS" {
  default = flatten([for a in APPS : [for v in concat([""], try(a.variants, [])) : {
    name     = v == "" ? a.id : "${a.id}-${v}"
    stage    = v == "" ? "flatpak" : "flatpak-${v}"
    test     = v == "" ? "test" : "test-${v}"
    dir      = "apps/${a.id}"
    on       = a.on
    contexts = try(a.contexts, [])
  }]])
}

# The named context that builds FROM FEDORA_REF on FEDORA (none without it)
function "fedora" {
  params = []
  result = FEDORA == "" || FEDORA_REF == "" ? {} : { (FEDORA_REF) = FEDORA }
}

function "cache_from" {
  params = [name]
  result = CACHE == "" ? [] : [format(CACHE, name)]
}

function "cache_to" {
  params = [name]
  result = CACHE != "" && contains(split(",", CACHE_WRITE), name) ? ["${format(CACHE, name)},mode=max,ignore-error=true"] : []
}

# A Flatpak's image (or its test's), NAME, for output/images.
function "layout" {
  params = [name]
  result = ["type=oci,dest=output/images/${name},tar=false,compression=zstd"]
}

group "default" {
  targets = ["devcontainer", "flatpaks"]
}

group "devcontainer" {
  targets = ["devcontainer-plain", "devcontainer-ai"]
}

group "flatpaks" {
  targets = ["builder", "runtime", "runtime-test", "sdk", "sdk-test", "app", "app-test"]
}

# What every target has: the base images pulled again where newer, as
# Fedora's are every few days, and no attestations, which nothing here
# reads (CI signs what it pushes).
target "_common" {
  pull   = true
  attest = ["type=provenance,disabled=true"]
}

# ai is plain with a few layers on top, built with it in one run: the same
# stages, and so the same layers, on the same base.
target "devcontainer-plain" {
  inherits        = ["_common"]
  context         = "devcontainer"
  dockerfile      = "Containerfile"
  target          = "plain"
  contexts        = { tools = "tools", keys = "keys" }
  no-cache-filter = FRESH ? ["plain"] : []
  cache-from      = cache_from("devcontainer-plain")
  cache-to        = cache_to("devcontainer-plain")
  tags            = [DEVCONTAINER]
  output          = ["type=docker"]
}

target "devcontainer-ai" {
  inherits   = ["devcontainer-plain"]
  target     = "ai"
  cache-from = cache_from("devcontainer-ai")
  cache-to   = cache_to("devcontainer-ai")
  tags       = [DEVCONTAINER_AI]
}

target "builder" {
  inherits   = ["_common"]
  context    = "build"
  dockerfile = "Containerfile"
  contexts   = fedora()
  no-cache   = FRESH
  cache-from = cache_from("builder")
  cache-to   = cache_to("builder")
  tags       = ["localhost/packages/builder"]
  output     = ["type=docker"]
}

target "runtime" {
  inherits   = ["_common"]
  context    = "runtime"
  dockerfile = "Containerfile"
  target     = "flatpak"
  contexts   = fedora()
  no-cache   = FRESH
  cache-from = cache_from("runtime")
  cache-to   = cache_to("runtime")
  tags       = ["localhost/packages/runtime"]
  output     = layout("runtime")
}

target "runtime-test" {
  inherits   = ["_common"]
  context    = "runtime"
  dockerfile = "Containerfile"
  target     = "test"
  tags       = ["localhost/packages/runtime-test"]
  output     = layout("runtime-test")
}

target "sdk" {
  inherits   = ["_common"]
  context    = "runtime/sdk"
  dockerfile = "Containerfile"
  target     = "flatpak"
  contexts   = { runtime = RUNTIME }
  cache-from = cache_from("sdk")
  cache-to   = cache_to("sdk")
  tags       = ["localhost/packages/sdk"]
  output     = layout("sdk")
}

target "sdk-test" {
  inherits   = ["_common"]
  context    = "runtime/sdk"
  dockerfile = "Containerfile"
  target     = "test"
  tags       = ["localhost/packages/sdk-test"]
  output     = layout("sdk-test")
}

target "app" {
  name       = replace(f.name, ".", "_")
  matrix     = { f = FLATPAKS }
  inherits   = ["_common"]
  context    = f.dir
  dockerfile = "Containerfile"
  target     = f.stage
  contexts   = merge(f.on == "sdk" ? { sdk = SDK } : { runtime = RUNTIME }, { for c in f.contexts : c => c })
  cache-from = cache_from(f.name)
  cache-to   = cache_to(f.name)
  tags       = ["localhost/packages/${lower(f.name)}"]
  output     = layout(f.name)
}

target "app-test" {
  name       = "${replace(f.name, ".", "_")}-test"
  matrix     = { f = FLATPAKS }
  inherits   = ["_common"]
  context    = f.dir
  dockerfile = "Containerfile"
  target     = f.test
  contexts   = merge(f.on == "sdk" ? { sdk = SDK } : { runtime = RUNTIME }, { for c in f.contexts : c => c })
  cache-from = cache_from("${f.name}-test")
  cache-to   = cache_to("${f.name}-test")
  tags       = ["localhost/packages/${lower(f.name)}-test"]
  output     = layout("${f.name}-test")
}
