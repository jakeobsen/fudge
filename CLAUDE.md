# CLAUDE.md

Guidance for AI coding agents working in this repository.
User-facing docs are in README.md.

## What this is

Fudge is a keyboard launcher for macOS, built to run extensions written for Raycast's `@raycast/api` without changing them.
It is a native Swift app.
Extensions run in a separate Node.js process, the extension host.

## Architecture

- **One Swift package, three targets.**
  - `FudgeApp` is the app: an accessory app with a menu bar item and no Dock icon.
    The item's glyph is `MenuBarIcon`, a fudge cube drawn in code as a template image.
    Its autosave name is `fudge` (`AppDelegate.statusItemName`), because macOS keeps whether a status item is shown in the app's preferences under that name, and an unnamed item's `Item-0` was once saved as hidden.
    It's shown at every launch, and its `behavior` is `[]`, so ⌘-dragging can't remove it.
    Its menu ends with the running version (`FudgeVersion.current`, Fudge's form of the `Info.plist`'s `FudgeGitDescribe`), About Fudge and Quit Fudge, and has Check for Updates… and, at the top while a newer release is known, `Fudge <version> Is Available…` (see the update check).
    **About Fudge** (SPEC-113 §3) brings Fudge forward, then opens the standard About panel with the version shown, the build number (`CFBundleVersion`), `NSHumanReadableCopyright` (`AboutFudge.copyright`) and `AboutFudge.credits` (core): the license notice and links to the source (at the tag for a release build), `LICENSE.txt` and `Third-Party Notices.txt` in the app.
    The GPL family calls these the Appropriate Legal Notices (v3 §0, §5(d)), so they stay in the panel.
    Esc, ⌘W and ⌘Q close it (`AboutFudge.closesPanel`), since an accessory app has no File menu; snapshot runs have no menu, so they never open it.
    - **Global hotkeys** go through Carbon (`CarbonHotKeys` in `HotKey.swift`), which needs no Accessibility permission: one event handler, one id per registration.
      `HotKeyRegistry` (core) decides what's registered: the launcher's hotkey (`hotkey` in `settings.json`, default ⌥Space, read and written through `FudgeSettings.launcherHotkey`) and each installed command's (`commands` in `settings.json`, by `<extension>/<command>`), registering only what changed.
      A refused change of the launcher's hotkey registers the old one again (`setLauncher`); one refused at launch stays wanted, marked `launcherRefused`, and is tried again on every `resume`.
      A change that's registered but can't be saved puts back exactly what was there, the old hotkey registered or still refused (`changeLauncher`), so the registration and the file never disagree.
      `AppDelegate.launcherHotkeyChanged` shows the outcome on the General page and in the menu bar item's "Open Fudge (…)" title.
      Hotkeys of commands that aren't installed stay in the file but aren't registered.
      `HotKeySpec` (core) is the text form (`option+s`, `f5`, `keycode:<n>` for keys with no name), and an F-key may stand alone.
      `FudgeSettings` reads `settings.json` tolerantly, and writes it atomically, keeping keys it doesn't know.
      A pressed command hotkey calls `LauncherModel.openFromHotkey`, which follows `HotKeyLaunch` (core): open it as root search would, hide the panel when it's the view command on screen, or show root search with the fields when a required argument is empty.
      A no-view command run by hotkey doesn't clear root search when it finishes (`LaunchOrigin`).
      Root-search rows show a command's hotkey as keycaps (`Keycaps`, labelled as the current keyboard layout types the key).
    - `LauncherPanel` is a non-activating `NSPanel`: it takes keys while the app you were in stays frontmost.
      It opens a little above the middle of the screen **Show Fudge on** picks (`showOnScreen`, `PanelScreen.choose` in core): the mouse's (the default), the primary one, or the one holding most of the frontmost app's topmost window, read with `CGWindowListCopyWindowInfo`, which needs no permission for bounds.
      Its bounds are flipped to Cocoa coordinates first (`PanelScreen.cocoaFrame`), and with no such window it's the mouse's screen.
    - **Esc** follows `EscapeAction` (core) and **Escape Key Behavior** (`escapeBehavior`).
      An open dropdown or action panel closes first either way, then the Quick Look preview.
      "Navigate back or close window" (the default) pops a view, clears the search, leaves the command, then hides; "Close window and pop to root" hides at once and resets to root search as Pop to Root Search does.
      A Form keeps navigating back, since Esc is its own key there, and Esc in an argument field, an input method, a hotkey recording or an alert sheet never reaches `LauncherModel.escape()`.
    - **Pop to Root Search** (`resetAfterSeconds` in `settings.json`, `PanelResetSetting`: Immediately, 30 s, 1 min, 90 s by default, or Never).
      `PanelReset` (core) keeps the time the panel was hidden, on `ContinuousClock`, which runs through sleep.
      `AppDelegate.hidePanel`, the one path every hide takes, records it, and `showPanel` forgets it, so only hidden time counts.
      A path that shows the panel builds its screen inside `LauncherModel.resettingFirst`, which first resets to an empty root search if the hide was long enough (`PanelReset.enter`): the launcher hotkey and the menu bar item (`resetIfDue`), `openFromHotkey`, a user-initiated `launchCommand` view launch, and `showArguments`.
      The reset unloads the command on screen as Esc to root does, except a `launchCommand` caller, which `unloadReplaced` unloads after its call is answered.
      `presented()` never resets: it runs after the path has built its screen, and a reset there would throw the hotkey's or `launchCommand`'s target away.
      A command that closes the window with `popToRootType: Suspended` (`closeMainWindow`, `showHUD`) suspends the reset for that hide (`PanelReset.suspend`).
      A sign-in in progress holds it off from when its "Sign in to …" prompt shows until the sign-in ends (`PanelReset.hold`, `release`), since the user is in the browser meanwhile; a hide then counts from that end.
      The launcher hotkey doesn't hide the panel while a `confirm` sheet is on it.
    - `LauncherModel` holds the panel's state.
      Root search ranks `ApplicationIndex`, installed commands and Fudge's own items (`RootSearch.builtInItems`: "Fudge Settings", "Create Quicklink", "Search Snippets", "Create Snippet", "Reload Extensions" and "Quit Fudge", so nothing needs the menu bar) with `RootSearch` (fuzzy match, then `LaunchHistory`).
      "Reload Extensions" runs the menu bar item's own reload (`reloadAll`, set by `AppDelegate`).
      "Quit Fudge" asks through `confirm` first, and it's never recorded in `LaunchHistory` (`RootItem.recordsLaunch`), so an empty search never offers it first.
      With no launch history yet (or after Clear Search History), an empty search lists Search Snippets, Clipboard History, Search Emoji & Symbols and Fudge Settings first (`RootSearch.firstRunItemIDs`), each when it's there, then the rest by title; one launch of anything puts it back to most-used first.
      Commands run through `ExtensionHost`, and its messages update the screen.
    - **Aliases and Enabled** come from `settings.json` too (`CommandSettings.alias`/`enabled`, `ExtensionSettings.enabled`).
      `LauncherModel.applySettings()` rebuilds root search from the cached installed extensions with `RootSearch.applying`, which drops disabled commands and sets aliases; it runs on every reload and whenever the Settings window changes something.
      An exact alias (case-insensitive) outranks everything (`exactAliasScore`), and `RootSearch.rows` puts it above the calculator card: that's the one row order the panel draws and ↑↓ follows.
      An alias prefix ranks next.
      For a command with arguments, "alias, space, rest" in the search field selects it and moves the rest into its first argument field (`CommandAliases.handOff`).
      One of Fudge's own commands can have a default alias (`CommandAliases.defaults`: Define Word's `define`), which the Commands page shows and edits like any other.
      It applies while `settings.json` has no alias for the command and no other command has taken it, so the user's own wins, and it's never written there (`FudgeSettings.alias(ofCommand:)`); clearing it saves an empty alias, so it stays cleared (`setAlias`).
      It does that once per query (`AliasHandOff`): the same query coming back while an argument field has the keyboard is the search field writing its text back as it loses the keyboard, and changes nothing.
      `CommandAliases.problem` holds the alias rules (1–32 characters, no whitespace, unique ignoring case).
      A disabled command's hotkey isn't registered (`FudgeSettings.availableHotkeys`), and `CommandLocator` refuses `launchCommand` for it (`LaunchCommandError.disabled`).
      **A command that uses Raycast AI or the Browser Extension is off by default** (SPEC-109): `fudge build` records which commands do in the install's `compatibility.json` (`CommandCompatibility`), and `FudgeSettings.offByDefault` (`InstalledExtension.offByDefault`) holds their ids.
      `offByDefault` is never saved: the launcher and the Settings window work it out from the installed extensions each time they read `settings.json`, so Fudge's default never looks like the user's choice.
      A command's own Enabled (`FudgeSettings.isEnabledOwn`) is `enabled` when it's set, which only the user's toggle does, true or false (`FudgeSettings.setEnabled(_:commandID:)`), and otherwise whether it's off by default.
      So an update that drops the use turns the command on again, and a command the user turned on stays on.
      An install without `compatibility.json` (built before, or its scan failed) has every command on.
    - **Built-in command groups** (`BuiltInCommandGroup`, core) are Fudge's own commands, each with a title, keywords and an SF Symbol.
      Root search lists the enabled ones (`RootItem.Kind.builtInCommand`, the group's title as the subtitle, the symbol as the icon), and the Commands page lists each group above the extensions.
      They can take arguments, as Define Word does.
      They get an alias, a hotkey and Enabled as an extension's commands do: in `settings.json`'s `commands` under `<group>/<command>`, and the group's own Enabled under `extensions`, like an extension's.
      A group's name is `:` and then a valid extension name (`:window-management`, `BuiltInCommandGroup.isValidName`).
      The extension name rule allows no `:`, so no extension can take a group's keys.
      Their hotkeys are registered, block a key and are named in conflicts like installed commands' (`BuiltInCommandGroup.commandIDs`, `CommandNames`).
      Root search and a hotkey both run one through `LauncherModel.runBuiltIn`, and each group's commands decide whether the panel shows.
    - **Window management** (`BuiltInCommandGroup.windowManagement`, one command per `WindowCommand`) moves the frontmost app's focused window.
      `WindowLayout` (core) is the geometry: each command's frame in the window's screen's visible frame (`WindowScreen.visibleBounds`: `NSScreen.visibleFrame` flipped into top-left coordinates against the primary screen by `PanelScreen.topLeftFrame`), with each edge rounded to a whole point.
      Next and Previous Display keep the frame relative to the next screen's visible frame, the screens ordered left to right, then top to bottom.
      `WindowManager.run` (core) finds the window as `getActiveWindow` does and changes it: a full-screen window takes only Toggle Full Screen; one that can't be resized moves to the target's top-left corner; one that can't be moved either gets a HUD.
      A frame is set as position, size, then position again.
      Restore's memory (`WindowFrames`) is per window number, in memory, for the run, and drops windows that are gone.
      `SystemCalls.windowCommand` checks Accessibility as a user-initiated call and runs the commands one at a time, in order, off the main thread.
      `LauncherModel.runBuiltIn` hides the panel first, and the HUD says what went wrong.
    - **Switch Windows** (FUD-120, `:window-management/switch-windows`) is the group's one command with a view: a List built in core (`SwitchWindowsList`) under its own session (`SwitchWindowsList.session`), shown like Search Snippets, so nothing of it reaches the host.
      Its hotkey opens it as a view command's does, or hides the panel when it's on screen.
      `WindowSwitcher` (core) reads through `WindowSwitchSystem`: the regular apps but Fudge, each app's AX windows (title, frame, minimized, subrole, focused), the window list's order, the screens' names, and the apps most recently active (`RecentApps`, which `SystemWindowSwitching` keeps from `didActivateApplicationNotification` from launch).
      Every app is read at once, each on its own thread with FUD-93's AX timeout, and the read waits about 1 s for them all.
      An app that hasn't answered by then, or answers `kAXErrorCannotComplete`, is left out and named in the bottom bar ("Some apps didn't answer: …", the List's `navigationTitle`); one still being read isn't asked again until that read ends (`WindowReadsInFlight`), so a hung app holds one thread.
      A later read waits on that read, holding no thread of its own, and takes its answer if it comes within its own deadline; the answer goes to no read after it.
      Only standard windows are listed (`kAXStandardWindowSubrole`).
      **The order** (`WindowSwitcher.order`): the windows on screen front to back, each the AX window `WindowMatch.pairs` pairs it with; then the rest by app, most recently active first; then the window the user was in (the frontmost app's focused window, else its front window on screen) moves to second, so the list is `[z2, z1, z3, …]` and ↵ goes back as ⌘Tab does.
      A row is the app's icon (`fileIcon`), the title or else the app's name, the app's name as subtitle and keyword (so search matches it), and "Minimized" or, with several screens, the screen's name. ↵ Switch to Window hides the panel, then, off the main thread, un-minimizes, performs `kAXRaiseAction` (and sets `kAXMainAttribute`),
      and unhides and activates the app (`NSRunningApplication.activate`, then `kAXFrontmostAttribute`, in case the system declines an activation asked for by an app that isn't active). ⌃X Close Window presses `kAXCloseButtonAttribute` (with the same 2 s AX timeout); ⌃⌥X Quit App calls `terminate()` after `confirm`; both read again 400 ms later,
      and the selection follows the window it's on when that read arrives (`WindowListing.row(sameWindowAs:in:)`, through `WindowSwitchSystem.sameWindow`, `CFEqual`), or keeps its place when that window is gone.
      **Window titles stay in memory:** the read (`WindowListing`, its handles behind closures) is kept only while the list is on screen, and dropped when it goes or the panel hides (the list then shows as loading, and the windows are read again when the panel shows); item ids and node ids are positions, never anything from a window;
      nothing per window goes to `LaunchHistory`, `LauncherLog` or a file.
      Without Accessibility (`SystemCalls.mayReadWindows`: the shared `AccessibilityGate`, as a user-initiated call, so macOS's prompt, then Fudge's offer), the List is empty and its empty view offers Open Accessibility Settings.
      The Accessibility API usually lists only the current Space's windows, and Fudge uses no private API to see the others.
      Snapshot runs use `FixedWindowSwitching`, never the system.
    - **Custom positions and saved layouts** (SPEC-094) are the user's own commands in that group, kept in `window-layouts.json` by `WindowLayoutStore` (core):
      `{ "positions": [ { id, name, x, y, width, height } ], "layouts": [ { id, name, createdAt, windows: [ { bundleId, index, screen: { name, index }, x, y, width, height } ] } ] }`, through `EntryFile` (read tolerantly, written atomically, keys it doesn't know kept, an `Unreadable` file never overwritten), and in backups.
      Frames are `WindowFractions` of a screen's visible frame, valid only within 0–1, with a width and height of at least 5% (`WindowFractions.minimum`, the same on any screen) and inside the screen; an entry that isn't valid (or a layout window that isn't) is left out and kept in the file.
      Placing one grows a side under 100 pt to 100 pt (`minimumPoints`, or the whole side of a smaller screen) and moves it back inside the visible frame, and a window saved smaller than 5% is kept at 5%.
      `BuiltInCommandGroup.all(with:)` adds Save Layout…, then each position (`position-<id>`, titled by its name) and each layout (`layout-<id>`, "Apply <name>"), each by name, after the group's own commands; the app's root search, hotkeys and Commands page use that list, never `all` alone.
      `WindowManager.run(position:)` moves the front window exactly as Left Half does (`place`, shared with the commands).
      `captureLayout` keeps every standard window (`AXWindow.standard`, `kAXStandardWindowSubrole`) of the regular apps on the screens: its app's bundle id, its place among that app's standard windows front to back (a full-screen window counts but isn't kept), its screen (`WindowScreen.name`, `NSScreen.localizedName`, and its place in the screen list) and its fractions; never a title.
      `apply` places each saved window by app and place on its screen (`SavedScreen.match`: by name, then place, then the primary), once (a hand-edited file's second entry for the same app and place is skipped), skips what isn't there (an app that isn't running is never launched), and the HUD says `LayoutPlacement.message` ("Placed 5 windows; skipped 2").
      Save Layout… reads the windows (`WindowLayoutActions`; a snapshot run's are `--layout-windows`' made-up ones, and it moves nothing), then asks for the name in the Save Layout form (`LayoutForm`, `LayoutDraft`), shown like Create Snippet.
      **The Window Management page** (`WindowManagementPage.swift`, after Snippets) lists the positions (+, Edit…, −; the sheet takes x, y, width and height in percent, checked by `PositionDraft.problems`, with a drawing) and the layouts (Rename…, −).
      Deleting one also removes its command's alias, hotkey and Enabled from `settings.json`.
      `--edit-position [<name>]` shows the sheet in the page in a snapshot run, never as a sheet.
    - **System commands** (`BuiltInCommandGroup.system`, one command per `SystemCommand`): Lock Screen, Sleep, Restart, Shut Down, Log Out, Empty Trash, Eject All Disks, Toggle Dark Mode, Hide All Apps and Quit All Apps.
      `SystemCommandRunner` (core) decides everything over `SystemActions`, a protocol the app's `MacSystemActions` implements with public APIs, and tests with a fake that only records: no test, snapshot or probe locks, sleeps, restarts, logs out, empties the Trash, ejects, changes the appearance, hides or quits anything (snapshot runs get `InertSystemActions`).
      Restart, Shut Down, Log Out, Empty Trash and Quit All Apps ask first through `confirm` (`SystemConfirmation`, the action as a destructive button), Empty Trash always, as in Raycast.
      Restart, Shut Down and Log Out send `loginwindow` (addressed as the system process, Apple's QA1134) `kAERestart`, `kAEShutDown` and `kAEReallyLogOut` (`kAELogOut` would ask again), after Fudge's own question.
      Empty Trash counts through Finder (`count items of trash`, every volume's Trash, with no Full Disk Access), so one Automation answer covers counting and emptying; a refusal says so and asks nothing.
      Its question has the number of items when Finder counted some, else none ("The items in the Trash will be deleted permanently."), so a count of 0, or one Fudge couldn't get or read, never turns into "empty".
      `SystemAppleEvents` (core) builds the events and reads their replies, so tests pin their shape:
      the count is `core/cnte` with the Trash (`trsh` of the application) as the direct parameter and `kocl` `cobj`, as AppleScript sends it (with `every item of trash` there instead, `kocl` would count inside each item), and a reply counts only when its direct parameter coerces to a 32-bit integer, as Toggle Dark Mode's must to a boolean; anything else throws.
      Toggle Dark Mode sets System Events' `dark mode of appearance preferences`, launching System Events first when it isn't running.
      Automation of Finder, System Events and `loginwindow` is asked for as user-initiated (`AEDeterminePermissionToAutomateTarget`), and a refusal's HUD says where to allow it.
      Lock Screen posts ⌃⌘Q at the HID level, on the key that types "q" (`LockScreenKey`), after `AccessibilityGate`'s check.
      Sleep is `IOPMSleepSystem`.
      Eject All Disks unmounts ejectable, removable and network volumes, never the one macOS started from (`MountedVolume.toEject`, which puts each disk's volumes together, by DiskArbitration's whole disk, read only), off the main thread, and the HUD names what it ejected and what it couldn't, with why.
      Ejecting a volume ejects its whole disk, so each volume is checked before its turn (`SystemActions.isMounted`, the mounted volumes read afresh): one that's gone went with its disk and counts as ejected.
      Whether an eject worked is read from the mounts afterwards, never from the call's error.
      When the mounts can't be read, each volume is still ejected, and the HUD says it couldn't check, never that it ejected.
      Hide All Apps hides every regular app but Fudge; Quit All Apps asks every regular app but Fudge and Finder that has finished launching to quit, counting and reading the list the same way, again once confirmed (`RunningApp.toHide`, `toQuit`).
      `LauncherModel.runBuiltIn` hides the panel first, as for window commands, and a command that asks does it in an alert of its own.
      In a snapshot run, `confirm` lays the alert out off-screen (`SnapshotSheet.laidOut`) and answers no, and the run saves the alert instead of the panel (`--query "empty trash" --activate`; `--trash-count <n>` sets the made-up count, 12 by default, and anything but a number is a count Finder couldn't give).
    - **Search Menu Items** (FUD-121, `BuiltInCommandGroup.apps`, `:apps/search-menu-items`) lists the menu items of the app the user was in: the frontmost one, never Fudge (`MenuTarget.searched`).
      It's a List built in core (`MenuItemsList`) under its own session (`MenuItemsList.session`), shown like Search Snippets.
      `MenuReader` (core) reads the menus over `MenuSystem`; `SystemMenus` (`FudgeApp/MenuItems.swift`) is the system side, the Accessibility API with `SystemWindows.timeout` per call: `kAXMenuBarAttribute`, then each element's role, title, enabled state, children and shortcut in one `AXUIElementCopyMultipleAttributeValues`.
      The read runs on a thread of its own, and after about 1.5 s the list shows what it found (`MenuWalk.finish`), the bottom bar saying so when some menus didn't load.
      An app still being read isn't asked again (`MenuReadsInFlight`), unless that read was cancelled because its list went (`MenuReadCancel`, when the panel hides or the list is left): the next read waits for it, up to its own deadline, since it stops at its next step.
      The rows are the enabled leaf items with a title, in menu order, none of the Apple menu's: the menus above as the subtitle, the app's own menu by the app's name, and the shortcut as keycaps (`MenuShortcut.keycaps`: ⌃⌥⇧⌘, with ⌘ unless `NoCommand`, and glyph keys by `kAXMenuItemCmdGlyph`), drawn by Fudge's own `keycaps` accessory (`ListContent.Accessory.keycaps`).
      Search matches the title, and the path with the title as a keyword. ↵ finds the item first, with the panel up (`MenuItemsListing.item`): the element read, if it still answers with its title, else the item found again by its whole path, once (`MenuReader.current`, `locate`).
      Alike items (the same path and title, such as two Terminal windows) are told apart by their place among them, and found again only while their number is the one the read saw (`FoundMenuItem.place` and `count`); otherwise the item counts as gone, never pressed by a place that now means another.
      Every alike leaf counts, whether it's on, off or of unknown state, at the read as at the press, though only those that aren't off are listed, and neither enters a menu that's off, so a twin turned on or off in between leaves the others' places as they were (SPEC-118 §2).
      An item turned off since the read isn't pressed, and a toast says "That menu item is turned off right now." (`MenuLookup.disabled`).
      `MenuNode.enabled` is nil when the app couldn't give `kAXEnabledAttribute` (it timed out, say): the list shows such an item, and a press takes it as no answer, never as on; an item that has no such attribute at all counts as on.
      When it's gone, a toast says "That menu item isn't there anymore." and the menus are read again.
      Found, and only while the list the run came from is still on screen (`MenuItemRun`; hiding the panel or leaving the list moves `MenuItemsGeneration` on), the panel hides, the app is made active if it isn't, and the item is pressed (`kAXPressAction`), so an app slow to answer never comes back over the one the user went to.
      No answer in time says nothing, since an item that opens a dialog can hold the answer back.
      **Menu titles stay in memory**, since they name documents: nothing logs them, rows are known by place (item and node ids are positions), and only the command's launch goes into `LaunchHistory`.
      Each app's last read is kept for the run (`MenuItemsCache`, by bundle id, the 8 most recent apps) and shown at once the next time while the menus are read again, the selection staying on the same item (`MenuItemsList.place`).
      Hiding the panel drops the read on screen, and showing it reads the frontmost app's menus again.
      Without Accessibility the list says so, after the gate's prompt or offer.
      Snapshot runs never read a real app's menus (`FixedMenuSystem`).
    - **Hyperkey** (SPEC-093) is off until **Hyperkey (Caps Lock)** (`hyperkey` in `settings.json`, the General page's switch, `HyperkeyControls`) is on; then holding Caps Lock adds ⌘⌥⌃⇧ to every key pressed.
      `HyperkeyService` (app) maps Caps Lock to F18 (`HyperkeyMapping.entry`) in macOS's per-user key mapping through `/usr/bin/hidutil` (`HidutilKeyMapping`, behind core's `KeyMappingSystem`, so no test runs it), on a serial queue off the main thread.
      `HyperkeyMapping` (core) reads `hidutil`'s output (`(null)`, or CoreFoundation's description of the list), adds or removes only Fudge's entry and writes the whole list back.
      It refuses, naming the key, when Caps Lock is mapped elsewhere: in the mapping every keyboard gets, in a keyboard's own (`--matching keyboard`), or in System Settings → Keyboard → Modifier Keys (`HIDKeyboardModifierMappingPairs`, per keyboard; Caps Lock left as itself there isn't a mapping).
      It also refuses when any of them can't be read.
      A Caps Lock → Caps Lock entry, which some tools write, isn't a mapping, but Fudge's entry takes its place rather than adding a second one for Caps Lock (`HyperkeyMapping.capsLockItself`, SPEC-118 §1).
      Removing Fudge's entry puts it back where it was, the launch cleanup after a crash included, since `HidutilKeyMapping` remembers it in `hyperkey.json` in the support folder (written before the mapping, never in a backup).
      Turning it on needs Accessibility (`SystemCalls.mayPostKeysForUser`, the usual prompt and offer) and is saved only once the tap runs and the mapping is in; a refusal shows under the switch (`hyperkeyProblem`).
      An active `CGEventTap` at the HID level runs on a thread and run loop of its own (`HyperTapThread`), and sees only the keyboard's own events (`eventSourceStateID` is the HID system's, so keys Fudge or another app posts are left alone).
      It hands each key's code, kind, repeat flag and time to `HyperTap` (core): F18's own events are swallowed, and any other key gets ⌘⌥⌃⇧ while F18 is down in the HID system.
      That state is `CGEventSource.keyState(.hidSystemState)`, read for every event, never only what the tap saw, so a lost key-up can't leave Hyper stuck.
      It keeps nothing about what's typed, only when F18 went down and whether another key came since, and nothing is logged.
      With **Quick press toggles Caps Lock** (`hyperkeyQuickPress`), a press under 200 ms with no other key toggles Caps Lock with `IOHIDSetModifierLockState` (a posted key can't).
      Under secure input the tap does nothing, and the state starts over then, when macOS turns the tap off and it's turned back on, and when it's switched off.
      `HyperkeyLifecycle` (core) decides when it runs, at launch, on each change and every 2 s: only while the setting is on and Accessibility is allowed, so without Accessibility the tap stops and the mapping goes, and both come back with it.
      Whenever it won't run, Fudge's entry is removed once, at launch too, since a crash, a kill or a force-quit skips the removal at quit and a leftover Caps Lock → F18 with no tap leaves Caps Lock dead.
      A start that failed (the tap or the mapping refused) isn't tried again until the setting or Accessibility changes.
      Quitting removes Fudge's entry, and SIGTERM quits as Quit does (`NSApp.terminate`), so a kill or `make run`'s restart does too; `hidutil` mappings also reset at logout.
      The 2 s check also turns the tap back on if macOS left it off.
      With Quick press off, Fudge turns caps off when Hyperkey starts, since the key no longer can.
      The quick press is timed on the uptime clock (`CLOCK_UPTIME_RAW`), read in the tap.
      `HotKeySpec` shows all four modifiers as "Hyper" (`isHyper`; "Hyper+T", and a "Hyper" keycap), and saves them as the four.
      Snapshot runs never tap or run `hidutil`.
    - **The Color Picker** (SPEC-090) is the Tools group (`BuiltInCommandGroup.tools`, one command per `ToolCommand`), a group for utilities that also holds Define Word.
      **Pick Color** hides the panel as the window commands do, then shows macOS's loupe through `ColorSampling` (the app's `ScreenColorSampler` is `NSColorSampler`, which needs no Screen Recording permission; snapshot runs get `InertColorSampler`, which picks nothing, and tests a fake).
      `ColorPick` (core) copies the picked color in the **Copy Format** (`colorFormat` in `settings.json`, `ColorFormat`: HEX by default, RGB, HSL, SwiftUI or UIColor) with a HUD ("Copied #3A7BD5") and adds it to Recent Colors; Esc copies and keeps nothing, and a color `colors.json` can't take is still copied, with the HUD saying so.
      `PickedColor(cgColor:)` converts the loupe's color, which is in the display's color space (often Display P3), to sRGB with `CGColor.converted(to:)` (what `NSColor.usingColorSpace(.sRGB)` gives), and every component is clamped to 0…1 and read-only once made.
      Each format is written from the components rounded to bytes.
      HEX, RGB, SwiftUI and UIColor name exactly the color the HEX does; HSL is in whole degrees and percent, as CSS writes it, so it's rounded: `#3A7BD5`, `rgb(58, 123, 213)`, `hsl(215, 65%, 53%)`, `Color(red: 0.227, green: 0.482, blue: 0.835)`, `UIColor(red: 0.227, green: 0.482, blue: 0.835, alpha: 1)`, and with alpha `#3A7BD580`, `rgba(…, 0.502)`, `hsla(…)` and `opacity:`.
      `RecentColorStore` (core) keeps `colors.json`, `{ "colors": [ { id, red, green, blue, alpha, pickedAt } ] }`, newest first, through `EntryFile` as snippets are kept: at most 32 valid colors, the oldest dropped (entries that aren't colors don't count, and stay in the file), and a color picked again (the same bytes) moves to the top.
      **Recent Colors** (`RecentColorsGrid`, core) is a Grid of 8 columns built in core and shown like Search Snippets, under its own session (`RecentColorsGrid.session`, in `LauncherModel.builtInSessions`): a swatch per color titled with its HEX.
      ↵ copies in the Copy Format, ⌘K lists every format with that one first, ⌃X removes a color, and ⌃⇧X (Clear Recent Colors…) asks through `confirm` first;
      each copy hides the panel with a HUD.
      Its empty view offers Pick Color.
      Its hotkey shows it as a view command's does, or hides the panel when it's already on screen.
      **The Color Picker page** (`ColorPickerPage.swift`, after Sign-in) has Copy Format, a `SettingsPopupRow`; changing it draws Recent Colors again if it's open.
    - **Define Word** (SPEC-091, the Tools group) takes an optional Word argument (`DefineWord.argument`), and `define` is its default alias (`BuiltInCommand.defaultAlias`), so `define serendipity` hands "serendipity" to the field.
      `DefineWord.start` (core) takes the typed word, else the frontmost app's selection (`LauncherModel.selectedText`, `selection.text` as the user's own call, read only when nothing was typed), each cut to its first line that isn't blank, trimmed, at most 100 characters (`DefineWord.word`); with neither, root search shows the Word field with the keyboard in it.
      The word is looked up through `DefinitionLookup`: the app's `DictionaryServicesLookup` is `DCSCopyTextDefinition`, the Mac's active dictionaries, offline; snapshot runs read no selection and get `FixedDefinitions` (`--definitions <file>`, a JSON object of word to made-up definition, else none), and tests fakes.
      `DefineWordView` (core) is a Detail under its own session (in `LauncherModel.builtInSessions`), and `DefinitionText.markdown` makes the dictionary's plain text light Markdown.
      The headword, the text before the first " | ", is the heading, then the pronunciation; each part of speech is in italics on its own line where a definition or a run of senses starts, and each numbered sense in the expected order, each `•` sub-sense and each section such as ORIGIN gets a line of its own.
      Everything from the dictionary, and the word, is escaped so none of it is read as Markdown (`DefinitionText.escaped`), scalar by scalar as Markdown reads it, since a `*` with a combining mark after it is one `Character` that isn't `*` (FUD-142).
      An e-mail address in it is still linked, since that happens after escapes are read.
      ↵ and ⌘D (Look Up in Dictionary) open `dict://` and the word, percent-encoded and cut (`DefineWord.dictionaryURL`); ⌘↵ (Copy Definition) copies the dictionary's text with a HUD.
      With no definition it says so, with Look Up in Dictionary only.
      A run from root search shows its result only if root search is still on Define Word when the selection and the dictionary have answered.
    - **My Schedule** (`BuiltInCommandGroup.calendar`, SPEC-092) lists the Mac's events through EventKit, behind `CalendarSource` (core).
      The app's `EventKitCalendarSource` implements it, reading only; tests and snapshot runs fake it with `FixedCalendarSource` (`--calendar-events <file>`, made-up events with times relative to now), so nothing reads the real calendars there.
      `Schedule` (core) holds the logic: the days from today to **Days Ahead** (`calendarDaysAhead`: 1, 3, 7 or 14), each titled Today, Tomorrow or its date, with the events not over yet that overlap it.
      An event spanning days is on each, as "From 22:00", "All day" or "Until 10:00"; all-day ones come first; "Now" or "in N min" marks what's within the hour; and the calendars unticked on the Calendar page are left out (`calendarHidden`, so a new calendar shows).
      `ScheduleList` (core) is the List, built like Search Snippets and shown under its own session (`ScheduleList.session`), so nothing of it reaches the host.
      **Invites are written by other people.** `MeetingLinks` (core) takes a link from the event's URL, then location, then notes, only when its parsed host, written plainly (no user, no percent encoding), is a known meeting host or a subdomain of one (`MeetingLinks.hosts`).
      Its scheme must be `https` with a path, or a meeting app's on that service's hosts (`zoommtg`, `msteams`; `facetime:` calls whoever it names, so FaceTime counts only as `https://facetime.apple.com/…`), never matched by substring and never another scheme.
      Only the first 20,000 characters of a location or notes are looked through (`MeetingLinks.searchedLength`), and the detail shows the first 5,000, since an invite's notes can be megabytes.
      The notes are shown in a code block, so nothing in them is read as markdown and no image loads.
      Nothing from an event is logged or written anywhere, its row id is its position (`event-<n>`), and only the command counts in `LaunchHistory`.
      ↵ is Join Meeting when there's a link, else Open in Calendar (⌘O, `ical://ekevent/<id>?method=show&options=more`), then Copy Meeting Link (⌘⇧C) and Copy Details; Show Details (⌘D) shows the detail pane, which hides the rows' times.
      Calendar access (`NSCalendarsFullAccessUsageDescription`) is asked for only when My Schedule runs, the first time; refused, it shows an empty view with Open Privacy Settings.
      A search that matches none of the events listed says "No events match", with no action; "No upcoming events", with Open Calendar Settings, is for days with no events.
      Its hotkey hides it again when it's on screen, and `EKEventStoreChanged` draws it again.
      After a new read (a calendar change, Days Ahead, a refresh), the selection stays on the event it was on (`ScheduleList.row(after:selected:in:)`), known by its day, its start and a hash of its title held in memory only, or keeps its place when that event is gone.
      The calendars are read off the main thread (`LauncherModel.readSchedule`, and the Calendar page's `loadCalendars`), since every EventKit call waits on the calendar agent: the list shows as loading until the read lands, and ⌘D draws again from it without reading again.
      `EventKitCalendarSource` runs every call on one serial queue, and makes its store on first use.
      **Settings → Calendar** (`CalendarPage.swift`, after Sign-in) has Days Ahead and a checkbox per calendar.
    - **Arguments.**
      A selected command's `arguments` get fields after the query, which then shrinks to its text.
      `ArgumentInput` (core) holds what's entered and which field has the keyboard, and takes the keys: Tab and ⇧Tab between the fields, Esc back to the query, ⌫ in an empty field back one, ↑↓ on a dropdown argument. ↵ with a required argument empty moves the keyboard there and outlines it.
      The model decides which field has the keyboard, and takes a move SwiftUI reports only while the panel holds the keyboard (`ArgumentInput.follows`; `LauncherPanel.holdsKeyboard`, from its own `becomeKey` and `resignKey`), since the user moves it only then.
      In a panel that doesn't (a snapshot run's never does), a field can't take the keyboard, and SwiftUI answers by falling back to the search field, then asking again; taken as moves, those answers undid the request and set off the next without end (FUD-140).
      A launch passes every argument in `launchProps.arguments`, with an empty string for those left empty, and the fields start over.
      They also start over when the selection moves, but not when a launch couldn't start.
    - **Quicklinks** (FUD-86) are root items too (`RootItem.quicklink`, kind "Quicklink"), from `QuicklinkStore` (core):
      `quicklinks.json`, `{ "quicklinks": [ { id, name, link, application?, createdAt } ] }`, read tolerantly and written atomically, keeping keys it doesn't know on the file and on each entry, and entries that aren't valid quicklinks (no `id`, a `name` outside 1–64 characters, no `link`).
      It never overwrites a file it can't read (`Unreadable`).
      `applySettings` reads it again, so a change shows at once.
      Search matches the name, and the link without its placeholders like a subtitle (`secondaryText`, `QuicklinkTemplate.searchableText`), so typing "argument" doesn't list every quicklink with a field.
      `QuicklinkTemplate` (core) reads the link's placeholders: arguments (`{argument name="…" default="…" options="a, b"}`, an unnamed `{argument}`, and Raycast's older bare `{Query}`; the same name twice is one field, at most 3), which become root search's argument fields (`fields`:
      a dropdown for `options`, required unless there's a default), dynamic values (`{clipboard}`, `{uuid}`, `{date}`, `{time}`, `{datetime}`, in the Mac's format and calendar), and modifiers (`raw`, `percent-encode`, `uppercase`, `lowercase`, `trim`) after a `|` outside quotes, so `default="a|b"` stays one attribute.
      Raycast's other dynamic names (`{selection}`, `{day}`, `{cursor}`, `{browser-tab}`, `{snippet}`), attributes Fudge doesn't know and unbalanced braces are a `problem` naming the placeholder; such a quicklink shows, with no fields, and opening it shows the problem.
      Dynamic names and modifiers ignore letter case (`{Date | UPPERCASE}`).
      In a URL every value is encoded as JavaScript's `encodeURIComponent` does, unless it's `raw`; in a path (starting with `/` or `~`) values go in as they are; a link that is one placeholder is taken raw.
      The clipboard is read only for a link that uses `{clipboard}` (`usesClipboard`), and reads as nothing when it's marked concealed or transient (`clipboardText`). ↵ fills it in, and `QuicklinkOpening` (core) checks the result: a URL with a scheme, or a path that exists.
      It opens through `SystemCalls`' `open`, with the quicklink's `application` (a bundle id) or the default app, then records the launch and hides the panel; any failure is a toast (`SystemCalls.message(of:)`: Fudge's message or the system's localized one) and the panel stays.
      The row's icon is the opening app's: the `application`'s, else the default app for the scheme, else the path's own icon; nothing is fetched. ⌘K adds Copy Link (⇧⌘C, the link as saved), Edit Quicklink… (⌘E) and Delete Quicklink… (⌃X, after `confirm`).
      **Each quicklink is a command too** (SPEC-097, `QuicklinkCommands`, core): its alias, hotkey and Enabled are kept in `settings.json`'s `commands` under `:quicklinks/<id>`, by its `id` (never its name, so a rename keeps them) exactly as `quicklinks.json` holds it, and the group's own Enabled under `extensions`, as a built-in group's are.
      A quicklink id has its own rule for that (`QuicklinkCommands.isValidID`: 1–64 ASCII letters, digits, `-` and `_`, letter case kept, since `UUID().uuidString` is upper case and the extension name rule allows none), and one that doesn't fit gets no settings, though it still shows and opens.
      `RootItem.commandSettingsID` gives a quicklink's item that key, so `RootSearch.applying` drops a disabled one and sets its alias, and `RootItem.id(forCommandSettingsID:)` maps a key back to `quicklink:<id>` for the pressed hotkey and the row's keycaps.
      The quicklinks' keys count as installed commands' (`QuicklinkCommands.commandIDs`), so their hotkeys are registered, block a key and are named in conflicts by the quicklink's name (`QuicklinkCommands.group`, passed to `CommandNames`).
      A hotkey follows `QuicklinkCommands.hotkeyLaunch`, as a no-view command's does: with no required field it opens at once, filled in at the press (`QuicklinkOpening.target(for:arguments:context:)`), leaving root search as it is and showing a failure in the HUD; with one, it shows root search with the quicklink selected and its fields.
      Deleting a quicklink, in the launcher or in Settings, also takes its keys out of `settings.json` (`QuicklinkCommands.prune`) and registers the hotkeys again.
      Only ids no entry in `quicklinks.json` has are pruned (`QuicklinkStore.entryIDs`), so an entry a hand edit broke keeps its settings until it's fixed or gone.
      A message naming the key of a quicklink that's gone says "a deleted quicklink" (`QuicklinkCommands.nameWhenGone`), and an alias such a key still holds is freed when it's asked for.
    - **The Create Quicklink form** makes and edits quicklinks: the "Create Quicklink" root item, Edit Quicklink…, and an extension's `Action.CreateQuicklink`.
      It's a Form view built in core (`QuicklinkForm.view`: Name, Link with its info text, and Open With, a dropdown of "Default" then root search's applications by bundle id; an app it names that isn't listed is kept, by its bundle id), shown as a `CommandScreen` whose session is `QuicklinkForm.session`, so `FormScreen`, ⌘↵, ⌘K, Tab and Esc work as in any Form.
      Nothing of it reaches the host: `send` hands its events to `builtInFormEvent`, and drops its `pop`, `unload` and `slots`.
      Its fields are uncontrolled with fixed node ids, so a render keeps what was typed. ⌘↵ (Save Quicklink) reads the file again and checks `QuicklinkDraft.problems` (core):
      a name of 1–64 characters that no other quicklink has, ignoring case and spaces around it, and a link with no placeholder problem that's a URL with a scheme, a path (`/`, `~` or `~/`), or starts with a placeholder (`{clipboard}`).
      Problems show as the fields' `error`s, each until its field is edited.
      Saving trims both, replaces the edited quicklink by `id` (keeping its `createdAt` and keys Fudge doesn't know) or adds a new one, writes the file (an `Unreadable` one stays as it is, with a toast), shows the HUD "Quicklink saved" and closes the form.
      Closing (a save, or Esc) goes back to root search, with its query cleared after a save, or to the extension's view it was opened over (`BuiltInFormState.returnTo`).
      That view's session keeps running meanwhile: its renders, errors and exit wait in `deferred` and are handled once it's back, and its calls are answered as usual.
      If the form goes any other way (a launch, Pop to Root Search, a reset), `builtInFormLeft` unloads that session too.
      The Create Snippet form takes the same path: `BuiltInFormState`'s content is a quicklink draft or a snippet draft, each form with its own session, and `LauncherModel.builtInSessions` lists every session of Fudge's own that `send` keeps from the host.
    - **`Action.CreateQuicklink`** renders a host `Action` with `fudgeBuiltIn: "createQuicklink"` and a `quicklink` prop (its link, name and application: a name or bundle id, or an `Application`'s name, path and bundle id; the icon isn't used).
      `ActionPanelReader` makes it `ActionTarget.createQuicklink(QuicklinkRequest)`, and running it opens the form over the command's view, filled in by `QuicklinkDraft(request:commandTitle:applications:)`: the link, the name or else the command's title, and the application matched by bundle id, path or name, ignoring case (else Default).
    - **Snippets** (FUD-101) are saved text to paste.
      `SnippetStore` (core) keeps them in `snippets.json`, `{ "snippets": [ { id, name, text, keyword?, createdAt } ] }`, through `EntryFile`, the file logic it shares with `QuicklinkStore`: read tolerantly, written atomically, keys it doesn't know and invalid entries kept, and an `Unreadable` file never overwritten.
      A name has 1–64 characters, unique ignoring case; the text at most 100,000; a keyword 1–32 characters with no whitespace, and no keyword may contain another, ignoring case, as a prefix, a suffix or inside it (`Snippet.keywordsClash`), so expansion is never ambiguous.
      `SnippetTemplate` (core) reads the text with `QuicklinkTemplate`'s parser in its snippet mode (`parseSnippet`): `{clipboard}`, `{date}`, `{time}`, `{datetime}`, `{day}` (the weekday), `{uuid}`, at most one `{cursor}`, and the modifiers, with nothing encoded; `{date}`, `{time}` and `{datetime}` take a `format` (a Unicode date pattern, `Placeholder.format`).
      In a snippet a `{` starts a placeholder only when what follows it, up to the next `}` on the same line with no `{` between, is one of `snippetNames` (those, and Raycast's names Fudge refuses: `{argument}`, `{selection}`, `{browser-tab}`, `{snippet}`) first thing, then only attributes and modifiers (FUD-130).
      Any other brace, lone or paired, is text, so code and JSON paste as written, and a name is a placeholder wherever it sits (`{{date}}` is a brace, the date and a brace), with no escape, as in Raycast.
      A known name used wrongly (an attribute it doesn't take, an unknown modifier, a second `{cursor}`) and Raycast's refused names are a problem.
      Quicklinks are unchanged: there every brace is a placeholder.
      `fill` gives the text and how many grapheme clusters follow `{cursor}`.
    - **Search Snippets** (`SnippetList`, core) is a List built in core and shown like Fudge's forms, under its own session (`SnippetList.session`), so nothing of it reaches the host.
      Snippets are listed by name, and Raycast's filtering matches the name, the keyword and the text's first 200 characters.
      The detail shows the text in a code block whose fence no line of it can close, what it pastes as when it has placeholders, and the keyword. ↵ pastes through `Paste`, in its turn, with the panel hidden and the clipboard put back, and `Paste` then puts the caret where `{cursor}` was (`leftArrows`, the grapheme clusters after it; `CaretPlacer`, below); ⌘↵ copies with a HUD;
      ⌘E opens the form over the list, which is drawn again when the form closes; ⌃X deletes after `confirm`; ⌘N creates one.
      An action is read back from its node id (`SnippetList.target`).
      The clipboard is read for `{clipboard}` only when a snippet uses it (`LauncherModel.templateClipboard`, which reads none in snapshot runs).
      **The Create Snippet form** (`SnippetForm`, `SnippetDraft`, core) has Name, a several-line Snippet with the placeholders as its info, and Keyword.
      `SnippetDraft.problems` checks the rules above, and saving trims the name and keyword and keeps the text exactly as typed.
    - **`Action.CreateSnippet`** renders a host `Action` with `fudgeBuiltIn: "createSnippet"` and its `snippet` (text, name and keyword), which `ActionPanelReader` makes `ActionTarget.createSnippet(SnippetRequest)`.
      Running it opens the Create Snippet form over the command's view, with the name, or else the command's title.
    - **Expanding snippets as you type** (SPEC-078 B) is off until **Expand Snippets as You Type** (`expandSnippets` in `settings.json`, the Snippets page's switch) is on.
      `SnippetExpansion` (app) then runs a **listen-only** `CGEventTap` on key-down and clicks (it can't swallow or change a key), at the annotated session point, so each key names the app it goes to (`eventTargetUnixProcessID`).
      The tap runs only while some snippet has a keyword and Input Monitoring is allowed (`IOHIDCheckAccess`, checked every 2 s, so revoking it removes the tap), and goes at once when switched off.
      Each key's facts go to `SnippetExpander` (core), which keeps the last 32 characters typed and answers only `.expand(snippetID:)` when they end with a keyword, matched exactly as written.
      **What's typed never leaves it** (the reviewer's MUST 2): the buffer is private, its description and mirror show nothing typed, and all the launcher's log gets is "expand snippet", with the id `.private`, then, for a `{cursor}`, `Paste`'s caret line (numbers only).
      It's cleared by a click, an app switch, Return, Tab, Esc, ⌦, the arrows and page keys, the function keys, ⌥⌫, a ⌘ or ⌃ combination, one of Fudge's windows having the keyboard (the launcher's non-activating panel included), the snippets changing, switching off and the permission being revoked; ⌫ takes one character back.
      A key that goes to another app than the last one clears it too (`SnippetKeyEvent.target`), so a panel that takes the keyboard mid-keyword never gets the ⌫s.
      Under secure input (`IsSecureEventInputEnabled()`) nothing is kept or expanded.
      macOS delivers no keys to the tap then, so secure input is also checked twice a second while the tap runs, and in the 2 s poll, which clear the buffer (`Reset.secureInput`); both timers run in the common run-loop modes, so a modal session doesn't stop them.
      Keys Fudge posts carry `SnippetExpander.marker` as their `eventSourceUserData` and are ignored.
      Keywords that clash, which only a hand edit or a restore can hold, expand none of them.
      A tap macOS turns off is turned back on.
      Expanding checks secure input and Fudge's windows again, then `SystemCalls.expandSnippet` checks Accessibility without a prompt (without it nothing is deleted, the clipboard isn't touched, and a HUD says so once per run).
      It pastes through `Paste.expand` in its turn: `backspaces` ⌫ presses delete the keyword just before ⌘V, and `{cursor}`'s ← presses follow.
      Only an expansion with a `{cursor}` reads the field (below); a plain one has no caret to place, so its ⌫s and ⌘V go at once, and its restore waits the plain second after ⌘V (SPEC-118 §3).
      All of them go to the app the keyword's last key went to, never to the frontmost app when that's another (a panel such as Spotlight's has the keyboard without being frontmost).
      Nothing is posted when that app is unknown or Fudge, or when secure input is on by the time the turn comes or comes on while the field is read (checked again right before the first key), and the clipboard is put back.
      `SnippetTemplate.leftArrows` caps those at 2,000, past which the caret stays at the end.
      The switch's row shows Input Monitoring's status every second while the page is on screen; turning it on without the permission explains it in a sheet, then asks macOS (its prompt the first time, the Input Monitoring pane after that); onboarding's step turns it on the same way (`SettingsModel.turnOnSnippetExpansion`).
      Snapshot runs never tap (`--input-monitoring allowed|missing` fixes the status shown).
    - **The calculator.**
      On each root query, `Calculator.evaluate` (core) tries `TimeZoneConversion` (`13.00 copenhagen time to new york time`, `3pm cet in pst`, `time in tokyo`), then `CurrencyConversion` (`100 usd to eur`, `€100 in usd`, `100 € in kr`:
      the ECB's codes from a static list, four symbols, and `kr` as the locale's krone or krona, else DKK), then `UnitConversion` (`13kg to lbs`, through Foundation's `Measurement`, with exact factors where Foundation rounds), then `Arithmetic` (a recursive-descent parser with `%`, `!`, functions and implicit products, where a sign binds looser than a right-associative `^`, so `-2^2` is -4).
      It ignores queries over 200 characters, a lone number, constants alone (`e`, `pi pi`), an ISO date (`2026-11-20`), and non-finite results.
      Numbers are read and written in a `NumberFormat` (core): the `numberFormat` setting, "Same as macOS" by default, resolved from `Locale.current` for each query (`NumberFormatSetting.resolve`), so `Calculator.evaluate` takes a format besides the locale, which still names times, dates and currencies.
      Reading (`NumberFormat.number`): the decimal separator starts the fraction, at most once, and the format's grouping separator (`typedGrouping`: `.`, `,`, or `'` and `’` alike) is dropped wherever it stands between two digits, with no group sizes checked, since it's only there for the eye (`0.1234` is 1234 and `1.5` is 15 with "1.234,5").
      A grouping separator anywhere else (`.5`, `5.`, `1..2` there), or a second decimal separator, means no card.
      The tokenizer and the conversions' patterns keep every grouping character inside a number (`NumberFormat.groupingCharacters`) and let the format decide.
      A grouping the locale writes as a space is shown on the card but never read, since a space separates tokens.
      Copies use the decimal separator without grouping.
      A number can have an exponent with no spaces inside (`1e-7`, `2.5E3`, `2e+1`, and the card's own `1.152921505E18`), which conversions read too; without a digit straight after the `e` and its sign, the `e` is the constant (`2e`, `2e + 1`).
      The `CalculatorResult` shows as a card above the results: the question and answer, and a label under each.
      The card's answer has 10 significant digits, or, while it's written out (below 1e15), as many as its integer part has, up to 15, so it never rounds the integer part; a copied answer has up to 15, so floating-point noise (`0.1+0.2`) rounds away.
      A zone's label is its familiar abbreviation where `TimeZoneConversion.named` has one (`Copenhagen, CET`), else Foundation's offset (`GMT+8`).
      The card is selected first, and ↵ copies the answer (`RootActions.calculatorSections`, plus Copy Question and Answer ⌘⇧C) and closes the panel with a HUD.
      `now` and the time zone are parameters, so tests fix them.
    - **Currency rates** come from the European Central Bank, and only while `currencyRates` is on in `settings.json` (off by default; the General page's switch).
      `ExchangeRateUpdater` (core) loads `exchange-rates.json` and downloads when `ExchangeRatePolicy` says so: on turning it on, when the rates are a day old, at most once per 12 hours, one download at a time, keeping the old rates when one fails. ↵ on the "Couldn't download exchange rates" card retries at once.
      `ExchangeRates` parses the ECB's XML and says how fresh the rates are, under the card's arrow.
      The app's `ECBRatesFetcher` uses an ephemeral `URLSession` (no cookies, credentials or cache; 15 s; 1 MB), and `ExchangeRateSchedule` checks every hour.
      With the setting off, a currency query still gets a card ("Currency conversion is off"), and its ↵ opens Settings on the General page.
      When the rates change (they arrive, a download starts or fails), a currency card is evaluated again for the open query, keeping the selection (`Calculator.afterRatesChange`), with a command open too, so the card is right when the user comes back to root search.
      Snapshots never download.
    - **The update check** (SPEC-082) asks GitHub for the newest release, and only once `updateCheck` in `settings.json` has been chosen: `daily`, `weekly`, `monthly` or `off` (`UpdateCheckSetting`; unset until onboarding's Updates step or General's Check for Updates saves it, and an unknown value reads as unset).
      `UpdateChecker` (core) checks when `UpdateCheckPolicy` says it's due: the last success is older than the interval (30 days for monthly) or in the future, so never more than once per interval.
      The app asks at launch and every hour (`UpdateCheckSchedule`), so a failure is tried again at the next tick, with at most 4 scheduled failures in a rolling day.
      Check Now (General, and the menu's Check for Updates…, which opens General first) always runs; its failures don't count.
      One check runs at a time.
      `update-check.json` (`UpdateCheckState`) keeps the last check, the last success, the latest release's tag, the last failure, the failed scheduled checks and the version the HUD announced; it's read tolerantly and written atomically.
      **The running version** (`RunningVersion`) is what the Makefile writes into `Info.plist`'s `FudgeGitDescribe` (`FudgeVersion.describe`), `git describe --tags --always --dirty`: a trailing `-dirty`, then `-<n>-g<hex>`, then a leading `v` come off by their exact shapes, and the rest is a `SemanticVersion` (semver 2.0.0, compared by precedence, build metadata dropped).
      It reads `FudgeVersion.display`'s form too (`0.2.0-dev+14.51ba5a2` is 0.2.0): a last pre-release identifier `dev` with build metadata is a build after that version.
      Anything else, such as a bare commit or `dev`, is untagged and older than any release.
      So a dev build after `v0.2.0` is told about `v0.2.1` but not `v0.2.0`, and `v1.2.0-rc.1-3-gabc1234` about `v1.2.0`.
      **GitHub's answer** (`UpdateCheck.parseLatest`): `tag_name`, and `draft` and `prerelease`, which must be JSON booleans; a draft, a pre-release or a pre-release tag counts as no release, as does GitHub's 404 when there's none yet.
      The tag must be `v` and a semantic version, and the release page is built from it (`Release.pageURL`), never from `html_url`.
      The app's `GitHubReleaseFetcher` sends one GET of `releases/latest` with `User-Agent: Fudge/<version>` (`UpdateCheck.userAgent`), `Accept: application/vnd.github+json` and `Accept-Language: en` (else URLSession adds the Mac's languages), on an ephemeral `URLSession` (no cookies, credentials or cache; 15 s), and reads at most 1 MB (`UpdateCheck.readBody`; `parseLatest` refuses more too).
      General's update row names the running version (`UpdateStatus.headline(version:)`): `Fudge 0.3.0 is up to date`, `Fudge 0.3.0: not checked for updates yet` or `Fudge 0.3.0: couldn't check for updates`.
      A newer release shows as General's `Fudge <version> is available` with Download…, `You have Fudge <running version>` under it, the menu's `Fudge <version> Is Available…`, and, once per version, the HUD; Download… and the menu item open the release page.
      A failure shows on General only.
      Nothing is downloaded or installed.
      Snapshot runs and tests never ask GitHub: tests use fake fetchers, and a snapshot run uses `SnapshotReleaseFetcher`, keeps the state in memory and counts as untagged, so `--update-available <version>` shows that version as found.
    - `LauncherView` is the SwiftUI side.
    - **Lists and Grids.**
      `ListContent` (core) reads a `List` or `Grid` node: its sections and items, Raycast's own filtering (title and keywords, best match first, sections reordered unless `keepSectionOrder`), when the empty view shows (never while loading with an empty search), accessories with dates written relatively, and the search bar's `SearchBarDropdown`.
      A new search text filters the items read at the last render again (`ListContent.search`) rather than reading the view again.
      An item's `actions` and `detail` may come after the item (`ItemSlots`, `Item.deferred`): `LauncherModel` asks for those of the selected item and the ones around it (`requestSlots`, after every render and selection change, and before `onSelectionChange` is sent) and keeps them until the next render.
      `SlotRequests` (core) decides when: since a render carries in full exactly the items of the last request, each request names the whole window (8 before the selected item, 10 after, the selected one included), and a new one goes out when the selection nears the window's edge or an item near it is still held back with no answer coming.
      Meanwhile, ↵, ⌘↵ and ⌘K pressed before the selected item's have come wait for them, as does any shortcut of that item's actions (`Item.waitsForActions`), since the render names them.
      `HeldKey` (core) holds one such key: another replaces it and starts its time over; Esc, typing, the panel hiding (`panelHidden`) and leaving the view or command drop it, saying nothing; and one whose actions haven't come 2 s after the press is dropped with a failure toast, never run late.
      `LauncherModel` keeps the selection on the same item across renders (`ListContent.selection`), follows `selectedItemId`, which wins, selects the first item when the user types (at once with Fudge's own filtering; for a command that filters itself, also with the first render of its results: `TypingSelection` waits until the text has gone to the extension,
      which a `throttle`d search does 250 ms later, then takes the first render whose items differ from those on screen then, once, unless the user moved the selection or asked for the next page meanwhile), reports `onSelectionChange`, keeps a search text per navigation level, and holds the dropdown's value (stored in `dropdown-values.json` for `storeValue`; `onChange` fires with the first value,
      as in Raycast).
      The dropdown opens as a panel (click or ⌘P) with its own search field, filtered by Fudge or by the extension's `onSearchTextChange`.
      A `searchText` the extension sets replaces the search field's text, except for stale echoes of typing (`FieldValue`).
      An item's `quickLook` (`{ path, name? }`) is read into a `QuickLookItem` (core): an absolute path, a `~/` path or a `file://` URL, titled by `name` or the file's name; anything else is none.
      With `pagination`, items coming into view or being selected near the end call `onLoadMore`, once for each length of the list.
      `ListScreen.swift` draws it all, with the detail pane for `isShowingDetail`, which shows the selected row's detail as loading while it hasn't come.
      Items outside any section form an untitled section whose id comes from its place (−1, −2, …), never from its items: the views tell sections apart by it, and an id that changed with the first item kept the old rows drawn, highlight included, after a re-rank.
      **A Grid is the same `ListContent`** (`layout: .grid`), so all of that applies to it unchanged.
      Each section carries a `GridSectionLayout` (core): the Grid's `columns` (clamped to 1–8 before it becomes an `Int`, `NaN` counting as not set; default 5, or the old `itemSize`), `aspectRatio`, `fit` and `inset` (in points, scaled with the column count), with the section's own overrides.
      A Grid item's `content` is a `GridItemContent`: an image, or a color drawn exactly as given.
      Its `drawing` says how: a picture (an asset, a file path, an http(s) image) follows the section's `fit`; an icon (a `fileIcon`, one of Raycast's icons, an emoji) is always drawn whole, centred inside the inset, so Fill never crops it; a color fills the cell.
      An image's mask shapes the drawn image, not the cell.
      `GridNavigation` (core) moves the selection in two dimensions, across sections to the nearest column, and decides when ← and → move it rather than the search field's cursor: with the field empty, or with the cursor at its end and nothing selected, and never with ⇧, ⌥, ⌘ or ⌃ (`fieldModifiers`; the `fn` and `numpad` flags every arrow key carries don't count). ↑↓ always do.
      While an input method is composing (marked text), no arrow moves a selection, in a Grid, a List or root search: they're the input method's.
      `GridScreen.swift` draws the cells, and paging asks for more two rows from the end.
    - **Markdown, metadata, images and colors** are shared by the views.
      `Markdown` (core) splits markdown into blocks, and `MarkdownView` draws them, with inline markdown through `AttributedString`.
      Code blocks wrap to the pane (inside over-long tokens too, with whitespace kept); tables scroll sideways, fading at the right edge while columns are hidden there.
      `MetadataEntry` (core) reads a `Metadata` node for `MetadataView`.
      `ExtensionImages` resolves an `Image.ImageLike` (file icons, assets with their `@dark` variant, file paths, Raycast's icons, emoji).
      `RaycastIcons` (core) maps every Raycast icon to an SF Symbol; a test checks that each icon in the generated enums has one and that each symbol exists.
      `ExtensionColor` (core) reads a `Color.ColorLike`: Raycast's named colors, any HTML color, or a light/dark pair.
    - **Remote images.**
      An `https://` image source, in an `Image.ImageLike` or in markdown, goes through `RemoteImages` (app), an observable entry per source so only the views showing that image redraw when it arrives, and its decoding; `RemoteImageStore` (core) keeps the entries, at most 300 in memory, and starts their loads.
      The placeholder shows meanwhile; a failure shows `fallback`, else the placeholder.
      The logic is in core: `RemoteImageURL` decides what's fetched (https only, no user info, no localhost, `.local`, one-label names or non-public IP literals, in every form `getaddrinfo` reads), `RemoteImageLoader` fetches (coalesced, 6 at once, 10 MB cut off while streaming, redirects re-checked) and says why a load failed (`RemoteImageFailure`),
      `RemoteImageCache` keeps bodies in `image-cache/` by the URL's SHA-256 with a sidecar (fresh for 24 h, then shown and revalidated with `If-None-Match`/`If-Modified-Since`, 200 MB, least recently used first), and `RemoteImageDecoder` refuses a header over 16,384 px and decodes thumbnails of at most 2048 px, or SVG up to 1 MB.
      `URLSessionImageFetcher` is the one `URLSession`: no cookies, credentials or URL cache, and authentication challenges cancelled.
      Markdown images honour `raycast-width`, `raycast-height` and `raycast-tint-color` (`MarkdownImageHints`).
      **Loading again** happens only when a view asks for the source, never on a timer, as `RemoteImageRetry` (core) decides: a network error, HTTP 408, 429 or 5xx is retried after 1 min, 5 min, 30 min, then every 2 h, or after a 429's or 503's `Retry-After` when that's longer, up to 2 h, with the fallback shown meanwhile; any other failure is final for the run.
      An image fetched 24 h ago or more is refreshed: a 304 keeps it without decoding again, a new body replaces it once decoded, and a failed refresh keeps it for another 24 h.
      One whose first load comes from the disk cache that old is shown at once and refreshed straight away, not at the next ask.
      Nothing starts while a load for that source runs.
      A source that leaves memory in back-off, or failed for good, keeps that (`RemoteImageRetries`, at most 1,000, oldest out): asked for again, it shows the fallback and loads only when it's due.
    - **Detail and Form** have no search field: their navigation title takes its place, and `handleKey` takes ↵ and Esc.
      `DetailScreen` shows the markdown with the metadata in a column beside it.
      `FormContent` (core) reads a Form's fields for `FormScreen`, and its `searchBarAccessory` when that's a `Form.LinkAccessory` with a text and a target (`LinkAccessory`):
      the title bar shows it at the right as a link (`ViewTitle`), mouse-only as in Raycast, truncating before the title and never wider than 40% of the bar, and a click opens the target as `Action.OpenInBrowser` does, then hides the panel.
      Over the link the pointer is a pointing hand, pushed and popped through `PointerPush` (core, by `LinkPointer`): popped on the way out, on the click, and when the panel hides with the pointer resting on it (`hidePanel`), and never more than it was pushed.
      A `Form.LinkAccessory` among the fields is skipped.
      `FieldValue` (core) holds what the user types, telling a controlled field's stale echoes from values the extension set itself.
      Each edit goes to the field's `onChange`.
      A `Form.Dropdown` reads like a search bar dropdown (`SearchBarDropdown`), and a `Form.TagPicker`'s tokens are kept by `TagPicking` (core).
      A `Form.DatePicker` shows its date, with a `DateTime`'s time beside it to edit in place, and a clear button (or ⌫).
      Space, ↵ or a click opens its calendar under the field: `DateCalendar` (core) highlights the field's day or today, ←→↑↓ and ⇞⇟ move it within `min` and `max`, and nothing is picked until ↵, Space or a click on a day picks one.
      The field keeps the keyboard, so `handleKey` gives the open calendar its keys first, Esc closes it before anything else, and any other key closes it and does what it always does.
      `FormDates` (core) makes a `Date` picker's value local midnight and a `DateTime` picker's whole minutes (limits with seconds clamp to whole minutes within them), within `min` and `max`, and `null` when cleared.
      A `Form.FilePicker` lists its paths with a × each, and Select… opens an `NSOpenPanel` as a sheet on the launcher (`FilePicking`, core, keeps the paths).
      The open panel only takes typing while Fudge is the active app, so Fudge activates for it, and `hidePanel` gives the keyboard back to the app that had it.
      The Dropdown and TagPicker both open the dropdown panel under the field: the panel has a source (`DropdownPanelSource`: the List's search bar, a Form dropdown or a TagPicker), and `FormFieldBounds` tells `LauncherView` where the field is.
      A field with `storeValue` (never a PasswordField) starts on the value saved when its form was last submitted (`FormValueStore`: `form-values/<extension>.json`, by command and field `id`), ahead of `defaultValue`.
      A Dropdown's or TagPicker's stored value waits for the field's items when they arrive after the first render, unless the field is changed first (`FormContent.Field.start`).
      When a field starts on something the extension's Form didn't register, such as a stored value or a dropdown's first item, the app reports it with `onChange`.
      `onFocus` and `onBlur` fire with Raycast's `FormEvent` when the keyboard moves from one field to another.
    - **Actions.**
      `ActionPanelReader` (core) turns an `ActionPanel` node into sections of `ActionEntry`. ↵ runs the first entry and ⌘↵ the second; in a Form, where ↵ belongs to the fields, ⌘↵ and ⌘⇧↵. ⌘K opens the action panel overlay, with search, sections and submenus (opening one calls its `onOpen`).
      An `Action.PickDate` (an `Action` with a `pickDate` prop and an `onChange`, `ActionEntry.pickDate`) opens a picker there in place of the list, as a submenu does; run with ↵, ⌘↵ or its shortcut, the overlay opens straight to it.
      `DatePick` (core) holds it: Form.DatePicker's calendar (`DateCalendar`, drawn by the shared `MonthView`) and a `DateTime`'s time, which Tab moves to. ↵, Space or a click on a day picks and calls `onChange` once with `FormDates`' value, ⌫ calls it with null, and Esc goes back to the list it came from, or closes the overlay, calling nothing.
      Closing the overlay any other way calls nothing either.
      The picker's keys come through `handleKey` with no field holding the keyboard (a Form's field lets go of it while the picker is open, and takes it back when the overlay closes), so typing filters nothing; a render keeps it open with the action's new title and limits (`DatePick.following`), or closes it when the action is gone.
      No Form field takes the keyboard while an overlay holds it, the action panel (picker or not) or a dropdown's panel, even when the fields change or the panel is shown again; the overlay's closing gives it to the last field, or the first if that's gone (`KeyboardFocus.formFieldAfterFieldsChange`, `formFieldAfterOverlay`).
      In root search the same overlay shows Fudge's own actions for the selected item, from `RootActions` (core): Open (↵) on everything, Configure Extension (⌘⇧,) on a command, Show in Finder (⌘⇧F) on an application.
      Their shortcuts work without opening the panel.
      An entry's `target` says what it runs: an extension's `Action` node (`onAction` in the running command), a `RootAction`, or `toggleQuickLook`, which the app performs itself (an `Action` with `fudgeBuiltIn: "toggleQuickLook"`, `ActionPanelReader.builtInProp`).
      An `NSEvent` local monitor in `AppDelegate` turns key presses into `KeyShortcut`s for `LauncherModel.handleKey` (⌘K, ⌘↵, actions' shortcuts) before the search field sees them.
      The key is named by what it types with no modifier at all (`characters(byApplyingModifiers: [])`), so ⌘⇧, is `,` with cmd and shift, not `<`.
      It leaves every key alone while an input method is composing (marked text), so ↑↓, Esc and ↵ reach the input method.
    - **Quick Look** (`Action.ToggleQuickLook`, however it's run) previews the selected item's `quickLook` file in macOS's Quick Look panel.
      `QuickLookState` (core) decides what it shows: a toggle opens it, or closes it if open, and an item without `quickLook` or whose file doesn't exist gets a failure toast instead; while it's open it follows the selection, and closes for an item without one, another view (a push, a pop, another command, root search), Esc, the launcher hiding (`hidePanel`), or its own close button.
      That button is noticed through `windowWillClose`, and also before every decision (a toggle, Esc, the selection moving): `QuickLookState.reconcile(panelVisible:)` closes the state when the panel isn't on screen, so ↓ never reopens a preview the user closed and one ⌘Y opens it.
      `QuickLookPreview` mirrors it into `QLPreviewPanel`:
      the app delegate is the panel's controller, which the responder chain reaches whether or not Fudge is active, and the panel is ordered front just above the launcher, with Quick Look's own Spaces behaviour allowed over a full-screen app (`.fullScreenAuxiliary`, `QuickLookPreview.overFullScreen`), without becoming key and without activating Fudge, so the keyboard stays with the launcher.
      If the preview takes the keyboard anyway (the user clicks it, or Quick Look takes it as the preview opens), `LauncherResign` (core) keeps the launcher open and gives it the keyboard back instead of hiding it.
      That's decided a turn after the launcher resigns, on what holds the keyboard then (`LauncherResign.Settled`; a launcher that hid or took the keyboard back meanwhile is left as it is), never on the current event: while the launcher resigns, the new key window isn't key yet, and ⌘Y opening the preview is a key press in the launcher.
      Whether the preview holds the keyboard is read from its own `didBecomeKey` and `didResignKey` too (`PreviewKey`, cleared when it closes), not only `isKeyWindow`: after ⌘Y, Quick Look takes the keyboard by itself about 200 ms later, and Fudge stops being the active app as it does, so `isKeyWindow` answers false (FUD-104, seen in the launcher's log).
      `hidePanel` later returns the keyboard to the app the user was in when the preview opened (set when the launcher takes the keyboard back, whatever `frontmostApplication` says yet, and forgotten when the panel hides);
      keys the preview gets meanwhile go where the launcher would send them: its shortcuts and a date picker's keys through `handleKey`, the arrows to the action panel, the dropdown's panel or the List or Grid (`PreviewArrow`, ←→ in a Grid as `GridNavigation` allows), and Esc.
      Snapshot runs and tests never touch Quick Look.
      **The launcher's log** (`LauncherLog`, the unified log's subsystem `io.github.jakeobsen.fudge`, category `launcher`) records each step from a shortcut press to the panel hiding: the key and `handleKey`'s answer, Quick Look's toggle and show, each resign and its settled decision, Fudge becoming active or not, and every `hidePanel` with its reason (the model's `hide()` passes its caller).
      It holds public facts only: window classes and levels, bundle ids and decisions, never paths, titles or typing.
      Read it with `/usr/bin/log show --last 2m --predicate 'subsystem == "io.github.jakeobsen.fudge"' --info` (in zsh, a bare `log` is a builtin).
    - **The General page** (`GeneralPage.swift`) is the Settings window's first page, and the one ⌘, Settings… and "Fudge Settings" open on:
      Open at Login, the launcher's hotkey, Show Fudge on, Pop to Root Search, Escape Key Behavior (all three `SettingsPopupRow`s), Keyboard (Hyperkey and its Quick press switch, which is disabled while Hyperkey is off), Updates (Check for Updates, another `SettingsPopupRow` with Daily, Weekly, Monthly and Never, then `UpdateStatusRow`:
      While the update check is unset, that popup shows Not Chosen first (`UpdateCheckSetting.popupOptions`): it checks nothing, as Never does, and can't be picked again once something is chosen.
      the last check's result and time, Check Now, and Download… while a newer release is known; saved through `change {}`), the currency switch, the calculator's Number format (Same as macOS, "1,234.5" or "1.234,5", saved through `change {}`; changing it re-evaluates the open query), Clear Search History…, and Import / Export.
      The launcher's hotkey is recorded like a command's, through the same `HotkeyRecordingPrompt`, but it can't be cleared: ⌫ and the Reset button set ⌥Space (`HotKeyRecording.launcherEdit`).
      A command's hotkey wins, so a launcher hotkey that equals one is refused, naming the command.
      It's registered before it's saved, and a refusal or a failed save leaves both the registration and the file as they were (`HotKeyRegistry.changeLauncher`); a failed save shows the `settingsProblem` banner.
      **Open at Login** goes through the `LoginItem` protocol (core): `SMAppServiceLoginItem` (`SMAppService.mainApp`) in the app, and a `FixedLoginItem` in snapshot runs, so they never register anything (`--login-item <status>` sets its status).
      The switch shows the system's real status (`LoginItemState`, core), read whenever the page appears or the window becomes key, so changes made in System Settings show; nothing is stored.
      `LoginItemState.change` registers or unregisters, then reads the status back, with any error to show.
      It turns nothing on while Fudge runs from its disk image or a translocated copy (`AppLocation.loginItemRefusal`), since that path goes away, and says to move Fudge to Applications first.
      **Clear Search History…** confirms in a sheet, then `LauncherModel.clearHistory()` empties `LaunchHistory` and `history.json`.
    - **Import / Export** (`BackupSection.swift`, at the bottom of General) writes and reads a `.fudgebackup` (declared in `App/Info.plist`).
      `Backup` (core) collects the parts from the support folder:
      - `colors.json`
      - `command-metadata.json`
      - `dropdown-values.json`
      - `history.json`
      - `launch-permissions.json`
      - `quicklinks.json`
      - `settings.json` without `extensionStoreConsentAt` and `signInServerConsentAt`
      - `snippets.json`
      - `window-layouts.json`
      - `preferences/`, `form-values/`, `local-storage/` and `extension-data/` per extension (never the Extension Store's data folder, which is its clone of the store)

      It adds a `manifest.json` listing the installed extensions with their version and source (the Extension Store's `installed.json`, else local), and for the store's installs the tree it recorded (`storeTree`, optional, so the format stays 1 and older backups read with none).
      It takes only regular files inside the support folder and never follows a link; extension data over 100 MB leaves out the biggest extensions'.
      `BackupArchive` (core) writes an Apple Archive encrypted with AppleEncryptedArchive's scrypt profile.
      Its `setPassword` takes only 20 to 256 bytes, so the archive gets the hex SHA-256 of `"fudge-backup-v1:" + password` (64 characters) and the user's minimum stays 8; scrypt still runs on every guess, and Apple's `aea` tool can't open the file with the typed password.
      **An imported backup is untrusted input:** `BackupArchive.read` refuses links, hard links and anything that isn't a regular file, more than 100,000 entries, a path over 1,024 bytes or a segment over 255, and data over 100 MB in an entry or 150 MB in all, path bytes included, counted while reading.
      Each path is checked as it's read (`Backup.part(of:)`: a path Fudge doesn't write, an invalid extension name, the Extension Store's folder), and the manifest's format as soon as it's read.
      `Backup.contents` also refuses a duplicate, and any of these that isn't a JSON object:
      - a keyed file
      - `colors.json`
      - `quicklinks.json`
      - `settings.json`
      - `snippets.json`
      - `window-layouts.json`

      The summary counts the quicklinks, snippets, window positions and layouts.
      Apple Archive's decoder already refuses `..` and absolute paths.
      A plain file in this support folder's `backups/` is Fudge's own before-import backup and is read without the size limits (`Backup.readLimits`).
      Nothing is written until all of it has passed.
      The import's summary lists the backup's extensions that are installed but changed since (`Backup.changedExtensions`, matched by name and shown with the current title): the first of a different version when both have one, a different store tree when both have one, or a different source; what it can't tell, and the bundled store, aren't listed.
      It only flags them, and the import restores them like any other.
      `Backup.apply` then saves the current state, unencrypted, to `backups/before-import-<time>.fudgebackup` (folder 0700, file 0600, the last 3 kept, always including the one just written), and replaces each part the backup holds:
      an extension's data folder whole, the keyed files extension by extension, `settings.json` keeping this Mac's `extensionStore`, `signInServer` and their consent dates (`Backup.consentKeys`), since this Mac's sign-ins are in its Keychain.
      A failed write puts back everything changed so far, trying every step; if one fails, the staging folder stays and the error names the before-import file.
      The app then reloads settings, hotkeys, history and root search (`AppDelegate.afterImport`).
    - **Bundled extensions** (`BundledExtensions`, core) are the Extension Store, Search Files, Search Emoji & Symbols and Clipboard History.
      `make app` builds each from `runtime/<folder>` into `Contents/Resources/<folder>` when its source is there.
      They're always installed (`InstalledExtension.all(paths:resources:)`, which reads only their manifests), and a user's extension with one's name gives way to it.
      Search Files and Search Emoji & Symbols are enabled by default like any extension; the store keeps its own rules, below.
    - **Search Emoji & Symbols** (FUD-99) is a bundled extension (`fudge-emoji`, `runtime/emoji-extension/`): a Grid of 8 columns, a section per Unicode group in Unicode's order, with **Recently Used** first.
      Each cell is the emoji drawn whole, titled with its CLDR name, with CLDR's keywords, so Fudge's own filtering finds it by either. ↵ pastes it (`Action.Paste`), ⌘↵ copies it, ⌘⇧C copies its name, and a recent one also has Remove from Recently Used and Clear Recently Used.
      Pasting or copying puts it first in Recently Used, kept in its `LocalStorage` as base emoji (up to 16, newest first), so a new tone applies to them too; the grid shows only once it's read, so the most recent is selected first.
      The **Skin Tone** preference (Default, Light, Medium-Light, Medium, Medium-Dark, Dark) shows and pastes the emoji that take one in that tone, two-person ones with both in it.
      **Its data** is generated: `runtime/vendor/unicode/` holds Unicode's files unmodified (Emoji 16.0's `emoji-test.txt`, CLDR 46's `annotations/en.xml` and `annotationsDerived/en.xml`, and the Unicode License v3), and `scripts/emoji-data.ts` turns them into `emoji-extension/src/emoji.generated.json`:
      every fully-qualified emoji outside the Component group, with its name and keywords (CLDR keys sequences without variation selectors), group, subgroup and Emoji version, and its five skin-tone variants as a field of it when all five exist (a variant mixing tones isn't offered).
      `npm run generate` writes it, and `npm run typecheck` fails while it's stale; the builds never fetch anything.
      **Only what the Mac draws is shown:** `emojiVersions` maps macOS to the newest Emoji version it draws (14.0: 15.0, 14.4: 15.1, 15.4: 16.0, from Apple's notes on its updates; each release draws its row's version up to the next), and `macOSVersion` reads `os.release()`, which is Darwin's version: Darwin 20 to 24 are macOS 11 to 15, Darwin 25 is macOS 26, and the minor is the point release.
      A release newer than the table draws the newest version it knows.
    - **Search Files** (FUD-100) is a bundled extension (`fudge-file-search`) that asks the app for files by name with `files.search`.
      `LauncherModel` answers it through `FileSearch` (core), only for a session of `fudge-file-search` (`FileSearchError.notSearchFiles` otherwise, as strong as the one-process model allows), with the calling command's **Search In** and **Leave Out** preferences resolved at each call (`FileSearchOptions`).
      `FileSearchPredicate` asks Spotlight for every word of the query in the name (`kMDItemFSName LIKE[cd] "*word*"`, the words as arguments, with `LIKE`'s `*`, `?` and `\` escaped), or, with no query, for what was used in the last 30 days.
      `SpotlightFileQuery` runs an `NSMetadataQuery` on its own `OperationQueue`, in the home folder or the whole Mac, sorted by last use.
      The call is answered once it finishes gathering or after 1.5 s, with at most the 5,000 most recently used results read (`FileSearch.readCap`, since a broad query on the whole Mac gathers far more).
      Those are filtered (`FileSearchFilter`: outside the home folder when that's the scope, under a Leave Out folder ignoring case, a hidden component, or inside a package, though a package itself stays), ranked, and only then cut to `limit` (200, at most 500), so a late exact match isn't lost.
      `FileSearchRanking`: the name equal to the query with or without its extension, then starting with it, then a word in it (a run of letters and digits) starting with it, then anywhere, ignoring case and diacritics; ties go to the most recently used, then modified, then the shorter path.
      A newer call from the same session stops the older query, and the older call answers `[]`.
      A query Spotlight can't start is the call's error, which the extension shows as a toast.
      Snapshot runs never ask Spotlight (`FixedFileQuery`).
    - **Clipboard history** (FUD-98) is off until **Keep Clipboard History**, the first row of the bundled Clipboard History's Settings page (`ClipboardHistorySettings`), is turned on through its consent sheet; `FudgeSettings.isClipboardHistoryOn` needs `clipboardHistory` and `clipboardHistoryConsentAt`, which are this Mac's (`Backup.consentKeys`).
      Turning it off stops recording at once, then asks Keep History or Delete History.
      The page also has **Keep For** (`clipboardHistoryKeepDays`: 1, 7, 30 or 90 days), **Ignore Apps** (`clipboardHistoryIgnoredApps`, bundle ids) and **Clear History…**.
      While it's on, `ClipboardHistoryService` reads the pasteboard's change count every 0.5 s off the main thread, and on a change records a copy into `ClipboardHistory` (core): files, else text or a link, else an image as PNG, with the frontmost app as its source.
      Ignore Apps is judged by the app frontmost when the change is seen, so it can lag a copy by up to the 0.5 s poll.
      It skips copies marked concealed, transient or auto-generated (`ClipboardSkip`), Fudge's own writes (a paste and its restore, the ⌘C fallback's copy and restore, whose change counts `PasteboardTurns.markOwn` remembers), and while a paste or the fallback is mid-way (`PasteboardTurns.isBusy`) it looks again at the next poll.
      A copy the history holds moves to the top.
      At most 1,000 entries; a text over 1 MB is kept cut and marked truncated; an image over 10 MB isn't kept; all images together stay under 500 MB; the oldest unpinned go first, and Keep For prunes everything but pins, at start and hourly.
      `ClipboardHistoryStore` (core) keeps `clipboard-history/` (0700) in the support folder: `history.enc` and one `<image>.enc` per image (0600), each sealed with AES-GCM under a 256-bit key in the Keychain (service `io.github.jakeobsen.fudge.clipboard-history`, through `SecretStore`), with the file's name as associated data.
      Image files are named at random; an image's digest, which finds it again, is only in the sealed history.
      A missing key or a damaged file starts an empty history and keeps the file aside as `.unreadable-<time>`, while a Keychain error (a locked Keychain) leaves the file where it is: `ClipboardHistoryKeeper` (core) counts the history as read only once a read has worked, so until then nothing is recorded, changed or saved over it, and the read is tried again at the next copy or call.
      Saves, image writes and deletions run in order on a queue of their own, off the main thread, and a copy is recorded only if the change count hasn't moved again while it was read.
      Delete History removes the folder and the key.
      Backups never hold it.
      The `clipboardHistory.*` calls (`list`, `image`, `paste`, `copy`, `pin`, `delete`, `clear`) answer only Clipboard History's sessions.
      `list` sends at most 20,000 characters of an entry's text, `paste` goes through `clipboard.paste`'s path and turn, and `image` decrypts a copy into a private folder that's deleted when the command ends or Fudge quits.
      Any extension's `Clipboard.read({ offset })` from 1 to 5, Raycast's documented range, gets the nth previous copy from the history (`ClipboardHistory.entry(offset:)`), or nothing while it's off; `ClipboardOffset` (core) reads the offset without an `Int` conversion that could trap, and anything above 5 or fractional is no copy, so no extension pages through the history.
      The caller check is `ClipboardHistory.mayCall`.
    - **The Extension Store** (FUD-50) is an extension bundled with the app (`Contents/Resources/store-extension`).
      Using it takes two steps.
      **Enabled**, on the Commands page, is off by default for the store alone (`FudgeSettings.isEnabled(extension:)`, which always writes the store's state), so until it's ticked the store isn't in root search, its hotkeys aren't registered and `launchCommand` can't reach it.
      An install that had the store switched on before counts as enabled until either is changed.
      **The switch** is the first row of the store's Settings page (`ExtensionStoreSwitch`): turning it on shows the consent sheet and writes `extensionStore` and the ISO 8601 `extensionStoreConsentAt`.
      `FudgeSettings.isExtensionStoreOn` needs both, so a hand-set `true` counts as off.
      `FudgeSettings.setExtensionStore` writes the store's Enabled down first, so the switch never changes it.
      Turning it off, after its own sheet, removes both keys and deletes only the store's `repo/` (`ExtensionStore.deleteRepository`), keeping its `installed.json`.
      **While it's off, the app never starts the store's code:** `LauncherModel.launch` checks `ExtensionStore.isOff` against `settings.json` first.
      A launch the user started shows "The Extension Store is off." instead, a `Failure` with a `Notice`, drawn like an empty view.
      Its one action, Open Extension Store Settings (↵, ⌘K or ⌘⇧,), opens the store's page.
      A background launch is refused with the same words.
      The extension host's environment carries `FUDGE_CLI` (the bundle's `fudge`) and `FUDGE_EXTENSIONS_DIR` to every worker, and the store installs with `fudge build <folder> --into "$FUDGE_EXTENSIONS_DIR"` (`BuildArguments`: an absolute path to a folder that exists).
    - **The Commands page** (`CommandsPage.swift`) is the Settings window's second page:
      Fudge's own command groups, then the quicklinks as a group of their own (`SettingsModel.commandGroups`, shown once there is one, its Type "Quicklinks" and theirs "Quicklink", `BuiltInCommandGroup.typeLabels`),
      then every installed extension, each expanded to its commands (menu-bar ones included), with each command's alias, hotkey and Enabled checkbox (an extension's row has its own checkbox).
      The bundled Extension Store is listed too, unticked until it's enabled.
      An alias is saved on ↵, and Esc puts the old one back.
      Recording a hotkey suspends all of Fudge's hotkeys (`HotKeyRegistry.suspend`), so pressing one records it instead of firing.
      While recording, `HotkeyRecordingPrompt` turns each key press into a `HotKeyRecording` (core): Esc alone cancels, ⌫ or ⌦ alone clears, anything else is the new hotkey.
      Ending the recording (saving, Esc, closing the window, or leaving the page or onboarding step) resumes them (`HotKeyRecorder`, `SettingsModel.select`).
      A conflict (`HotKeyConflict`: the launcher's key, another installed command's, named by its title, with its extension's when two share one, `CommandNames`, or no ⌘ ⌥ ⌃) or a shortcut the system refuses keeps the old hotkey and shows why in the cell.
      A command that isn't installed keeps its saved hotkey for a reinstall, but doesn't block the key: taking it clears that one's hotkey, keeping its alias and Enabled state (`HotKeyConflict.displaced`), and the cell says so (`HotKeyConflict.displacedNote`): by the command's title, and a deleted quicklink's key as "a deleted quicklink", never its id.
      A command that's off by default says why on a line under its title (`SettingsModel.offByDefaultReason`, `CommandCompatibility.reason`: "Uses Raycast AI, which Fudge doesn't support.").
    - **The Sign-in page** (`SignInPage.swift`, after Window Management) sets the server extensions sign in through (SPEC-056): Off (the default), **Fudge's sign-in server** (`SignInServer.fudgeURL`, `https://fudge-oauth.rackofpain.net`) or **Your own server…**, whose address is saved on ↵ once `SignInServer.validate` accepts it (`https://`, or `http://` on `localhost` or `127.0.0.1`;
      no user info, query or fragment).
      It's saved as the worker's `new URL()` writes it (scheme and host in lowercase, no default port, dot segments resolved), since a sign-in's authorize URL is compared with what the worker sends back; a host that parser would rewrite otherwise (non-ASCII, percent-encoded, IPv6, IPv4 in another notation) isn't accepted.
      Every choice but Off shows a consent sheet first ("Extensions will sign in through <host>."), and only Continue saves `signInServer` (`"fudge"` or the URL) with `signInServerConsentAt`; `FudgeSettings.signIn` needs both, so a hand-set server counts as off, and Off removes both.
      Changing the server signs out of everything, after its own sheet when there are sign-ins.
      Below it, **Signed in** lists each stored sign-in (the extension's title, the provider, when) with Sign Out.
      **Sign-ins** are Keychain generic passwords (`KeychainSecretStore`), service `io.github.jakeobsen.fudge.oauth`, account `<extension>/<providerId>`, holding a JSON `StoredTokenSet`;
      `OAuthTokenStore` (core) reads and writes them through the `SecretStore` protocol, and the `oauth.tokens.*` calls go through `SignInCalls` (core) with the calling session's extension, never one named in the call, so one extension never reads, sets or removes another's.
      A stored sign-in keeps `relayProvider`, the provider its relay sign-in was for, only when the session prepared that sign-in; a refresh keeps the mark.
      **Signing in** (`LauncherModel.authorizeSignIn`): a background call is refused ("Sign in from Fudge to continue.").
      Otherwise the launcher shows "Sign in to <provider>" (`SignInPrompt`, over whatever the command shows) with the provider's icon (a `data:` image, `DataURL`) and description. ↵ opens the URL in the default browser, which must be the prepared request's (`PreparedSignIn.state(ofAuthorizeURL:)`); Esc cancels, and the command exiting does too.
      The prompt takes its prepared request (`SignInRequests`, core), so both reach the listener it waits on, whatever the session prepares meanwhile.
      A relay sign-in is pending (`SignInRequests.pending`, for the fetch rewrite and the `relayProvider` mark) while it's prepared or shown, and after it brings a code, for the token exchange that follows; one that ends without a code (Esc, an error, the timeout, a request replaced or expired) isn't.
      `OAuthLoopback` (an `NWListener` on `127.0.0.1`, a free port, path `/oauth/callback/<random>`) answers only while a sign-in waits, and binds only `127.0.0.1`.
      Only a `GET` on exactly that path with the sign-in's `state` and a `code` or `error` ends the wait (`OAuthCallback.read` and `endsWait`, core): it answers the browser with "Signed in. You can close this tab." and closes.
      A wrong path gets a 404 and a wrong `state` a 400, and the sign-in keeps waiting.
      The wait lasts at most 5 minutes, and a request never used closes after 5 minutes too.
      On the code, the launcher comes back to the command.
      **A sign-in stopped on purpose** (SPEC-095) names why in its refusal (`SignInRefusal.notice`: off, cancelled, timed out, or refused by the provider or the relay), and the error the command reports with that `notice` (`HostMessage.error`) shows as `SignInNotice` (core) in the command's place, drawn like the store's "off" notice, with no trace and nothing red:
      Like any failure that stands in for a command, the notice keeps the command's title in the bottom bar (`LauncherFooter`); one that belongs to no command, like the store's, says "Fudge".
      "Sign-in is off" with Open Extension Settings (↵, ⌘⇧,) and Open Sign-in Settings (⌘⌥,), or the others with Try Again (`RootAction.retryCommand`, as root search runs it).
      A background or menu-bar command shows its `hud` instead.
      Any other error keeps the failure view with its details.
      Snapshot runs keep sign-ins in memory (`--sign-ins <extension>/<providerId>=<Provider>,…`), and `--sign-in-consent` saves the Sign-in page's consent alert: laid out by `NSAlert.layout()` without being shown, and moved to a `SnapshotSheet` that refuses key status and is never ordered in (`SettingsWindowController.snapshotSheet`).
      So the image has the app's icon, which the real sheet leaves out.
    - **Menu bar commands.**
      `MenuBarController` puts each active `menu-bar` command in the menu bar as one `NSStatusItem` with an `NSMenu`.
      Running one from root search (or its hotkey) activates it; running it again refreshes it and opens its menu. ⌘K on an active one offers Deactivate Menu Bar Item (`RootAction.deactivateMenuBarItem`).
      `MenuBarStore` (core) keeps the active commands in `menu-bar.json`, at most 50, pruned of commands that aren't installed.
      It keeps keys it doesn't know, and never overwrites a file it can't read (`Unreadable`): activating or deactivating then fails with a toast saying why.
      A disabled command, or one of a disabled extension, stays in it but leaves the menu bar and stops refreshing, and comes back when it's turned on again (`MenuBarStore.shown`; `LauncherModel.applySettings` hands the controller the settings).
      Each item's autosave name is `menubar:<extension>/<command>` (`MenuBarStore.autosaveName`), so it keeps its own position and never takes over another item's saved state, and it's made visible whenever it's put in the menu bar.
      `MenuBarContent` (core) reads the `MenuBarExtra` tree: items without `onAction` disabled, sections as a heading between separators, submenus, ⌥ alternates, and each item's position path.
      `MenuBarLifecycle` (core) decides loads and unloads: at most one instance per command; Background at Fudge's start and on the manifest `interval` (`MenuBarInterval`, at least 10 s, a `.common`-mode timer), UserInitiated when the menu opens or root search runs it; a tick while loaded is skipped and a click just opens the menu;
      unloaded once it has rendered without `isLoading`, its menu is closed and every `onAction` has settled (`eventSettled`).
      The item keeps the last tree.
      A pick made in that tree before the new instance's first render waits, then goes to the item at the same position path with the same title, or is dropped.
      Waiting picks are dropped too once no instance is still to render (`MenuBarLifecycle.awaitsFirstRender`: it failed or exited first, or the host stopped), so a later launch never runs them.
      UserInitiated errors show in the HUD; Background ones are logged and add a disabled "⚠ Last refresh failed" until a later render.
      `LauncherModel` starts the controller's commands (`launchMenuBarCommand`) and routes their sessions' `render`, `error`, `eventSettled` and `exit` to it; their rpcs are answered like any command's.
    - **The Quicklinks page** (`QuicklinksPage.swift`) comes after Commands:
      a table of every quicklink's Name, Link, Open With, and its Alias and Hotkey, read only, with "Edit on the Commands page" as their help, sorted by name, read again whenever the page is shown or the window becomes key, so changes made in the launcher show. + opens a sheet with the same three fields, Edit… (or a double-click) opens it filled in, and − (or ⌫) deletes after a confirmation sheet.
      The sheet saves through `SettingsModel.saveQuicklink`, which reads the file again and shows `QuicklinkDraft.problems` under the fields.
      An unreadable `quicklinks.json` shows the notice and disables changes.
      Each change calls `quicklinksChanged`, so root search reads the file again.
    - **The Snippets page** (`SnippetsPage.swift`) comes after Quicklinks and works like it, under the Expand Snippets as You Type switch: a table of every snippet's Name, Keyword and the start of its text on one line, sorted by name, read again when the page is shown or the window becomes key.
      + and Edit… (or a double-click) open a sheet with Name, a several-line Snippet and Keyword, and − (or ⌫) deletes after a confirmation sheet.
      The sheet saves through `SettingsModel.saveSnippet`, which reads the file again and shows `SnippetDraft.problems` under the fields.
      An unreadable `snippets.json` shows the notice and disables changes.
      Each change draws Search Snippets again if it's open in the launcher, and expansion reads the snippets again (`snippetsChanged`).
    - **The Permissions page** (`PermissionsPage.swift`) comes after General: Accessibility's status (`AccessibilityStatus`, read without a prompt when it's shown and every second while it's on screen), its reason, and Open Accessibility Settings.
      The reason (`AccessibilityPermission.reason`, which onboarding's Accessibility step shows too) names Fudge's own commands that need it first, then extensions that read the selection or paste.
      That button asks for macOS's prompt on the first click and opens the pane on later ones, or at once when something in this run already asked for the prompt (`AccessibilityPermission.request`, `SystemAccessibility.promptShown`), so the prompt and the pane never stack.
      Below it, always shown, are the answers to "Allow <A> to open <B>'s commands?" (`LaunchPermissionsSection`, `LaunchPermissions.entries`), each changeable or forgotten, with the file read again before each change, a line saying none has asked yet when there are none, and the unreadable-file notice.
      Between them is Calendar access as macOS has it, with Open Privacy Settings (`CalendarAccessRow`); My Schedule asks for it, never this page.
      Show Onboarding Again restarts onboarding from Welcome.
    - **Moving to Applications** (SPEC-114 §1).
      At launch, before onboarding, `AppLocation` (core) reads where the app runs from: a read-only volume is the disk image, and a path through `AppTranslocation` is macOS's read-only copy of a quarantined download.
      Either gets one alert, **Move to Applications** (↵) or **Not Now**, which keeps it running and asks nothing more this run.
      `AppMover` (app) copies it into `/Applications`, or `~/Applications` for an account that can't write there, and never asks for an administrator's password (`AppLocation.destination`).
      It copies under a hidden name, asks before replacing a copy already there (asking a Fudge running from there to quit), puts the old one in the Trash and moves the new one into place, so a failed copy never leaves half an app.
      It clears the new copy's quarantine, since this copy has already passed Gatekeeper and a quarantined copy not moved by Finder would be translocated again, then opens it once this one has quit (a shell waiting on its pid, the paths as arguments).
      The moved copy is opened with `--moved-to-applications`; if macOS still runs it from a read-only place, it says so once instead of offering the move again (`AppLocation.launchStep`), so the offer can't loop.
      Snapshot runs leave launch before it.
    - **Onboarding** (`OnboardingWindow.swift`) opens at every launch until it's complete, once the extensions have loaded; never in snapshot runs, tests or the CLI.
      `Onboarding` (core) keeps the answered step ids in `onboarding.json` and decides what to show (`pending`): the unanswered steps, in order, then Done.
      Once it has been completed, Welcome isn't shown again, and a step added later shows on its own, then Done, under "Something new to decide" (`hasSomethingNew`).
      **`OnboardingStep`'s cases are the one list of steps**: adding a step means adding its case and drawing it.
      The steps use General's own controls (`LauncherHotkeyControls`, `OpenAtLoginControls`, `CurrencyRatesToggle`, `HyperkeyControls`, and the Permissions page's `AccessibilityControls`), so an answer takes effect at once.
      The **Extension Store** step (after Currency) shows the store's consent sheet's own words (`ExtensionStore.Consent`), with **Turn On Extension Store**, which writes what the switch and its sheet write and also ticks the store's Enabled (`FudgeSettings.turnOnExtensionStore`), and **Not Now**, which is ↵.
      The **Sign-in** step is the Sign-in page's own choice (`SignInServerControls`, shared with the page, with `SignInServer.explanation`), whose consent sheets show on the onboarding window (`OnboardingModel.ask`; laid out off-screen in snapshot runs), with Continue as ↵, so Off stays Off.
      The **Clipboard history** step (after Sign-in) shows the consent sheet's own words (`ClipboardHistory.consentMessage`, the one string both use) with **Keep Clipboard History**, which does what the switch and its sheet do (`SettingsModel.keepClipboardHistory`), and **Not Now**, which is ↵, so going through onboarding with ↵ never starts recording.
      When it's already on, the step says so and turning it off is left to Settings.
      **Expand snippets as you type**, after Clipboard history, works the same way: it explains Input Monitoring, and that pasting the snippet needs Accessibility (`SnippetExpander.permissionsExplanation`, the Snippets page's sheet's own words), **Turn On** does what the switch does (`SettingsModel.turnOnSnippetExpansion`, then macOS's prompt or pane), and **Not Now** is ↵.
      **Use Caps Lock as Hyper?** (after Snippet expansion) shows General's `HyperkeyControls`, with **Not Now** as ↵ while it's off.
      Updates, after Hyperkey, is `UpdateCheckChoice`: Daily, Weekly, Monthly or Off, with Daily preselected, and its Continue saves the choice, since nothing is checked until one is saved.
      **Done** says how to open Fudge and that it stays in the menu bar, since it has no Dock icon (`OnboardingDone`): "Press", the launcher hotkey's keycaps, "to open Fudge.", or, while another app has that hotkey (`launcherHotkeyInUse`), to open it from the menu bar icon.
      Welcome also has **Restore from a Backup…**, General's import flow with its own sheets on the onboarding window (`SettingsModel.onboardingBackup`); a backup never holds `onboarding.json`, so onboarding carries on after an import.
      A step is answered when it's left with Get Started, Continue or Not Now, and saved straight away, so closing the window keeps the answers so far.
      Leaving a step or closing the window ends a hotkey recording. ⌘W and ⌘Q close the window as they do Settings (`WindowShortcut`), without completing onboarding.
      Unlike `settings.json` and `launch-permissions.json`, a broken `onboarding.json` is read as nothing answered and replaced on the next save, since it holds nothing else.
    - `SettingsWindow.swift` is the Settings window, with a fixed 200 pt sidebar beside the page (a `List` with the sidebar material, not a `NavigationSplitView`, so there's no divider to drag and nothing to collapse).
      Every way in goes through `SettingsWindowController.show`, which deminiaturizes the window, moves it to the current Space, activates Fudge with `activate(ignoringOtherApps:)` (`activateFromUserAction`; the plain `activate()` can be declined since macOS 14, leaving the window behind the app in front) and orders it front and key.
      It's for user-initiated entries only, never a background path: `show` takes the call's `CallOrigin` and does nothing for a background one. ⌘Q closes the window as ⌘W and its close button do (`SettingsNSWindow.performKeyEquivalent`, `WindowShortcut` in core), and Fudge keeps running; while a hotkey is being recorded, the recorder takes ⌘Q like any other key.
      The sidebar lists the extensions with preferences, and the Extension Store, whose page starts with its switch (`InstalledExtension.settingsPages`), enabled or not.
      The window holds each extension's preferences, stored by `PreferenceStore` in `preferences/<extension>.json`.
      Before a launch, `PreferenceResolver` merges stored values, manifest defaults and type defaults.
      It turns appPicker references into Raycast `Application` objects, and the launch message carries the values to `getPreferenceValues()`.
      A command with an unset required preference opens this window instead of running.
      The other ways in: Settings… (⌘,) in the menu bar item; ⌘, in the panel, and the "Fudge Settings" root item, on the General page; ⌘⇧, (Configure Extension) on the extension of the command selected in root search or running.
      An extension's own action shortcut wins over ⌘, and ⌘⇧, inside its command.
      `openExtensionPreferences()` and `openCommandPreferences()` open it on the calling extension.
    - **Only a user action brings Fudge forward** (SPEC-045).
      Every call that may show an alert or a window carries a `CallOrigin` (core): user-initiated (a command the user opened, a menu-bar item they picked, their own click in Fudge) or background (an interval refresh, a background `launchCommand`).
      `LauncherModel.origin(of:)` reads it from the calling session: a menu-bar session is user-initiated while its menu is open or one of the user's picks is running (`MenuBarLifecycle.origin(of:)`, since only picks send it events), else as it was launched; the command the user opened (the view on screen, or a no-view one showing "Running …") is user-initiated;
      any other session, such as a background launch's, is background.
      A background call gets no alert, offer, prompt, window or panel: `confirmAlert` resolves false (`CallOrigin.unaskedAnswer`), `openExtensionPreferences()` rejects, "Allow A to open B?" is refused without being saved (`LaunchPermissions.step`), with one HUD per pair per run (`OncePerRun`), a `launchCommand` runs as Background whatever type it asks for (`LaunchRequest.asCalled(from:)`),
      and neither macOS's Accessibility prompt nor its "control Finder" consent is asked for.
      `NSApplication.activateFromUserAction(origin:)` is the one way an extension's call brings Fudge forward, and asserts that the origin it's passed is user-initiated; every caller passes it explicitly.
      Fudge's own windows use `NSApp.activate()`: onboarding at launch, and a FilePicker's Select… click.
  - `FudgeCLI` is the `fudge` command-line tool.
  - `FudgeCore` is shared code, and the only target with tests.

  Put logic in `FudgeCore`, where it can be tested.
  Keep the app and the tool thin.
- **The extension host lives in `runtime/`.**
  It's written in TypeScript.
  Extensions trust the certificates the Mac trusts (SPEC-081, `NodeTrust`): the app starts the host with `--use-system-ca` when its Node has it (22.15+, 23.8+, 24 and later).
  The Node.js Fudge bundles has it, so the `NODE_EXTRA_CA_CERTS` path below only runs while its version isn't known yet.
  `node --version` is read in the background when the app starts and kept for the run per resolved binary and its modification date (`NodeVersionCache`), so a host start never waits for it;
  while it isn't known, a start takes the `NODE_EXTRA_CA_CERTS` path, which works on any Node, and a host that ends at once on the flag, saying nothing, marks that binary as without it (a version manager's shim can switch Node underneath).
  Else the host starts with `NODE_EXTRA_CA_CERTS` naming `trust/roots.pem` in the support folder, written afresh at each start from the user's and admin's trust settings (`SystemTrustSettings`, read only; the system's roots are Apple's, and Node has its own).
  That file holds only certificates trusted for SSL with no restriction (a trust for one host would become a trust for every host in Node), and never one denied in any domain, the system's included.
  An inherited `NODE_EXTRA_CA_CERTS` (set for Fudge by the user or a profile) is kept: with the flag it passes through as it is, and otherwise its certificates follow the Mac's in `roots.pem` (only blocks macOS reads as certificates, since Node stops at the first block it can't load), or it passes through untouched when there's nothing of the Mac's to add or its file can't be read.
  Nothing turns verification off.
  Tests run the `.ts` files directly through Node's type stripping, and esbuild bundles `src/host.ts` and `src/worker.ts` into `runtime/dist/` as ES modules, with production React.
  - **The protocol.**
    The app talks to `host.ts` over stdin/stdout, one JSON message per line, as typed and parsed in `src/protocol.ts`.
    The app reads lines with `LineSplitter`, which looks at each byte once, and decodes them through `JSONSerialization` (`HostMessage(line:)`), falling back to `JSONDecoder`: a 1,000-row list is a line of several hundred kilobytes.
    Messages about a running command carry the `session` id the app chose when launching it: `s-` and 32 hex digits from 128 random bits (`SessionID.make()`).
    The app handles a host message only when it names no session, or one the app started in the running host and hasn't seen exit (`HostSessions`, checked in `LauncherModel.receive`).
    Nor does the app send anything for a session that isn't running (`HostSessions.mayReceive`, checked in `send`), so a pick or an action left open in a command that has ended goes nowhere, and the command's exit closes its ⌘K panel and date picker.
    Its exit, unless Fudge unloaded it, and the host stopping under it, close every panel over it: ⌘K, a dropdown's panel and a form's calendar (`EndedCommand.closesPanels`); Fudge's own views need no host and keep theirs.
    Anything else is dropped and logged once per id, the sessions of Fudge's own views included (`LauncherModel.builtInSessions`):
    - Define Word
    - its forms
    - My Schedule
    - Recent Colors
    - Search Menu Items
    - Search Snippets
    - Switch Windows

    stdout carries nothing but the protocol: in the host, `console.log` goes to stderr, and a worker's output arrives as `log` messages.
  - **Extensions share one process, as in Raycast.**
    Every command is a worker thread in the one host, so a running extension can read and write the protocol channel (the host's stdin and stdout) and reach the host's main thread (`inspector`).
    Extensions running together can reach each other and the host.
    That's by decision (D-65), to stay as close to Raycast as possible, so nothing is blocked.
    Random session ids stop only blind guessing, not an extension that reads the channel.
    So never put anything in the protocol that would be worse to leak than what an extension can already read as the user.
    The one known exception, accepted with D-65, is an extension's OAuth tokens (SPEC-056): they cross the channel in `oauth.tokens.get`'s answer and `oauth.tokens.set`'s params.
    The Keychain's access list keeps them from other programs running as the user, but another extension running at the same time can read them off the channel.
    Don't add more secrets to it.
  - **One worker thread per launch.**
    `worker.ts` intercepts `Module._load` so that `require("@raycast/api" | "react" | "react/jsx-runtime" | "react/jsx-dev-runtime")` gets the host's own modules.
    The extension and the renderer must share one React, or hooks break.
    The command is the module's default export; an old module that exports nothing and calls the deprecated `render(<Command />)` while it loads gets that element as its root instead (`recordRender` in `src/api/render.ts` keeps the first call during the load; any other call does nothing).
    The app shows nothing a no-view command renders, so a no-view command that does this fails with an error saying so.
    An old no-view module with neither does its work in its top-level code, which runs as it loads; its worker ends when that work does (the message port keeps it alive only while a call into the app waits for its answer, `holdWhilePending` in `bridge.ts`), and the host reports `finished`.
    A view or menu-bar module with neither has nothing to run.
  - **The renderer** (`src/renderer/`) is a React 19 host config.
    Host instances are plain objects named after the component (`List.Item`, `ActionPanel.Section`, …).
    Commits are coalesced into one snapshot per event-loop turn, and only the top navigation view (a `$view` instance) is sent.
    A `menu-bar` command renders the same way, its `MenuBarExtra` being the view.
  - **A no-view command's exit.**
    Before the worker reports `exit`, it waits until the host has read everything the command wrote to stdout and stderr (`flushOutput`, at most a second), so the last `console.log` arrives before the `exit` and the host stopping the worker can't lose it.
  - **Events.**
    The worker answers every `event` with one `eventSettled`, once the handler has returned (or its promise settled) and the render it caused has been sent (`Root.whenRendered`).
    The menu bar unloads a command only when every event has settled.
  - **Snapshot encoding.**
    Functions are sent as `{ "$fn": path }`, and the app calls one back with the node id and that path.
    Dates are sent as `{ "$date": iso }`.
    Element props (`actions`, `detail`, …) are rendered as `$slot` children and sent as nodes inside props.
    A `List.Item`'s or `Grid.Item`'s `actions` and `detail` are sent only for the first item, the one the view's `selectedItemId` names (read in each snapshot, one item only), and the items the app last asked for with `slots` (`Deferral` in `src/renderer/serialize.ts`);
    the others carry `{ "$deferred": true }`, and the worker answers `slots` with them, with an entry for every id asked for (`Root.slots`).
    A deferred `actions` also names the shortcuts its panel's actions use, and its submenus' own (Open With…'s ⌘O), as an index (`"shortcuts": 0`) into the view's `$shortcutSets`, where each distinct set appears once.
  - **Built-in actions** (`src/api/actions.ts`: CopyToClipboard, CreateQuicklink, CreateSnippet, Open, OpenInBrowser, OpenWith, Paste, PickDate, ShowInFinder, Trash, SubmitForm) are JS components over the host `Action`, doing their work through the system APIs.
    Paste is titled after the frontmost app ("Paste to TextEdit") once it's known, and shows a failed paste as a toast.
    OpenWith looks up the applications that can open its path only when its submenu opens (`onOpen`), not once per row.
    PickDate sends its `type`, `min` and `max` as a `pickDate` prop for the app's picker, and its `onChange` gets a `Date` or null.
    ToggleQuickLook, CreateQuicklink (with its `quicklink`) and CreateSnippet (with its `snippet`) render a host `Action` with `fudgeBuiltIn` and no `onAction`, for the app to perform; a CreateQuicklink without a link, or a CreateSnippet without a text, only shows a failure toast when picked.
    The ones Fudge can't perform (InstallMCPServer, …) still render, and show a failure toast when picked.
    `Keyboard.Shortcut.Common` holds Raycast's documented combinations as `{ macOS, Windows }` pairs.
  - **Forms.**
    `Form` provides a registry (`src/api/form-state.ts`) where each mounted field keeps its value under its `id`: `value`, else `defaultValue` (read on mount), else the field's empty value.
    Fields always carry an `onChange`, which the app calls as the user edits, and `Action.SubmitForm` submits the registry.
    Fields with `storeValue` are marked in the registry, and `Action.SubmitForm` sends their values to the app (`form.storeValues`, Dates encoded as `$date`) before it calls `onSubmit`.
    `Form.DatePicker.isFullDay` and `Action.PickDate.isFullDay` are the same function (`src/api/dates.ts`).
    Entries belong to field instances, so a field remounted under a new `key` replaces the old one's value.
  - **`@raycast/api` is `src/api/`.**
    `index.ts` exports what's implemented.
    `module.ts` wraps it so that any other Raycast export is a stub that throws `NotAvailableError` naming the API (e.g. `Clipboard.copy isn't available in Fudge yet`).
    Raycast AI and the Browser Extension, which Fudge doesn't support at all (`unsupported` in `stubs.ts`, FUD-118), say so instead, with no "yet": "Raycast AI isn't supported in Fudge." and "The Raycast Browser Extension isn't supported in Fudge."
    `environment.canAccess` is false for every stub, those included, as Raycast's own check is for a user without them.
    `scripts/raycast-types.ts` derives two files from the vendored types: the list of Raycast's exports (`src/api/raycast-exports.generated.ts`) and its enums with their values (`src/api/raycast-enums.generated.ts`: `Icon`, `Color`, `Action.Style`, …).
    `make raycast-types` regenerates them after updating the types, or run `npm run generate` by hand.
    `npm run typecheck` fails while either is stale.
  - **`OAuth`** (`src/api/oauth.ts`) signs in through a fudge-oauth relay (D-63), never Raycast's servers.
    The relay lives in its own repository, `jakeobsen/fudge-oauth`; it holds the OAuth apps' secrets, so Fudge holds none.
    `OAuth.PKCEClient` can be built with any `RedirectMethod`, as `@raycast/utils`' `OAuthService` does when an extension loads.
    `authorizationRequest()` asks the app for the request (`oauth.prepare`): the app refuses while sign-in is off, or for an `endpoint` that isn't one of `OAuthProviders`' authorize URLs, and otherwise starts the loopback listener and answers with the relay's authorize URL and the redirect.
    The client makes the PKCE verifier (64 unreserved characters from `crypto.getRandomValues`), its S256 challenge and the `state`, and `toURL()` puts them on the relay's URL with the extension's `clientId`, `scope` and extra parameters.
    `authorize()` sends the URL and its state to the app (`oauth.authorize`) and resolves `{ authorizationCode }`.
    `getTokens()`, `setTokens()` and `removeTokens()` call `oauth.tokens.*`; `getTokens()` returns a `TokenSet` whose `isExpired()` is true from 10 s before `expiresIn` runs out, so `OAuthService` refreshes on its own; without `expiresIn`, or with 0, it never is.
    `withAccessToken` retries a refused sign-in with a new promise until React gives up on the root (error #482), so after a refusal the worker reports that error as the refusal's own message (`explainRenderError`), once.
    **A refusal on purpose is a notice, not a crash** (SPEC-095, `src/notice.ts`): when the app's answer names a `notice` (`rpcResult`'s, e.g. `signInOff`), the bridge marks the rejection with it (a symbol, not enumerable), `explainRenderError` keeps the mark, and the worker's error report (`errorReport`) looks for it on the error, along its `cause` chain and in an `AggregateError`'s `errors`,
    since `@raycast/utils` or the extension may wrap the refusal, and sends the `notice` with the refusal's own message.
    The fetch rewrite's refusal while sign-in is off is marked the same way.
    Nothing is ever read from a message's text.
    A top-level `use()` with no `<Suspense>` boundary just holds the first render until the promise settles.
  - **The fetch rewrite** (`src/api/oauth-fetch.ts`).
    `OAuthService` fetches its token and refresh URLs itself, so the worker wraps `fetch`: a `Request`, or anything else read as a string, as `fetch` reads it.
    A request goes to the relay, as `<server>/<provider>/token` or `/refresh-token` with the same method, headers and body, only when it's a `POST` to one of the table's token or refresh URLs (by scheme, host and path) with `grant_type` `authorization_code` or `refresh_token`.
    Google, Atlassian and Zoom refresh at their own token URL, so there the grant picks the endpoint, and since those are the providers' own URLs, they go to the relay only when this extension has a relay sign-in for that provider, pending or stored (`SignInCalls.hasRelaySignIn`); an extension's own flow, or a service account's grant, goes where it was going.
    **Nothing is ever sent to Raycast's proxy hosts** (`*.oauth.raycast.com`, with or without a trailing dot): what isn't rewritten there is refused, with sign-in on or off.
    A rewritten request goes to the relay through Node's `http`/`https` (`sendToRelay`), never undici, as the `Request` `fetch` would send (its method, headers and serialized body, its `signal`), and comes back as the `Response` `fetch` would give, streamed and decoded.
    Its connection always verifies (`relayTLSOptions`: `rejectUnauthorized: true` and TLS 1.2 at least), whatever the worker's `NODE_TLS_REJECT_UNAUTHORIZED` says, since it carries the code and verifier or the refresh token.
    A redirect from the relay is an error, never followed, since a 307 or 308 would send that body on.
    Every other request keeps `fetch`'s own redirects, as in Raycast (D-65), so a third party's redirect to `*.oauth.raycast.com` isn't intercepted.
    The table holds the seven providers `OAuthService` has built in, at their default URLs, and Raycast's proxies for Jira and Zoom (`jira.oauth.raycast.com`, `zoom.oauth.raycast.com`), which the store's Jira and Zoom extensions set (FUD-137).
    Those go to the relay's `atlassian` and `zoom` providers, beside Atlassian's and Zoom's own URLs, so two entries can share a relay provider (`OAuthProvider.id`), and an entry is known by its authorize URL.
    One Atlassian app covers Jira and Confluence, so both Atlassian entries are named **Atlassian (Jira, Confluence)**.
    A sign-in stored with `relayProvider: "jira"`, the relay's Atlassian provider before fudge-oauth v0.3.0, counts as Atlassian's (`OAuthProviders.currentRelayProvider`).
    The table is core's (`OAuthProviders`), handed to the host as JSON in `FUDGE_OAUTH_PROVIDERS`; `runtime/test/fixtures/oauth-providers.json` is the same table, pinned by a Swift test, for the runtime's tests.
    Only for a request that may go to the relay does the worker ask the app (`oauth.server`, with the provider): the server in use, so a change while a command runs is honoured, and whether the extension has a relay sign-in there.
  - **Below `fetch`** (`src/api/oauth-http.ts`, SPEC-075).
    Extensions bundle their own HTTP clients (`@raycast/utils` 1.x posts its token requests through `cross-fetch` → `node-fetch` → `https.request`, as axios and got go through `http`/`https`), so the same rules (`decide` in `oauth-fetch.ts`, the one decision function for every entry point) apply to `http` and `https`'s `request` and `get`.
    A request that needs a decision (`needsDecision`: Raycast's proxy hosts and the table's token and refresh URLs) keeps its real `ClientRequest`, with no agent and a socket of Fudge's own (`createConnection`) that holds the bytes until the request has finished, decides, and then sends them to the relay with the request line and `Host` rewritten (over a connection that always verifies,
    with the caller's trust and identity, a CA or a client certificate, never an option that weakens verification such as `rejectUnauthorized: false`, and the relay's name; `relayTLSOptions`), fails the request with `fetch`'s refusal, or lets it go out exactly as the caller made it: through Node's own function with the caller's arguments, its agent (a proxy's included) and TLS options,
    and the headers and body it wrote, the answer coming back through Fudge's socket as the bytes it arrived as.
    A redirect from the relay fails it too.
    Every other request is untouched.
    **The backstop** is `net.Socket.prototype.connect`, which every client in the worker reaches (https, http2, undici's `fetch` and WebSocket): a connection to `*.oauth.raycast.com`, by its host or a TLS connection's `servername`, ignoring case and trailing dots, fails with that refusal before any DNS lookup.
    The worker installs all of it before the command loads, then calls `syncBuiltinESMExports()`, so a library that keeps `https.request` at load, or imports it as an ESM name, gets the wrapped one.
    What it can't catch is a raw IP address with no TLS name, or a native addon.
  - **Calls into the app** go through `src/bridge.ts` (`callApp(method, params)`), which sends an `rpc` message and waits for the app's `rpcResult`.
    On the Swift side, `SystemCalls` answers them (clipboard, `open`, Trash, Finder, applications, the selection, windows).
    `LauncherModel` handles `preferences.*`, `oauth.*` (sign-in), `command.launch`, `command.updateMetadata`, `clipboard.paste` (it hides the panel), `form.storeValues` and the window calls: toasts in the bottom bar, the HUD (`HUDWindow`), `alert.confirm` (an `NSAlert` sheet on the panel), `window.close`, `window.popToRoot` and `searchBar.clear`.
    A toast's actions come back through the `toastAction` message.
  - **`updateCommandMetadata`** (`src/api/command-metadata.ts`) sends `command.updateMetadata` with the calling command's new root-search subtitle, or null to go back to the manifest's.
    `CommandMetadata` (core) keeps it in `command-metadata.json`, by `<extension>/<command>`, keeps keys it doesn't know, and drops the entries of commands that aren't installed when the file is loaded (never from an empty listing); the manifest is never touched.
    It never overwrites a file it can't read (`Unreadable`): the update fails instead, and the extension's promise rejects saying why.
    A command's root item shows that subtitle, else the manifest's `subtitle`, else its extension's title, and search matches the extension's title either way.
    The extension's title is left out when it only repeats the command's title, ignoring case and spaces around them (`RootItem.subtitle(_:unlessItRepeats:)`, SPEC-120), so a one-command extension named like its command shows its name once; a subtitle the author set is shown as set, and a built-in group's title falls back the same way.
  - **`launchCommand`** (`src/api/launch-command.ts`) checks its options in the worker, makes the arguments strings, and encodes `context` with `encode` (`src/protocol.ts`): Dates as `{ "$date": iso }`, Buffers as `{ "$buffer": base64 }`.
    It then sends `command.launch`.
    In the app, `LaunchRequest` reads the call and `CommandLocator` (core) finds the command: in the caller's extension, or in the one with that name and owner (else author).
    It fills every manifest argument, and its checks turn away what can't run: view commands in the background, a menu-bar command in the background unless it's active (`checkMode`), and missing required arguments or preferences in the background.
    A menu-bar command goes to `MenuBarController`: Background refreshes it like an interval tick, and UserInitiated activates it if needed and refreshes it, without opening its menu.
    A user-initiated launch with a required argument empty shows root search with the command's fields instead; an unset required preference opens Settings.
    The first time an extension opens another extension's command, the user is asked through `confirm`, and `LaunchPermissions` keeps the answer in `launch-permissions.json`; only a call from a session the user is using may ask, whatever `LaunchType` it requests.
    The caller's origin is read when the call comes in, and a background caller's request runs as Background (`LaunchRequest.asCalled(from:)`), so it fails where a Background launch would instead of showing the panel, argument fields or Settings.
    It never overwrites a file it can't read (`Unreadable`), which the Permissions page then says.
    The launch itself goes through `prepareLaunch` and `launch`, as from root search.
    A background launch is `quiet`: no status line, the panel stays as it is, failures show in the HUD, and it isn't recorded in `LaunchHistory`.
    The call is answered once the `launch` message is sent, and only then is a replaced command on screen unloaded.
    Swift carries `context` untouched, and the launched command's worker revives it into `launchProps.launchContext`.
  - **The selection.**
    `getSelectedText()` and `getSelectedFinderItems()` call `selection.text` and `selection.finderItems`; the logic is `SelectedText` and `FinderSelection` (core), and `FudgeApp/Selection.swift` is the system side, behind small protocols.
    Both read the frontmost app, which is the one the user was in because the panel doesn't activate Fudge.
    - `SelectedText` asks the app's focused element for its selected text through the Accessibility API.
      When that gives nothing, it snapshots the pasteboard (every item, every type), posts ⌘C to the app (`CGEvent.postToPid` from a private event source, on the key that types "c" in the current layout), polls `changeCount` for up to 500 ms, and restores the snapshot before answering, without types over 50 MB, unless `changeCount` never moved (then nothing touched the pasteboard).
      A snapshot marked `org.nspasteboard.ConcealedType` (a password manager's copy) isn't written back: the pasteboard is left empty, because a restored password gets a new `changeCount` and the manager never auto-clears it.
      The fallback takes its turn from `PasteboardTurns` (core), the one the app shares with `Paste`, so fallbacks and pastes run one at a time, and in its turn it first waits for a pending Paste restore to run or be dropped (never hurried, since the target app may not have read the pasted content yet), so its snapshot is the user's clipboard, not Fudge's pasted content.
      It never posts ⌘V or ⌘X.
    - `FinderSelection` asks for Automation permission first (`AEDeterminePermissionToAutomateTarget`, no timeout, since the user may be reading the consent dialog).
      A background call doesn't ask (`askUserIfNeeded` false), and while the user hasn't decided it's refused (`finderAutomationNotAsked`).
      Then it sends Finder `core/getd` of `selection` as an alias list with a 5 s timeout.
      It resolves POSIX paths in Finder's order, folders without a trailing slash.
    - `Paste` (`Clipboard.paste`, `Action.Paste`, `clipboard.paste`) snapshots the pasteboard the same way, writes the content as `Clipboard.copy` does, marked `org.nspasteboard.TransientType` and `AutoGeneratedType`, hides the panel unless `closeMainWindow` is false, waiting a run-loop turn plus 50 ms after hiding it so key status is back with the target app,
      and posts ⌘V to the frontmost app on the key that types "v", after any ⌫ presses it was given (`backspaces`, an expanded keyword), to the same app from a private event source with only each key's own flags and `SnippetExpander.marker`.
      **The caret** (SPEC-101, FUD-133): an app takes ⌘V on a later turn of its run loop, so ← presses sent at once can arrive before the pasted text.
      Before any key goes out (an expansion's ⌫ presses included, which `PastedText.deletedBefore` counts in UTF-16 units; a plain expansion skips this), `Paste` reads the focused field's `kAXNumberOfCharactersAttribute` and `kAXSelectedTextRangeAttribute` (`CaretSystem`, the app's `SystemCaret`), never its value.
      After it, `CaretPlacer` (core) polls them every 15 ms until they show the paste, until a second after ⌘V by the clock (each read can take its 2 s timeout, so polls aren't counted); a read that fails ends the wait at once.
      The paste has landed (`PasteLanding`, in UTF-16 units) when the caret is just after the pasted text, or, where the caret isn't reported, when the length is what the paste gives, counting the selection the paste replaces or the text ⌫ presses deleted before it.
      A paste no longer than what the ⌫ presses delete can't be told apart from them, so it isn't watched.
      Then, for a `{cursor}`, it sets an empty `kAXSelectedTextRangeAttribute` before the text after it and reads it back (a set the field took is trusted when the read-back fails).
      Where the field doesn't take that, or stops partway, ← presses go from where the caret is, 10 at a time, 10 ms apart, from a private event source with only the arrow keys' own flags and `SnippetExpander.marker`.
      A field that reports nothing, or never shows the paste, gets the ← presses after 150 ms more.
      Every call into the app runs on a dispatch queue with FUD-93's 2 s timeout, never the main actor, and a `{cursor}` paste resolves once the caret is placed.
      Each one logs one line (`CaretReport`: the path taken, the wait, the counts; no text or app).
      About a second after ⌘V, and not before the paste has landed or the wait has ended (`PasteWatch`), it writes the snapshot back if `changeCount` is still its own; a concealed snapshot is cleared instead.
      Pastes take the same turns as the ⌘C fallback (`PasteboardTurns`).
      A paste while a restore is pending keeps that restore's snapshot, unless the pasteboard has changed since Fudge's last write.
      Without Accessibility permission the content stays on the pasteboard and the call rejects; it never pastes into Fudge itself.
    - `AccessibilityGate` holds the Accessibility check for both, so macOS's prompt shows at most once per run. macOS shows that prompt only when Fudge isn't in the Accessibility list, so an entry that's off or left by an older build's signature gets none.
      `check(origin:)` says so: the first user-initiated refusal asks for the prompt, and the next one, from either feature, also says `offerSettings`, once per run.
      A background call only checks (`isTrusted(prompt: false)`), with no prompt and no offer, and leaves both for the next user-initiated refusal.
      Then `isTrusted()` calls the app's `AccessibilitySettingsOffer`, which shows Fudge's own alert (`AccessibilitySettingsAlert`, core) with a button that opens the Accessibility pane.
      It's a sheet on the panel when the panel is up, and it's shown on a later main-actor turn, so the refused call is answered first, with its usual message.
    - Everything that waits on another app runs off the main thread.
  - **Windows.**
    `WindowManagement` (`src/api/window-management.ts`) calls `windows.desktops`, `windows.active`, `windows.onActiveDesktop` and `windows.setBounds`, each after `AccessibilityGate`'s check, as Paste does.
    `WindowManager` (core) holds the logic over `WindowSystem`; `SystemWindows` (`FudgeApp/Windows.swift`) is the system side, public APIs only: the window list (`CGWindowListCopyWindowInfo`) and the Accessibility API, off the main thread with a 2 s timeout.
    A window is an on-screen, visible, layer-0 window of a regular app, never Fudge's, and its id is its window number.
    Its Accessibility window, which says what can change and whether it's full screen, is one in the same place at the same size to within a point, with the same title when both have one.
    The window list has no titles without Screen Recording, so an app's same-size windows in one place all match each other: `WindowMatch.pairs` pairs an app's listed windows one to one with its AX windows, front to back in both lists, a window's title match first, and minimized AX windows take no part.
    The active window is the one paired with the frontmost app's focused AX window.
    Public APIs can't list Spaces, so each screen is one desktop (`screen-<display id>`): active when it holds the active window (else the frontmost app's topmost window, else the mouse's screen; a window counts as on the screen holding most of it, the primary one when it's on none), and `FullScreen` when its front window is.
    `getWindowsOnActiveDesktop()` lists only the active desktop's windows.
    `setWindowBounds` keeps what it isn't given, and refuses an unknown id, a change the window doesn't allow, and another desktop.
  - **The launch context.**
    `src/api/launch.ts` holds what the app sent with the launch: preferences, `LaunchEnvironment` (built by `LaunchEnvironment.make`) and launch props.
    `environment` reads it through getters.
    Raycast's deprecated `preferences` record (`src/api/deprecated.ts`) is built from it when first read: the declarations in the installed extension's `package.json` (`manifestPath`, which the app sends in the launch's `LaunchEnvironment`, never worked out from where the command's file is; the extension's, then the command's, which win), each with its resolved value.
    `createApiModule` leaves its members alone (`plainRecords`).
    The deprecated `randomId` is nanoid's: 21 URL-safe characters from `crypto.getRandomValues`.
    `LocalStorage` (one JSON file) and `Cache` (one `cache.json` per namespace, least recently used dropped beyond its capacity) read and write in the worker, under the paths the environment names in Fudge's support folder.
- **The Extension Store** is an extension bundled with Fudge, in `runtime/store-extension/` (`fudge-extension-store`), written against `@raycast/api` like any other.
  `npm run typecheck` checks it with its own `tsconfig.json`, and `runtime/test/store.test.ts` tests its modules, with a fake git runner and a local bare repository (no network).
  - `git.ts` keeps a shallow, blobless, sparse clone of github.com/raycast/extensions in its support folder's `repo/`, with only `/extensions/*/package.json` checked out.
    A README or an extension's source comes on demand through `sparse-checkout add`; the detail's scan adds only a folder's source files (`scanPatterns`: `src/**/*.tsx`, `.ts`, `.jsx`, `.js`) and takes those patterns out again afterwards (`drop`, through `sparse-checkout set --no-cone --stdin` with every other pattern), so a later refresh doesn't fetch their changes.
    Those extensions are the scanner's own (`sourceExtensions`, in `scripts/compat/source-files.ts`, which the store imports).
    What was downloaded stays in `.git` while the copy's commit reaches it (a refresh prunes only what its new commit doesn't), so a checked folder's source is downloaded once per version.
    Nothing else prunes it, since a repack that left out blobs would also drop the checked-out manifests.
    `sourceFiles` lists a folder's `src/` from the trees alone, which a blobless clone has in full, so it downloads nothing.
    The copy is refreshed when it's a day old or on ⌘R: the default branch's name (checked by `isValidBranch`) is fetched as `refs/heads/<branch>` into its remote-tracking ref, the branch moves there, every other ref and the reflogs go, and only what the refs reach is packed again, into one pack marked as the remote's, before `git prune`.
    So the copy stays one commit deep and `.git/shallow` names only that commit.
    `gc` can't do this in a blobless clone: it keeps every object that came from the remote, reachable or not, and its repack asks the remote for the old commits `.git/shallow` still names.
    Every git call is an argument array with a timeout (`timeouts.ts`: the long one for anything that downloads or rewrites the copy), and runs with `GIT_TERMINAL_PROMPT=0` and without the user's git configuration (`storeEnvironment`), so an `insteadOf` rule can't redirect it.
    Git isn't run until `xcode-select -p` succeeds, so macOS's offer to install the Command Line Tools never shows.
    Without them the store shows `NeedsGit` (`failure-view.tsx`): ↵ Install Command Line Tools runs `xcode-select --install`, macOS's own installer, only from that action (`installCommandLineTools`), and ⌘R Refresh checks again.
    A failure whose cause is Git missing has the same action.
    Unloading the store ends its running git (`stopRunningGit`, in the command's effect cleanup, which `unload` runs), and turning the store off unloads its sessions and waits for them to exit (`LauncherModel.unloadSessions(ofExtension:)`) before Part A deletes `repo/`.
    A copy that can't be read, such as a clone stopped halfway, is deleted and cloned again.
    A failure before the list has ever loaded, which can only be the clone, shows in the load-error view (`LoadFailure` in `failure-view.tsx`), whose Refresh (↵, ⌘R) opens the copy again the same way and then refreshes it.
    That view has the failure view's cause line (a clone that can't reach GitHub says so), ⌘C Copy Error and ⌘D Show Details, which pushes the failure view with the end of git's output.
    A refresh runs only once the list has loaded from the copy, so a failed one, a default branch name `isValidBranch` refuses included, shows as a toast over the list, which stays usable.
  - **Files from the copy are read as regular files only** (`files.ts`, `readRegularFile`: opened with `O_NOFOLLOW` and `O_NONBLOCK`, then `fstat`), each kind with a size cap: every `package.json` for the list, a README, and the package-source check's `package.json` and lockfiles. git checks out a committed link as a link, so `README.md -> /dev/zero` would otherwise read forever.
  - `catalog.ts` gives each row two things, each checked by its own rule before it's used.
    `name` is the manifest's name (`isValidName`, the app's rule, pinned to `ExtensionManifest.isValidName` by `runtime/test/fixtures/extension-names.json`): the extension's identity, its installed folder (`<extensions>/<name>`) and its `installed.json` key.
    `dir` is its folder in the repository (`isValidFolder`: one segment of letters, digits, `.`, `_` and `-`, starting with a letter or digit), which can differ (`amazon-aws` holds `aws`): the sparse pattern, the README, the scan, the build's source and the URLs.
    Folders that differ only by case are one on APFS, so only the first is read (`distinctFolders`).
    Two folders whose manifests share a name are both listed; `installed.json` records each install's folder (`dir`; an entry from before has its name's), and only that folder's row is installed or has an update (`installedRecord`).
    An install is refused while another extension of that name is installed, from another folder or not from the store ("Another extension called … is installed. Uninstall it first."), for a bundled extension's name (`bundledNames`), and when the folder's manifest no longer has the listed name.
  - `sources.ts` refuses an extension that could get packages from anywhere but registry.npmjs.org: an `.npmrc` anywhere in it, a lockfile entry off the registry (both lockfile shapes;
    `link`, and a `file:`, path, `user/repo` or tarball version too), an entry's own dependency specs that aren't registry versions (its dependency sections, or a version 1 entry's `requires`), or a dependency spec or override that isn't a registry version (a tarball name like `x.tgz` isn't).
    File names are compared ignoring case, as APFS and the build's copy by name do, and two names that differ only by case are refused.
  - `readme.ts` shows images only from GitHub's hosts; other images become their alt text.
    `detailMarkdown` lists each command with its mode (view, no-view, menu bar) and runs everything in the detail pane through it, the manifest's own text included.
    A source the renderer would read differently (whitespace, `<`, `>`, `)`) is refused, and a last pass (`rendererPass`) applies the renderer's own image rule to the finished text.
  - `compatibility.ts` is what the store says about compatibility (FUD-118).
    A scan's result (`Compatibility`: the categories Fudge doesn't support, the APIs it lacks, signing in, unreadable source;
    or `notChecked`) is cached by the folder's git tree id in `compatibility.json` in the store's data folder (the newest 4,000, entries checked on reading, API names identifiers only), with the scanner that wrote it: the `fudge` tool's size and modification time, so a new build of Fudge, which may support more, scans again (`scannerIdentity`).
    The list never scans: a row whose cached result uses something Fudge doesn't support gets a tag (`compatibilityTag`), a red **Not compatible** when every command does, or an orange **Partly compatible** when only some do.
    A result keeps which commands do (`byCommand`, from the scan's per-command results); one without it, or whose scan has none, counts the whole extension, as before SPEC-109.
    What only an AI tool uses counts for no command, so it isn't mentioned.
    The detail pane's first fact is **Compatibility** (`compatibilityText`): Checking…, Compatible, Partly compatible: 2 of 9 commands use Raycast AI: and their titles, Not compatible: Raycast AI, Missing: the APIs, Signs in with OAuth, Couldn't check, or Not checked.
    **Browsing never turns into downloading** (`CompatibilityChecks`): only the row the selection rests on, with the detail showing, is checked, after half a second, and moving on cancels its timer, or the check itself: its download ends at once, and the check stops between its other steps; selecting the same row again changes nothing, and a cached row is never fetched.
    Only the download (`fetchSource`) is ever ended, since it writes nothing but new packs: it runs in a process group of its own, which the cancel's `signal` sends SIGTERM, then SIGKILL after `cancelGrace` (a second).
    Every other git step runs to its end, since one that writes the index holds `index.lock`, and ending it would leave that behind for every later checkout and install.
    The README waits the same way: both run through `RestingWork` (`resting.ts`), and only the resting row's README is fetched (`fetchReadme`), once per folder tree, since READMEs are kept by tree id.
    It's selected before the check, so its quick fetch goes ahead of the check's download in the git queue.
    A README git couldn't fetch isn't kept (it shows as none), and ⌘R fetches it again (`RestingWork.again`).
    A check (`checkFolder`) runs in the git queue, one at a time: it counts the files under the folder's `src/` from the trees (`srcFiles`), the source files (`isScanned`: what the patterns check out, a folder named like a script included) and all of them, and isn't checked past either cap (`maxScanFiles`, 300 source files; `maxSrcFiles`, 1,000 files).
    It then downloads what isn't here yet with each file's size capped (`fetchSource`), only when a source file is missing (`missingObjects`), so a folder checked before in this version downloads nothing again.
    That's the `src/` tree fetched again (`--refetch`) with a `blob:limit` of `maxScanBytes`, which the server applies to what it finds under the tree, assets included, since a filter can't pick files by name; that's why every file counts toward `maxSrcFiles`.
    Blobs asked for by their own ids would come whatever their size.
    A source file left out for its size means the row isn't checked (`missingObjects`, `rev-list --missing=print`, which downloads nothing on any git); an asset left out isn't read, so it doesn't matter.
    It then checks out the source files with git's lazy fetch off (`addFetched`, `GIT_NO_LAZY_FETCH`), checks their total (more than `maxScanBytes`, 5 MiB, isn't checked), scans with `fudge scan`, caches the result, and always takes its patterns out again.
    Only a server that refuses the tree's id, in git's own words (`isRefusedWant`: "not our ref", or "Server does not allow request for unadvertised object"), gets the fetch as before: `add`'s lazy fetch, which downloads each source file by its id whatever its size, with the total checked after the download.
    Any other failure of the tree fetch (a timeout, the network) fails the check, and nothing more is downloaded.
    A blobless clone has no sizes before a download, so the first cap is on the number of files.
    Install shares the cache both ways.
  - `store.ts` installs with `$FUDGE_CLI build <source> --into $FUDGE_EXTENSIONS_DIR`.
    Every git operation (refresh, a README's `sparse-checkout add`, a detail's scan, install, uninstall) waits its turn in one queue (`oneAtATime`), so none overlaps another.
    Before asking, it takes this version's cached result, or runs `$FUDGE_CLI scan <source> --json` and caches it, and the confirmation says what it found (`compatibilityLine`).
    For Raycast AI or the Raycast Browser Extension, which Fudge doesn't support, it's "Partly compatible with Fudge", naming the commands its scan found, which the build turns off, or "Not compatible with Fudge" when that's every command; installing stays possible either way.
    The build scans the source again, exactly what it installs, so its `compatibility.json` is what's true: after the build, the store reads it (`builtCompatibility`), and when it isn't what the confirmation named, the done message says what is, in a toast instead of the HUD (`installNote`, SPEC-121 §2).
    That's "Turned off: …" for commands the confirmation didn't name (its scan failed, say), "Every command is on" when the build found none, and that Fudge couldn't check, so every command is on, when the build's scan failed after the confirmation named some.
    Then it names up to five APIs it doesn't have yet and how many more; that it signs in with OAuth, which works if the chosen sign-in server supports its provider (never called not compatible); everything supported; or that the scan couldn't run, which doesn't stop the install.
    It records the folder's git tree id in `installed.json` ("Update available" when the id changes), and uninstalls only what it recorded.
    **Unloading the store doesn't stop a `fudge build` it started** (or npm under it), unlike its git: the worker's timeout goes with it, so the build runs to the end, or until npm's own network timeouts give up.
    That's acceptable because nothing is installed half-way: the build writes into a staging folder and swaps it in only at the end, and the extensions watcher picks the result up like any install.
    The store just doesn't record it, so it counts as installed another way.
    **A failed install or update** pushes `FailureView` (`failure-view.tsx`, SPEC-116) over the list, and the toast only says where to look.
    It has the title, the likely cause in plain words (`causeOf` in `failure.ts`: npm or Node.js not found, which, since both come with Fudge, means a damaged app to reinstall, the npm registry or GitHub unreachable, Git missing, the extension's own build error with its first line, or else something went wrong), and the last 40 lines of the step's output.
    The output is untrusted (package names, build scripts' output), so it's in a code block nothing in it can close (`codeBlock`), and the title and cause are escaped code point by code point (`escapeMarkdown`), so no package can add an image, a link or formatting.
    Before it's shown or copied, terminal codes, user info in URLs, `_authToken=`, authorization headers and token-shaped strings are masked, and the home folder is written as `~`, as a whole path component only (`cleanOutput`).
    ↵ Try Again runs the install again, once per view; ⌘C Copy Error copies the title, cause, command, exit, Fudge's version (`fudge version`) and all the output; Open Extension Page on GitHub opens the folder.
    `failureDetails` (`store.ts`) reads them from `BuildFailed` (all of `fudge build`'s output, its command and exit), a `GitError` (with its command) or one of the store's own refusals, shown as its own sentence.
    **The Mac's proxy** reaches the store's npm and git (`proxy.ts`): the app reads the proxy set in System Settings → Network (`CFNetworkCopySystemProxySettings`) into `SystemProxy` (core), well-formed hosts and ports only and never a user or password, and hands it to the host as `FUDGE_SYSTEM_PROXY`.
    `storeEnvironment` adds `HTTPS_PROXY`, `HTTP_PROXY` and `NO_PROXY`, in both letter cases since git's curl reads only `http_proxy` in lower case, and only where no proxy variable is set, so the user's own wins.
    That `NO_PROXY` is `localhost`, `127.0.0.1` and the Mac's bypass list, unless the user set their own.
    A proxy auto-configuration file can't be passed on, so a network failure's cause line says so.
- **`fudge build <folder>` installs an extension** (`ExtensionBuilder` in `FudgeCore`).
  - It reads `package.json` (`ExtensionManifest`) and compiles every command's `src/<command>.{tsx,ts,jsx,js}` with esbuild into `<extensions>/<name>/<command>.cjs`, beside `package.json` and `assets/`, as Raycast installs it (SPEC-123).
    So a command's `__dirname` is the extension's folder, and `${__dirname}/assets/…` and `${__dirname}/package.json` are its own, as extensions such as the store's amazon-aws expect.
    esbuild writes into a folder of its own inside the staging folder, and only the commands' files move up, so anything else it writes (a stylesheet an import pulls in) never reaches the install.
    The modules the host provides (`ExtensionBuilder.providedModules`) stay external.
    Extension and command names are lowercase letters, digits, `-` and `_`, starting with a letter or digit, as Raycast's rule allows (`notion_researcher`): `ExtensionManifest.isValidName` is the one name rule, which every check of an extension's name uses (the build, backups and their paths, settings keys, built-in group names) and the store's `catalog.ts` mirrors.
  - It writes the build into `.staging-<name>-<uuid>` with `package.json` and `assets/` alongside, then swaps the whole folder into place (a previous install is moved to `.old-<name>-<uuid>` first, then deleted).
    It replaces only a folder that holds what a build writes, hidden files aside (`ExtensionBuilder.holdsOnlyABuild`): `package.json`, `assets/`, `compatibility.json`, `dist/` (the old layout), and `<command>.cjs` for each command that folder's own `package.json` names, so an update that renames a command still replaces it; anything else is `BuildError.notAnInstall`.
  - **Installs from before SPEC-123** have their commands in `dist/`.
    At launch, before the extensions first load and before the watcher starts, the app moves each such install in the extensions folder over (`ExtensionLayout.moveUp`, from `AppDelegate`; never in a snapshot run, and never the bundled extensions inside the app).
    Each `dist/<command>.cjs` is renamed up with `RENAME_EXCL`, never copied, so a command is whole in one place or the other, and then `dist/` goes with `rmdir`, only when it's empty.
    The compiled files are self-contained bundles, so moving them needs no rebuild.
    An install isn't touched unless it passes `holdsOnlyABuild`, and one whose `dist/` holds anything but regular `<command>.cjs` files its manifest names, or a command in both places, is left as it is, with one line in the unified log (category `extensions`, the extension's name private).
    `InstalledExtension.entry(for:)` finds a command at the root first, then in `dist/`, so a move stopped halfway or refused still launches every command, and the next launch finishes a stopped one.
    When a command is in both places, the root's wins and the `dist/` copy stays.
  - Before the swap it scans the source (`ExtensionBuilder.scanCommands`: the CLI runs `fudge scan --json` through `CompatScanner.commands`, reading its stdout alone) and writes which commands use Raycast AI or the Browser Extension into the install as `compatibility.json`.
    A scan that can't run or fails leaves it out, and every command is on.
  - It never writes into the source folder.
    When the source has no `node_modules`, it installs the dependencies into a temporary folder (`npm ci --ignore-scripts`; under `$TMPDIR` when it's set, which Foundation's `temporaryDirectory` ignores) and points esbuild at it with `NODE_PATH`.
  - **Ending the tool ends what it started.**
    `fudge build` and `fudge scan` run every program (esbuild, npm, node) through `ChildProcesses` (core): `posix_spawn` in a process group of its own, with default signals and only stdin, stdout and stderr passed on.
    On SIGTERM, SIGINT or SIGHUP the tool signals each child's whole group, so npm's and node's own children go too, waits up to a second, kills what's left, deletes `fudge build`'s staging and scratch folders, which `defer` would miss (`ChildProcesses.deleteOnSignal`; not a staging folder already being moved into place), and exits with 128 + the signal (`ChildProcesses.endChildrenOnSignals`).
    That's what makes the Extension Store's timeouts, which send SIGTERM, end the whole job.
  - Extensions live in `FudgePaths.extensionsDirectory`: `~/Library/Application Support/fudge/extensions`, or under `$FUDGE_SUPPORT_DIR`.
  - **The running app picks it up.**
    `ExtensionsWatcher` (core) watches the extensions folder through FSEvents, with file-level events.
    Its stream is made, started, stopped and released on a serial queue of its own, which it delivers on, never on the main thread, since each of those calls asks `fseventsd`, which can take seconds or not answer (FUD-153); `start` and `stop` return at once, and a batch goes on to the main queue.
    A path counts unless its first component under the folder starts with `.` (`.staging-*`, `.old-*`, `.DS_Store`), and a trailing 0.3 s debounce makes each install, rebuild or removal one reload: `LauncherModel.reloadExtensions()` (the installed extensions only, keeping the scanned applications, the query and the selection), the command hotkeys, and the Settings window if it's open.
    The menu's Reload Extensions also scans applications again.
    Snapshot runs don't watch.
- **The Makefile assembles the app bundle** (`make app`):
  - the `FudgeApp` binary becomes `Contents/MacOS/Fudge`
  - the `fudge` tool and esbuild's native binary go into `Contents/Helpers/`, where `ExtensionBuilder.locateEsbuild` finds esbuild next to the tool
  - **Node.js** (SPEC-115): an official build from nodejs.org, `NODE_VERSION` in the `Makefile`, for the architecture the Mac builds for (arm64 or x64, never both: the app itself is built for one).
    Its tarball's SHA-256, copied from the release's `SHASUMS256.txt`, is pinned beside the version, and `make` checks it before unpacking anything; a tarball that doesn't match is deleted, and the build fails.
    It's downloaded once into `.cache/node` (ignored, and kept by `make clean`), and every Node step of the build runs it (`npm ci`, esbuild, the runtime's tests), since the `Makefile` puts it first on `PATH`.
    To update it, change the version and both checksums together.
    The bundle gets the binary as `Contents/Helpers/node`, npm from the same distribution as `Contents/Resources/node/npm`, and its `LICENSE` (Node.js's, with what it bundles) as `Contents/Resources/node/LICENSE`.
    `fudge build` runs npm as `node npm-cli.js` (`BundledNode.npm`), with the helpers first on `PATH` so whatever npm starts gets the same Node.js.
    Its entitlements are in `App/Helpers/node.entitlements`, which `scripts/sign-app.sh` gives it (below), so a release's Developer ID signature keeps them: `allow-jit`, without which V8 can't start, and `disable-library-validation`, without which an extension's native addon (`.node`), signed by whoever built it, is refused ("different Team IDs").
  - `App/Info.plist` gets three versions from `git describe --tags --always --dirty` (`VERSION`, or the release workflow's `RELEASE_TAG`):
    `CFBundleShortVersionString` is the version tag's major, minor and patch, as macOS expects (`runtime/scripts/bundle-version.ts`: `v0.3.0-14-ga539cdd` is `0.3.0`, and with no version tag `0.0.0`), `CFBundleVersion` is `git rev-list --count HEAD`, and `FudgeGitDescribe` is the describe itself.
    Fudge shows its own form of the describe (`FudgeVersion.display`: `0.3.0`, `1.2.0-rc.1`, or after a tag `0.3.0-dev+14.a539cdd.dirty`), in the menu, General's update row, About, `fudge version` and its `User-Agent`s.
    `FudgeVersion` (core) reads the keys in the app, and in the `fudge` tool from the app's `Info.plist` beside `Contents/Helpers` (through a symlink too), only when its bundle id is Fudge's; anywhere else it's `0.0.0-dev`.
    **A release build stops rather than number itself wrong** (`make release-check`, before anything is built): with `CONFIG=release`, a shallow clone, which has no tags and would make the build number 1; with `RELEASE_TAG`, a tag that isn't on this commit.
    The release workflow checks out the whole history and its tags, and passes `RELEASE_TAG` for a tag's build.
  - `App/AppIcon.icon` (an Icon Composer icon) is compiled by `actool` into `Assets.car` and an `AppIcon.icns` fallback.
    That needs Xcode 26 or later.
  - the bundled extensions (`BUNDLED_EXTENSIONS`, as `BundledExtensions.folders` lists them) are built with `fudge build` from `runtime/<folder>` into `Contents/Resources/<folder>`
  - the host and worker bundles go into `Contents/Resources/runtime/`, with `fudge scan`'s `compat-scan.js` and Raycast's types beside it (`raycast-api.d.ts`, with its MIT notice as `raycast-api.LICENSE`)
  - Fudge's `LICENSE` goes into `Contents/Resources/LICENSE.txt`, and `runtime/scripts/notices.ts --text` writes `Contents/Resources/Third-Party Notices.txt`: each third-party component the app ships, with its version and its own license file's text.
    Its `components` list is the one place they're named, and the repo's `THIRD-PARTY-NOTICES.md` is the same, written by `npm run generate`.
    Node.js's entry is the `LICENSE` of the Node.js the `Makefile` pins (`NODE_VERSION`), read from `.cache/node`: the same file `make app` copies to `Contents/Resources/node/LICENSE`.
    `npm run typecheck` fails while that file is stale, or when a bundle Fudge ships (the host, the worker, `compat-scan.js`, a bundled extension) takes in an npm package the list doesn't have; anything else the app ships, such as a binary in `Helpers/`, adds its entry by hand.
  - with `CONFIG=release`, `strip -S -x` takes the debug and local symbols out of `Contents/MacOS/Fudge` and `Contents/Helpers/fudge`, which otherwise name the builder's folders (`/Users/…`, about 300 paths each) and double their size
  - `scripts/sign-app.sh` signs it inside-out, each executable in `Contents/Helpers` (the `fudge` tool, esbuild and Node.js), then the app with `App/Fudge.entitlements`, all with the hardened runtime (FUD-44).
    A helper that needs entitlements of its own has them in `App/Helpers/<its file name>.entitlements`, so a release's signing with the Developer ID gives them too.
    Any other executable added to the bundle (a dylib, a `.node` addon) must be signed there too, or notarization refuses the release.
    The identity is `SIGN_IDENTITY`: from what `security find-identity -v -p codesigning` lists, the default is "fudge local signing", else the first `Apple Development:` identity, else ad hoc (see the README).
    It's picked by SHA-1, since two certificates can share a name.
    The `→ built` line names the identity, and codesign's output shows only when it fails, which fails the build.
    Only a Developer ID signature gets Apple's secure timestamp, which notarizing needs, so dev builds never sign over the network.
    A Developer ID identity's name is never shown (`Developer ID Application: <redacted>`), since a release's log is public.
- **`make compat-scan DIR=<folder>` measures store compatibility statically** (`runtime/scripts/compat-scan.ts`).
  Every folder in `DIR` with a `package.json` and a `src/` is an extension, as in a checkout of raycast/extensions.
  Nothing is built or run.
  - `scripts/compat/scan.ts` turns each source file into JavaScript with esbuild, which drops type-only uses.
    Sources are read as regular files of at most 5 MB (`scripts/compat/files.ts`, as the store's `files.ts` does); a link, FIFO, device, folder or bigger file with a source's name is listed as unreadable, and nothing is followed.
    Tests and mocks are skipped (`*.test.*`, `*.spec.*`, and `__mocks__/`, `__tests__/`, `test/` and `tests/` folders).
    It collects the API paths used through `@raycast/api` imports (`Clipboard.copy`, `Action.CopyToClipboard`) and the names imported from `@raycast/utils`.
    An export passed whole to `canAccess` (`environment.canAccess(AI)`, or `canAccess(BrowserExtension)` destructured) isn't a use, since that's how an extension asks whether it's there, and Fudge answers no (`isAccessCheck`, SPEC-121 §1); any other reference is, `AI.ask` and `const x = AI` included.
  - Each path is checked against `createApiModule()`.
    A stub anywhere on the path makes it `missing`, a lowercase member's included.
    So do the markers in `src/api/stubs.ts`: `UNAVAILABLE` is on the actions that render but fail when picked (`render-but-fail`), `NOT_DRAWN` is on the components the app can't draw yet, listed at the end of `components.ts` (`not-drawn`), and `LEFT_OUT` is on `OAuth`, which is there but counted apart,
    since it signs in only to the providers the sign-in server supports and the scan can't tell those from an extension's own; it and everything under it count as `missing`.
    Whoever teaches the app to draw one removes it from that list in the same PR.
    Anything under a record of the extension's own data (`plainRecords`, the deprecated `preferences`, read as `preferences.apiKey.value`) is `implemented`, since its members are the extension's own names.
  - A path Raycast's types don't declare (`Color.Gray`, a mock's `showToast.mockResolvedValue`) is `not-raycast`: listed, but not a gap.
    `raycastDeclarations` (`scripts/raycast-types.ts`) reads the vendored types for that.
  - `@raycast/utils` is bundled from each extension's own dependencies, so its calls are invisible.
    `scripts/compat/raycast-utils.generated.ts` maps each of its exports to the API paths it needs, and an extension using one inherits them (`via @raycast/utils`).
    `scripts/compat/raycast-utils.ts` generates it from the `src/` files in the source map of the pinned `@raycast/utils` devDependency, with the same path extraction.
    `npm run generate` rewrites it, and `npm run typecheck` fails while it's stale.
  - One extension's scan is `scanExtension` (`scripts/compat/extension.ts`), shared with **`fudge scan <folder> [--json]`**.
    The CLI runs `scripts/compat/fudge-scan.ts`, bundled by `npm run build` into `dist/compat-scan.js` and shipped in the app, with node (`CompatScanner`, core).
    The app has esbuild's binary but not its JS package, so the bundle marks `esbuild` external, `toJavaScript` takes the transform to use (esbuild's JS API is imported only when it's the default), and the CLI passes `FUDGE_ESBUILD` (the binary, `binaryTransform`) and `FUDGE_RAYCAST_TYPES`:
    the types beside the script, unless it's set already or there are none there, as with `FUDGE_COMPAT_SCAN=runtime/dist/compat-scan.js` in a checkout, which then reads the vendored ones.
    The JSON report (`report`) names the extension, says `supported` (no gaps and every file read), and lists each gap with its kind and, for one counted apart, its category (`byDesign`).
    It also has `commands`: each command of the manifest with the categories Fudge doesn't support that it reaches (`unsupported`), and whether every import it makes could be followed (`traced`).
    A command is traced from its entry (`src/<name>.{tsx,ts,jsx,js}`, as the build finds it) through every import esbuild leaves, re-exports, `import()` and `require` included (`imports`), resolved among the files the scan read, ignoring case as APFS does (`resolveImport`): relative paths, `@/…` and `~/…` as `src/…`, and TypeScript's `./x.js` for `x.ts`.
    A bare import is a package's only when the manifest lists that package in any of its dependency sections, it's one of Node's built-ins, or the host provides it (`packages`), and a data file (`.json`, `.css`, an image) can't reach the API.
    A command with an import that can't be followed (outside `src/`, an unreadable file, any other bare import, such as a tsconfig `paths` alias or a `baseUrl` import, or an `import()` or `require()` of a computed path, `hasComputedImport`) counts as reaching the whole extension.
    So does every command when a file that uses Raycast AI or the Browser Extension is reached by no entry, a command's or a tool's (`src/tools/<name>`), since something the scan can't see reaches it.
    A barrel's re-exports are followed whole, so a command can be counted for a module of the barrel it doesn't use; in the store that decides 3 of 224 commands.
    The text output (`describe`) lists what Fudge doesn't have yet, then each category apart, saying why (`byDesign`'s `says`: Raycast AI and the Raycast Browser Extension, "which Fudge doesn't support", from the runtime's `unsupported`; OAuth, "which needs a sign-in server").
    Under Raycast AI and the Browser Extension it says which commands use them ("in 2 of 9 commands: …", or "in every command").
    Before scanning it checks that the esbuild it was given runs (exit 1 with one line if not, rather than every file unreadable), and a folder without a `package.json` file and a `src` folder, or with either as a link, is refused with exit 2.
    `FudgeToolTests` runs the real `fudge` binary end to end.
  - The Markdown report counts extensions with no gaps, those lacking only APIs counted apart (AI and the Browser Extension, which Fudge doesn't support, and OAuth, which signs in through a sign-in server, only to the providers it supports: D-63), and the rest.
    It ranks gaps by API and kind.
    `--json <file>` also writes each extension's gaps with their kind.
- **`runtime/vendor/raycast-api/index.d.ts` is Raycast's own type definitions** (MIT, notice alongside).
  It's the contract Fudge implements.
  `make raycast-types` copies it unmodified from the `@raycast/api` release named by `RAYCAST_API_VERSION`.
  Never edit it by hand.

## Gotchas

- **Names must differ by more than case.** macOS file systems are case-insensitive, so no two products or targets may differ only by case.
  The tool's product is `fudge`, which is why the app's product is `FudgeApp`.
- **Scripts that also run as a command guard it by their own file name** (`import.meta.url.endsWith(".ts")`), as `raycast-types.ts` and `raycast-utils.ts` do.
  Bundled into another script, `import.meta.url` and `process.argv[1]` are both the bundle's, so a guard on those alone would run the generator from inside `compat-scan.js`.
- **Proxies must return frozen properties untouched.**
  `createApiModule` wraps components to name missing members, but it leaves frozen constants (`Keyboard`, enums) unwrapped, or JavaScript throws.
- **Runtime TypeScript must be erasable syntax only** (`erasableSyntaxOnly`), because tests run it through type stripping.
  That rules out enums, namespaces, parameter properties and JSX in `.ts` files.
  Relative imports carry the `.ts` extension.
- **Compiled extension commands are CommonJS.**
  The worker loads them with `require`, which is the only way `Module._load` can hand them Fudge's modules.
- **actool's paths must be absolute.**
  `xcrun actool` hands the work to a shared daemon, which resolves relative paths against its own working directory.
  That's whichever checkout started it, so with several worktrees, relative paths make one worktree's `make app` write the icon into another's `build/`. actool can also exit 0 when it compiled nothing, and it reports errors on stdout, so `make app` checks for `Assets.car` and then shows `build/actool.log`.
- **Fudge runs only its own Node.js** (SPEC-115, D-74), never one the user has installed, so no setting, variable, Homebrew or `PATH` changes it.
  The app and the `fudge` tool find it beside themselves (`Runtime.locateNode`: `Contents/Helpers/node`, the tool's folder with links resolved), and a missing or broken one says to reinstall Fudge (`Runtime.nodeMissing`).
  The tests get it from `FUDGE_TEST_NODE`, which `make test` sets and only the test target reads; the tool's tests run a copy of `fudge` with a Node.js beside it, as in the bundle.
- **A test never holds up the main actor or Swift's shared pool waiting for another program, a pipe or a semaphore** (FUD-153).
  CI's runners have three cores, so the pool has about three threads, and Swift Testing itself needs the pool to start and report tests: with it full, nothing runs, fails or prints until a thread frees.
  A child process, a pipe read, a build or a long semaphore wait runs on a thread of its own (`OffThePool.run`, in the tests), never in `Task.detached`, which takes a pool thread.
  A deadline fires from Dispatch (`OffThePool.after`, or `run(within:)`), not from a `Task.sleep`, and a wait for an event ends as it comes (`Reloads` in `ExtensionsWatcherTests`).
  A pool that's full for good can still stop the run, so CI's 20-minute step timeout is the last net.
- **SwiftUI's `TextField` writes its unchanged text back** now and then, three times on ↵ before `onSubmit` and again when it loses the keyboard.
  Setters bound to a field must ignore writes that change nothing, or they'll redo work such as resetting the selection.
- **`.onAppear` runs once for the panel's lifetime**, not each time it's shown.
  Showing the panel (`LauncherModel.presented()`) and clicking a row ask for the keyboard back explicitly (`keyboardRequests`).
  `KeyboardFocus` (core) names the field each screen wants, and the views move it there through `nil`, because setting a `@FocusState` to the value it already holds does nothing, even when AppKit's first responder has moved.
- **Check the panel's layout without showing it:** `build/Fudge.app/Contents/MacOS/Fudge --snapshot out.png [--query text] [--activate]`.
  It renders the panel off-screen and transparent, then saves a PNG and quits.
  `--settings` renders the Settings window the same way, and `SettingsNSWindow` and `OnboardingNSWindow` keep a snapshot run's window off every screen (`constrainFrameRect`, as `LauncherPanel.allowsOffscreen` does), since AppKit otherwise moves a titled window back onto one when it's ordered front.
  Nothing in a snapshot run is begun as a sheet: a sheet is a window of its own, opaque, and would show wherever its parent is.
  A `confirmAlert` the run reaches (an install's confirmation through `--run-action Install`, say) is laid out instead, as the consent sheets are (`SnapshotSheet.laidOut`), saved in place of the panel, and answered Cancel.
  A snapshot run never activates (activation policy `.prohibited`, set in `main.swift` before launch), its windows refuse key status (`LauncherPanel.refusesKey`, `SettingsNSWindow`), and it installs no status item (Fudge's or a menu-bar command's), global hotkey or key monitor, so it can't take anyone's typing or put a second icon in the menu bar.
  Just before saving, it prints `snapshot-state active=… appActive=… key=… canBecomeKey=…` to stderr; all four are false.
  The menu bar item's menu can't be snapshotted, since a snapshot run installs no status item.
  The window blur doesn't render in snapshots.
  Run snapshots one at a time: several at once can miss their timing.
  `make run` opens the app with `open -n`, because LaunchServices would otherwise hand the open to a live snapshot run (same bundle id) and fail with -600; just before, it checks again that none of the user's own Fudge is running.
  The flags, one per line:
  - In the command `--activate` opened:
    - `--actions` opens the action panel.
    - `--dropdown value` picks a search bar dropdown value.
    - `--open-dropdown` opens the dropdown's panel (in a Form, its first Dropdown's; `--open-tags`, its first TagPicker's; `--open-date`, its first DatePicker's calendar).
    - `--pick-date <title>` opens the picker of the `Action.PickDate` with that title (from the list with `--actions`, else straight).
    - `--run-action <title>`, given once or more, runs those actions in order, half a second apart (e.g. an extension's Create Quicklink, then Save Quicklink).
    - `--search text` types into its search field.
  - `--accessibility allowed|missing`, `--input-monitoring allowed|missing` and `--login-item <status>` fix what Accessibility, the Snippets page's Input Monitoring and Open at Login show, so nothing asks the system.
  - `--calendar-events <file>` gives My Schedule made-up events (`FixedCalendarSource.load`), and without it nothing has been asked.
  - `--clipboard-consent` saves Clipboard History's consent sheet, laid out off-screen like the sign-in one; it implies `--settings` and that page, as `--sign-in-consent` does.
  - `--clipboard-entries <file>` gives Clipboard History made-up entries (a JSON array of `clipboardHistory.list` entries); snapshots never read the clipboard or watch it.
  - `--definitions <file>` gives Define Word made-up definitions; snapshots never read the selection or the Mac's dictionaries.
  - `--found-files <file>` gives Search Files fixed results (a JSON array of `files.search` entries, `~/` paths in the home folder), and without it there are none; snapshots never ask Spotlight.
  - `--menu-items <file>` gives Search Menu Items a made-up app and menus (`FixedMenuFile`: `{ "app", "path"?, "menus": [{ "title", "key"?, "modifiers"?, "glyph"?, "enabled"?, "items"? }] }`, the app's own menu first), and without it there's no app to search; snapshots never read another app's menus.
  - `--onboarding [<step>]` renders the onboarding window.
  - `--settings` renders the Settings window instead, and `--settings <page>` one of these pages:
    - `:calendar`
    - `:color-picker`
    - `:commands --search text`, the Commands page searched for that text
    - `:permissions`
    - `:quicklinks`
    - `:snippets`
    - `:window-management`
  - `--update-available <version>` shows that version as found by an update check (General's line and Download…); no snapshot run asks GitHub.
  - `--windows <file>` gives Switch Windows made-up windows (`FixedWindowSystem`: a JSON array of `{ app, path?, title?, screen?, minimized?, answers? }`, front to back), and without it Switch Windows shows that it needs Accessibility; snapshots never read the window list or the Accessibility API.
    Made-up pids never take the run's own, and the windows step ten times down their screen, then start again at its corner.
- **Permission grants need a signing identity.** macOS ties Accessibility and Automation grants to the app's designated requirement.
  An ad hoc signature's is its cdhash, which changes with every build, so each ad hoc `make run` drops them; builds signed with an identity keep them.
  **The first signing with an identity shows a keychain prompt** that only a person can answer (Always Allow).
  Until someone has, `make app` waits on it, so build with `SIGN_IDENTITY=-` where nobody has.
  CI has no identity and stays ad hoc; a release is signed again with the Developer ID identity (see CI and releases).
  No certificate, key, name or team ID ever goes into the repo.
- **The hardened runtime refuses a protected resource without its entitlement**, with no prompt, whatever the user allowed.
  `App/Fudge.entitlements` has the two Fudge uses, each with a comment: Apple Events (Finder, System Events and the login window) and Calendars (My Schedule's EventKit).
  A feature that starts using the camera, the microphone, location, contacts, photos, calendars or Apple Events adds its entitlement there in the same change.
  Accessibility, Input Monitoring, Screen Recording and Full Disk Access are permissions the user grants, with no entitlement.
- **The local-network check reads the URL, not DNS.**
  A public name that resolves to a private address isn't caught. https mostly covers it, since a LAN device rarely has a certificate for a public name.
- **AppKit draws nothing inside an SVG `<a>` element**, so `RemoteImageDecoder.svgForDrawing` unwraps links before `NSImage(data:)` sees the SVG.
- **Tests must not touch the user's system.**
  Never trash, open, copy, read the selection, post key events or send Apple Events for real in a test, and smoke-run extensions with a throwaway `HOME`: commands do what they say.
- **Swift tests that build extensions need esbuild** from `runtime/node_modules`.
  `make test` installs it; without it, `swift test` skips those tests.
- **npm may block install scripts.** esbuild works without its postinstall step, so don't approve it just to silence the warning.

## Commands

`make app` · `make dmg` · `make dmg-image` · `make release` · `make run` · `make install-extension DIR=<folder>` · `make test` · `make lint` · `make fmt` · `make raycast-types` · `make compat-scan DIR=<folder>`

## Conventions

- Swift for the app and the tool.
  TypeScript only in `runtime/`, because extensions are JavaScript.
- Docs describe what exists.
  No roadmaps, status tables or TODO lists in committed files.
- Every setting has a control in the Settings window.
  `settings.json` and the other support files are never the documented way to change one.
- An on/off setting shown as a row in the Settings window is a switch on the right, with its label (and any explanation) on the left, as in System Settings.
  A column of on/off cells in a table, like the Commands page's Enabled, uses checkboxes, as do extensions' own Forms.
- Conventional commits (`feat:`, `fix:`, `chore:`, `docs:`), scoped by area where it helps, e.g. `feat(runtime): ...`, `feat(app): ...`, `feat(cli): ...`.
- `AGPL-3.0-or-later` everywhere.
  Files taken from MIT-licensed upstream keep their notice next to them.
  New dependencies must be AGPL-compatible.
- Third-party GitHub Actions are pinned to commit SHAs, with the version in a trailing comment.
- **A probe or hand check that launches a second Fudge** which creates status items, windows or preferences runs from a copy of the bundle with a **different bundle id**, e.g. `plutil -replace CFBundleIdentifier -string io.github.jakeobsen.fudge.probe <copy>/Contents/Info.plist`.
  Builds with the same bundle id share the real app's preferences, whatever `HOME` or `FUDGE_SUPPORT_DIR` says, and that's how a probe once hid the user's menu bar icon.
  `--snapshot` runs are exempt: they create no status item, take no keyboard and write no preferences.
- **Help text, in the app and the README, is brief and says what a feature does, for an end user.**
- **Every feature that's off by default has an onboarding step** asking whether to turn it on, using the feature's own Settings control and consent, with ↵ leaving it off and nothing preselected.
  `OnboardingStep.optIns` maps each such `FudgeSettings` property to its step, and a test fails for a property that's neither there nor listed as not an opt-in.
- **Docs are one sentence per line.**
  In `CLAUDE.md` and `README.md`, start each sentence on a new line, and add an item to a list as its own line, so two changes rarely touch the same line.
  `make lint` fails on a line over 400 characters outside code blocks and tables.
- **The product's name is Fudge**, capitalized, in all text people read.
  `fudge` is only the CLI command, paths, env variables and identifiers.

## CI and releases

- **CI** (`.github/workflows/ci.yml`) runs `make lint` and `make test` on pull requests and pushes to `mainline`.
  The test step, here and in the release workflow, stops after 20 minutes (`timeout-minutes`), so a hang fails the job instead of holding a runner.
  `swift test` compiles every target, so the app's code is checked, but the app bundle is not assembled.
- **The release workflow** (`.github/workflows/release.yml`) is the only place a release is built, and it runs on a pushed `v*` tag.
  Tags are pushed only with the maintainer's explicit permission, never by an agent.
  Two jobs:
  - **`build`**, with a read-only token: the tag must be `v` and a semantic version (checked through an env var, never `${{ }}` in a script), then `make test`, `scripts/release.sh --tag <tag> --ad-hoc-without-secrets` and a `.sha256`, uploaded as an artifact.
    `--tag` hands the tag to `make app` and `make dmg-image` as `RELEASE_TAG`, never as `VERSION`, so `make release-check` refuses a tag that isn't on the commit.
  - **`publish`** runs only for a pushed tag, and has the only write token, and runs none of the repo's code: it checks the tag again, downloads the artifact and runs `gh release create` with GitHub's generated notes and one line on opening the app, which depends on how `build` signed it (its `signing` output).
    A tag with a pre-release suffix (`v1.2.0-rc.1`) is a pre-release.
  - **Run by hand** (Actions → Release → Run workflow, `workflow_dispatch`), it's the dry run: no tag check, the version `git describe` gives the commit, signed, notarized and stapled, and the disk image as an artifact.
    Nothing is published.
  - **The secrets are the `release` environment's**, not the repository's: only `mainline` and `v*` tags may use that environment, and only `build` names it, so no workflow on another branch can read them, one an unreviewed branch adds included.
    Never add them as repository secrets again.
- **Release signing** (`scripts/release.sh`, FUD-44) reads five secrets, which the workflow gives to that one step only:
  - `APPLE_CERTIFICATE_BASE64`: the Developer ID Application certificate with its private key, a `.p12` in base64
  - `APPLE_CERTIFICATE_PASSWORD`: the `.p12`'s password
  - `APPLE_ID` and `APPLE_APP_SPECIFIC_PASSWORD`: the Apple Account that notarizes, and an app-specific password of it
  - `APPLE_TEAM_ID`: the identity's team

  It builds the app ad hoc first (`make app`), with none of them in its environment, so no code the build runs can reach them.
  Then it imports the certificate into a keychain of its own in a temporary folder, its key usable by codesign alone and not exportable, deleted however the script ends.
  It signs again with the Developer ID identity (`scripts/sign-app.sh`), notarizes the app with `notarytool` and staples it, makes the disk image from it (`make dmg-image`), signs, notarizes and staples that, and checks both with `spctl`.
  It never prints a secret or the identity's name: the tools' output shows only when one fails, with those values as `***`.
  Without any of the five, a tag still makes a release, ad hoc, and its notes say so (a fork has none); the dry run fails instead, as does any run with only some of them.
- **`make release`** does the same on the maintainer's Mac, for a release built without CI, after `secret env apple`, which sets the same five variables.
  It refuses a tree with changes, never pushes or tags, and writes no secret to disk but the temporary keychain.
  `make release RELEASE_TAG=<tag>` builds that tag's release (`--tag`), and without it the version is `git describe`'s (`--version`).
- **Dev builds** still sign with the Apple Development identity (or "fudge local signing", or ad hoc; see `make app`), so only a release has the Developer ID, and switching between the two asks for permissions again.
- **`make dmg`** builds the app, then `build/Fudge-<version>.dmg` (the version without its `v`) with `make dmg-image`, which packs the app as it is: the app and a link to `/Applications`, UDZO, volume name Fudge, made with `hdiutil` from a staging folder that's removed afterwards.
- **Linting the workflows:** actionlint isn't in CI; run it by hand after changing one: `go run github.com/rhysd/actionlint/cmd/actionlint@v1.7.12 .github/workflows/*.yml`.
