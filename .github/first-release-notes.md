Fudge is a keyboard launcher for macOS that runs extensions written for Raycast, without changing them.
This is its first release.

## Installing

- You need macOS 14 or later and a Mac with Apple silicon.
- Download `Fudge.dmg` below, open it, and drag Fudge to Applications.
- Fudge includes the Node.js that runs extensions, so there's nothing else to install.
- Fudge lives in the menu bar, and ⌥Space opens it.
  The first time it starts, it walks you through a few choices.
- If you used a build of Fudge you made yourself, macOS asks for Fudge's permissions again, once, since they're tied to how the app is signed.

## What's in it

- Root search for applications and commands, with a hotkey and an alias for any command.
- Raycast extensions, from the Extension Store (Raycast's open-source extensions) or built from a folder with the `fudge` tool.
- Signing in to services for extensions: GitHub and Atlassian (Jira and Confluence) through Fudge's sign-in server, and more through one you run.
  Extensions that sign in with an app of their own work too, once you turn that on under Settings → Sign-in.
  Some of them come back through a Raycast link, which opens Fudge only while **Fudge opens Raycast links** is on, on the same page.
- Fudge's own commands: quicklinks, snippets that can expand as you type, a calculator with units, time zones and currencies, Search Files, Search Emoji & Symbols, Clipboard History, a Color Picker, Define Word, window management with your own positions and layouts, Switch Windows, system commands, Search Menu Items and My Schedule.
- A backup of everything you've set up, encrypted with a password.

## Known limits

- Raycast AI and the Raycast Browser Extension aren't supported, and commands that use them are installed turned off.
- Some `@raycast/api` features aren't in Fudge yet; the Extension Store and `fudge scan` name the ones an extension uses before you install it.
- Fudge usually sees only the windows on the current Space, and can't move a window to another Space.

The [README](https://github.com/jakeobsen/fudge#readme) has the details.
