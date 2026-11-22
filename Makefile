# fudge — a keyboard launcher for macOS, built to run Raycast extensions.
#
# Single command surface for building, testing and running fudge.
# Run `make help` for targets.

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

VERSION   := $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
# The release workflow names the tag it builds (RELEASE_TAG=v0.3.0): that's the version, and it must be on this commit.
ifdef RELEASE_TAG
VERSION := $(RELEASE_TAG)
endif
# What Fudge.app's Info.plist says: the version tag's major, minor and patch (0.3.0, as macOS expects), a build number
# that only goes up, and VERSION itself in FudgeGitDescribe, which Fudge shows its own form of and the update check reads.
SHORT_VERSION = $(shell '$(NODE)' runtime/scripts/bundle-version.ts '$(VERSION)')
BUILD_NUMBER := $(shell git rev-list --count HEAD 2>/dev/null || echo 1)
CONFIG    ?= debug
APP       := build/Fudge.app
# Fudge Links (SPEC-140), the app inside Fudge.app that alone declares Raycast's link schemes.
LINKS_APP := $(APP)/Contents/Helpers/Fudge Links.app
# The disk image a release ships, named after the version without its leading v (Fudge-0.3.0.dmg).
DMG       := build/Fudge-$(patsubst v%,%,$(VERSION)).dmg
# The extensions bundled with the app, as BundledExtensions.folders lists them.
BUNDLED_EXTENSIONS := store-extension file-search-extension emoji-extension clipboard-history-extension
SWIFT_BIN  =$(shell swift build -c $(CONFIG) --show-bin-path)
# esbuild's native binary, installed with the extension host's dependencies.
ESBUILD    = $(firstword $(wildcard runtime/node_modules/@esbuild/darwin-*/bin/esbuild))

# The identity `make app` signs with: a name or SHA-1 hash that `security find-identity -v -p codesigning` lists, or -
# for ad hoc. macOS ties Accessibility and Automation grants to the signature, and an ad hoc one changes with every
# build. The default is "fudge local signing", else the first "Apple Development:" identity, else ad hoc (CI has
# neither; a release is built ad hoc, then signed again with the Developer ID identity by scripts/release.sh). It's
# picked by hash, so two certificates with the same name can't make codesign refuse the name as ambiguous. See the
# README.
# (Every parenthesis in the awk program is balanced: make counts them to find the end of $(shell).)
SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F'"' \
	'{ split($$1, f, " ") } length(f[2]) == 40 && f[2] ~ /^[0-9A-F]+$$/ { \
		if ($$2 == "fudge local signing" && local == "") local = f[2]; \
		else if (index($$2, "Apple Development: ") == 1 && dev == "") dev = f[2] } \
	END { print (local != "" ? local : (dev != "" ? dev : "-")) }')

# The @raycast/api release whose type definitions live in runtime/vendor/raycast-api.
RAYCAST_API_VERSION ?= 2.13.1

# The Node.js Fudge bundles and always runs (SPEC-115), and the one every step of the build runs: an official build
# from nodejs.org, for the architecture this Mac builds for. Each tarball's SHA-256 is copied from the release's
# SHASUMS256.txt, and a tarball that doesn't match is deleted before anything is unpacked. It's downloaded once into
# .cache/node, which `make clean` keeps. To update it, change the version and both checksums together.
NODE_VERSION      := 26.13.1
NODE_SHA256_arm64 := af6202f5370a3a5209e85dc543758dfd9f44c8726626a236730cd603a67a8559
NODE_SHA256_x64   := 2693310b2820f9350d29524f21344e1c623875bab773457d55b2aceb9670716f
NODE_ARCH         := $(subst x86_64,x64,$(shell uname -m))
NODE_NAME         := node-v$(NODE_VERSION)-darwin-$(NODE_ARCH)
NODE_CACHE        := $(CURDIR)/.cache/node
NODE_HOME         := $(NODE_CACHE)/$(NODE_NAME)
NODE              := $(NODE_HOME)/bin/node
# Every recipe's node, npm and npx are that Node.js's, whatever else is on PATH.
export PATH := $(NODE_HOME)/bin:$(PATH)

.PHONY: help release-check app dmg dmg-image release run install-extension build runtime node test test-swift test-runtime lint fmt raycast-types compat-scan clean

help:
	@printf 'Fudge — a keyboard launcher for macOS, built to run Raycast extensions\n\n'
	@printf 'Usage: make <target>\n\n'
	@printf '  help           Show this help (default).\n'
	@printf '  app            Build %s (CONFIG=debug|release, now: %s). Signs with SIGN_IDENTITY: by default\n' '$(APP)' '$(CONFIG)'
	@printf '                 "fudge local signing", else an Apple Development identity, else ad hoc (-). See README.md.\n'
	@printf '  dmg            Build the app, then %s: the app and a link to Applications (RELEASE_TAG=<tag> for a release).\n' '$(DMG)'
	@printf '  dmg-image      Make %s from the app as it is, without building it.\n' '$(DMG)'
	@printf '  release        Build %s signed with Developer ID, notarized and stapled, after secret env apple.\n' '$(DMG)'
	@printf '  run            Build the app and open it, quitting a running copy first.\n'
	@printf '  install-extension DIR=<folder>  Build the app, then compile and install the extension in <folder>.\n'
	@printf '  build          Build the Swift targets and the extension host.\n'
	@printf '  node           Download and check the Node.js Fudge bundles (%s) into .cache/node.\n' '$(NODE_VERSION)'
	@printf '  test           Run the Swift and extension host tests.\n'
	@printf '  lint           Check Swift formatting and type-check the extension host.\n'
	@printf '  fmt            Format all Swift code.\n'
	@printf '  raycast-types  Copy the type definitions of @raycast/api %s into runtime/vendor and regenerate what is derived from them.\n' '$(RAYCAST_API_VERSION)'
	@printf '  compat-scan DIR=<folder>  Report which @raycast/api uses of the extensions in <folder> Fudge lacks.\n'
	@printf '  clean          Remove build output.\n'

# Downloads, checks and unpacks the pinned Node.js. The tarball is unpacked into a fresh folder of its own under
# .cache/node, and moved into place only once it's whole. Each failure exits explicitly: make 3.81 ignores .SHELLFLAGS.
$(NODE):
	@tarball='$(NODE_CACHE)/$(NODE_NAME).tar.xz'; expected='$(NODE_SHA256_$(NODE_ARCH))'; \
	[ -n "$$expected" ] || { printf 'make: no Node.js checksum for %s\n' '$(NODE_ARCH)'; exit 1; }; \
	[ ! -e '$(NODE_HOME)' ] || { printf 'make: %s is there without bin/node; move it away\n' '$(NODE_HOME)'; exit 1; }; \
	mkdir -p '$(NODE_CACHE)' || exit 1; \
	if [ ! -f "$$tarball" ]; then \
		printf '→ downloading Node.js %s (%s)\n' '$(NODE_VERSION)' '$(NODE_ARCH)'; \
		curl -fsSL --proto '=https' --tlsv1.2 -o "$$tarball.part" \
			'https://nodejs.org/dist/v$(NODE_VERSION)/$(NODE_NAME).tar.xz' \
			|| { rm -f "$$tarball.part"; printf 'make: could not download Node.js %s\n' '$(NODE_VERSION)'; exit 1; }; \
		mv "$$tarball.part" "$$tarball" || exit 1; \
	fi; \
	actual=$$(shasum -a 256 "$$tarball" | cut -d' ' -f1); \
	[ "$$actual" = "$$expected" ] \
		|| { rm -f "$$tarball"; printf 'make: %s.tar.xz has SHA-256 %s, not the pinned %s; deleted it\n' \
			'$(NODE_NAME)' "$$actual" "$$expected"; exit 1; }; \
	unpack=$$(mktemp -d '$(NODE_CACHE)/unpack.XXXXXX') || exit 1; \
	tar -xJf "$$tarball" -C "$$unpack" && mv "$$unpack/$(NODE_NAME)" '$(NODE_HOME)'; status=$$?; \
	case "$$unpack" in '$(NODE_CACHE)/unpack.'?*) rm -rf -- "$$unpack" ;; esac; \
	[ "$$status" = 0 ] || { printf 'make: could not unpack %s.tar.xz\n' '$(NODE_NAME)'; exit 1; }
	@'$(NODE)' --version >/dev/null || { printf 'make: the downloaded Node.js does not run\n'; exit 1; }

node: $(NODE)

runtime/node_modules: runtime/package.json runtime/package-lock.json | $(NODE)
	@cd runtime && npm ci --no-audit --no-fund --loglevel=error
	@touch $@

runtime: runtime/node_modules
	@cd runtime && npm run --silent build

build: runtime
	@swift build -c $(CONFIG)

# A release build stops rather than number itself wrong (SPEC-113): a shallow clone has no tags and would make the
# build number 1, and RELEASE_TAG must be a tag on this commit. Checked before anything is built.
release-check:
	@if [ '$(CONFIG)' = release ] && [ "$$(git rev-parse --is-shallow-repository 2>/dev/null)" = true ]; then \
		echo "make: a release build needs the whole history and its tags, but this is a shallow clone: check it out with fetch-depth: 0"; \
		exit 1; \
	fi
	@if [ -n '$(RELEASE_TAG)' ] && ! git tag --points-at HEAD 2>/dev/null | grep -qxF '$(RELEASE_TAG)'; then \
		echo "make: RELEASE_TAG $(RELEASE_TAG) isn't a tag on this commit"; \
		exit 1; \
	fi

app: release-check build
	@rm -rf '$(APP)'
	@mkdir -p '$(APP)/Contents/MacOS' '$(APP)/Contents/Helpers' '$(APP)/Contents/Resources/runtime'
	@cp '$(SWIFT_BIN)/FudgeApp' '$(APP)/Contents/MacOS/Fudge'
	@cp '$(SWIFT_BIN)/fudge' '$(ESBUILD)' '$(APP)/Contents/Helpers/'
	@# Fudge Links: a nested app here, since nothing but turning on "Fudge opens Raycast links" (or onboarding's button)
	@# registers it, by LSRegisterURL on it (Contents/Library/LoginItems is registered at every launch).
	@mkdir -p '$(LINKS_APP)/Contents/MacOS' && cp '$(SWIFT_BIN)/FudgeLinks' '$(LINKS_APP)/Contents/MacOS/FudgeLinks' \
		&& cp App/Links/Info.plist '$(LINKS_APP)/Contents/Info.plist'
	@# Fudge's own Node.js (SPEC-115): the binary beside the helpers, npm from its distribution, and its license,
	@# which also covers what Node.js bundles, npm included.
	@cp '$(NODE)' '$(APP)/Contents/Helpers/node'
	@mkdir -p '$(APP)/Contents/Resources/node' \
		&& cp -R '$(NODE_HOME)/lib/node_modules/npm' '$(APP)/Contents/Resources/node/npm' \
		&& cp '$(NODE_HOME)/LICENSE' '$(APP)/Contents/Resources/node/LICENSE'
	@cp App/Info.plist '$(APP)/Contents/Info.plist'
	@# actool hands the work to a shared daemon, which resolves relative paths against its own working directory:
	@# another worktree's, if one started it. Every path is absolute. actool reports on stdout, even its errors,
	@# and may exit 0 when it compiled nothing, so its report goes to build/actool.log and is shown when it fails.
	@xcrun actool '$(CURDIR)/App/AppIcon.icon' --compile '$(abspath $(APP))/Contents/Resources' --app-icon AppIcon \
		--platform macosx --target-device mac --minimum-deployment-target 14.0 \
		--output-format human-readable-text --output-partial-info-plist '$(CURDIR)/build/AppIcon.plist' \
		>'$(CURDIR)/build/actool.log' && test -f '$(APP)/Contents/Resources/Assets.car' \
		|| { cat build/actool.log; printf 'actool did not write %s (it needs Xcode 26 or later; see its output above, also in build/actool.log)\n' '$(APP)/Contents/Resources/Assets.car'; exit 1; }
	@plutil -replace CFBundleShortVersionString -string '$(SHORT_VERSION)' '$(APP)/Contents/Info.plist'
	@plutil -replace CFBundleVersion -string '$(BUILD_NUMBER)' '$(APP)/Contents/Info.plist'
	@plutil -replace FudgeGitDescribe -string '$(VERSION)' '$(APP)/Contents/Info.plist'
	@plutil -replace CFBundleShortVersionString -string '$(SHORT_VERSION)' '$(LINKS_APP)/Contents/Info.plist'
	@plutil -replace CFBundleVersion -string '$(BUILD_NUMBER)' '$(LINKS_APP)/Contents/Info.plist'
	@cp runtime/dist/host.js runtime/dist/worker.js '$(APP)/Contents/Resources/runtime/'
	@# `fudge scan`'s scanner, and Raycast's types it reads, with their MIT notice.
	@cp runtime/dist/compat-scan.js '$(APP)/Contents/Resources/runtime/'
	@# `fudge build`'s compile step (ExtensionBuilder.locateBundler), with esbuild's JavaScript inside, before the
	@# bundled extensions below are built through it.
	@cp runtime/dist/bundle-extension.cjs '$(APP)/Contents/Resources/runtime/'
	@cp runtime/vendor/raycast-api/index.d.ts '$(APP)/Contents/Resources/runtime/raycast-api.d.ts'
	@cp runtime/vendor/raycast-api/LICENSE '$(APP)/Contents/Resources/runtime/raycast-api.LICENSE'
	@# Fudge's own license, and the notices of the third-party code and data it ships, from their own license files.
	@cp LICENSE '$(APP)/Contents/Resources/LICENSE.txt'
	@cd runtime && node scripts/notices.ts --text '$(abspath $(APP))/Contents/Resources/Third-Party Notices.txt'
	@# The bundled extensions (BundledExtensions in core), each built like any other into a scratch folder and
	@# moved to Contents/Resources/<folder>. Their sources are runtime/<folder>; no source, no extension.
	@for folder in $(BUNDLED_EXTENSIONS); do \
		[ -f "runtime/$$folder/package.json" ] || continue; \
		scratch="$(abspath build)/$$folder-build" && rm -rf "$$scratch" && mkdir -p "$$scratch" && \
		'$(APP)/Contents/Helpers/fudge' build "runtime/$$folder" --into "$$scratch" >/dev/null && \
		mv "$$scratch"/* "$(APP)/Contents/Resources/$$folder" && rm -rf "$$scratch" \
		|| { echo "make app: building runtime/$$folder failed"; exit 1; }; \
	done
	@# A release ships without the binaries' debug and local symbols, which name the builder's folders (/Users/…).
	@# strip warns that it invalidates the linker's signature, which the signing below replaces, so its output shows
	@# only when it fails.
	@if [ '$(CONFIG)' = release ]; then \
		out=$$(strip -S -x '$(APP)/Contents/MacOS/Fudge' '$(APP)/Contents/Helpers/fudge' \
			'$(LINKS_APP)/Contents/MacOS/FudgeLinks' 2>&1) || \
			{ printf '%s\nmake app: strip failed\n' "$$out"; exit 1; }; \
	fi
	@# Signed inside-out with the hardened runtime (scripts/sign-app.sh): each helper with App/Helpers/<name>.entitlements
	@# when it has them (Node.js does), then the app with App/Fudge.entitlements, with no timestamp unless it's a
	@# Developer ID. Each failure exits explicitly: make 3.81, the one macOS ships, ignores .SHELLFLAGS.
	@signed=$$(scripts/sign-app.sh '$(APP)' '$(SIGN_IDENTITY)') && \
	printf '→ built %s (%s, %s, signed %s, hardened runtime)\n' '$(APP)' '$(VERSION)' '$(CONFIG)' "$$signed"

# The user's fudge: Fudge processes launched as the app, by LaunchServices (their parent is launchd), with no
# arguments. `--snapshot` runs, key probes and test harnesses that agents start from a shell are left alone.
# A process whose shell has exited is re-parented to launchd too, so a detached Fudge started with no arguments
# counts as the user's: give anything you leave running an argument.
USER_FUDGE_PIDS = for pid in $$(pgrep -x Fudge); do \
		[ "$$(ps -o ppid= -p $$pid | tr -d ' ')" = 1 ] && [ "$$(ps -o args= -p $$pid)" = "$$(ps -o comm= -p $$pid)" ] \
			&& echo $$pid; \
	done; true

# A release's disk image: the app as `make app` built it, and a link to /Applications to drag it onto, compressed
# (UDZO), with the volume name Fudge. The staging folder is gone afterwards.
dmg: app
	@$(MAKE) --no-print-directory dmg-image

# The disk image of the app as it is, without building it again: the release script notarizes and staples the app
# before packing it.
dmg-image:
	@test -d '$(APP)' || { printf 'make dmg-image: there is no %s; run make app first\n' '$(APP)'; exit 1; }
	@rm -rf build/dmg '$(DMG)' && mkdir -p build/dmg
	@ditto '$(APP)' build/dmg/Fudge.app && ln -s /Applications build/dmg/Applications
	@hdiutil create -volname Fudge -srcfolder build/dmg -format UDZO -ov '$(DMG)' >/dev/null \
		|| { echo 'make dmg-image: hdiutil could not create $(DMG)'; rm -rf build/dmg; exit 1; }
	@rm -rf build/dmg
	@printf '→ built %s\n' '$(DMG)'

# A release's disk image signed with the Developer ID identity, notarized and stapled, with the variables
# `secret env apple` sets (scripts/release.sh). It refuses a tree with changes, and never pushes or tags. With
# RELEASE_TAG, it's that tag's release, which must be on this commit.
release:
	@scripts/release.sh $(if $(RELEASE_TAG),--tag '$(RELEASE_TAG)',--version '$(VERSION)')

run: app
	@# Quit the user's fudge and wait for exactly those processes: open hands off to a Fudge that's still quitting
	@# and fails (-600).
	@pids=$$($(USER_FUDGE_PIDS)); \
	[ -z "$$pids" ] || kill $$pids 2>/dev/null; \
	for _ in $$(seq 50); do \
		alive=; for pid in $$pids; do kill -0 $$pid 2>/dev/null && alive=$$pid; done; \
		[ -z "$$alive" ] && break; sleep 0.1; \
	done; \
	[ -z "$$alive" ] || { printf 'the running Fudge did not quit\n'; exit 1; }; \
	again=$$($(USER_FUDGE_PIDS)); \
	[ -z "$$again" ] || { printf 'another Fudge started meanwhile (pid %s); quit it, then run make run again\n' \
		"$$again"; exit 1; }
	@# -n starts a new instance. Without it, LaunchServices hands the open to any live Fudge with the same bundle
	@# id, such as a --snapshot run from another checkout, and fails with -600, leaving no fudge running. The user's
	@# own fudge was quit, and checked for again, just above, so -n can't start a second copy of it.
	@open -n '$(APP)'

install-extension: app
	@test -n '$(DIR)' || { printf 'usage: make install-extension DIR=<folder>\n'; exit 2; }
	@'$(APP)/Contents/Helpers/fudge' build '$(DIR)'

test: test-swift test-runtime

# The tests get the pinned Node.js through FUDGE_TEST_NODE, which only the test target reads.
test-swift: runtime/node_modules
	@FUDGE_TEST_NODE='$(NODE)' swift test

test-runtime: runtime/node_modules
	@cd runtime && npm test

lint: runtime/node_modules
	@swift format lint --strict --recursive Package.swift Sources Tests
	@cd runtime && npm run --silent typecheck
	@# Docs are one sentence per line: no line of CLAUDE.md or README.md over 400 characters, outside code and tables.
	@perl -CSD -ne 'chomp; if (/^\s*(```|~~~)/) { $$fence = !$$fence } elsif (!$$fence && !/^\s*\|/ && length > 400) { print STDERR "$$ARGV:$$.: " . length . " characters; write docs one sentence per line\n"; $$bad = 1 } if (eof) { close ARGV; $$fence = 0 } END { exit $$bad }' CLAUDE.md README.md

fmt:
	@swift format --in-place --recursive Package.swift Sources Tests

raycast-types: | $(NODE)
	@tmp=$$(mktemp -d); trap 'rm -rf "$$tmp"' EXIT; \
	(cd "$$tmp" && npm pack --silent '@raycast/api@$(RAYCAST_API_VERSION)' >/dev/null && tar -xzf raycast-api-*.tgz); \
	test "$$(node -p "require('$$tmp/package/package.json').license")" = MIT; \
	cp "$$tmp/package/types/index.d.ts" runtime/vendor/raycast-api/index.d.ts; \
	printf '%s\n' '$(RAYCAST_API_VERSION)' > runtime/vendor/raycast-api/VERSION
	@cd runtime && npm run --silent generate
	@printf '→ copied the type definitions of @raycast/api %s and regenerated the files derived from them\n' '$(RAYCAST_API_VERSION)'

compat-scan: runtime/node_modules
	@test -n '$(DIR)' || { printf 'usage: make compat-scan DIR=<folder of extensions>\n'; exit 2; }
	@cd runtime && node scripts/compat-scan.ts '$(abspath $(DIR))'

clean:
	@rm -rf build .build runtime/dist
