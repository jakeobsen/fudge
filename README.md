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

macOS remembers the permissions you give fudge (Accessibility, Automation) by its code signature. `make app` signs ad hoc unless your keychain has a code-signing identity named **fudge local signing**, and an ad hoc signature changes with every build, so macOS forgets them each time. To create the identity once:

1. In Keychain Access, choose **Keychain Access → Certificate Assistant → Create a Certificate…**. Name it `fudge local signing`, with identity type **Self-Signed Root** and certificate type **Code Signing**.
2. Open the certificate, expand **Trust**, and set **Code Signing** to **Always Trust**.
3. Expand the certificate in **My Certificates**, open its private key, and under **Access Control** add `/usr/bin/codesign` to the allowed applications (⌘⇧G in the file dialog lets you type the path). Or answer codesign's first keychain prompt with **Always Allow**. Either way, later builds never stop at a keychain dialog.

`make app` then signs with it, and its last line says which identity it used. `make app SIGN_IDENTITY=-` builds ad hoc anyway.

Release builds are signed ad hoc. Until fudge has a Developer ID, you grant its permissions again after each update.

## Using it

Open fudge with ⌥Space, type to search applications and extension commands, and press ↵. Esc goes back, then hides the window.

To use another shortcut, put it in `~/Library/Application Support/fudge/settings.json`:

```json
{ "hotkey": "cmd+space" }
```

Shortcuts are modifiers (`cmd`, `option`, `ctrl`, `shift`) plus a key, joined with `+`.

Extensions' preferences are under **Settings…** in the fudge menu bar menu, or ⌘, in the fudge window. You can also search root search for "fudge Settings". To go straight to a command's extension, select the command and press ⌘⇧, (or ⌘K, then **Configure Extension**). A command that needs a preference you haven't set opens that window instead of running.

### Selected text and Finder items

Extensions can read the text selected in the app you were in, and the items selected in Finder. The first time, macOS asks you to allow fudge under **Privacy & Security → Accessibility** or **Automation**.

When an app doesn't share its selection through Accessibility (often browsers and Electron apps such as VS Code), fudge copies it with ⌘C and puts back what was on your clipboard right after. That has some side effects:

- A clipboard history app may record the copied text.
- If your clipboard holds a password that a password manager marked as concealed, fudge leaves the clipboard empty instead of putting the password back. Put back, it would look like a new copy, and the password manager would no longer clear it.
- Clipboard data over 50 MB (of one type) isn't put back. An app that only produces its clipboard data when asked (some design apps do this with large images) still has to produce it, so that can take a moment.
- An app that copies something when nothing is selected hands that over instead. VS Code, for example, copies the current line.

Secure text fields, such as passwords, never give their text.

## License

Copyright (C) 2026 Morten Jakobsen.

Licensed under the GNU Affero General Public License, version 3 or (at your option) any later version (`AGPL-3.0-or-later`). See [LICENSE](LICENSE).

`runtime/vendor/raycast-api/index.d.ts` contains the type definitions from the `@raycast/api` package. They are Copyright (c) 2021 Raycast and MIT-licensed; see [the notice next to them](runtime/vendor/raycast-api/LICENSE).
