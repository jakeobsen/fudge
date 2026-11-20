# fudge

A keyboard launcher for macOS, built to run extensions written for Raycast's [`@raycast/api`](https://developers.raycast.com).

fudge is an independent project. It is not affiliated with or endorsed by Raycast.

## What's here

- `Sources/FudgeApp`: the macOS app. It runs in the menu bar, without a Dock icon.
- `Sources/FudgeCLI`: the `fudge` command-line tool. `fudge build <folder>` compiles the Raycast extension in `<folder>` and installs it for fudge.
- `Sources/FudgeCore`: code shared by the app and the tool.
- `runtime/`: the extension host. This is the Node.js program that runs extensions. The app talks to it over stdin/stdout.

## Building

You need macOS 14 or later, Xcode 26 or later and Node.js 22.18 or later. The app runs on macOS 14 and later.

```bash
make app     # build build/Fudge.app
make run     # build it and open it
make test    # run the Swift and extension host tests
make lint    # check formatting and types

make install-extension DIR=path/to/extension   # compile and install an extension
```

`make help` lists every target.

## Using it

Open fudge with ⌥Space, type to search applications and extension commands, and press ↵. Esc goes back, then hides the window.

To use another shortcut, put it in `~/Library/Application Support/fudge/settings.json`:

```json
{ "hotkey": "cmd+space" }
```

Shortcuts are modifiers (`cmd`, `option`, `ctrl`, `shift`) plus a key, joined with `+`. An F-key may stand alone (`f5`).

### Command hotkeys

Any command can have its own hotkey. Open **Settings…** on the **Commands** page, click **Record Hotkey** next to the command, and press the shortcut. Esc cancels, and ⌫ removes it. A hotkey needs ⌘, ⌥ or ⌃, unless it's an F-key. Pressing it anywhere opens the command as root search would: a view command shows the fudge window, a no-view command just runs, and a command with a required argument shows root search with that field ready. Pressing a view command's hotkey again while it's on screen hides the window.

fudge refuses a shortcut that's its own (⌥Space) or another command's, and one another app has registered. That last check is best-effort: macOS doesn't report system shortcuts such as ⌘Space or ⌃↑, so one of those can be recorded but never fire. Hotkeys are kept in `settings.json` under `commands`, e.g. `{ "commands": { "scratch/scratch-folders": { "hotkey": "option+s" } } }`. fudge keeps anything else you put in that file.

Extensions' preferences are under **Settings…** in the fudge menu bar menu, or ⌘, in the fudge window. You can also search root search for "fudge Settings". To go straight to a command's extension, select the command and press ⌘⇧, (or ⌘K, then **Configure Extension**). A command that needs a preference you haven't set opens that window instead of running.

## License

Copyright (C) 2026 Morten Jakobsen.

Licensed under the GNU Affero General Public License, version 3 or (at your option) any later version (`AGPL-3.0-or-later`). See [LICENSE](LICENSE).

`runtime/vendor/raycast-api/index.d.ts` contains the type definitions from the `@raycast/api` package. They are Copyright (c) 2021 Raycast and MIT-licensed; see [the notice next to them](runtime/vendor/raycast-api/LICENSE).
