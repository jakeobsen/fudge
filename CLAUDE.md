# CLAUDE.md

Guidance for AI coding agents working in this repository. User-facing docs are in README.md.

## What this is

fudge is a keyboard launcher for macOS, built to run extensions written for Raycast's `@raycast/api` without changing them. It is a native Swift app. Extensions run in a separate Node.js process, the extension host.

## Architecture

- **One Swift package, three targets.**
  - `FudgeApp` is the app: an accessory app with a menu bar item and no Dock icon.
    - `HotKey` registers the global shortcut through Carbon, which needs no Accessibility permission. It's `hotkey` in `settings.json` (`FudgeSettings`), default ⌥Space.
    - `LauncherPanel` is a non-activating `NSPanel`: it takes keys while the app you were in stays frontmost.
    - `LauncherModel` holds the panel's state. Root search ranks `ApplicationIndex` and installed commands with `RootSearch` (fuzzy match, then `LaunchHistory`). Commands run through `ExtensionHost`, and its messages update the screen.
    - `LauncherView` is the SwiftUI side.
    - `SettingsWindow.swift` is the Settings window: each extension's preferences, stored by `PreferenceStore` in `preferences/<extension>.json`. Before a launch, `PreferenceResolver` merges stored values, manifest defaults and type defaults. It turns appPicker references into Raycast `Application` objects, and the launch message carries the values to `getPreferenceValues()`. A command with an unset required preference opens this window instead of running.
  - `FudgeCLI` is the `fudge` command-line tool.
  - `FudgeCore` is shared code, and the only target with tests.

  Put logic in `FudgeCore`, where it can be tested. Keep the app and the tool thin.
- **The extension host lives in `runtime/`.** It's written in TypeScript. Tests run the `.ts` files directly through Node's type stripping, and esbuild bundles `src/host.ts` and `src/worker.ts` into `runtime/dist/` as ES modules, with production React.
  - **The protocol.** The app talks to `host.ts` over stdin/stdout, one JSON message per line, as typed and parsed in `src/protocol.ts`. Messages about a running command carry the `session` id the app chose when launching it. stdout carries nothing but the protocol: in the host, `console.log` goes to stderr, and a worker's output arrives as `log` messages.
  - **One worker thread per launch.** `worker.ts` intercepts `Module._load` so that `require("@raycast/api" | "react" | "react/jsx-runtime" | "react/jsx-dev-runtime")` gets the host's own modules. The extension and the renderer must share one React, or hooks break.
  - **The renderer** (`src/renderer/`) is a React 19 host config. Host instances are plain objects named after the component (`List.Item`, `ActionPanel.Section`, …). Commits are coalesced into one snapshot per event-loop turn, and only the top navigation view (a `$view` instance) is sent.
  - **Snapshot encoding.** Functions are sent as `{ "$fn": path }`, and the app calls one back with the node id and that path. Dates are sent as `{ "$date": iso }`. Element props (`actions`, `detail`, …) are rendered as `$slot` children and sent as nodes inside props.
  - **`@raycast/api` is `src/api/`.** `index.ts` exports what's implemented. `module.ts` wraps it so that any other Raycast export is a stub that throws `NotAvailableError` naming the API (e.g. `Clipboard.copy isn't available in fudge yet`). `scripts/raycast-types.ts` derives two files from the vendored types: the list of Raycast's exports (`src/api/raycast-exports.generated.ts`) and its enums with their values (`src/api/raycast-enums.generated.ts`: `Icon`, `Color`, `Action.Style`, …). `make raycast-types` regenerates them after updating the types, or run `npm run generate` by hand. `npm run typecheck` fails while either is stale.
  - **Calls into the app** go through `src/bridge.ts` (`callApp(method, params)`), which sends an `rpc` message and waits for the app's `rpcResult`.
- **`fudge build <folder>` installs an extension** (`ExtensionBuilder` in `FudgeCore`).
  - It reads `package.json` (`ExtensionManifest`) and compiles every command's `src/<name>.{tsx,ts,jsx,js}` with esbuild into `<extensions>/<name>/dist/<name>.cjs`. The modules the host provides (`ExtensionBuilder.providedModules`) stay external.
  - It copies `package.json` and `assets/` alongside, then swaps the whole folder into place.
  - It never writes into the source folder. When the source has no `node_modules`, it installs the dependencies into a temporary folder (`npm ci --ignore-scripts`) and points esbuild at it with `NODE_PATH`.
  - Extensions live in `FudgePaths.extensionsDirectory`: `~/Library/Application Support/fudge/extensions`, or under `$FUDGE_SUPPORT_DIR`.
- **The Makefile assembles the app bundle** (`make app`):
  - the `FudgeApp` binary becomes `Contents/MacOS/Fudge`
  - the `fudge` tool and esbuild's native binary go into `Contents/Helpers/`, where `ExtensionBuilder.locateEsbuild` finds esbuild next to the tool
  - `App/Info.plist` gets the version from `git describe`
  - `App/AppIcon.icon` (an Icon Composer icon) is compiled by `actool` into `Assets.car` and an `AppIcon.icns` fallback. That needs Xcode 26 or later.
  - the host and worker bundles go into `Contents/Resources/runtime/`
  - the helpers and the bundle are signed ad hoc
- **`runtime/vendor/raycast-api/index.d.ts` is Raycast's own type definitions** (MIT, notice alongside). It's the contract fudge implements. `make raycast-types` copies it unmodified from the `@raycast/api` release named by `RAYCAST_API_VERSION`. Never edit it by hand.

## Gotchas

- **Names must differ by more than case.** macOS file systems are case-insensitive, so no two products or targets may differ only by case. The tool's product is `fudge`, which is why the app's product is `FudgeApp`.
- **Runtime TypeScript must be erasable syntax only** (`erasableSyntaxOnly`), because tests run it through type stripping. That rules out enums, namespaces, parameter properties and JSX in `.ts` files. Relative imports carry the `.ts` extension.
- **Compiled extension commands are CommonJS.** The worker loads them with `require`, which is the only way `Module._load` can hand them fudge's modules.
- **Apps opened from Finder don't get the shell's `PATH`.** That's why `Runtime.locateNode` checks `$FUDGE_NODE`, `Contents/Helpers`, Homebrew and `/usr/local` before `PATH`.
- **Check the panel's layout without showing it:** `build/Fudge.app/Contents/MacOS/Fudge --snapshot out.png [--query text] [--activate]`. It renders the panel off-screen and transparent, never key, then saves a PNG and quits. The window blur doesn't render in snapshots.
- **Swift tests that build extensions need esbuild** from `runtime/node_modules`. `make test` installs it; without it, `swift test` skips those tests.
- **npm may block install scripts.** esbuild works without its postinstall step, so don't approve it just to silence the warning.

## Commands

`make app` · `make run` · `make install-extension DIR=<folder>` · `make test` · `make lint` · `make fmt` · `make raycast-types`

## Conventions

- Swift for the app and the tool. TypeScript only in `runtime/`, because extensions are JavaScript.
- Docs describe what exists. No roadmaps, status tables or TODO lists in committed files.
- Conventional commits (`feat:`, `fix:`, `chore:`, `docs:`), scoped by area where it helps, e.g. `feat(runtime): ...`, `feat(app): ...`, `feat(cli): ...`.
- `AGPL-3.0-or-later` everywhere. Files taken from MIT-licensed upstream keep their notice next to them. New dependencies must be AGPL-compatible.
- Third-party GitHub Actions are pinned to commit SHAs, with the version in a trailing comment.
- fudge makes no network connections of its own: no updater, telemetry or crash reporting.

## CI and releases

- **CI** (`.github/workflows/ci.yml`) runs `make lint` and `make test` on pull requests and pushes to `mainline`. `swift test` compiles every target, so the app's code is checked, but the app bundle is not assembled.
- **The release workflow** (`.github/workflows/release.yml`) is the only place the app bundle gets built. It runs on a pushed `v*` tag: tests, then `make app CONFIG=release VERSION=<tag>`, then the bundle zipped with `ditto` and uploaded as a workflow artifact.
