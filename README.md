# Fudge

A Raycast-compatible keyboard launcher for your Mac. It runs extensions written for Raycast's [`@raycast/api`](https://developers.raycast.com).

Fudge is an independent project. It is not affiliated with or endorsed by Raycast.

## What's here

- `Sources/FudgeApp`: the macOS app. It runs in the menu bar, without a Dock icon.
- `Sources/FudgeCLI`: the `fudge` command-line tool. `fudge build <folder>` compiles the Raycast extension in `<folder>` and installs it for Fudge; `--into <folder>` installs it in that extensions folder instead. `fudge scan <folder>` says what the extension uses that Fudge doesn't have yet, without building it (`--json` for a script). A running Fudge picks up an extension you install, rebuild or remove within a second, with nothing to reload.
- `Sources/FudgeCore`: code shared by the app and the tool.
- `runtime/`: the extension host. This is the Node.js program that runs extensions. The app talks to it over stdin/stdout.
- `runtime/store-extension/`: the Extension Store, an extension bundled with Fudge that lists and installs the extensions published in github.com/raycast/extensions.
- `runtime/file-search-extension/`: Search Files, an extension bundled with Fudge that finds files and folders by name.
- `runtime/emoji-extension/`: Search Emoji & Symbols, an extension bundled with Fudge that finds emoji by name and pastes them.
- `runtime/clipboard-history-extension/`: Clipboard History, an extension bundled with Fudge that lists what you copied.

## Installing

Each release on GitHub has a disk image, `Fudge-<version>.dmg`: open it and drag Fudge to Applications. Fudge isn't notarized yet, so macOS blocks it the first time: open it, then go to System Settings → Privacy & Security and click Open Anyway (on macOS 14, Control-click Fudge and choose Open instead).

## Building

You need macOS 14 or later, Xcode 26 or later and Node.js 22.18 or later. The app runs on macOS 14 and later.

```bash
make app     # build build/Fudge.app
make dmg     # build it into a disk image, build/Fudge-<version>.dmg
make run     # build it and open it
make test    # run the Swift and extension host tests
make lint    # check formatting and types

make install-extension DIR=path/to/extension   # compile and install an extension
```

`make help` lists every target.

### Keeping permissions across builds

macOS remembers the permissions you give Fudge (Accessibility, Automation) by its code signature. An ad hoc signature changes with every build, so macOS would forget them each time. `make app` signs with the first of these that your keychain has:

1. a code-signing identity named **fudge local signing**;
2. an **Apple Development** identity, which Xcode creates when you add your Apple Account under **Xcode → Settings → Accounts**;
3. otherwise none: it signs ad hoc.

Its last line says which identity it used. `make app SIGN_IDENTITY=-` builds ad hoc anyway, and `SIGN_IDENTITY=<name>` picks another identity.

**The first build that signs with an identity shows a keychain prompt** ("codesign wants to sign using key … in your keychain"). Enter your login password and click **Always Allow**, once. Otherwise every later build stops at that prompt, and a build nobody is watching hangs on it.

Without an Apple Development identity, you can create the self-signed one:

1. In Keychain Access, choose **Keychain Access → Certificate Assistant → Create a Certificate…**. Name it `fudge local signing`, with identity type **Self-Signed Root** and certificate type **Code Signing**.
2. Open the certificate, expand **Trust**, and set **Code Signing** to **Always Trust**.
3. Expand the certificate in **My Certificates**, open its private key, and under **Access Control** add `/usr/bin/codesign` to the allowed applications (⌘⇧G in the file dialog lets you type the path). Or answer the first build's prompt with **Always Allow**, as above.

Release builds are signed ad hoc. Until Fudge has a Developer ID, you grant its permissions again after each update.

## Using it

Open Fudge with ⌥Space, type to search applications and extension commands, and press ↵. Esc goes back, then hides the window.

Extensions run with your permissions, and while they run they can reach each other's data, as in Raycast. Install the ones you trust.

When you open Fudge again within 90 seconds, it's as you left it. After longer, it starts over on an empty root search. **Pop to Root Search** on the **General** page of **Settings…** sets how long: Immediately, after 30 seconds, 1 minute or 90 seconds, or Never. Only the time the window is closed counts.

**Show Fudge on**, on the same page, picks the screen Fudge opens on: the one with the mouse (the default), the primary screen, or the one with the app you're using. **Escape Key Behavior** picks what Esc does: by default it clears the search, then goes back, then closes the window; with "Close window and pop to root", Esc closes the window at once, and Fudge opens on an empty root search next time.

What the Fudge menu bar menu does is in root search too: "Fudge Settings", **Reload Extensions** (reads the extensions and applications again) and **Quit Fudge** (asks first, since Fudge's hotkeys stop working until you open it again).

To use another shortcut, open **Settings…** on the **General** page, click the keys next to **Launcher hotkey**, and press the new shortcut. Esc cancels. A shortcut needs ⌘, ⌥ or ⌃, unless it's an F-key. The launcher always has a hotkey, so ⌫ (or **Reset to ⌥Space**) puts ⌥Space back. Fudge refuses a shortcut that a command already has, and keeps the old one when another app has the new one. If another app already holds the launcher's hotkey when Fudge starts, the General page says so, and the menu bar menu's **Open Fudge** still works.

### Command hotkeys

Any command can have its own hotkey. Open **Settings…** on the **Commands** page, click **Record Hotkey** next to the command, and press the shortcut. Esc cancels, and ⌫ removes it. A hotkey needs ⌘, ⌥ or ⌃, unless it's an F-key. Pressing it anywhere opens the command as root search would: a view command shows the Fudge window, a no-view command just runs, and a command with a required argument shows root search with that field ready. Pressing a view command's hotkey again while it's on screen hides the window.

Fudge refuses a shortcut that's the launcher's or another command's, and one another app has registered. That last check is best-effort: macOS doesn't report system shortcuts such as ⌘Space or ⌃↑, so one of those can be recorded but never fire.

### Aliases and turning commands off

On the same page, a command can have an **Alias**: a short word such as `sf`. Click the Alias cell, type it, and press ↵ (Esc puts back what was there, and an empty alias removes it). An alias is 1 to 32 characters with no spaces, and two commands can't share one (letter case doesn't count). Typing the alias in root search puts its command first, above a calculator result. For a command with arguments, typing the alias and a space moves to its first argument field, and the rest of what you type goes there.

Untick **Enabled** to turn a command off, or a whole extension. A command that's off isn't in root search, its hotkey doesn't fire, and other extensions can't launch it; its alias and hotkey are kept for when you turn it back on. A menu bar command that's off leaves the menu bar, and comes back when you turn it on again.

**Settings…** in the Fudge menu bar menu, ⌘, in the Fudge window, and "Fudge Settings" in root search open the Settings window on its **General** page. Extensions' preferences are in the same window, under each extension. To go straight to a command's extension, select the command and press ⌘⇧, (or ⌘K, then **Configure Extension**). A command that needs a preference you haven't set opens that window instead of running.

### First run

The first time Fudge starts, it walks you through a few choices: the launcher hotkey, Accessibility, Open at Login, currency conversion and how often to check for updates. Each takes effect at once, and **Settings…** has them all. Until you click **Start Using Fudge** at the end, Fudge shows these steps again at its next start, from where you left off.

**Settings… → Permissions** shows whether Fudge may use Accessibility, which extensions need to read the text you've selected, to paste, or to move windows. **Open Accessibility Settings** lets macOS ask you first; if it doesn't ask, click it again to open **System Settings → Privacy & Security → Accessibility** and turn Fudge on there. **Show Onboarding Again** goes through the first-run choices again.

### Open at Login and search history

Fudge doesn't start at login until you turn on **Open at Login** at the top of **Settings… → General**. macOS then shows a "Login item added" notification, and lists Fudge under **System Settings → General → Login Items**, where you can also turn it off; the switch shows what's set there. If macOS asks you to allow it first, the page says so and **Open Login Items** takes you there. The login item is tied to where the app is, so after moving Fudge (to `/Applications`, say), turn Open at Login off and on again.

Root search ranks what you open often first. **Clear Search History…** on the same page makes it forget, after asking.

### Extensions that open other extensions

The first time an extension opens another extension's command, Fudge asks whether to allow it, and remembers the answer. To change or forget an answer, open **Settings…** → **Permissions** → **Extensions that open other extensions**: pick **Allowed** or **Not allowed**, or click × to be asked again next time.

An extension running in the background, such as a menu bar refresh, never interrupts you to ask: Fudge says so once, and asks the next time you open that extension.

### Backup: import and export

**Settings… → General → Import / Export** saves everything you've set up in Fudge to one file, and brings it back, on this Mac or another one.

- **Export…** asks for a password (at least 8 characters), then where to save `fudge-backup-<date>.fudgebackup`. The file holds Fudge's settings (hotkeys, aliases, which commands are on), your quicklinks and snippets, the answers about extensions opening other extensions, root search's ranking, every extension's preferences and data, and the list of installed extensions. It's always encrypted with your password, because extensions keep passwords and tokens in there; Fudge can't recover a forgotten one. The file opens only in Fudge, not with Apple's `aea` tool. Extension data over 100 MB in total leaves out the biggest extensions' data, and the export says which.
- **Import…** (also **Restore from a Backup…** on the Welcome screen Fudge shows the first time) asks for the file and its password, shows what's in it, and replaces your settings and the data of the extensions in the backup; other extensions keep theirs. The summary also lists the backup's extensions that changed since it was made (a new version, an update from the Extension Store, or installed another way); they're imported all the same. It then lists the extensions in the backup that aren't installed here, so you can reinstall them. It installs nothing itself.
- **The extensions themselves aren't in a backup**, only the list, and neither are caches, the exchange rates, your sign-ins, the sign-in server or the Extension Store's switch (set these again yourself).
- Before importing, Fudge saves what it's about to replace in `backups/` in its support folder (`~/Library/Application Support/fudge/backups`), readable by you only. It keeps the last 3. You can import one of those with **Import…**; it needs no password.

### Quicklinks

A quicklink is a saved link that opens from root search: a web page, an app's link (`slack://…`) or a folder (`~/Downloads`), in the app you chose for it or the default one. Type its name and press ↵.

To make one, open **Create Quicklink** from root search, fill in its name, link and the app it opens with, and press ⌘↵. Extensions can offer to make one too (**Create Quicklink** in their ⌘K), which opens the same form, filled in. **Settings → Quicklinks** lists them all, to add, change or delete one.

A link can have fields, filled in after its name like a command's arguments: `https://jira.example.com/browse/{argument name="ticket"}`. `{argument name="q" default="news"}` has a default, and `{argument name="kind" options="bug, task"}` is a list to pick from. `{clipboard}`, `{uuid}`, `{date}`, `{time}` and `{datetime}` fill themselves in; something a password manager copied is never used. In a web link, what's filled in is encoded for the URL, unless the placeholder ends in `| raw`. `| uppercase`, `| lowercase` and `| trim` change it first.

⌘K on a quicklink offers **Copy Link** (⇧⌘C), **Edit Quicklink…** (⌘E) and **Delete Quicklink…** (⌃X).

### Snippets

A snippet is text you use often, such as an address or a reply, saved to paste anywhere. Open **Search Snippets** from root search, pick one and press ↵: Fudge pastes it into the app you were in. ⌘↵ copies it instead, ⌘E edits it and ⌃X deletes it.

To make one, open **Create Snippet**, give it a name and its text, and press ⌘↵. Extensions can offer to make one too (**Create Snippet** in their ⌘K). **Settings → Snippets** lists them all, to add, change or delete one.

A snippet's text can fill itself in: `{clipboard}`, `{date}`, `{time}`, `{datetime}`, `{day}` and `{uuid}`, changed by `| uppercase`, `| lowercase` or `| trim`, and `{date format="yyyy-MM-dd"}` picks a date's format. `{cursor}` marks where the cursor ends up after pasting. These names are always filled in, wherever they appear, as in Raycast; any other text in braces, such as code or JSON, is pasted as it is. A snippet can also have a keyword, such as `;addr`, which Search Snippets finds it by. No keyword can contain another.

### Calculator and currency

Type a calculation in root search and the answer shows above the results: arithmetic (`5+5/10*39`), units (`13kg to lbs`), time zones (`3pm cet in pst`) and currencies (`100 usd to eur`, `€100 in usd`, `100 € in kr`). ↵ copies the answer.

Numbers follow your Mac's number format, or the one you pick under **Settings… → General → Number format**: "1,234.5" or "1.234,5". In "1.234,5", `1.000 + 1` is 1.001, and `1.5` isn't a number, so it gets no answer rather than a wrong one.

Currency conversion uses the European Central Bank's daily exchange rates. Turn it on under **Settings… → General**; until then, a currency query shows a card that takes you there.

### Updates

Fudge can check for a new version daily, weekly or monthly. Pick how often when Fudge first starts, or under **Settings… → General → Check for Updates** (Never turns it off); until you pick, it doesn't check. **Check Now** on the same page, or **Check for Updates…** in the menu bar menu, checks at once.

When there's a new version, Fudge says so once, the General page shows it with **Download…**, and the menu bar menu shows it at the top. Both open the release's page on GitHub. Fudge never downloads or installs anything by itself.

### Search Files

**Search Files** finds files and folders by name with Spotlight. Type part of a name; with nothing typed, it lists the files you used in the last 30 days.

- ↵ opens the file, ⌘↵ shows it in Finder, ⌘Y previews it with Quick Look, and ⌘O opens it with another app.
- ⌘⇧C copies its path, ⌘⌥C copies the file, and ⌃X moves it to the Trash, after asking.
- ⌘⇧D shows or hides the details.

In **Settings… → Search Files**, **Search In** picks your home folder (the default) or the whole Mac, and **Leave Out** lists folders to skip, separated by commas (`~/Library` by default).

### Emoji

**Search Emoji & Symbols** finds an emoji by its name or a keyword ("thumbs", "+1", "heart"). ↵ pastes it into the app you were in, ⌘↵ copies it, and ⌘⇧C copies its name. The ones you use most recently come first, under **Recently Used**. It shows the emoji your Mac can draw.

In **Settings… → Search Emoji & Symbols**, **Skin Tone** picks the tone for the emoji that have one.

### Clipboard History

**Clipboard History** keeps what you copy, so you can search it and paste it again. It's off until you turn on **Keep Clipboard History** in **Settings… → Clipboard History**. The history is encrypted on this Mac, and copies that password managers mark as private aren't kept. Extensions can read it, as in Raycast.

- ↵ pastes a copy into the app you're in, and ⌘↵ copies it. ⇧⌘P pins it, so it's kept however old it gets.
- ⌃X deletes a copy, and ⌃⇧X deletes them all, after asking.

On the same page, **Keep For** sets how long copies are kept (7 days by default), **Ignore Apps** lists apps whose copies aren't kept, and **Clear History…** deletes everything. Turning the switch off asks whether to keep or delete what's there.

### Extension Store

The Extension Store browses the extensions in Raycast's open-source repository and installs the ones you choose. It takes two steps:

1. Enable **Extension Store** under **Settings… → Commands**, and it shows up in Fudge.
2. Turn it on with the switch at the top of **Settings… → Extension Store**.

Turning it off removes the store's downloaded list; the extensions you installed stay installed.

In the **Extension Store** command, search the extensions, or pick a category in the dropdown; **Installed** shows the ones you installed from it.

- ↵ installs one, after saying whether Fudge supports everything it uses. ⌘U updates one marked **Update available**, and ⌃X uninstalls it, to the Trash.
- ⌘D shows an extension's details, with each command and whether it opens a view, runs without one, or sits in the menu bar, and its README. ⌘R updates the list, which otherwise happens when you open the store and the list is a day old. If the list couldn't be downloaded, ⌘R tries again.
- The store needs Git. If it's missing, install Apple's Command Line Tools: run `xcode-select --install` in Terminal.
- It never touches extensions you installed with `fudge build` yourself. An extension installs under its own name, so it can't be installed while another extension of that name is: uninstall that one first.

### Signing in

Some extensions sign in to a service, such as GitHub or Linear. Pick a sign-in server under **Settings… → Sign-in**: **Fudge's sign-in server**, or **Your own server…**. A company can run its own with [fudge-oauth](https://github.com/jakeobsen/fudge-oauth). When an extension needs to sign in, Fudge shows **Sign in to** the service, and ↵ continues in your browser. Sign-ins are kept in your Keychain, and the Sign-in page lists them, each with **Sign Out**. Changing the server signs you out of everything.

Extensions trust the certificates your Mac trusts, so a server behind your company's own certificate works as it does in Safari.

An extension that takes a token in its settings (⌘⇧,) works without signing in.

### Menu bar commands

An extension's menu bar command puts its own item in the menu bar. Run it from root search to turn it on, and the item stays there, across restarts, until you select the command in root search and pick **Deactivate Menu Bar Item** from ⌘K. Running it again from root search refreshes it and opens its menu. The command refreshes itself in the background at Fudge's start and as often as its extension asks, and again each time you open its menu. When a background refresh fails, the item keeps what it showed last and its menu ends with "⚠ Last refresh failed". Fudge shows at most 50 of these items.

### Window management

Fudge can move and resize the window you're using: halves, quarters, thirds and two thirds, Maximize (also Almost Maximize, Maximize Width and Maximize Height), Center, Reasonable Size, Make Larger and Make Smaller, Next and Previous Display, and Toggle Full Screen. **Restore** puts a window back where it was before Fudge last moved it. Search for them, or give them hotkeys under **Settings… → Commands → Window Management**. They need Accessibility permission (**Settings… → Permissions**).

### System commands

Fudge's System commands are **Lock Screen**, **Sleep**, **Restart**, **Shut Down**, **Log Out**, **Empty Trash**, **Eject All Disks**, **Toggle Dark Mode**, **Hide All Apps** and **Quit All Apps**. Restart, Shut Down, Log Out, Empty Trash and Quit All Apps ask first, and apps with unsaved work ask about it as they quit. Search for them, or give them hotkeys under **Settings… → Commands → System**. The first time, macOS asks you to let Fudge control Finder, System Events or the login window (**Privacy & Security → Automation**). Lock Screen needs Accessibility permission.

### Selected text and Finder items

Extensions can read the text selected in the app you were in, and the items selected in Finder. The first time, macOS asks you to allow Fudge under **Privacy & Security → Accessibility** or **Automation**.

macOS only asks when Fudge isn't in the Accessibility list yet. If Fudge is there but switched off, or the entry was left by an older build of Fudge, nothing appears, and extensions are just refused. So when Accessibility is refused a second time, Fudge shows its own alert, once per run, and **Open Accessibility Settings** takes you to the list. Switch Fudge on there. If it's already on, select it, remove it with −, and add it again with +.

When an app doesn't share its selection through Accessibility (often browsers and Electron apps such as VS Code), Fudge copies it with ⌘C and puts back what was on your clipboard right after. That has some side effects:

- A clipboard history app may record the copied text.
- If your clipboard holds a password that a password manager marked as concealed, Fudge leaves the clipboard empty instead of putting the password back. Put back, it would look like a new copy, and the password manager would no longer clear it.
- Clipboard data over 50 MB (of one type) isn't put back. An app that only produces its clipboard data when asked (some design apps do this with large images) still has to produce it, so that can take a moment.
- An app that copies something when nothing is selected hands that over instead. VS Code, for example, copies the current line.
- Fudge waits half a second for the copy. An app that answers ⌘C later than that copies after Fudge has put your clipboard back, so the selected text ends up on your clipboard.

Secure text fields, such as passwords, never give their text.

### Images from the web

When an extension uses an `https://` image (an icon, or an image in markdown), Fudge shows it and keeps it in `~/Library/Application Support/fudge/image-cache/` (up to 200 MB). A downloaded image is reused for a day, then checked for changes the next time it's shown. `http://` images, and images from your Mac or the local network, aren't shown.

### Pasting

Extensions can paste into the app you were in (`Clipboard.paste`, the Paste action). Fudge puts the content on your clipboard, presses ⌘V in that app, and puts back what was on your clipboard about a second later. It needs the same Accessibility permission. Without it, the content stays on your clipboard for you to paste yourself.

- Fudge marks what it puts on the clipboard as transient, so clipboard history apps that follow [nspasteboard.org](http://nspasteboard.org) skip it.
- If you copy something within that second, Fudge leaves your new copy alone.
- If your clipboard held a password that a password manager marked as concealed, Fudge leaves the clipboard empty instead of putting the password back, for the same reason as above.
- Apps that read the clipboard late, such as virtual machines or remote desktops that sync it, may paste what Fudge put back instead of the content.

### Windows

Extensions can list your windows, and move, resize or make full screen any of them (`WindowManagement`). That needs the same Accessibility permission. macOS doesn't let apps see your Spaces, so to extensions each screen is one desktop, and Fudge can't move a window to another Space.

## License

Copyright (C) 2026 Morten Jakobsen.

Licensed under the GNU Affero General Public License, version 3 or (at your option) any later version (`AGPL-3.0-or-later`). See [LICENSE](LICENSE).

`runtime/vendor/unicode/` holds Unicode's emoji data and CLDR's English annotations, under the Unicode License v3; see [the license next to them](runtime/vendor/unicode/LICENSE).

`runtime/vendor/raycast-api/index.d.ts` contains the type definitions from the `@raycast/api` package. They are Copyright (c) 2021 Raycast and MIT-licensed; see [the notice next to them](runtime/vendor/raycast-api/LICENSE).
