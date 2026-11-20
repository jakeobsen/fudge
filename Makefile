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
SWIFT_BIN  = $(shell swift build -c $(CONFIG) --show-bin-path)
# esbuild's native binary, installed with the extension host's dependencies.
ESBUILD    = $(firstword $(wildcard runtime/node_modules/@esbuild/darwin-*/bin/esbuild))

# The @raycast/api release whose type definitions live in runtime/vendor/raycast-api.
RAYCAST_API_VERSION ?= 2.13.1

.PHONY: help app run install-extension build runtime test test-swift test-runtime lint fmt raycast-types compat-scan clean

help:
	@printf 'fudge — a keyboard launcher for macOS, built to run Raycast extensions\n\n'
	@printf 'Usage: make <target>\n\n'
	@printf '  help           Show this help (default).\n'
	@printf '  app            Build %s (CONFIG=debug|release, now: %s).\n' '$(APP)' '$(CONFIG)'
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
	@codesign --force --sign - '$(APP)'/Contents/Helpers/* 2>/dev/null
	@codesign --force --sign - '$(APP)' 2>/dev/null
	@printf '→ built %s (%s, %s)\n' '$(APP)' '$(VERSION)' '$(CONFIG)'

run: app
	@pkill -x Fudge 2>/dev/null || true
	@# open hands off to a Fudge that's still quitting and fails (-600), so wait for it to exit.
	@for _ in $$(seq 50); do pgrep -x Fudge >/dev/null || break; sleep 0.1; done
	@! pgrep -x Fudge >/dev/null || { printf 'the running Fudge did not quit\n'; exit 1; }
	@open '$(APP)'

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
