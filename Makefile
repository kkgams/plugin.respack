SHELL := bash
.ONESHELL:
.SHELLFLAGS := -eu -o pipefail -c
.DELETE_ON_ERROR:
MAKEFLAGS += --no-builtin-rules --warn-undefined-variables
.DEFAULT_GOAL := build

ODIN ?= odin
WIT_BINDGEN ?= wit-bindgen
WASM_TOOLS ?= wasm-tools
WASI_P2_CC ?= wasm32-wasip2-clang
export TMPDIR := $(abspath build.nosync/tmp)
export XDG_CACHE_HOME := $(abspath build.nosync/cache)
export PYTHONPYCACHEPREFIX := $(abspath build.nosync/pycache)
export CARGO_TARGET_DIR := $(abspath build.nosync/runtime-target)
ODIN_SOURCES := $(wildcard src/*.odin src/jsmn/*.odin)
ODIN_DIRS := src src/jsmn
WIT_SOURCES := $(shell find src/wit -type f -name '*.wit' | sort)
WIT_DIRS := $(shell find src/wit -type d | sort)

.PHONY: build package test clean
build: build.nosync/plugin.respack.wasm
package: build.nosync/plugin.respack.wasm build.nosync/LICENSE build.nosync/NOTICE build.nosync/SHA256SUMS

# Test compilation is independent from release packaging.
define component_rules
$(1)/core.o.wasm: $(ODIN_SOURCES) $(ODIN_DIRS) Makefile flake.nix flake.lock | build.nosync/tmp
	@mkdir -p "$(1)"
	@rm -f "$$@" "$(1)/core.o.obj"
	@$(ODIN) build ./src -target:wasi_wasm32 -build-mode:obj --no-entry-point -o:speed -out:$$@
	@if [ -f "$(1)/core.o.obj" ]; then mv "$(1)/core.o.obj" "$$@"; fi
	@test -f "$$@"

$(1)/plugin.respack.unstripped.wasm: src/component.c $(1)/core.o.wasm $(WIT_SOURCES) $(WIT_DIRS) Makefile flake.nix flake.lock | build.nosync/tmp
	@rm -rf "$(1)/bindings"
	@mkdir -p "$(1)/bindings"
	@(cd "$(1)/bindings" && $(WIT_BINDGEN) c "$(abspath src/wit)" -w gams:respack/respack-plugin@1.0.0)
	@$(WASI_P2_CC) -o "$$@" -mexec-model=reactor -I"$(1)/bindings" -O2 -DNDEBUG \
		"$(1)/bindings/respack_plugin.c" src/component.c "$(1)/core.o.wasm" \
		"$(1)/bindings/respack_plugin_component_type.o" -Wl,--strip-all

$(1)/plugin.respack.stripped.wasm: $(1)/plugin.respack.unstripped.wasm Makefile
	@$(WASM_TOOLS) strip -a "$$<" -o "$$@"

$(1)/plugin.respack.wasm: $(1)/plugin.respack.stripped.wasm LICENSE NOTICE scripts/embed-notices.py Makefile
	@python3 scripts/embed-notices.py "$$<" "$$@"
endef
$(eval $(call component_rules,build.nosync))
$(eval $(call component_rules,build.nosync/test))

build.nosync/tmp:
	@mkdir -p "$@"

build.nosync/LICENSE: LICENSE Makefile | build.nosync/tmp
	@cp "$<" "$@"

build.nosync/NOTICE: NOTICE Makefile | build.nosync/tmp
	@cp "$<" "$@"

build.nosync/SHA256SUMS: build.nosync/plugin.respack.wasm build.nosync/LICENSE build.nosync/NOTICE Makefile
	@cd build.nosync && shasum -a 256 plugin.respack.wasm LICENSE NOTICE > SHA256SUMS

test: build.nosync/test/plugin.respack.wasm
	@RESPACK_COMPONENT_PATH="$(abspath build.nosync/test/plugin.respack.wasm)" CC="$$NIX_CC/bin/cc" CXX="$$NIX_CC/bin/c++" AR="$$NIX_CC/bin/ar" cargo test --locked --manifest-path runtime-test/Cargo.toml -- --nocapture

clean:
	@python3 scripts/clean.py

PYTHON ?= python3
CURL ?= curl
GAMS_RELEASE_API ?= https://api.github.com/repos/kkgams/gams/releases/latest
UNAME_S := $(shell uname -s)
UNAME_M := $(shell uname -m)
DOCS_PORT ?= 8080
WIKI_VERSION := v1.4.0
WIKI_REPOSITORY := https://github.com/justgook/wiki
WIKI_MAKEFILE := build.nosync/wiki-$(WIKI_VERSION).mk
WIKI_ENGINE := $(abspath build.nosync/wiki-$(WIKI_VERSION))

.PHONY: open docs serve-docs validate-docs

# Retain an existing app; never update it implicitly.
tools/gams.app:
	@test "$(UNAME_S)" = Darwin && test "$(UNAME_M)" = arm64 || \
		{ echo 'GAMS release download requires macOS Apple Silicon' >&2; exit 1; }
	@test ! -e tools/gams-release-notices || \
		{ echo 'tools/gams-release-notices already exists; move it aside before reinstalling GAMS' >&2; exit 1; }
	@mkdir -p tools build.nosync/tmp
	@set -eu; stage=$$(mktemp -d "build.nosync/tmp/gams-download.XXXXXX"); \
		trap 'rm -rf "$$stage"' EXIT; \
		$(CURL) --fail --location --silent --show-error "$(GAMS_RELEASE_API)" --output "$$stage/release.json"; \
		url=$$($(PYTHON) -c 'import json, sys; release = json.load(open(sys.argv[1])); assets = [a for a in release["assets"] if a["name"].startswith("GAMS-") and a["name"].endswith("-macos-aarch64.zip")]; assert len(assets) == 1, "Expected exactly one GAMS macOS Apple Silicon ZIP asset"; print(assets[0]["browser_download_url"])' "$$stage/release.json"); \
		$(CURL) --fail --location --silent --show-error "$$url" --output "$$stage/gams.zip"; \
		unzip -q "$$stage/gams.zip" -d "$$stage/unpacked"; \
		test -f "$$stage/unpacked/GAMS.app/Contents/Info.plist"; \
		test -x "$$stage/unpacked/GAMS.app/Contents/MacOS/gams"; \
		mv "$$stage/unpacked/GAMS.app" "$$stage/GAMS.app"; \
		printf 'plugin.respack Makefile Host download\n' > "$$stage/unpacked/.gams-managed"; \
		mv "$$stage/unpacked" tools/gams-release-notices; \
		mv "$$stage/GAMS.app" "$@"

open: build tools/gams.app
	GAMS_APP_CWD="$(CURDIR)" GAMS_CONFIG="$(CURDIR)/gams.json" ./tools/gams.app/Contents/MacOS/gams

$(WIKI_MAKEFILE): | build.nosync/tmp
	@mkdir -p "$(@D)"
	@set -eu; trap 'rm -f "$@.tmp"' EXIT; \
		$(CURL) --fail --location --retry 3 "$(WIKI_REPOSITORY)/raw/$(WIKI_VERSION)/Makefile" -o "$@.tmp"; \
		mv "$@.tmp" "$@"

serve-docs validate-docs docs: $(WIKI_MAKEFILE) | build.nosync/tmp
	$(MAKE) -f "$(WIKI_MAKEFILE)" "$(if $(filter docs,$@),build,$(patsubst %-docs,%,$@))" WIKI_REPOSITORY="$(WIKI_REPOSITORY)" WIKI_VERSION="$(WIKI_VERSION)" WIKI_ENGINE="$(WIKI_ENGINE)" WIKI_SOURCE="$(abspath docs)" WIKI_OUTPUT="$(abspath build.nosync/site)" PORT="$(DOCS_PORT)"
