# fudge — a keyboard launcher for macOS, built to run Raycast extensions.
#
# Single command surface for building, testing and running fudge.
# Run `make help` for targets.

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

VERSION   := $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
CONFIG    ?= debug
APP       := build/Fudge.app
# The extensions bundled with the app, as BundledExtensions.folders lists them.
BUNDLED_EXTENSIONS := store-extension file-search-extension
SWIFT_BIN  =$(shell swift build -c $(CONFIG) --show-bin-path)
# esbuild's native binary, installed with the extension host's dependencies.
ESBUILD    = $(firstword $(wildcard runtime/node_modules/@esbuild/darwin-*/bin/esbuild))

# The identity `make app` signs with: a name or SHA-1 hash that `security find-identity -v -p codesigning` lists, or -
# for ad hoc. macOS ties Accessibility and Automation grants to the signature, and an ad hoc one changes with every
# build. The default is "fudge local signing", else the first "Apple Development:" identity, else ad hoc (CI and
# releases have neither). It's picked by hash, so two certificates with the same name can't make codesign refuse
# the name as ambiguous. See the README.
# (Every parenthesis in the awk program is balanced: make counts them to find the end of $(shell).)
SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F'"' \
	'{ split($$1, f, " ") } length(f[2]) == 40 && f[2] ~ /^[0-9A-F]+$$/ { \
		if ($$2 == "fudge local signing" && local == "") local = f[2]; \
		else if (index($$2, "Apple Development: ") == 1 && dev == "") dev = f[2] } \
	END { print (local != "" ? local : (dev != "" ? dev : "-")) }')

# The @raycast/api release whose type definitions live in runtime/vendor/raycast-api.
RAYCAST_API_VERSION ?= 2.13.1

.PHONY: help app run install-extension build runtime test test-swift test-runtime lint fmt raycast-types compat-scan clean

help:
	@printf 'fudge — a keyboard launcher for macOS, built to run Raycast extensions\n\n'
	@printf 'Usage: make <target>\n\n'
	@printf '  help           Show this help (default).\n'
	@printf '  app            Build %s (CONFIG=debug|release, now: %s). Signs with SIGN_IDENTITY: by default\n' '$(APP)' '$(CONFIG)'
	@printf '                 "fudge local signing", else an Apple Development identity, else ad hoc (-). See README.md.\n'
	@printf '  run            Build the app and open it, quitting a running copy first.\n'
	@printf '  install-extension DIR=<folder>  Build the app, then compile and install the extension in <folder>.\n'
	@printf '  build          Build the Swift targets and the extension host.\n'
	@printf '  test           Run the Swift and extension host tests.\n'
	@printf '  lint           Check Swift formatting and type-check the extension host.\n'
	@printf '  fmt            Format all Swift code.\n'
	@printf '  raycast-types  Copy the type definitions of @raycast/api %s into runtime/vendor and regenerate what is derived from them.\n' '$(RAYCAST_API_VERSION)'
	@printf '  compat-scan DIR=<folder>  Report which @raycast/api uses of the extensions in <folder> fudge lacks.\n'
	@printf '  clean          Remove build output.\n'

runtime/node_modules: runtime/package.json runtime/package-lock.json
	@cd runtime && npm ci --no-audit --no-fund --loglevel=error
	@touch $@

runtime: runtime/node_modules
	@cd runtime && npm run --silent build

build: runtime
	@swift build -c $(CONFIG)

app: build
	@rm -rf '$(APP)'
	@mkdir -p '$(APP)/Contents/MacOS' '$(APP)/Contents/Helpers' '$(APP)/Contents/Resources/runtime'
	@cp '$(SWIFT_BIN)/FudgeApp' '$(APP)/Contents/MacOS/Fudge'
	@cp '$(SWIFT_BIN)/fudge' '$(ESBUILD)' '$(APP)/Contents/Helpers/'
	@cp App/Info.plist '$(APP)/Contents/Info.plist'
	@# actool hands the work to a shared daemon, which resolves relative paths against its own working directory:
	@# another worktree's, if one started it. Every path is absolute. actool reports on stdout, even its errors,
	@# and may exit 0 when it compiled nothing, so its report goes to build/actool.log and is shown when it fails.
	@xcrun actool '$(CURDIR)/App/AppIcon.icon' --compile '$(abspath $(APP))/Contents/Resources' --app-icon AppIcon \
		--platform macosx --target-device mac --minimum-deployment-target 14.0 \
		--output-format human-readable-text --output-partial-info-plist '$(CURDIR)/build/AppIcon.plist' \
		>'$(CURDIR)/build/actool.log' && test -f '$(APP)/Contents/Resources/Assets.car' \
		|| { cat build/actool.log; printf 'actool did not write %s (it needs Xcode 26 or later; see its output above, also in build/actool.log)\n' '$(APP)/Contents/Resources/Assets.car'; exit 1; }
	@plutil -replace CFBundleShortVersionString -string '$(VERSION)' '$(APP)/Contents/Info.plist'
	@cp runtime/dist/host.js runtime/dist/worker.js '$(APP)/Contents/Resources/runtime/'
	@# `fudge scan`'s scanner, and Raycast's types it reads, with their MIT notice.
	@cp runtime/dist/compat-scan.js '$(APP)/Contents/Resources/runtime/'
	@cp runtime/vendor/raycast-api/index.d.ts '$(APP)/Contents/Resources/runtime/raycast-api.d.ts'
	@cp runtime/vendor/raycast-api/LICENSE '$(APP)/Contents/Resources/runtime/raycast-api.LICENSE'
	@# The bundled extensions (BundledExtensions in core), each built like any other into a scratch folder and
	@# moved to Contents/Resources/<folder>. Their sources are runtime/<folder>; no source, no extension.
	@for folder in $(BUNDLED_EXTENSIONS); do \
		[ -f "runtime/$$folder/package.json" ] || continue; \
		scratch="$(abspath build)/$$folder-build" && rm -rf "$$scratch" && mkdir -p "$$scratch" && \
		FUDGE_ESBUILD='$(abspath $(ESBUILD))' '$(SWIFT_BIN)/fudge' build "runtime/$$folder" --into "$$scratch" \
			>/dev/null && \
		mv "$$scratch"/* "$(APP)/Contents/Resources/$$folder" && rm -rf "$$scratch" \
		|| { echo "make app: building runtime/$$folder failed"; exit 1; }; \
	done
	@# Each failure exits explicitly: make 3.81, the one macOS ships, ignores .SHELLFLAGS. No timestamp, so signing
	@# never goes over the network. An identity's errors stay visible, and the last line names it as listed.
	@identity='$(SIGN_IDENTITY)'; \
	if [ "$$identity" = - ]; then \
		codesign --force --sign - '$(APP)'/Contents/Helpers/* 2>/dev/null && codesign --force --sign - '$(APP)' 2>/dev/null && \
		signed='ad hoc'; \
	else \
		name=$$(security find-identity -v -p codesigning 2>/dev/null | \
			awk -F'"' -v id="$$identity" '{ split($$1, f, " ") } f[2] == id || $$2 == id { print $$2; exit }'); \
		{ codesign --force --timestamp=none --sign "$$identity" '$(APP)'/Contents/Helpers/* && \
			codesign --force --timestamp=none --sign "$$identity" '$(APP)'; } || \
			{ printf 'codesign could not sign with "%s" (see its error above)\n' "$${name:-$$identity}"; exit 1; }; \
		signed="with $${name:-$$identity}"; \
	fi && \
	printf '→ built %s (%s, %s, signed %s)\n' '$(APP)' '$(VERSION)' '$(CONFIG)' "$$signed"

# The user's fudge: Fudge processes launched as the app, by LaunchServices (their parent is launchd), with no
# arguments. `--snapshot` runs, key probes and test harnesses that agents start from a shell are left alone.
# A process whose shell has exited is re-parented to launchd too, so a detached Fudge started with no arguments
# counts as the user's: give anything you leave running an argument.
USER_FUDGE_PIDS = for pid in $$(pgrep -x Fudge); do \
		[ "$$(ps -o ppid= -p $$pid | tr -d ' ')" = 1 ] && [ "$$(ps -o args= -p $$pid)" = "$$(ps -o comm= -p $$pid)" ] \
			&& echo $$pid; \
	done; true

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

test-swift: runtime/node_modules
	@swift test

test-runtime: runtime/node_modules
	@cd runtime && npm test

lint: runtime/node_modules
	@swift format lint --strict --recursive Package.swift Sources Tests
	@cd runtime && npm run --silent typecheck

fmt:
	@swift format --in-place --recursive Package.swift Sources Tests

raycast-types:
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
