# Fudge

A Raycast-compatible keyboard launcher for your Mac.
It runs extensions written for Raycast's [`@raycast/api`](https://developers.raycast.com).

Fudge is an independent project.
It is not affiliated with or endorsed by Raycast.

## Installing

Fudge needs macOS 14 or later and a Mac with Apple silicon.
On an Intel Mac, [build it from source](#building-from-source).

Each release on GitHub has a disk image, `Fudge.dmg`, also there as `Fudge-<version>.dmg`: open it and drag Fudge to Applications.
Fudge includes the Node.js that runs extensions, so there's nothing else to install.
If you open Fudge straight from the disk image or from Downloads, it offers to move itself to Applications, since it can't open at login from there.
On an account that can't add apps to `/Applications`, it moves to the Applications folder in your home folder instead.
Releases are signed with a Developer ID and notarized by Apple, so the first time you open Fudge, macOS asks once whether to open an app downloaded from the internet.
Click **Open**, and Fudge starts.
It lives in the menu bar, with no Dock icon.

### The `fudge` command-line tool

Fudge includes `fudge`, a command-line tool for building and checking extensions, at `/Applications/Fudge.app/Contents/Helpers/fudge`.
To run it as `fudge`, link it into a folder on your `PATH`; it finds Fudge's own Node.js and esbuild through the link.
A new Mac may not have `/usr/local/bin` yet, so the first line creates it:

```bash
sudo mkdir -p /usr/local/bin
sudo ln -s /Applications/Fudge.app/Contents/Helpers/fudge /usr/local/bin/fudge
```

- `fudge build <folder>` compiles the Raycast extension in `<folder>` and installs it for Fudge, which picks it up within a second, with nothing to reload.
  Run it again after changing the extension.
  It goes in the development folder, `fudgeapp/development`, beside any extension of the same name that the Extension Store installed from Raycast's official repository, with its own settings, data and sign-ins.
  When another installed extension has the same name, Fudge shows it as "<title> (development)".
  `--repository raycast/extensions` installs it in the folder of Raycast's official repository instead: it replaces the Extension Store's install of that name and keeps its settings, until the Extension Store's next Update of it.
  To get Raycast's official version back, uninstall it with ⌃X in the Extension Store, then Install it there again.
  `--into <folder>` installs it in that extensions folder instead.
  It stops at once, with exit status 75, while another build of the same extension into the same repository's folder is running.
  `--outcome <folder>` writes its exit status to `<folder>/<pid>.ended.json` as it ends, which the Extension Store passes so that it learns how a build ended after the store was closed.
- `fudge scan <folder>` says what the extension uses that Fudge doesn't have yet or doesn't support, without building or running it (`--json` for a script).
- `fudge version` prints Fudge's version.

Fudge keeps each repository's extensions in a folder of their own, in its extensions folder (`~/Library/Application Support/fudge/extensions`):

- `raycast/extensions/<name>`: Raycast's official repository, where the Extension Store installs.
- `<owner>/<repository>/<name>`: a repository on GitHub, and `<server>/<path>/<name>` one on another server.
- `fudgeapp/development/<name>`: the development folder, for `fudge build` and `make install-extension` without `--repository`.

Each repository's extensions keep their own settings, data and sign-ins, so two extensions of one name from different places never share them.
The first time this version of Fudge starts, it moves every extension already installed to `raycast/extensions/<name>`, and each keeps its settings.
A later `fudge build` of one of them without `--repository` makes a separate copy in the development folder.

## First run

The first time Fudge starts, it walks you through a few choices.
It asks about the features that are off until you turn them on, and each answer takes effect at once.
**Settings…** has them all, to change later.
Until you click **Start Using Fudge** at the end, Fudge shows these steps again at its next start, from where you left off.

macOS asks you to allow some things the first time Fudge needs them:

- **Accessibility**, to paste (snippets, emoji, clipboard history and extensions), move and switch windows, search an app's menus, use Caps Lock as Hyper, lock the screen, and read the text you've selected.
  The first-run steps ask for it.
- **Input Monitoring**, only if you turn on expanding snippets as you type, so Fudge can spot a snippet's keyword.
- **Automation**, to let Fudge use Finder (the items selected in Finder, Empty Trash), System Events (Toggle Dark Mode) or the login window (Restart, Shut Down, Log Out).
- **Calendars**, the first time you open My Schedule.

**Settings… → Permissions** shows whether Fudge may use Accessibility and your calendars.
**Open Accessibility Settings** lets macOS ask you first; if it doesn't ask, click it again to open **System Settings → Privacy & Security → Accessibility** and turn Fudge on there.
**Show Onboarding Again** goes through the first-run choices again.

## What works

Fudge runs extensions written for Raycast through its own `@raycast/api`, without changing them.
Before you install one, the Extension Store says whether Fudge has everything it uses, and `fudge scan` does the same for an extension's folder.
Both read the `@raycast/api` features the extension's code uses, without running it.

- **Raycast AI and the Raycast Browser Extension aren't supported.**
  Fudge checks each command on its own, following the files it imports, and installs a command that uses either turned off.
  The store marks an extension with some such commands **Partly compatible**, and one with only such commands **Not compatible**.
- **Parts written in Rust** are for Windows, so Fudge leaves them out, as Raycast does on a Mac.
- **Parts written in Swift** are built on your Mac once Apple's Command Line Tools are set up in **Settings… → Development**, and the first build takes a few minutes.
- **A feature Fudge doesn't have yet** makes the command that uses it stop with a message naming it.
- **Signing in:** extensions that sign in to a service with OAuth go through a sign-in server, which you pick under **Settings… → Sign-in** (see [Signing in](#signing-in)).
  Fudge's sign-in server offers GitHub and Atlassian (Jira and Confluence), and a company can run its own with [fudge-oauth](https://github.com/jakeobsen/fudge-oauth).
  An extension that takes a token in its settings works without one.

## Using it

Open Fudge with ⌥Space, type to search applications and extension commands, and press ↵.
Esc goes back, then hides the window.

Extensions run with your permissions, and while they run they can reach each other's data, as in Raycast.
Install the ones you trust.
An extension may ask to use your contacts, location, photos, calendars, reminders, camera, microphone or Bluetooth, and macOS asks you first.
macOS keeps one answer for Fudge, so a yes covers every extension, and you can change it under **System Settings → Privacy & Security**.

When you open Fudge again within 90 seconds, it's as you left it.
After longer, it starts over on an empty root search.
**Pop to Root Search** on the **General** page of **Settings…** sets how long: Immediately, after 30 seconds, 1 minute or 90 seconds, or Never.
Only the time the window is closed counts.

**Show Fudge on**, on the same page, picks the screen Fudge opens on: the one with the mouse (the default), the primary screen, or the one with the app you're using.
**Escape Key Behavior** picks what Esc does: by default it clears the search, then goes back, then closes the window; with "Close window and pop to root", Esc closes the window at once, and Fudge opens on an empty root search next time.

What the Fudge menu bar menu does is in root search too: "Fudge Settings", **Reload Extensions** (reads the extensions and applications again) and **Quit Fudge** (asks first, since Fudge's hotkeys stop working until you open it again).

To use another shortcut, open **Settings…** on the **General** page, click the keys next to **Launcher hotkey**, and press the new shortcut.
Esc cancels.
A shortcut needs ⌘, ⌥ or ⌃, unless it's an F-key.
The launcher always has a hotkey, so ⌫ (or **Reset to ⌥Space**) puts ⌥Space back.
Fudge refuses a shortcut that a command already has, and keeps the old one when another app has the new one.
If another app already holds the launcher's hotkey when Fudge starts, the General page says so, and the menu bar menu's **Open Fudge** still works.

### Command hotkeys

Any command can have its own hotkey.
Open **Settings…** on the **Commands** page, click **Record Hotkey** next to the command, and press the shortcut.
Esc cancels, and ⌫ removes it.
A hotkey needs ⌘, ⌥ or ⌃, unless it's an F-key.
Pressing it anywhere opens the command as root search would: a view command shows the Fudge window, a no-view command just runs, and a command with a required argument shows root search with that field ready.
Pressing a view command's hotkey again while it's on screen hides the window.

Fudge refuses a shortcut that's the launcher's or another command's, and one another app has registered.
That last check is best-effort: macOS doesn't report system shortcuts such as ⌘Space or ⌃↑, so one of those can be recorded but never fire.

### Aliases and turning commands off

On the same page, a command can have an **Alias**: a short word such as `sf`.
Click the Alias cell, type it, and press ↵ (Esc puts back what was there, and an empty alias removes it).
An alias is 1 to 32 characters with no spaces, and two commands can't share one (letter case doesn't count).
Typing the alias in root search puts its command first, above a calculator result.
For a command with arguments, typing the alias and a space moves to its first argument field, and the rest of what you type goes there.

Untick **Enabled** to turn a command off, or a whole extension.
A command that's off isn't in root search, its hotkey doesn't fire, and other extensions can't launch it; its alias and hotkey are kept for when you turn it back on.
A menu bar command that's off leaves the menu bar, and comes back when you turn it on again.

**Settings…** in the Fudge menu bar menu, ⌘, in the Fudge window, and "Fudge Settings" in root search open the Settings window on its **General** page.
Extensions' preferences are in the same window, under each extension.
To go straight to a command's extension, select the command and press ⌘⇧, (or ⌘K, then **Configure Extension**).
A command that needs a preference you haven't set opens that window instead of running.

### Open at Login and search history

Fudge doesn't start at login until you turn on **Open at Login** at the top of **Settings… → General**. macOS then shows a "Login item added" notification, and lists Fudge under **System Settings → General → Login Items**, where you can also turn it off; the switch shows what's set there.
If macOS asks you to allow it first, the page says so and **Open Login Items** takes you there.
The login item is tied to where the app is, so after moving Fudge (to `/Applications`, say), turn Open at Login off and on again.

Root search ranks what you open often first.
**Clear Search History…** on the same page makes it forget, after asking.

### Hyperkey

Turn on **Hyperkey (Caps Lock)** in **Settings… → General**, and holding Caps Lock presses ⌘⌥⌃⇧ at once, called Hyper, for shortcuts like Hyper+T that no other app uses.
Caps Lock then no longer turns caps on, unless you also turn on **Quick press toggles Caps Lock**.
Hyper doesn't work in password fields, and it needs Accessibility permission (**Settings… → Permissions**).
Turning it off, or quitting Fudge, gives Caps Lock back.
If Caps Lock is already mapped to another key, Fudge leaves it alone and says so.

### Extension Store

The Extension Store browses the extensions in Raycast's open-source repository and the extension repositories you add, and installs the ones you choose.
It takes two steps:

1. Enable **Extension Store** under **Settings… → Commands**, and it shows up in Fudge.
2. Turn it on with the switch at the top of **Settings… → Extension Store**.

Turning it off removes the store's downloaded list; the extensions you installed stay installed.

In the **Extension Store** command, search the extensions, or pick a category in the dropdown; **Installed** shows the ones you installed from it.

- ↵ installs one, after saying whether Fudge supports everything it uses.
  Fudge doesn't support Raycast AI or the Raycast Browser Extension.
  An extension where only some commands use either is marked **Partly compatible**, and its details name those commands; one where every command does is marked **Not compatible**.
  Those commands are installed turned off, so they aren't in root search, and **Settings… → Commands** says why.
  You can turn one on there: it then works, apart from what needs Raycast AI or the Browser Extension.
  ⌘U updates one marked **Update available**, and ⌃X uninstalls it, to the Trash.
- ⌘D shows an extension's details: whether it's compatible (checked once you stay on it for a moment), each command and whether it opens a view, runs without one, or sits in the menu bar, and its README. ⌘R updates the list, which otherwise happens when you open the store and the list is a day old.
  If the list couldn't be downloaded, ⌘R tries again.
- If an install or update fails, the store shows the whole error and its likely cause, such as npm not found or the npm registry not reachable. ↵ tries again, and ⌘C copies the error, to send with an issue.
  It uses the proxy set in **System Settings → Network** for npm and Git, unless you've set one yourself (`HTTPS_PROXY`); a proxy configuration file (PAC) can't be passed on.
  After you change the proxy settings, quit and reopen Fudge for the store to use them.
- The store needs Git, which comes with Apple's Command Line Tools.
  Without them, the store offers **Install Command Line Tools** (↵), macOS's own installer, and ⌘R checks again once they're in.
- While an extension installs, its row says so, and closing the store doesn't stop the install: a store you open again shows it installing and records it when it's done.
  When an install or update finishes or fails while the store isn't on screen, Fudge shows a notification, and clicking it opens the store on that extension.
  macOS asks whether Fudge may show notifications the first time you confirm an install or update.
  An install that failed after you closed the store is marked on its row the next time you open the store, with **Try Again** and **Show Error**.
  **Settings… → Notifications** chooses which of these notifications Fudge shows.
- It never touches extensions you installed with `fudge build` yourself.
  An extension of the same name from another repository, or your own development build in the development folder, doesn't stop an install: each is installed beside the other, with its own settings and data.
  It installs each extension in its repository's folder, and won't install one there while an extension of that name that it didn't install is in that folder, such as one built with `fudge build --repository <owner>/<repository>`.
  The Extension Store has no record of such a build, so it can't uninstall it either: to remove it, delete its folder `<owner>/<repository>/<name>` in Fudge's extensions folder, for example `raycast/extensions/<name>`.
- It never updates your own development builds, but shows each under **Installed** as **Development build**, and ⌃X moves it to the Trash.
  Those rows are there only while the Extension Store is on (it's off until you turn it on), so with it off, remove a development build by deleting its folder `fudgeapp/development/<name>` in Fudge's extensions folder.

#### Extension repositories

Besides Raycast's official repository, the Extension Store can list the extensions in repositories you add: any Git repository with an `extensions` folder holding one folder per extension, as Raycast's has.
Add one under **Settings… → Extension Store → Extension Repositories**: click **Add Repository…**, type its address, such as `https://github.com/owner/repository`, a branch if it isn't the default one, and a name if you want one, then click **Add**.
Only public `https://` addresses work, without a user name or password, and Fudge never asks for a password.
The **Add Repository** window says that a repository's extensions run their own code on your Mac, like any app you install: only add one you trust.
Raycast's official repository is in the list from the start, as `raycast`, and can be switched off or removed like any other; **Add Raycast's Repository** puts it back.
Each repository has a switch, Raycast's official repository too; one that's off keeps its copy, but the Extension Store doesn't list or update its extensions.
Under each one is what the Extension Store last found there: how many extensions it lists, or what went wrong.
The minus button removes a repository, Raycast's official repository too; the extensions you installed from it stay installed, but get no more updates.
They show under **Installed** as **Not updated**, as do those of a repository that's switched off, and ⌃X uninstalls them there.
Each extension's details name the repository it's from, a row from a repository you added names it too, and with more than one repository on, the dropdown also filters by repository.
An extension of the same name in two repositories can be installed from both: each is its own extension, with its own settings and data.
When two installed extensions have the same name, Fudge shows where each one is from after its name: `raycast` for Raycast's official repository, a repository's name if you gave it one, else its `owner/repository`, and `development` for your own builds.
To name a repository you've already added, or to change its name, remove it and add it again: its extensions stay installed and keep their settings, hotkeys and aliases.
You can add up to 10, and `https://github.com/fudgeapp/development` can't be added, since Fudge keeps your own builds in that repository's folder.
Changes reach the Extension Store the next time you open it, or when you press ⌘R in it.

### Signing in

Some extensions sign in to a service, such as GitHub or Jira.
Pick a sign-in server under **Settings… → Sign-in**: **Fudge's sign-in server**, or **Your own server…**.
Fudge's sign-in server offers GitHub and Atlassian (Jira and Confluence).
Under your choice, the page names up to five of the services the chosen server offers, when the server lists them.
With more than five, it gives their number, and **Show All** lists them.
A company can run its own with [fudge-oauth](https://github.com/jakeobsen/fudge-oauth), which supports many more services.
[fudge-oauth's README](https://github.com/jakeobsen/fudge-oauth#confirmed-integrations) lists the services confirmed so far.
Extensions that sign in with an app of their own work too, once **Extensions with their own sign-in** is on under **Settings… → Sign-in**.
Some of them come back through a Raycast link, which opens Fudge only while **Fudge opens Raycast links** is on, on the same page.
Turned on, Raycast's own links open Fudge too; turned off, they go back to Raycast.
It can't be turned on while Fudge runs from its disk image: move Fudge to Applications first.
When an extension needs to sign in, Fudge shows **Sign in to** the service, and ↵ continues in your browser.
Sign-ins are kept in your Keychain, and the Sign-in page lists them, each with **Sign Out**.
Changing the server signs you out of everything.

Extensions trust the certificates your Mac trusts, so a server behind your company's own certificate works as it does in Safari.

An extension that takes a token in its settings (⌘⇧,) works without signing in.

When Fudge isn't there to turn **Fudge opens Raycast links** off, for example after you've deleted it, Terminal can do the same.
This shows which app opens each kind of Raycast link, by its bundle identifier:

```sh
osascript -l JavaScript -e 'ObjC.import("CoreServices"); ["raycast", "com.raycast"].map(s => s + ": " + (ObjC.unwrap(ObjC.castRefToObject($.LSCopyDefaultHandlerForURLScheme($(s)))) || "none")).join("\n")'
```

And this gives both back to Raycast (`com.raycast.macos`):

```sh
osascript -l JavaScript -e 'ObjC.import("CoreServices"); ["raycast", "com.raycast"].forEach(s => $.LSSetDefaultHandlerForURLScheme($(s), $("com.raycast.macos")))'
```

Run the first command again to check.

### Menu bar commands

An extension's menu bar command puts its own item in the menu bar.
Run it from root search to turn it on, and the item stays there, across restarts, until you select the command in root search and pick **Deactivate Menu Bar Item** from ⌘K.
Running it again from root search refreshes it and opens its menu.
The command refreshes itself in the background at Fudge's start and as often as its extension asks, and again each time you open its menu.
When a background refresh fails, the item keeps what it showed last and its menu ends with "⚠ Last refresh failed".
Fudge shows at most 50 of these items.

### Extensions that open other extensions

The first time an extension opens another extension's command, Fudge asks whether to allow it, and remembers the answer.
To change or forget an answer, open **Settings…** → **Permissions** → **Extensions that open other extensions**: pick **Allowed** or **Not allowed**, or click × to be asked again next time.

An extension running in the background, such as a menu bar refresh, never interrupts you to ask: Fudge says so once, and asks the next time you open that extension.

### Selected text and Finder items

Extensions can read the text selected in the app you were in, and the items selected in Finder.
The first time, macOS asks you to allow Fudge under **Privacy & Security → Accessibility** or **Automation**.

macOS only asks when Fudge isn't in the Accessibility list yet.
If Fudge is there but switched off, or the entry was left by an older build of Fudge, nothing appears, and extensions are just refused.
So when Accessibility is refused a second time, Fudge shows its own alert, once per run, and **Open Accessibility Settings** takes you to the list.
Switch Fudge on there.
If it's already on, select it, remove it with −, and add it again with +.

When an app doesn't share its selection through Accessibility (often browsers and Electron apps such as VS Code), Fudge copies it with ⌘C and puts back what was on your clipboard right after.
That has some side effects:

- A clipboard history app may record the copied text.
- If your clipboard holds a password that a password manager marked as concealed, Fudge leaves the clipboard empty instead of putting the password back.
  Put back, it would look like a new copy, and the password manager would no longer clear it.
- Clipboard data over 50 MB (of one type) isn't put back.
  An app that only produces its clipboard data when asked (some design apps do this with large images) still has to produce it, so that can take a moment.
- An app that copies something when nothing is selected hands that over instead.
  VS Code, for example, copies the current line.
- Fudge waits half a second for the copy.
  An app that answers ⌘C later than that copies after Fudge has put your clipboard back, so the selected text ends up on your clipboard.

Secure text fields, such as passwords, never give their text.

### Pasting

Extensions can paste into the app you were in (`Clipboard.paste`, the Paste action).
Fudge puts the content on your clipboard, presses ⌘V in that app, and puts back what was on your clipboard about a second later.
It needs the same Accessibility permission.
Without it, the content stays on your clipboard for you to paste yourself.

- Fudge marks what it puts on the clipboard as transient, so clipboard history apps that follow [nspasteboard.org](http://nspasteboard.org) skip it.
- If you copy something within that second, Fudge leaves your new copy alone.
- If your clipboard held a password that a password manager marked as concealed, Fudge leaves the clipboard empty instead of putting the password back, for the same reason as above.
- Apps that read the clipboard late, such as virtual machines or remote desktops that sync it, may paste what Fudge put back instead of the content.

### Windows

Extensions can list your windows, and move, resize or make full screen any of them (`WindowManagement`).
That needs the same Accessibility permission. macOS doesn't let apps see your Spaces, so to extensions each screen is one desktop, and Fudge can't move a window to another Space.

### Images from the web

When an extension uses an `https://` image (an icon, or an image in markdown), Fudge shows it and keeps it in `~/Library/Application Support/fudge/image-cache/` (up to 200 MB).
A downloaded image is reused for a day, then checked for changes the next time it's shown.
`http://` images, and images from your Mac or the local network, aren't shown.

### Quicklinks

A quicklink is a saved link that opens from root search: a web page, an app's link (`slack://…`) or a folder (`~/Downloads`), in the app you chose for it or the default one.
Type its name and press ↵.

To make one, open **Create Quicklink** from root search, fill in its name, link and the app it opens with, and press ⌘↵.
Extensions can offer to make one too (**Create Quicklink** in their ⌘K), which opens the same form, filled in.
**Settings → Quicklinks** lists them all, to add, change or delete one.

A link can have fields, filled in after its name like a command's arguments: `https://jira.example.com/browse/{argument name="ticket"}`.
`{argument name="q" default="news"}` has a default, and `{argument name="kind" options="bug, task"}` is a list to pick from.
`{clipboard}`, `{uuid}`, `{date}`, `{time}` and `{datetime}` fill themselves in; something a password manager copied is never used.
In a web link, what's filled in is encoded for the URL, unless the placeholder ends in `| raw`.
`| uppercase`, `| lowercase` and `| trim` change it first.

⌘K on a quicklink offers **Copy Link** (⇧⌘C), **Edit Quicklink…** (⌘E) and **Delete Quicklink…** (⌃X).

Quicklinks are listed on **Settings → Commands** too, under **Quicklinks**, so each one can have an alias, a hotkey and **Enabled** like a command.
Its hotkey opens it straight away, or shows root search with its fields when one has no default.
Typing its alias and a space moves to its first field.

### Snippets

A snippet is text you use often, such as an address or a reply, saved to paste anywhere.
Open **Search Snippets** from root search, pick one and press ↵: Fudge pastes it into the app you were in. ⌘↵ copies it instead, ⌘E edits it and ⌃X deletes it.

To make one, open **Create Snippet**, give it a name and its text, and press ⌘↵.
Extensions can offer to make one too (**Create Snippet** in their ⌘K).
**Settings → Snippets** lists them all, to add, change or delete one.

A snippet's text can fill itself in: `{clipboard}`, `{date}`, `{time}`, `{datetime}`, `{day}` and `{uuid}`, changed by `| uppercase`, `| lowercase` or `| trim`, and `{date format="yyyy-MM-dd"}` picks a date's format.
`{cursor}` marks where the cursor ends up after pasting.
These names are always filled in, wherever they appear, as in Raycast; any other text in braces, such as code or JSON, is pasted as it is.

A snippet can also have a keyword, such as `;addr`, which Search Snippets finds it by.
Turn on **Expand Snippets as You Type** in **Settings → Snippets**, and typing a keyword in any app replaces it with its snippet.
It needs macOS's Input Monitoring permission, which Fudge asks for when you turn it on, and Accessibility, as pasting does.
Fudge keeps only the last few characters you typed, in memory, to spot a keyword.
What you type isn't saved or sent anywhere, and nothing is read while macOS protects a password field.
A keyword typed in Fudge's own windows isn't expanded, and an expansion goes only into the app the keyword was typed in.
No keyword can contain another, so a keyword never expands inside a longer one.

### Calculator and currency

Type a calculation in root search and the answer shows above the results: arithmetic (`5+5/10*39`), units (`13kg to lbs`), time zones (`3pm cet in pst`) and currencies (`100 usd to eur`, `€100 in usd`, `100 € in kr`). ↵ copies the answer.

Time zones also know towns of 15,000 people or more (`3pm roskilde to kouvola`), countries with one time zone (`denmark time`) and offsets from UTC (`gmt+2 to utc`).

Numbers follow your Mac's number format, or the one you pick under **Settings… → Calculator → Number format** (in the Extensions part of the sidebar): "1,234.5" or "1.234,5".
In "1.234,5", `1.000 + 1` is 1.001, and `1.5` isn't a number, so it gets no answer rather than a wrong one.

Currency conversion uses the European Central Bank's daily exchange rates.
Turn it on under **Settings… → Calculator**; until then, a currency query shows a card that takes you there.

For places the calculator doesn't know, such as small towns, turn on **Look up other places with Apple Maps** under **Settings… → Calculator**.
Then `time in hirtshals` shows its card once Apple Maps has found the town.

Town and country names come from [GeoNames](https://www.geonames.org), under the [Creative Commons Attribution 4.0 license](https://creativecommons.org/licenses/by/4.0/).
Fudge keeps only each town's names, country, population and time zone.

### Search Files

**Search Files** finds files and folders by name with Spotlight.
Type part of a name; with nothing typed, it lists the files you used in the last 30 days.

- ↵ opens the file, ⌘↵ shows it in Finder, ⌘Y previews it with Quick Look, and ⌘O opens it with another app.
- ⌘⇧C copies its path, ⌘⌥C copies the file, and ⌃X moves it to the Trash, after asking.
- ⌘⇧D shows or hides the details.

In **Settings… → Search Files**, **Search In** picks your home folder (the default) or the whole Mac, and **Leave Out** lists folders to skip, separated by commas (`~/Library` by default).

### Emoji

**Search Emoji & Symbols** finds an emoji by its name or a keyword ("thumbs", "+1", "heart"). ↵ pastes it into the app you were in, ⌘↵ copies it, and ⌘⇧C copies its name.
The ones you use most recently come first, under **Recently Used**.
It shows the emoji your Mac can draw.

In **Settings… → Search Emoji & Symbols**, **Skin Tone** picks the tone for the emoji that have one.

### Clipboard History

**Clipboard History** keeps what you copy, so you can search it and paste it again.
It's off until you turn on **Keep Clipboard History** in **Settings… → Clipboard History**.
The history is encrypted on this Mac, and copies that password managers mark as private aren't kept.
Extensions can read it, as in Raycast.

- ↵ pastes a copy into the app you're in, and ⌘↵ copies it. ⇧⌘P pins it, so it's kept however old it gets.
- ⌃X deletes a copy, and ⌃⇧X deletes them all, after asking.

On the same page, **Keep For** sets how long copies are kept (7 days by default), **Ignore Apps** lists apps whose copies aren't kept, and **Clear History…** deletes everything.
Turning the switch off asks whether to keep or delete what's there.

### Color Picker

**Pick Color** shows a magnifier: click a color anywhere on the screen to copy it, or press Esc to cancel.
**Recent Colors** shows the last 32 colors you picked.
↵ copies one, ⌘K copies it as HEX, RGB, HSL, a SwiftUI `Color` or a `UIColor`, ⌃X removes it, and ⌃⇧X clears them all, after asking.
Give either one a hotkey under **Settings… → Commands → Tools**.

**Settings… → Color Picker → Copy Format** sets how Pick Color and ↵ copy a color: `#3A7BD5` (HEX, the default), `rgb(58, 123, 213)`, `hsl(215, 65%, 53%)`, `Color(red: 0.227, green: 0.482, blue: 0.835)` or `UIColor(red: 0.227, green: 0.482, blue: 0.835, alpha: 1)`.

### Define Word

**Define Word** shows a word's definition from your Mac's own dictionaries.
Type `define` and the word (`define serendipity`), or run it with nothing typed to look up the text selected in the app you're in.
`define` is its alias, so you can change or clear it on the Commands page.
↵ (or ⌘D) opens the word in Dictionary, and ⌘↵ copies the definition.

### Window management

Fudge can move and resize the window you're using: halves, quarters, thirds and two thirds, Maximize (also Almost Maximize, Maximize Width and Maximize Height), Center, Reasonable Size, Make Larger and Make Smaller, Next and Previous Display, and Toggle Full Screen.
**Restore** puts a window back where it was before Fudge last moved it.
Search for them, or give them hotkeys under **Settings… → Commands → Window Management**.
They need Accessibility permission (**Settings… → Permissions**).

**Switch Windows**, in the same group, lists the open windows of all your apps, minimized ones included, and finds them by title or app name.
The window you were in comes second, so ↵ right away takes you back to the one before it. ↵ switches to the selected window, ⌃X closes it and ⌃⌥X quits its app. macOS usually shows Fudge only the windows on the current Space.
An app that's too slow to answer is left out and named at the bottom of the list.

**Custom positions** are your own: on **Settings… → Window Management**, click + and give one a name and where it goes, in percent of the screen from its top left (say "Left 70%" at 0, 0, 70 × 100).
Each one is a command like Left Half, with its own alias and hotkey.

**Save Layout…** remembers where every app's windows are on your screens and asks for a name.
**Apply <name>** puts them back later.
It moves only apps that are running, and the HUD says how many windows it placed and skipped.
Layouts keep apps and places, never window titles.
Rename or delete them on the same Settings page.

### System commands

Fudge's System commands are **Lock Screen**, **Sleep**, **Restart**, **Shut Down**, **Log Out**, **Empty Trash**, **Eject All Disks**, **Toggle Dark Mode**, **Hide All Apps** and **Quit All Apps**.
Restart, Shut Down, Log Out, Empty Trash and Quit All Apps ask first, and apps with unsaved work ask about it as they quit.
Empty Trash says how many items it will delete when Finder can count them.
Search for them, or give them hotkeys under **Settings… → Commands → System**.
The first time, macOS asks you to let Fudge control Finder, System Events or the login window (**Privacy & Security → Automation**).
Lock Screen needs Accessibility permission.

### Search Menu Items

**Search Menu Items** lists the menu commands of the app you're in, with their menus and shortcuts.
Type to find one, such as "export" or "show fonts", and press ↵ to run it.
Give it a hotkey under **Settings… → Commands → Apps**.
It needs Accessibility permission (**Settings… → Permissions**).

### My Schedule

**My Schedule** lists your events from today on, a section per day, from the calendars on your Mac.
Each shows its time, its calendar's color, and "Now" or "in 12 min" when it's about to start; **Show Details** (⌘D) adds the place, the calendar, how many are invited and the notes.
↵ joins the meeting when the event has a Zoom, Google Meet, Microsoft Teams, Webex, FaceTime, Whereby, Around or Jitsi link, and otherwise opens the event in Calendar (⌘O).
⌘⇧C copies the meeting link, and Copy Details copies the event.

The first time you open it, macOS asks to let Fudge see your calendars; you can change that under **Privacy & Security → Calendars**.
**Settings → Calendar** picks which calendars it shows, and how many days ahead (1, 3, 7 or 14).

### Updates

Fudge can check for a new version daily, weekly or monthly.
Pick how often when Fudge first starts, or under **Settings… → General → Check for Updates** (Never turns it off); until you pick, it doesn't check.
**Check Now** on the same page, or **Check for Updates…** in the menu bar menu, checks at once.

When there's a new version, Fudge says so once, the General page shows it with **Download…**, and the menu bar menu shows it at the top.
Both open the release's page on GitHub.
Fudge never downloads or installs anything by itself.

### Backup: import and export

**Settings… → General → Import / Export** saves everything you've set up in Fudge to one file, and brings it back, on this Mac or another one.

- **Export…** asks for a password (at least 8 characters), then where to save `fudge-backup-<date>.fudgebackup`.
  The file holds Fudge's settings (hotkeys, aliases, which commands are on), your quicklinks, snippets and recent colors, the answers about extensions opening other extensions, root search's ranking, every extension's preferences and data, and the list of installed extensions.
  It's always encrypted with your password, because extensions keep passwords and tokens in there; Fudge can't recover a forgotten one.
  The file opens only in Fudge, not with Apple's `aea` tool.
  Extension data over 100 MB in total leaves out the biggest extensions' data, and the export says which.
- **Import…** (also **Restore from a Backup…** on the Welcome screen Fudge shows the first time) asks for the file and its password, shows what's in it, and replaces your settings and the data of the extensions in the backup; other extensions keep theirs.
  The summary also lists the backup's extensions that changed since it was made (a new version, an update from the Extension Store, or installed another way); they're imported all the same.
  It then lists the extensions in the backup that aren't installed here, so you can reinstall them.
  It installs nothing itself.
- **The extensions themselves aren't in a backup**, only the list, and neither are caches, the exchange rates, your sign-ins, the sign-in server, the Extension Store's switch or its list of extension repositories (set these again yourself).
- Before importing, Fudge saves what it's about to replace in `backups/` in its support folder (`~/Library/Application Support/fudge/backups`), readable by you only.
  It keeps the last 3.
  You can import one of those with **Import…**; it needs no password.

## FAQ

### Why doesn't Fudge limit what each extension can do?

We tried.
The firmest way macOS supports is to run an extension inside Apple's App Sandbox, the one App Store apps run in.
A limited extension then can't control other apps with AppleScript, run tools installed with Homebrew, or read your files, so many extensions would stop working.
Limited extensions also need a second extension runner, about 77 MB more memory, and keeping their data in place needs sandbox exceptions that Apple documents only in its old archive.
So for now Fudge works as Raycast does: extensions run with your permissions, and one answer to macOS covers every extension.
Install the extensions you trust.

## Building from source

You need macOS 14 or later and Xcode 26 or later.
A build is for the kind of Mac you build on, Apple silicon or Intel.
The first build downloads the Node.js that Fudge includes from nodejs.org, checks it against the checksum pinned in the `Makefile`, and keeps it in `.cache/node`; every build step and test uses it.
The app runs on macOS 14 and later.

```bash
make app     # build build/Fudge.app
make dmg     # build it into a disk image, build/Fudge-<version>.dmg
make release # the same, signed with the Developer ID and notarized (the maintainer's, after secret env apple)
make run     # build it and open it
make test    # run the Swift and extension host tests
make lint    # check formatting and types

make install-extension DIR=path/to/extension   # compile and install an extension, in the development folder
```

`make help` lists every target.
Published releases are built on GitHub when a release's pull request is merged into `mainline`; `make release` builds one on your Mac.

### Keeping permissions across builds

macOS remembers the permissions you give Fudge (Accessibility, Automation) by its code signature.
An ad hoc signature changes with every build, so macOS would forget them each time.
`make app` signs with the first of these that your keychain has:

1. a code-signing identity named **fudge local signing**;
2. an **Apple Development** identity, which Xcode creates when you add your Apple Account under **Xcode → Settings → Accounts**;
3. otherwise none: it signs ad hoc.

Its last line says which identity it used.
`make app SIGN_IDENTITY=-` builds ad hoc anyway, and `SIGN_IDENTITY=<name>` picks another identity.

**The first build that signs with an identity shows a keychain prompt** ("codesign wants to sign using key … in your keychain").
Enter your login password and click **Always Allow**, once.
Otherwise every later build stops at that prompt, and a build nobody is watching hangs on it.

Without an Apple Development identity, you can create the self-signed one:

1. In Keychain Access, choose **Keychain Access → Certificate Assistant → Create a Certificate…**.
   Name it `fudge local signing`, with identity type **Self-Signed Root** and certificate type **Code Signing**.
2. Open the certificate, expand **Trust**, and set **Code Signing** to **Always Trust**.
3. Expand the certificate in **My Certificates**, open its private key, and under **Access Control** add `/usr/bin/codesign` to the allowed applications (⌘⇧G in the file dialog lets you type the path).
   Or answer the first build's prompt with **Always Allow**, as above.

Releases are signed with Fudge's Developer ID, so their permissions carry over from one release to the next.
A release and a build you made yourself have different signatures, so switching between them asks for the permissions again.

Every build has the hardened runtime, which notarizing needs.
It refuses a protected resource unless the app has its entitlement, so `App/Fudge.entitlements` lists the ones Fudge and its extensions may use: Apple Events, Calendars, Contacts, location, Photos, the camera and the microphone.
Bluetooth has no entitlement, only the text macOS asks with, in `App/Info.plist` with the others.
The Node.js inside Fudge has two of its own, in `App/Helpers/node.entitlements`: one to compile JavaScript as it runs, and one to load extensions' native addons, which others have signed.

## What's here

- `Sources/FudgeApp`: the macOS app.
  It runs in the menu bar, without a Dock icon.
- `Sources/FudgeCLI`: the [`fudge` command-line tool](#the-fudge-command-line-tool).
- `Sources/FudgeCore`: code shared by the app, the tool and Fudge Links.
- `Sources/FudgeLinks`: Fudge Links, a small app inside Fudge that passes Raycast's links on to Fudge once you turn on **Fudge opens Raycast links** under **Settings… → Sign-in**.
- `runtime/`: the extension host.
  This is the Node.js program that runs extensions.
  The app talks to it over stdin/stdout.
- `runtime/store-extension/`: the Extension Store, an extension bundled with Fudge that lists and installs the extensions published in github.com/raycast/extensions.
- `runtime/file-search-extension/`: Search Files, an extension bundled with Fudge that finds files and folders by name.
- `runtime/emoji-extension/`: Search Emoji & Symbols, an extension bundled with Fudge that finds emoji by name and pastes them.
- `runtime/clipboard-history-extension/`: Clipboard History, an extension bundled with Fudge that lists what you copied.

## License

Copyright (C) 2026 Morten Jakobsen.

Licensed under the GNU Affero General Public License, version 3 or (at your option) any later version (`AGPL-3.0-or-later`).
See [LICENSE](LICENSE).

The app icon was made with ChatGPT for this project.

The app also ships third-party code and data, each under its own license: [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) lists them, and Fudge.app carries the same as `Third-Party Notices.txt`, linked from **About Fudge**.

`runtime/vendor/unicode/` holds Unicode's emoji data and CLDR's English annotations, under the Unicode License v3; see [the license next to them](runtime/vendor/unicode/LICENSE).

`runtime/vendor/geonames/` holds the calculator's towns and countries, made from GeoNames' files, under the Creative Commons Attribution 4.0 license; see [the license next to them](runtime/vendor/geonames/LICENSE).

`runtime/vendor/raycast-api/index.d.ts` contains the type definitions from the `@raycast/api` package.
They are Copyright (c) 2021 Raycast and MIT-licensed; see [the notice next to them](runtime/vendor/raycast-api/LICENSE).
