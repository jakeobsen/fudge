# fudge

A keyboard launcher for macOS, built to run extensions written for Raycast's [`@raycast/api`](https://developers.raycast.com).

fudge is an independent project. It is not affiliated with or endorsed by Raycast.

## What's here

- `Sources/FudgeApp`: the macOS app. It runs in the menu bar, without a Dock icon.
- `Sources/FudgeCLI`: the `fudge` command-line tool. `fudge build <folder>` compiles the Raycast extension in `<folder>` and installs it for fudge; `--into <folder>` installs it in that extensions folder instead.
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

What the fudge menu bar menu does is in root search too: "fudge Settings", **Reload Extensions** (reads the extensions and applications again) and **Quit fudge** (asks first, since fudge's hotkeys stop working until you open it again).

To use another shortcut, open **Settings…** on the **General** page, click the keys next to **Launcher hotkey**, and press the new shortcut. Esc cancels. A shortcut needs ⌘, ⌥ or ⌃, unless it's an F-key. The launcher always has a hotkey, so ⌫ (or **Reset to ⌥Space**) puts ⌥Space back. fudge refuses a shortcut that a command already has, and keeps the old one when another app has the new one. If another app already holds the launcher's hotkey when fudge starts, the General page says so, and the menu bar menu's **Open fudge** still works.

### Command hotkeys

Any command can have its own hotkey. Open **Settings…** on the **Commands** page, click **Record Hotkey** next to the command, and press the shortcut. Esc cancels, and ⌫ removes it. A hotkey needs ⌘, ⌥ or ⌃, unless it's an F-key. Pressing it anywhere opens the command as root search would: a view command shows the fudge window, a no-view command just runs, and a command with a required argument shows root search with that field ready. Pressing a view command's hotkey again while it's on screen hides the window.

fudge refuses a shortcut that's the launcher's or another command's, and one another app has registered. That last check is best-effort: macOS doesn't report system shortcuts such as ⌘Space or ⌃↑, so one of those can be recorded but never fire.

### Aliases and turning commands off

On the same page, a command can have an **Alias**: a short word such as `sf`. Click the Alias cell, type it, and press ↵ (Esc puts back what was there, and an empty alias removes it). An alias is 1 to 32 characters with no spaces, and two commands can't share one (letter case doesn't count). Typing the alias in root search puts its command first, above a calculator result. For a command with arguments, typing the alias and a space moves to its first argument field, and the rest of what you type goes there.

Untick **Enabled** to turn a command off, or a whole extension. A command that's off isn't in root search, its hotkey doesn't fire, and other extensions can't launch it; its alias and hotkey are kept for when you turn it back on.

**Settings…** in the fudge menu bar menu, ⌘, in the fudge window, and "fudge Settings" in root search open the Settings window on its **General** page. Extensions' preferences are in the same window, under each extension. To go straight to a command's extension, select the command and press ⌘⇧, (or ⌘K, then **Configure Extension**). A command that needs a preference you haven't set opens that window instead of running.

### Open at Login and search history

fudge doesn't start at login until you turn on **Open at Login** at the top of **Settings… → General**. macOS then shows a "Login item added" notification, and lists fudge under **System Settings → General → Login Items**, where you can also turn it off; the switch shows what's set there. If macOS asks you to allow it first, the page says so and **Open Login Items** takes you there. The login item is tied to where the app is, so after moving fudge (to `/Applications`, say), turn Open at Login off and on again.

Root search ranks what you open often first. **Clear Search History…** on the same page makes it forget, after asking.

### Extensions that open other extensions

The first time an extension opens another extension's command, fudge asks whether to allow it, and remembers the answer. To change or forget an answer, open **Settings…** → **General** → **Extensions that open other extensions**: pick **Allowed** or **Not allowed**, or click × to be asked again next time.

### Calculator and currency

Type a calculation in root search and the answer shows above the results: arithmetic (`5+5/10*39`), units (`13kg to lbs`), time zones (`3pm cet in pst`) and currencies (`100 usd to eur`, `€100 in usd`, `100 € in kr`). ↵ copies the answer.

Currency conversion is off until you turn it on under **Settings… → General**, because it needs exchange rates from the network. Until then, a currency query shows a card saying so, and ↵ on it opens that page.

### Network

fudge makes no connections of its own, with one exception you turn on yourself: with currency conversion on, it downloads the European Central Bank's daily reference rates (`https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml`). It downloads that one public file when you turn the setting on, then when the rates are a day old, at most once every 12 hours. Like any download, the server sees your IP address, and nothing else is sent: no cookies and no identifier beyond `fudge/<version>` as the user agent. The rates are kept in `exchange-rates.json` in the support folder. Turning the setting off stops the downloads. Extensions make their own connections, as they do in Raycast.

**The Extension Store** is the other exception, and it's off until you turn it on under **Settings… → General** and confirm what it does. While it's on, fudge connects to GitHub (github.com and its image servers) to download the list of extensions in the open-source repository github.com/raycast/extensions, the extensions you install, and their pictures, and npm downloads those extensions' packages from registry.npmjs.org. fudge never contacts Raycast's servers. Turning the store off deletes its downloaded list; extensions you installed stay installed.

### Selected text and Finder items

Extensions can read the text selected in the app you were in, and the items selected in Finder. The first time, macOS asks you to allow fudge under **Privacy & Security → Accessibility** or **Automation**.

When an app doesn't share its selection through Accessibility (often browsers and Electron apps such as VS Code), fudge copies it with ⌘C and puts back what was on your clipboard right after. That has some side effects:

- A clipboard history app may record the copied text.
- If your clipboard holds a password that a password manager marked as concealed, fudge leaves the clipboard empty instead of putting the password back. Put back, it would look like a new copy, and the password manager would no longer clear it.
- Clipboard data over 50 MB (of one type) isn't put back. An app that only produces its clipboard data when asked (some design apps do this with large images) still has to produce it, so that can take a moment.
- An app that copies something when nothing is selected hands that over instead. VS Code, for example, copies the current line.
- fudge waits half a second for the copy. An app that answers ⌘C later than that copies after fudge has put your clipboard back, so the selected text ends up on your clipboard.

Secure text fields, such as passwords, never give their text.

### Pasting

Extensions can paste into the app you were in (`Clipboard.paste`, the Paste action). fudge puts the content on your clipboard, presses ⌘V in that app, and puts back what was on your clipboard about a second later. It needs the same Accessibility permission. Without it, the content stays on your clipboard for you to paste yourself.

- fudge marks what it puts on the clipboard as transient, so clipboard history apps that follow [nspasteboard.org](http://nspasteboard.org) skip it.
- If you copy something within that second, fudge leaves your new copy alone.
- If your clipboard held a password that a password manager marked as concealed, fudge leaves the clipboard empty instead of putting the password back, for the same reason as above.
- Apps that read the clipboard late, such as virtual machines or remote desktops that sync it, may paste what fudge put back instead of the content.

## License

Copyright (C) 2026 Morten Jakobsen.

Licensed under the GNU Affero General Public License, version 3 or (at your option) any later version (`AGPL-3.0-or-later`). See [LICENSE](LICENSE).

`runtime/vendor/raycast-api/index.d.ts` contains the type definitions from the `@raycast/api` package. They are Copyright (c) 2021 Raycast and MIT-licensed; see [the notice next to them](runtime/vendor/raycast-api/LICENSE).
