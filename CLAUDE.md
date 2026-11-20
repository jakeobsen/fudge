# CLAUDE.md

Guidance for AI coding agents working in this repository. User-facing docs are in README.md.

## What this is

fudge is a keyboard launcher for macOS, built to run extensions written for Raycast's `@raycast/api` without changing them. It is a native Swift app. Extensions run in a separate Node.js process, the extension host.

## Architecture

- **One Swift package, three targets.**
  - `FudgeApp` is the app: an accessory app with a menu bar item and no Dock icon.
  - `FudgeCLI` is the `fudge` command-line tool.
  - `FudgeCore` is shared code, and the only target with tests.

  Put logic in `FudgeCore`, where it can be tested. Keep the app and the tool thin.
- **The extension host lives in `runtime/`.** It's written in TypeScript. Tests run the `.ts` files directly through Node's type stripping, and esbuild bundles `src/host.ts` into `runtime/dist/host.cjs` for the app. The host talks to the app over stdin/stdout, one JSON message per line (`src/protocol.ts`).
- **The Makefile assembles the app bundle** (`make app`):
  - the `FudgeApp` binary becomes `Contents/MacOS/Fudge`
  - `App/Info.plist` gets the version from `git describe`
  - the host bundle goes into `Contents/Resources/runtime/`
  - the bundle is signed ad hoc
- **`runtime/vendor/raycast-api/index.d.ts` is Raycast's own type definitions** (MIT, notice alongside). It's the contract fudge implements. `make raycast-types` copies it unmodified from the `@raycast/api` release named by `RAYCAST_API_VERSION`. Never edit it by hand.

## Gotchas

- **Names must differ by more than case.** macOS file systems are case-insensitive, so no two products or targets may differ only by case. The tool's product is `fudge`, which is why the app's product is `FudgeApp`.
- **Runtime TypeScript must be erasable syntax only** (`erasableSyntaxOnly`), because tests run it through type stripping. That rules out enums, namespaces, parameter properties and JSX in `.ts` files. Relative imports carry the `.ts` extension.
- **`runtime/package.json` is `"type": "module"`**, so the CommonJS bundle has to be named `.cjs`.
- **npm may block install scripts.** esbuild works without its postinstall step, so don't approve it just to silence the warning.

## Commands

`make app` · `make run` · `make test` · `make lint` · `make fmt` · `make raycast-types`

## Conventions

- Swift for the app and the tool. TypeScript only in `runtime/`, because extensions are JavaScript.
- Docs describe what exists. No roadmaps, status tables or TODO lists in committed files.
- Conventional commits (`feat:`, `fix:`, `chore:`, `docs:`), scoped by area where it helps, e.g. `feat(runtime): ...`, `feat(app): ...`, `feat(cli): ...`.
- `AGPL-3.0-or-later` everywhere. Files taken from MIT-licensed upstream keep their notice next to them. New dependencies must be AGPL-compatible.
- Third-party GitHub Actions are pinned to commit SHAs, with the version in a trailing comment.
- fudge makes no network connections of its own: no updater, telemetry or crash reporting.
