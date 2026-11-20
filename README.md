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

### Keeping permissions across builds

macOS remembers the permissions you give fudge (Accessibility, Automation) by its code signature. An ad hoc signature changes with every build, so macOS would forget them each time. `make app` signs with the first of these that your keychain has:

1. a code-signing identity named **fudge local signing**;
2. an **Apple Development** identity, which Xcode creates when you add your Apple Account under **Xcode → Settings → Accounts**;
3. otherwise none: it signs ad hoc.

Its last line says which identity it used. `make app SIGN_IDENTITY=-` builds ad hoc anyway, and `SIGN_IDENTITY=<name>` picks another identity.

**The first build that signs with an identity shows a keychain prompt** ("codesign wants to sign using key … in your keychain"). Enter your login password and click **Always Allow**, once. Otherwise every later build stops at that prompt, and a build nobody is watching hangs on it.

Without an Apple Development identity, you can create the self-signed one:

1. In Keychain Access, choose **Keychain Access → Certificate Assistant → Create a Certificate…**. Name it `fudge local signing`, with identity type **Self-Signed Root** and certificate type **Code Signing**.
2. Open the certificate, expand **Trust**, and set **Code Signing** to **Always Trust**.
3. Expand the certificate in **My Certificates**, open its private key, and under **Access Control** add `/usr/bin/codesign` to the allowed applications (⌘⇧G in the file dialog lets you type the path). Or answer the first build's prompt with **Always Allow**, as above.

Release builds are signed ad hoc. Until fudge has a Developer ID, you grant its permissions again after each update.

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

### Aliases and turning commands off

On the same page, a command can have an **Alias**: a short word such as `sf`. Click the Alias cell, type it, and press ↵ (Esc puts back what was there, and an empty alias removes it). An alias is 1 to 32 characters with no spaces, and two commands can't share one (letter case doesn't count). Typing the alias in root search puts its command first, above a calculator result. For a command with arguments, typing the alias and a space moves to its first argument field, and the rest of what you type goes there.

Untick **Enabled** to turn a command off, or a whole extension. A command that's off isn't in root search, its hotkey doesn't fire, and other extensions can't launch it; its alias and hotkey are kept for when you turn it back on. Both are kept in `settings.json`, e.g. `{ "commands": { "scratch/scratch-folders": { "alias": "sf", "enabled": false } }, "extensions": { "scratch": { "enabled": false } } }`.

Extensions' preferences are under **Settings…** in the fudge menu bar menu, or ⌘, in the fudge window. You can also search root search for "fudge Settings". To go straight to a command's extension, select the command and press ⌘⇧, (or ⌘K, then **Configure Extension**). A command that needs a preference you haven't set opens that window instead of running.

### Selected text and Finder items

Extensions can read the text selected in the app you were in, and the items selected in Finder. The first time, macOS asks you to allow fudge under **Privacy & Security → Accessibility** or **Automation**.

When an app doesn't share its selection through Accessibility (often browsers and Electron apps such as VS Code), fudge copies it with ⌘C and puts back what was on your clipboard right after. That has some side effects:

- A clipboard history app may record the copied text.
- If your clipboard holds a password that a password manager marked as concealed, fudge leaves the clipboard empty instead of putting the password back. Put back, it would look like a new copy, and the password manager would no longer clear it.
- Clipboard data over 50 MB (of one type) isn't put back. An app that only produces its clipboard data when asked (some design apps do this with large images) still has to produce it, so that can take a moment.
- An app that copies something when nothing is selected hands that over instead. VS Code, for example, copies the current line.
- fudge waits half a second for the copy. An app that answers ⌘C later than that copies after fudge has put your clipboard back, so the selected text ends up on your clipboard.

Secure text fields, such as passwords, never give their text.

## License

Copyright (C) 2026 Morten Jakobsen.

Licensed under the GNU Affero General Public License, version 3 or (at your option) any later version (`AGPL-3.0-or-later`). See [LICENSE](LICENSE).

`runtime/vendor/raycast-api/index.d.ts` contains the type definitions from the `@raycast/api` package. They are Copyright (c) 2021 Raycast and MIT-licensed; see [the notice next to them](runtime/vendor/raycast-api/LICENSE).
