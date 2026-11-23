# CLAUDE.md

Guidance for AI coding agents working in this repository.
User-facing docs are in README.md.

## What this is

Fudge is a keyboard launcher for macOS, built to run extensions written for Raycast's `@raycast/api` without changing them.
It is a native Swift app.
Extensions run in a separate Node.js process, the extension host.

## Architecture

- **One Swift package, five targets.**
  - `FudgeApp` is the app: an accessory app with a menu bar item and no Dock icon.
    The item's glyph is `MenuBarIcon`, a fudge cube drawn in code as a template image.
    Its autosave name is `fudge` (`AppDelegate.statusItemName`), because macOS keeps whether a status item is shown in the app's preferences under that name, and an unnamed item's `Item-0` was once saved as hidden.
    It's shown at every launch, and its `behavior` is `[]`, so ⌘-dragging can't remove it.
    Its menu ends with the running version (`FudgeVersion.current`, Fudge's form of the `Info.plist`'s `FudgeGitDescribe`), About Fudge and Quit Fudge, and has Check for Updates… and, at the top while a newer release is known, `Fudge <version> Is Available…` (see the update check).
    **About Fudge** (SPEC-113 §3) brings Fudge forward, then opens the standard About panel with the version shown, the build number (`CFBundleVersion`), `NSHumanReadableCopyright` (`AboutFudge.copyright`) and `AboutFudge.credits` (core): the license notice and links to the source (at the tag for a release build), `LICENSE.txt` and `Third-Party Notices.txt` in the app.
    The GPL family calls these the Appropriate Legal Notices (v3 §0, §5(d)), so they stay in the panel.
    Esc, ⌘W and ⌘Q close it (`AboutFudge.closesPanel`), since an accessory app has no File menu; snapshot runs have no menu, so they never open it.
    - **Global hotkeys** go through Carbon (`CarbonHotKeys` in `HotKey.swift`), which needs no Accessibility permission: one event handler, one id per registration.
      `HotKeyRegistry` (core) decides what's registered: the launcher's hotkey (`hotkey` in `settings.json`, default ⌥Space, read and written through `FudgeSettings.launcherHotkey`) and each installed command's (`commands` in `settings.json`, by `<id>/<command>`), registering only what changed.
      A refused change of the launcher's hotkey registers the old one again (`setLauncher`); one refused at launch stays wanted, marked `launcherRefused`, and is tried again on every `resume`.
      A change that's registered but can't be saved puts back exactly what was there, the old hotkey registered or still refused (`changeLauncher`), so the registration and the file never disagree.
      `AppDelegate.launcherHotkeyChanged` shows the outcome on the General page and in the menu bar item's "Open Fudge (…)" title.
      Hotkeys of commands that aren't installed stay in the file but aren't registered.
      `HotKeySpec` (core) is the text form (`option+s`, `f5`, `keycode:<n>` for keys with no name), and an F-key may stand alone.
      `FudgeSettings` reads `settings.json` tolerantly, and writes it atomically, keeping keys it doesn't know.
      A pressed command hotkey calls `LauncherModel.openFromHotkey`, which follows `HotKeyLaunch` (core): open it as root search would, hide the panel when it's the view command on screen, or show root search with the fields when a required argument is empty.
      While the launcher holds the keyboard (`LauncherPanel.holdsKeyboard`), a command hotkey whose keys an action there takes runs that action as the key would, and doesn't open its command (`LauncherModel.pressHotkey`, `LauncherKeys.hotkeyPress`, SPEC-127).
      Its key is named as a key press is, through the current keyboard layout (`KeyShortcut(hotkey:layout:)`, with `KeyLayout.character(for:)`), so the two match on any layout.
      Fudge's own keys (⌘K, and ⌘, and ⌘⇧, unless an action has them) aren't actions', so a hotkey on one of them opens its command; outside the launcher every command hotkey does.
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
      **The Window Management page** (`WindowManagementPage.swift`, under Extensions) lists the positions (+, Edit…, −; the sheet takes x, y, width and height in percent, checked by `PositionDraft.problems`, with a drawing) and the layouts (Rename…, −).
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
      A Caps Lock → Caps Lock entry, which some tools write, isn't a mapping, but Fudge's entry takes the first one's place rather than adding a second one for Caps Lock, and any others go too (`HyperkeyMapping.capsLockItself`, SPEC-118 §1, SPEC-126 §4).
      Removing Fudge's entry puts as many back where it was, since they're alike, the launch cleanup after a crash included, because `HidutilKeyMapping` remembers how many in `hyperkey.json` in the support folder (`{"replacedCapsLock": <count>}`, written before the mapping, never in a backup; an older file's `true` counts as one).
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
      **The Color Picker page** (`ColorPickerPage.swift`, under Extensions) has Copy Format, a `SettingsPopupRow`; changing it draws Recent Colors again if it's open.
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
      **Settings → Calendar** (`CalendarPage.swift`, under Extensions) has Days Ahead and a checkbox per calendar.
    - **Settings → Development** (`DevelopmentPage.swift`, after Sign-in, SPEC-145 §1) has one row: **Command Line Tools**, the folder Fudge builds extensions' parts written in Swift with, and its status line.
      `CommandLineTools.resolve` (core) is the one place that finds them, for the page, the Extension Store and `fudge build`, so they never disagree: the folder chosen with Choose… (`commandLineTools` in `settings.json`, an absolute path; Use Default clears it), else `/Library/Developer/CommandLineTools`, the only one found by itself (D-117: "only Apple's Command Line Tools").
      A chosen folder's Swift is its `usr/bin/swift`, else `Toolchains/XcodeDefault.xctoolchain/usr/bin/swift`, so choosing Xcode's `Contents/Developer` works too.
      A Swift that is, or leads to, one of macOS's stubs in `/usr/bin` (a chosen `/`) is never run, and counts as not found, since the stub offers to install the tools; nothing runs `xcrun` either.
      The status line runs the folder's Swift with `--version` and shows `Swift 6.3.3`, the version after `Apple Swift version` (the first number on that line is the driver's), or `Not found`; older than 6.0 shows `Swift 6.0 or later is needed` and counts as not found.
      Install…, shown while nothing is found, runs `xcode-select --install`, Apple's own download prompt, and the page reads the status again every few seconds until something is found.
      The setting is this Mac's: an import keeps it (`Backup.consentKeys`).
      Snapshot runs take `--command-line-tools found|old|missing` (`CommandLineTools.fixedStatus`) and never ask the Mac.
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
      **Places** (SPEC-162): `TimeZoneConversion.place` looks a name up in this order: the abbreviations, offsets from UTC, the IANA zones' cities, `otherCities`, then from the `PlaceTable`, the countries, the towns' own and ASCII names, and the towns' alternate names.
      So `jamaica` is the zone's city before the town in New York, and `armenia` is the country before the town in Colombia.
      **Offsets** are `utc` or `gmt`, a sign (`+`, `-` or `−`) and `h`, `hh`, `h:mm`, `hh:mm` or `hhmm`, up to 14 hours, shown normalized (`gmt+0530` is `GMT+5:30`, `utc-0` is `UTC+0`) and with no abbreviation after them.
      They're `TimeZone(secondsFromGMT:)`, never `Etc/GMT-2`, whose sign is the other way round.
      A split at `to` or `in` still needs a clock time or the word `time`, so `copenhagen to new york` stays a search, unless both sides are abbreviations or offsets (`gmt+2 to utc`, `cet to pst`).
      `<place> time` alone (`denmark time`, `utc time`) is the time there now, but never in a town, since `sunrise time` and `tea time` would each find one.
      **A unit or currency word is never a country or a town** (`UnitConversion.knows`, `CurrencyConversion.knows`): time zones are tried first, so a town named like a unit would take `5 kgs to lbs` away; a test pairs every two spellings of each dimension, and every two currencies.
      **State and province names** of the US, Canada and Australia (`TimeZoneConversion.states`) never answer from the table either: `arizona` would be Arizona, Honduras, and `georgia` the country, so they give no card unless an earlier table knows them (`new york`, `washington`).
      **`PlaceTable`** (core) holds GeoNames' towns of 15,000 people or more and its country names, from `runtime/vendor/geonames/places.tsv` and `countries.tsv`, which `make app` copies into `Contents/Resources/places/`.
      `LauncherModel.loadPlaces` reads them once at launch, off the main actor (about 0.2 s and 20 MB); until then, and in `swift run`, the calculator knows only its own tables, and their arrival evaluates the card again, keeping the selection.
      Names are folded (`PlaceTable.fold`: no case, no diacritics), and a town's ASCII name is a name too, since `ø` isn't a diacritic (`hillerod`).
      A town is shown by its own name; of towns sharing a name, the bigger one has it, and a town's own name always beats another town's alternate name.
      Rows with a missing column, a population that isn't a number or a zone Foundation doesn't know are skipped.
      **Countries** are worked out at load, never by the generator: two zones share a clock when their offset at the start of the year and their summer time changes that year are the same, and a country answers when one clock covers at least 90% of its towns' people, with that clock's most populous zone (`canada` and `united states` don't).
      **The files** come from `scripts/geonames/make-places.py` (Python's standard library only, no Unicode tables, so the same download gives the same bytes anywhere), which `scripts/geonames/update.sh` runs on GeoNames' download.
      Their folder's `SOURCE` lists each downloaded file's address, sha256 and dates, and its `LICENSE` is GeoNames' licence, credited in the README and the notices.
      **The "Update GeoNames database" workflow** (`.github/workflows/update-geonames.yml`, on Linux) downloads them again and opens a pull request into `development` (`scripts/geonames/open-pull-request.sh`); only the repository's owner can start it, and no agent ever runs, dispatches or re-runs it.
      Builds never go online for the list.
      The card is selected first, and ↵ copies the answer (`RootActions.calculatorSections`, plus Copy Question and Answer ⌘⇧C) and closes the panel with a HUD.
      `now` and the time zone are parameters, so tests fix them.
    - **Currency rates** come from the European Central Bank, and only while `currencyRates` is on in `settings.json` (off by default; the Calculator page's switch).
      `ExchangeRateUpdater` (core) loads `exchange-rates.json` and downloads when `ExchangeRatePolicy` says so: on turning it on, when the rates are a day old, at most once per 12 hours, one download at a time, keeping the old rates when one fails. ↵ on the "Couldn't download exchange rates" card retries at once.
      `ExchangeRates` parses the ECB's XML and says how fresh the rates are, under the card's arrow.
      The app's `ECBRatesFetcher` uses an ephemeral `URLSession` (no cookies, credentials or cache; 15 s; 1 MB), and `ExchangeRateSchedule` checks every hour.
      With the setting off, a currency query still gets a card ("Currency conversion is off"), and its ↵, like its Turn On Currency Conversion, opens Settings on the Calculator page (`RootActions.currencySettingsPage`).
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
    - **Detail and Form** have no search field: their navigation title takes its place, and `handleKey` takes ↵ and Esc, and Tab and ⇧Tab in a Form.
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
      A field with `storeValue` (never a PasswordField) starts on the value saved when its form was last submitted (`FormValueStore`: `form-values/<extension id>.json`, by command and field `id`), ahead of `defaultValue`.
      A Dropdown's or TagPicker's stored value waits for the field's items when they arrive after the first render, unless the field is changed first (`FormContent.Field.start`).
      When a field starts on something the extension's Form didn't register, such as a stored value or a dropdown's first item, the app reports it with `onChange`.
      `onFocus` and `onBlur` fire with Raycast's `FormEvent` when the keyboard moves from one field to another.
      **A Form's first field gets the keyboard** (FUD-185): `FormScreen.onAppear` asks for it through `refocus` (nil, then the field a turn later), never by setting `focused` at once, since the launcher swaps its search field for the form's title in the same update and the search field going away leaves the panel itself as first responder.
      The field is the first editable one with `autoFocus`, else the first editable one, and none while an overlay holds the keyboard (`KeyboardFocus.formFieldOnAppear`); that covers a form as the first view, pushed from the action panel and pushed by a shortcut.
      **Tab and ⇧Tab** move between a Form's fields whichever field has the keyboard, a text area and the bare panel included, because AppKit's key view loop doesn't reach the fields in the launcher's panel (the hosting view sits in an `NSVisualEffectView`).
      `LauncherKeys.outcome` answers `.moveInForm` for them in a Form, after an open overlay, which keeps its own Tab, and before any action's shortcut, as Raycast's manual says Tab moves (`LauncherKeys.formTab`); ⌥Tab isn't taken, so a text area types a tab.
      The place to go is `KeyboardFocus.formFieldAfterTab`'s, from where the keyboard is now: the next or previous editable field, wrapping at both ends; the first (or, backwards, the last) from nowhere; and nothing in a form with no editable field, which still takes the key.
      A `DateTime` field with a date counts its time box as a stop after its date (`FormContent.tabFields`, `FormContent.Field.showsTimeBox`).
      `LauncherModel.formMove` hands it to `FormScreen`, which gives it the keyboard through `refocus`, and an open calendar closes on Tab first, as on any key.
      `FormScreen` also scrolls that field into view (`ScrollViewReader`), since giving it the keyboard there doesn't scroll as AppKit's key view loop does.
      **Where the keyboard is now** is `FormKeyboard` (core), which `CommandScreen` holds and `FormScreen` reports every move to, nowhere included (`formKeyboardMoved`).
      Its `now` goes to nil when the keyboard leaves every field (a click on the form's background), so Tab starts from the first field again, while its last place ignores nil, so `onBlur` and the panel's showing (`KeyboardFocus.Target.formTimeBox` for a time box) still go by it.
      A time box counts as its field for `onBlur` and `onFocus`.
      The places Tab asked for that the keyboard hasn't reached yet are kept in order, and Tab goes on from the last of them, so several Tabs at once each move one place, even when an earlier one lands late.
      A `Form.Checkbox` is `.focusable(true, interactions: .edit)`, as the pickers are, since with macOS's Keyboard navigation off (the default) asking for a plain `Toggle` gives the keyboard to the first text field instead; Space toggles it.
    - **Actions.**
      `ActionPanelReader` (core) turns an `ActionPanel` node into sections of `ActionEntry`. ↵ runs the first entry and ⌘↵ the second; in a Form, where ↵ belongs to the fields, ⌘↵ and ⌘⇧↵. ⌘K opens the action panel overlay, with search, sections and submenus (opening one calls its `onOpen`).
      Its rows show those keys on the first and second entries, counted across sections, in place of their own shortcuts, which still run them, as Raycast does (`ActionPanelReader.shownKey`, FUD-186); every other entry, and every entry in a submenu or in root search, shows its own.
      Entries are matched against the whole panel, so a search in the panel keeps each key on its action.
      An `Action.PickDate` (an `Action` with a `pickDate` prop and an `onChange`, `ActionEntry.pickDate`) opens a picker there in place of the list, as a submenu does; run with ↵, ⌘↵ or its shortcut, the overlay opens straight to it.
      `DatePick` (core) holds it: Form.DatePicker's calendar (`DateCalendar`, drawn by the shared `MonthView`) and a `DateTime`'s time, which Tab moves to. ↵, Space or a click on a day picks and calls `onChange` once with `FormDates`' value, ⌫ calls it with null, and Esc goes back to the list it came from, or closes the overlay, calling nothing.
      Closing the overlay any other way calls nothing either.
      The picker's keys come through `handleKey` with no field holding the keyboard (a Form's field lets go of it while the picker is open, and takes it back when the overlay closes), so typing filters nothing; a render keeps it open with the action's new title and limits (`DatePick.following`), or closes it when the action is gone.
      No Form field takes the keyboard while an overlay holds it, the action panel (picker or not) or a dropdown's panel, even when the fields change or the panel is shown again; the overlay's closing gives it to the last field, or the first if that's gone (`KeyboardFocus.formFieldAfterFieldsChange`, `formFieldAfterOverlay`).
      In root search the same overlay shows Fudge's own actions for the selected item, from `RootActions` (core): Open (↵) on everything, Configure Extension (⌘⇧,) on a command, Show in Finder (⌘⇧F) on an application.
      Their shortcuts work without opening the panel.
      An entry's `target` says what it runs: an extension's `Action` node (`onAction` in the running command), a `RootAction`, or `toggleQuickLook`, which the app performs itself (an `Action` with `fudgeBuiltIn: "toggleQuickLook"`, `ActionPanelReader.builtInProp`).
      An `NSEvent` local monitor in `AppDelegate` turns key presses into `KeyShortcut`s for `LauncherModel.handleKey` (⌘K, ⌘↵, actions' shortcuts) before the search field sees them.
      Which action a key runs is `LauncherKeys.outcome` (core), which a command hotkey asks too.
      With the action panel open, a key with a modifier runs the view's action with that shortcut, submenus included, as with the panel shut (SPEC-127 §0); plain keys go to "Search for actions…", and with a picker or a dropdown's panel open no action runs.
      So an action on ⌘A, ⌘C, ⌘V, ⌘X or ⌘Z wins over editing in the focused field, as it does with the panel shut.
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
    - **The log files** (SPEC-124) are in `~/Library/Logs/Fudge/` (`FudgePaths.logsDirectory`), or `$FUDGE_SUPPORT_DIR/Logs/` when that's set, so tests and snapshot runs never write the user's logs.
      `Fudge.log` is Fudge's own, and `Extensions/<id>.log` each extension's, bundled ones included, by its id (`LogFile.extension`, checked with the id rule), which is the manifest `name` for Raycast's and the bundled ones.
      Folders and files are made with the first line written to them.
      A line is a local ISO 8601 time with milliseconds and its offset, the level, `[<command>]` on an extension's line, and the message, its further lines indented under the first (`LogLine`).
      Each file's first line in a run is Fudge's version and commit.
      **What goes in `Fudge.log`:** every `fudge: couldn't …` line, through `FudgeLog`, which also writes it to stderr as before, so `make run` from a terminal still shows them.
      Also the extension host's own stderr, a refused protocol message, a launch that failed, and the host stopping, naming the commands it ended.
      A command that fails gets one line of Fudge's own, `<id>/<command> failed` and where its error is (`FudgeLog.commandError`), never the error's text or stack, which go to the extension's file and stderr.
      Also installs, updates and removals as the app sees them when it reads the extensions folder (`InstallStamp`), so the store's and `fudge build`'s alike.
      Also the Extension Store's failed downloads, installs, updates and uninstalls with the build's output (`logToFudge` in `fudge:app`, the `fudge.log` call, answered only for the store), sign-in errors, and failed update checks.
      **What goes in an extension's file:** its `console` (`console.error` an error, `console.warn` a warning, `console.log` and `console.info` info, `console.debug` debug), and what it writes to stdout (info) or stderr (error) itself.
      Also uncaught exceptions and unhandled rejections with their stack, and a command that crashed or was stopped for not finishing after it was closed.
      Also failure toasts with their title and message, including an animated toast that becomes one, logged once with the title and message it ends up with.
      An extension's lines go only to its own file and stderr, never `Fudge.log`.
      Menu bar commands' lines in `Fudge.log` name an item by its position, never its title, which can be the extension's data.
      **Log level** (`logLevel` in `settings.json`, General's Logs section): Errors (the default), Warnings, Info or Debug; each records its own lines and every level above.
      Lines below it are dropped where they're made: in the worker before they're formatted (`src/log.ts`), in the host for a command's raw output, and in `FudgeLog`; errors and warnings of Fudge's own still go to stderr.
      A change goes to the host as a `logLevel` message, which passes it to every running worker, and the host gets it at each start before any launch.
      **Nothing slows the launcher:** the host stamps each `log` line with the extension's and command's names from the launch, and `ExtensionHost` hands it to `FudgeLog.command` on the thread that reads the host, never through the main actor.
      The host lets a command send 1,000 lines a second, then drops and counts them and sends one `… N lines dropped` line when the second is up, as severe as the worst line it stands for.
      Its own lines about a command (the worker failed, it crashed, it was stopped) go outside that bound, after the count, so a flood just before can't hide them (`hostLine`).
      `LogWriter` writes on a queue of its own, in order, with a buffer of 2,000 lines per file: a full buffer drops and counts in the same way, and other files are unaffected.
      Past 5 MB (`Fudge.log`) or 1 MB (an extension's), a file becomes `<name>.old.log`, replacing the last one; nothing else is kept.
      A failed write goes to stderr only, and the next line tries again.
      Uninstalling an extension leaves its log, and a reinstall appends to it.
      Only the app writes these files; the `fudge` tool writes to its own stderr.
      **Never logged:** what the user types, clipboard and snippet contents, preference values, tokens, OAuth codes, secrets, URLs with their query and response bodies; a sign-in error names the call, the extension and the refusal, or only the error's domain and code.
      An extension's own output is written as it wrote it, which is why the default is Errors.
      Show Logs opens the folder in Finder (`NSWorkspace`), making it first.
    - **The General page** (`GeneralPage.swift`) is the Settings window's first page, and the one ⌘, Settings… and "Fudge Settings" open on:
      Open at Login, the launcher's hotkey, Show Fudge on, Pop to Root Search, Escape Key Behavior (all three `SettingsPopupRow`s), Keyboard (Hyperkey and its Quick press switch, which is disabled while Hyperkey is off), Updates (Check for Updates, another `SettingsPopupRow` with Daily, Weekly, Monthly and Never, then `UpdateStatusRow`:
      While the update check is unset, that popup shows Not Chosen first (`UpdateCheckSetting.popupOptions`): it checks nothing, as Never does, and can't be picked again once something is chosen.
      the last check's result and time, Check Now, and Download… while a newer release is known; saved through `change {}`), Clear Search History…, Logs, and Import / Export.
      The launcher's hotkey is recorded like a command's, through the same `HotkeyRecordingPrompt`, but it can't be cleared: ⌫ and the Reset button set ⌥Space (`HotKeyRecording.launcherEdit`).
      A command's hotkey wins, so a launcher hotkey that equals one is refused, naming the command.
      It's registered before it's saved, and a refusal or a failed save leaves both the registration and the file as they were (`HotKeyRegistry.changeLauncher`); a failed save shows the `settingsProblem` banner.
      **Open at Login** goes through the `LoginItem` protocol (core): `SMAppServiceLoginItem` (`SMAppService.mainApp`) in the app, and a `FixedLoginItem` in snapshot runs, so they never register anything (`--login-item <status>` sets its status).
      The switch shows the system's real status (`LoginItemState`, core), read whenever the page appears or the window becomes key, so changes made in System Settings show; nothing is stored.
      `LoginItemState.change` registers or unregisters, then reads the status back, with any error to show.
      It turns nothing on while Fudge runs from its disk image or a translocated copy (`AppLocation.loginItemRefusal`), since that path goes away, and says to move Fudge to Applications first.
      **Clear Search History…** confirms in a sheet, then `LauncherModel.clearHistory()` empties `LaunchHistory` and `history.json`.
    - **The Calculator page** (`CalculatorPage.swift`, under Extensions) has the currency switch and the calculator's Number format (Same as macOS, "1,234.5" or "1.234,5", saved through `change {}`; changing it re-evaluates the open query), under the `settingsProblem` banner.
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
      an extension's data folder whole, the keyed files extension by extension, `settings.json` keeping this Mac's `extensionStore`, `signInServer` and their consent dates (`Backup.consentKeys`), since this Mac's sign-ins are in its Keychain, and its `extensionRepositories` and `raycastRepository`, since adding a repository is a choice to trust its code.
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
      The caller check is `ClipboardHistory.mayCall`, through `BundledCalls`.
    - **The Extension Store** (FUD-50) is an extension bundled with the app (`Contents/Resources/store-extension`).
      Using it takes two steps.
      **Enabled**, on the Commands page, is off by default for the store alone (`FudgeSettings.isEnabled(owner:)`, which always writes the store's state), so until it's ticked the store isn't in root search, its hotkeys aren't registered and `launchCommand` can't reach it.
      An install that had the store switched on before counts as enabled until either is changed.
      **The switch** is the first row of the store's Settings page (`ExtensionStoreSwitch`): turning it on shows the consent sheet and writes `extensionStore` and the ISO 8601 `extensionStoreConsentAt`.
      `FudgeSettings.isExtensionStoreOn` needs both, so a hand-set `true` counts as off.
      `FudgeSettings.setExtensionStore` writes the store's Enabled down first, so the switch never changes it.
      Turning it off, after its own sheet, removes both keys and deletes only the store's downloaded copies (`ExtensionStore.deleteRepository`): `repo/`, `repo-status.json` and `repositories/`, keeping its `installed.json` and the list of repositories.
      **While it's off, the app never starts the store's code:** `LauncherModel.launch` checks `ExtensionStore.isOff` against `settings.json` first.
      A launch the user started shows "The Extension Store is off." instead, a `Failure` with a `Notice`, drawn like an empty view.
      Its one action, Open Extension Store Settings (↵, ⌘K or ⌘⇧,), opens the store's page.
      A background launch is refused with the same words.
      The extension host's environment carries `FUDGE_CLI` (the bundle's `fudge`) and `FUDGE_EXTENSIONS_DIR` to every worker, and the store installs with `fudge build <folder> --into "$FUDGE_EXTENSIONS_DIR" --repository raycast/extensions` (`BuildArguments`: an absolute path to a folder that exists), so its installs land in Raycast's folder, `raycast/extensions/<name>`.
      Every place in the store that works out an install's folder takes it from `installFolder(extensionsDir, name)` (`store.ts`): the install's check that the name is free (a development build of that name, in `fudgeapp/development`, refuses nothing), the compatibility read after a build, uninstall's Trash and `withoutSwift`.
      **Parts written in Swift** (SPEC-145 §3, `store-extension/src/swift-parts.ts`): before each install or update the store asks the app whether the Command Line Tools are set up (`commandLineToolsReady` in `fudge:app`, answered only for the store, resolved afresh each time).
      Set up, it passes `--swift-parts build` and shows nothing more (D-118), which changes nothing for an extension without such a part.
      Building an extension's Swift part, or building with `--swift-parts build` when the check didn't answer, gets 20 minutes (`swiftBuildTimeout`), since the first one fetches and compiles SwiftPM's packages; any other build gets `buildTimeout`'s 10.
      Not set up, an extension whose scan named a `swift:` import first gets a view (`SwiftPartsView`) saying what it needs, with Don't Install (↵), Install Without the Swift Part and Install with Command Line Tools, which installs once the tools are set up and until then opens Settings → Development (`openDevelopmentSettings`, from the user's own action only).
      A `swift:` import the scan missed makes the build stop asking for `--swift-parts`, and the store shows the view then instead of the error.
      An extension installed without its part says so on its detail page.
      **Install notifications** (SPEC-156) add three `fudge:app` calls that only the store may make, as with `fudge.log`: `installEnded` (`store.installEnded`, an install's end, answered with `{ onScreen, notified }`), `askForNotifications` (`store.askForNotifications`) and `nextNotificationClick` (`store.nextNotificationClick`, which waits for a click).
      Any other extension gets an error.
      **Extension repositories** (FUD-182, SPEC-157 A-B): the store's page has **Extension Repositories** below its switch (`ExtensionRepositoriesSection`), disabled while the store is off.
      Every repository has the same row (SPEC-160): its name, its address (and branch) and its status line, a switch and a remove button.
      Raycast's official repository is first while it's in the list, named `raycast/extensions` with the address `https://github.com/raycast/extensions` (`ExtensionRepositoryText.raycastName`, `raycastAddress`, and in `storeAnswer`); then the added ones in order.
      Behind those names nothing changes: its copy id stays `raycast`, its copy `repo/`, and its folder `raycast/extensions`.
      `raycastRepository` in `settings.json` (`RaycastRepositoryState`, core) is absent while it's in the list and on, `"off"` while it's switched off, and `"removed"` once it's removed; the `false` older builds wrote reads as `"off"`, and anything else as on.
      `FudgeSettings.removeRaycastRepository`, `restoreRaycastRepository` and `showsAddRaycastRepository` are its three states' functions, and `storeAnswer` leaves its entry out while it's removed.
      They're kept in `extensionRepositories`, a list of `{ "address", "branch"?, "off"? }` written only when it isn't empty, `off` only when true (`FudgeSettings.listedRepositories`); reading parses each entry again beside those before it and skips any the rule refuses, a duplicate included, so a hand edit never adds what Settings would refuse.
      `ExtensionRepository.parse(address:branch:existing:raycastListed:)` (core) is the rule, checked by hand on the address's UTF-8 bytes, never with `URL`, which disagrees with the runtime's `new URL` on `..`, `\`, tabs, `:443` and hosts outside ASCII.
      Its checks run in one order: trimmed of ASCII spaces only, the `https` scheme in any case, no `@` before the path, and only letters, digits, `.`, `-` and `:` in the server and port, and letters, digits, `.`, `_`, `~`, `-` and `/` in the path.
      Then a port of 1 to 5 digits with no leading zero, from 1 to 65535, a server, one trailing `/` and then one `.git` dropped, and no `.` or `..` segment.
      Then the identity, the folder (`ExtensionRepositoryFolder`, whose refusals keep their own sentences), the branch (`isValidBranch`, the store's `git.ts` rule), at most 10, no duplicate identity, no equal or nesting folder, and last the folder of Raycast's or Fudge's own repository, a second guard.
      The identity is `https://`, the server in lowercase with a port other than 443, and the path, in lowercase on `github.com` with no port or port 443; Raycast's identity is refused as already listed while it's in the list, and `https://github.com/fudgeapp/development` with its own sentence, both by identity, before the branch and the list, and again by folder at the end.
      The copy id is the identity's SHA-256's first 16 hex digits (`isValidCopyId`: those or `raycast`), and the name is `owner/repository` as typed on GitHub, else the identity without `https://`.
      The Extension Store's `repository-address.ts` (`parseRepositoryAddress`) is the same rule, step for step, and `runtime/test/fixtures/repository-addresses.json` pins both to the same cases, with each refusal's sentence and the status problems' sentences.
      Under the rows are **Add Raycast's Repository**, only while it's removed, which puts it back first and on with no window, and **Add Repository…**, which opens the add window (`AddRepositoryWindow`, a sheet): Address, with the cursor in it, Branch, the warning, a refused address's reason in red, and Cancel (Esc) and Add (↵).
      The window is the warning, so nothing asks again after Add.
      Its fields live in `ExtensionRepositoryDraft` (core), which the section keeps in its own state and makes new each time the window opens, never in `SettingsModel`.
      `ExtensionRepositoryDraft.add(existing:raycastListed:)` checks the address against the list and Raycast's place as they are when Add is pressed, and `SettingsModel.addRepository(_:)` saves what it accepts through `FudgeSettings.addRepository`; a refusal, or a save that fails, stays in the window as its reason.
      While Raycast's is removed, its address in the window (`parse(…, raycastListed: false)`) gives Raycast's own entry, copy id `raycast`, however many are added, and a branch typed with it is refused (`raycastBranch`); saved lists are always parsed with Raycast's refused, so it never becomes a second copy.
      The minus button asks "Remove <name>?" first, and for Raycast's official repository the sheet also says how to add it back; the store deletes the copy the next time it opens.
      Each row's status line comes from the copy's status file (`ExtensionRepositoryStatus.read`: Raycast's `repo-status.json`, an added one's `repositories/<copyId>/status.json`), read when the page appears and when the window becomes key.
      It's at most 4 KB, a JSON object with an ISO 8601 `checkedAt`, and a whole `extensions` count from 0 to 5,000 or a known `problem` kind, else `failed`; no file is "Not checked yet".
      Only a regular file counts (`RegularFile.read`): a link, a FIFO or a device there is `failed`, never followed or waited on, since Settings reads it on the main thread.
      Any extension running in the host could write that file, so the row shows only Fudge's own sentences, with the branch from `settings.json`.
      The store asks for the list with `extensionRepositories()` in `fudge:app` (`store.repositories`, answered only for the store's sessions, as `fudge.log` is, `BundledCalls.Call.storeRepositories`): `settings.json` is read afresh for each call, and the answer (`ExtensionRepository.storeAnswer`) is `[{ copyId, folder, address, branch?, name, on }]`, Raycast's first.
      The store checks it again (`checkRepositoriesAnswer` in `repository-address.ts`): Raycast's entry only in first place, as `RAYCAST_COPY` with its `on`, then each added entry that parses again, beside those before it, to the copy id and folder answered.
      A snapshot run takes `--add-repository <address>`, which draws the add window over the store's page with the address typed (`SettingsModel.snapshotAddRepository`), since a snapshot run never begins a sheet, and `--add-repository-add`, which presses its Add, so a refused address shows its reason.
    - **The Commands page** (`CommandsPage.swift`) is the Settings window's second page:
      Fudge's own command groups, then the quicklinks as a group of their own (`SettingsModel.commandGroups`, shown once there is one, its Type "Quicklinks" and theirs "Quicklink", `BuiltInCommandGroup.typeLabels`),
      then every installed extension, each expanded to its commands (menu-bar ones included), with each command's alias, hotkey and Enabled checkbox (an extension's row has its own checkbox).
      An extension's group is keyed by its id (`CommandOwner.extension`) and titled with its `displayTitle`, so two extensions of one name are two groups that read apart.
      `CommandsPageRows` (core) builds the rows, and the page only draws them; each command row is identified by its whole command id, since the page's lazy stack keeps one row per id across every group, and two extensions of one name have commands of the same names.
      The bundled Extension Store is listed too, unticked until it's enabled.
      An alias is saved on ↵, and Esc puts the old one back.
      Recording a hotkey suspends all of Fudge's hotkeys (`HotKeyRegistry.suspend`), so pressing one records it instead of firing.
      While recording, `HotkeyRecordingPrompt` turns each key press into a `HotKeyRecording` (core): Esc alone cancels, ⌫ or ⌦ alone clears, anything else is the new hotkey.
      Ending the recording (saving, Esc, closing the window, or leaving the page or onboarding step) resumes them (`HotKeyRecorder`, `SettingsModel.select`).
      A conflict (`HotKeyConflict`: the launcher's key, another installed command's, named by its title, with its extension's when two share one, `CommandNames`, or no ⌘ ⌥ ⌃) or a shortcut the system refuses keeps the old hotkey and shows why in the cell.
      A command that isn't installed keeps its saved hotkey for a reinstall, but doesn't block the key: taking it clears that one's hotkey, keeping its alias and Enabled state (`HotKeyConflict.displaced`), and the cell says so (`HotKeyConflict.displacedNote`): by the command's title, and a deleted quicklink's key as "a deleted quicklink", never its id.
      A command that's off by default says why on a line under its title (`SettingsModel.offByDefaultReason`, `CommandCompatibility.reason`: "Uses Raycast AI, which Fudge doesn't support.").
    - **The Sign-in page** (`SignInPage.swift`, after Commands) sets the server extensions sign in through (SPEC-056): Off (the default), **Fudge's sign-in server** (`SignInServer.fudgeURL`, `https://fudge-oauth.rackofpain.net`) or **Your own server…**, whose address is saved on ↵ once `SignInServer.validate` accepts it (`https://`, or `http://` on `localhost` or `127.0.0.1`;
      no user info, query or fragment).
      It's saved as the worker's `new URL()` writes it (scheme and host in lowercase, no default port, dot segments resolved), since a sign-in's authorize URL is compared with what the worker sends back; a host that parser would rewrite otherwise (non-ASCII, percent-encoded, IPv6, IPv4 in another notation) isn't accepted.
      Every choice but Off shows a consent sheet first ("Extensions will sign in through <host>."), and only Continue saves `signInServer` (`"fudge"` or the URL) with `signInServerConsentAt`; `FudgeSettings.signIn` needs both, so a hand-set server counts as off, and Off removes both.
      Changing the server signs out of everything, after its own sheet when there are sign-ins.
      **The line under the choice** (SPEC-149) names the services the server on screen offers, from its answer to `GET <server>/api/services` (`SignInServer.servicesURL`, built as `endpoint` builds a provider's, so a server under a path works).
      `SignInServices` (core) reads only each entry's `id`, keeps the ids `OAuthProviders` has, in the server's order and once each, and writes Fudge's own names for them, so no text from the server reaches the page.
      Up to five names, the line is "This server offers sign in through GitHub, Linear and Slack", with no comma before "and" and no full stop (SPEC-155).
      Past five, it's "This server offers sign in through 26 services" and **Show All**, whose popover lists every name in the server's order under "Services on this server".
      The number counts Fudge's names, after that mapping and dedupe.
      Anything else shows `SignInServer.explanation`, with no error: Off, still loading, an address of your own that's typed but not saved (`SignInServices.serverOnScreen`), no answer, any status but 200, a redirect, more than 64 KB, more than 5 s for the whole request, another shape of JSON, or no id Fudge knows.
      `SignInServerControls` asks through `.task(id:)` on the server on screen, and `SignInServicesLine` drops an answer that comes after the server changed or its task was cancelled; nothing is stored.
      Past five names, `SignInServerControls` puts Show All after the number, in the picker's label (`SignInServicesLine.showsAll`, false while loading and after a change of server, so the button and its popover go then).
      It's a popover, not a sheet, because a popover anchors to the button in whichever window it's in, so the Settings window and onboarding's both get it without `ask`.
      `URLSessionSignInServices` (core) is the request: an ephemeral `URLSession` with no cookies, credentials or cache, `User-Agent: Fudge/<version>`, `Accept: application/json` and `Accept-Language: en`, `timeoutIntervalForResource` 5 s, and no redirects.
      The fetcher is picked once at launch (`SignInServices.fetcher`): a snapshot run gets `FixedSignInServices`, never the network, even with a server chosen.
      Under the server choice, **Extensions with their own sign-in** (SPEC-132 §5, D-89, `OwnAppSignInControls`) is a switch of its own, off by default and independent of the server.
      Its line, "Let extensions sign in with their own apps. Most of them come back through raycast.com.", is one string (`OwnAppSignIn.explanation`) for the page, its consent sheet and onboarding.
      Only the sheet's Continue saves `ownAppSignIn` with `ownAppSignInConsentAt` (`FudgeSettings.isOwnAppSignInOn` needs both, and both are this Mac's, in `Backup.consentKeys`); off removes both, and sign-ins already stored stay under Signed in.
      Under it, the **Fudge opens Raycast links** switch (`RaycastLinksRow`, `RaycastLinksToggle` in core, D-114) is on while Fudge Links opens both `raycast://oauth` and `com.raycast:/oauth`, read from LaunchServices when the page appears and when the window becomes key, never stored.
      Its line says who opens them while it's off (another app by name, no app, or "another copy of Fudge": another copy's Fudge Links, or a build from before Fudge Links that declares the schemes itself), and who gets them back while it's on.
      On does what onboarding's Open Raycast Links with Fudge does (`RaycastLinks.openWithFudge(helper:location:)`), and is refused while Fudge runs from its disk image or a translocated copy (`AppLocation.raycastLinksRefusal`), as Open at Login is.
      Off gives both schemes back explicitly to the first other app that claims both and isn't Fudge's (`handBackTarget`, `giveBack`), so the choice macOS saves names that app; with no such app it's disabled while on, and its line says there's nothing to give them back to.
      A change that doesn't take shows the system's message, or that macOS didn't make it, and the switch shows what LaunchServices says.
      Below them, **Signed in** lists each stored sign-in (the extension's `displayTitle`, the provider, when) with Sign Out.
      **Sign-ins** are Keychain generic passwords (`KeychainSecretStore`), service `io.github.jakeobsen.fudge.oauth`, account `<extension id>/<providerId>`, holding a JSON `StoredTokenSet`;
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
      **The direct path** (SPEC-132, FUD-165) is for an extension with an OAuth app of its own: `oauth.prepare` also sends the client's `redirectMethod`, and `PreparedSignIn.route` (core) decides, in order.
      An endpoint in `OAuthProviders` takes the relay path as above.
      One on Raycast's hosts (`OAuthProviders.isRaycastDomainHost`: `raycastDomains`, so `raycast.com` and every host under it, ignoring case and trailing dots) or on a table entry's own authorize host (`ownAuthorizeHosts`, read from the table) is refused as before.
      Any other `https` endpoint with a host and no user info takes the direct path while its switch is on (else the `off` refusal), for the Web, App and AppURI methods only.
      There no listener starts, nothing is pending for the fetch rewrite, the stored sign-in has no `relayProvider`, and the redirect is Raycast's for the method (`OAuthRedirectMethod.raycastRedirectURI`).
      Its ↵ opens any `https` URL on neither of those hosts whose `state` is the request's (`PreparedSignIn.isDirectURL`), since some extensions build the URL themselves.
      The browser comes back through a `raycast://oauth` or `com.raycast:/oauth` link, which Fudge Links hands on as a get-URL Apple Event, whose handler Fudge sets in `applicationWillFinishLaunching`, so a link that launches Fudge isn't missed.
      Fudge.app itself declares no URL types (D-107).
      `RaycastReturn.read(link:state:)` (core) answers only those two shapes, reading the query as the loopback's is read (`OAuthCallback.read(query:state:)`, the state compared in constant time).
      Every other link, a link with another state, and any link while no direct sign-in waits is ignored: nothing happens, nothing is shown, and nothing logs it.
      `OAuthLinkWait` (app) is the direct sign-in's wait, in place of `OAuthLoopback`.
      **The paste** (Web only, `SignInPrompt.canPaste`): while it waits, the prompt says to copy the browser's address and press ⌘V, which reads the clipboard then and only then.
      `RaycastReturn.read(pasted:state:)` takes an `https` URL with any host or a `raycast://oauth` link, at most 16 KB; anything else shows "That address isn't from this sign-in." and the sign-in keeps waiting, and the text is never logged or kept.
      When Fudge doesn't open Raycast's links, the prompt says so in one line (`RaycastReturn.elsewhereHint`), pointing to Settings → Sign-in.
      **Who opens Raycast's links** is read through `RaycastLinks` (core): `SystemRaycastLinks` (`NSWorkspace.urlForApplication(toOpen:)` and `urlsForApplications(toOpen:)`; on a click, `LSRegisterURL` on Fudge Links and `setDefaultApplication(at:toOpenURLsWithScheme:)`) in the app, and `FixedRaycastLinks` in tests and snapshot runs, so neither touches LaunchServices.
      Only the user's click registers Fudge Links or changes the handler, never a launch, a move, an update or anything in the background.
      After a move or an update to a new path, Raycast's links go back to the other app that claims them until the user turns the switch on again.
      Snapshot runs take `--raycast-links fudge|<app name>` for who opens them (`fudge` is Fudge Links, and `fudge,<app name>` has that app claim them too), and `--own-app-sign-in` shows the switch on, in memory only.
      **A sign-in stopped on purpose** (SPEC-095) names why in its refusal (`SignInRefusal.notice`: off, cancelled, timed out, or refused by the provider or the relay), and the error the command reports with that `notice` (`HostMessage.error`) shows as `SignInNotice` (core) in the command's place, drawn like the store's "off" notice, with no trace and nothing red:
      Like any failure that stands in for a command, the notice keeps the command's title in the bottom bar (`LauncherFooter`); one that belongs to no command, like the store's, says "Fudge".
      "Sign-in is off" with Open Extension Settings (↵, ⌘⇧,) and Open Sign-in Settings (⌘⌥,), or the others with Try Again (`RootAction.retryCommand`, as root search runs it).
      A background or menu-bar command shows its `hud` instead.
      Any other error keeps the failure view with its details.
      Snapshot runs keep sign-ins in memory (`--sign-ins <extension id>/<providerId>=<Provider>,…`, an id the id rule refuses left out), and `--sign-in-consent` saves the Sign-in page's consent alert: laid out by `NSAlert.layout()` without being shown, and moved to a `SnapshotSheet` that refuses key status and is never ordered in (`SettingsWindowController.snapshotSheet`).
      So the image has the app's icon, which the real sheet leaves out.
      `--sign-in-services "github|atlassian"` is the sign-in server's answer in a snapshot run: relay ids, read, named and limited as a server's are; without it there's no answer, and the line under the choice is the plain one.
      `--sign-in-services-list`, with `--settings :sign-in`, draws Show All's list over the page in place of its popover (`SettingsModel.snapshotServicesList`), and nothing while the line names five services or fewer.
    - **Menu bar commands.**
      `MenuBarController` puts each active `menu-bar` command in the menu bar as one `NSStatusItem` with an `NSMenu`.
      Running one from root search (or its hotkey) activates it; running it again refreshes it and opens its menu. ⌘K on an active one offers Deactivate Menu Bar Item (`RootAction.deactivateMenuBarItem`).
      `MenuBarStore` (core) keeps the active commands in `menu-bar.json`, at most 50, pruned of commands that aren't installed.
      It keeps keys it doesn't know, and never overwrites a file it can't read (`Unreadable`): activating or deactivating then fails with a toast saying why.
      A disabled command, or one of a disabled extension, stays in it but leaves the menu bar and stops refreshing, and comes back when it's turned on again (`MenuBarStore.shown`; `LauncherModel.applySettings` hands the controller the settings).
      Each item's autosave name is `menubar:<id>/<command>` (`MenuBarStore.autosaveName`), so it keeps its own position and never takes over another item's saved state, and it's made visible whenever it's put in the menu bar.
      `MenuBarContent` (core) reads the `MenuBarExtra` tree: items without `onAction` disabled, sections as a heading between separators, submenus, ⌥ alternates, and each item's position path.
      `MenuBarLifecycle` (core) decides loads and unloads: at most one instance per command; Background at Fudge's start and on the manifest `interval` (`MenuBarInterval`, at least 10 s, a `.common`-mode timer), UserInitiated when the menu opens or root search runs it; a tick while loaded is skipped and a click just opens the menu;
      unloaded once it has rendered without `isLoading`, its menu is closed and every `onAction` has settled (`eventSettled`).
      The item keeps the last tree.
      A pick made in that tree before the new instance's first render waits, then goes to the item at the same position path with the same title, or is dropped.
      Waiting picks are dropped too once no instance is still to render (`MenuBarLifecycle.awaitsFirstRender`: it failed or exited first, or the host stopped), so a later launch never runs them.
      UserInitiated errors show in the HUD; Background ones are logged and add a disabled "⚠ Last refresh failed" until a later render.
      `LauncherModel` starts the controller's commands (`launchMenuBarCommand`) and routes their sessions' `render`, `error`, `eventSettled` and `exit` to it; their rpcs are answered like any command's.
    - **The Quicklinks page** (`QuicklinksPage.swift`, under Extensions):
      a table of every quicklink's Name, Link, Open With, and its Alias and Hotkey, read only, with "Edit on the Commands page" as their help, sorted by name, read again whenever the page is shown or the window becomes key, so changes made in the launcher show. + opens a sheet with the same three fields, Edit… (or a double-click) opens it filled in, and − (or ⌫) deletes after a confirmation sheet.
      The sheet saves through `SettingsModel.saveQuicklink`, which reads the file again and shows `QuicklinkDraft.problems` under the fields.
      An unreadable `quicklinks.json` shows the notice and disables changes.
      Each change calls `quicklinksChanged`, so root search reads the file again.
    - **The Snippets page** (`SnippetsPage.swift`, under Extensions) works like the Quicklinks page, under the Expand Snippets as You Type switch: a table of every snippet's Name, Keyword and the start of its text on one line, sorted by name, read again when the page is shown or the window becomes key.
      + and Edit… (or a double-click) open a sheet with Name, a several-line Snippet and Keyword, and − (or ⌫) deletes after a confirmation sheet.
      The sheet saves through `SettingsModel.saveSnippet`, which reads the file again and shows `SnippetDraft.problems` under the fields.
      An unreadable `snippets.json` shows the notice and disables changes.
      Each change draws Search Snippets again if it's open in the launcher, and expansion reads the snippets again (`snippetsChanged`).
    - **The Permissions page** (`PermissionsPage.swift`) comes after General: Accessibility's status (`AccessibilityStatus`, read without a prompt when it's shown and every second while it's on screen), its reason, and Open Accessibility Settings.
      The reason (`AccessibilityPermission.reason`, which onboarding's Accessibility step shows too) names Fudge's own commands that need it first, then extensions that read the selection or paste.
      That button asks for macOS's prompt on the first click and opens the pane on later ones, or at once when something in this run already asked for the prompt (`AccessibilityPermission.request`, `SystemAccessibility.promptShown`), so the prompt and the pane never stack.
      Below it, always shown, are the answers to "Allow <A> to open <B>'s commands?" (`LaunchPermissionsSection`, `LaunchPermissions.entries`, each extension shown by its `displayTitle`), each changeable or forgotten, with the file read again before each change, a line saying none has asked yet when there are none, and the unreadable-file notice.
      Between them is Calendar access as macOS has it, with Open Privacy Settings (`CalendarAccessRow`); My Schedule asks for it, never this page.
      Show Onboarding Again restarts onboarding from Welcome.
    - **The Notifications page** (`NotificationsPage.swift`, SPEC-156) comes after Permissions: macOS's answer for Fudge (`NotificationPermission.statusLine`), read and never asked when the page appears and when the window becomes key, with Ask Now while macOS hasn't been asked and Open Notification Settings otherwise.
      Below it is one switch per Extension Store notification, Install or update finished and Install or update failed (`notifyInstallFinished` and `notifyInstallFailed` in `settings.json`, true unless `false`; only `false` is written).
      **One decision per build** (`InstallNoticeCenter`, `InstallNotices`, core), known by its pid and `startedAt` and kept for the last 256 builds: nothing while the store is on screen (the panel visible with a store session on it) or for status 75, else a notification when its switch is on and macOS allows it.
      While a store session is loaded, only its `store.installEnded` reports decide.
      With none loaded, `InstallOutcomeWatcher` (an FSEvents stream on the store's `installing/`, on its own queue) decides from each new `<pid>.ended.json` that still has its record (`StoreBuildRecord`), and when a store session ends, the app reads the folder once for the outcomes it left undecided.
      At launch the stream starts first, and then the outcomes already in the folder count as decided, with nothing posted.
      **The notification** (`InstallNotice`) is `<title> is installed` or `<title> is updated`, or `Couldn't install <title>` or `Couldn't update <title>` with "Click to see what went wrong.", with the identifier `store:<name>` and the `userInfo` `{ name, dir, failed }`.
      It shows even while Fudge is the active app (`willPresent` answers `.banner` and `.list`).
      **A click** (`NotificationClicks`) with a store session still running on the screen's command (`ExtensionStore.sessionOnScreen`) shows the panel without the reset and answers the store's waiting `store.nextNotificationClick` call, or keeps the click for its next one.
      With no store loaded, the command on screen is left and the store launches as from root search, with `launchContext.storeNotification`.
      **macOS is asked** (`requestAuthorization(options: [.alert])`) only while it hasn't been, at most once a run, and only when the user confirms an install or update (`store.askForNotifications`, from a user-initiated store session), turns a switch on, or presses Ask Now.
      It's never asked at launch, at a build's end, in a snapshot run or in a test.
      **Only `SystemInstallNotifications` touches `UNUserNotificationCenter`**, as the poster, the asker and the delegate, made in `applicationWillFinishLaunching` unless the launch is a snapshot run.
      A snapshot run gets `FixedInstallNotifications` (`--notifications not-asked|allowed|quiet|off|unknown`), and tests use a recording fake.
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
      The steps use General's own controls (`LauncherHotkeyControls`, `OpenAtLoginControls`, `HyperkeyControls`, the Calculator page's `CurrencyRatesToggle`, and the Permissions page's `AccessibilityControls`), so an answer takes effect at once.
      The **Extension Store** step (after Currency) shows the store's consent sheet's own words (`ExtensionStore.Consent`), with **Turn On Extension Store**, which writes what the switch and its sheet write and also ticks the store's Enabled (`FudgeSettings.turnOnExtensionStore`), and **Not Now**, which is ↵.
      The **Sign-in** step is the Sign-in page's own choice (`SignInServerControls`, shared with the page, with `SignInServer.explanation`), whose consent sheets show on the onboarding window (`OnboardingModel.ask`; laid out off-screen in snapshot runs), with Continue as ↵, so Off stays Off.
      The **Raycast** step (after Sign-in, SPEC-132 §3.3, D-88, `RaycastStep`) says that Fudge runs extensions made for Raycast, that with Raycast on the same Mac the two can get in each other's way, and that signing in to some extensions ends with a Raycast link, which has to open Fudge.
      It offers **Open Raycast Links with Fudge**, which does what turning the Sign-in page's switch on does, while another app opens them (saying that Raycast's own links then open Fudge too), and **Turn On** for extensions with their own sign-in, with the switch's own line (`OnboardingStep.optIns` maps `ownAppSignIn` to it).
      Its Continue, or Not Now while it offers something, is ↵ and changes nothing (`RaycastStep.buttons`), so going through onboarding with ↵ leaves the switch and the links as they were.
      The **Clipboard history** step (after Raycast) shows the consent sheet's own words (`ClipboardHistory.consentMessage`, the one string both use) with **Keep Clipboard History**, which does what the switch and its sheet do (`SettingsModel.keepClipboardHistory`), and **Not Now**, which is ↵, so going through onboarding with ↵ never starts recording.
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
      The sidebar lists Fudge's core pages on top: General, Permissions, Notifications, Commands, Sign-in and Development.
      Under Extensions, one list sorted by title with `localizedStandardCompare` holds Fudge's Calculator, Calendar, Color Picker, Quicklinks, Snippets and Window Management pages, the extensions with preferences, and the Extension Store, whose page starts with its switch (`InstalledExtension.settingsPages`), enabled or not.
      `SettingsSidebar` (core) gives both lists and the tags of Fudge's own pages, which start with `:`, so no extension id can take one; `SettingsView` only draws them.
      An extension's page is tagged with its id (`SettingsSidebar.tag(of:)`), so two extensions of one name have a page each, and `--settings <id>` opens one in a snapshot run.
      Rows with exactly the same title have a fixed order, so it never changes: Fudge's own page first, then the copy from Raycast's official repository, then the development folder's, then the added repositories' by their folder, a segment at a time (`SettingsSidebar.Place`), then by tag.
      An extension from Raycast's official repository with exactly the title of one of Fudge's own pages shows " (installed)" after its title (`SettingsSidebar.title(of:)`; the Extension Store has a Color Picker of its own).
      A development build's and an added repository's rows show their `displayTitle` instead ("GitHub (development)", "GitHub (someone/tools)"), never " (installed)" as well.
      A selected page that's no longer listed, such as an extension removed while its page is open, gives way to General (`SettingsSidebar.lists`).
      The window holds each extension's preferences by its id (`InstalledExtension.index`, so a duplicate can't trap), stored by `PreferenceStore` in `preferences/<extension id>.json`, and each field (`PreferenceField`) reads and saves them by that id.
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
  - `FudgeLinks` is `Fudge Links.app` in `Contents/Helpers`, the only part of Fudge that declares `raycast:` and `com.raycast:` (`App/Links/Info.plist`, SPEC-140, D-107).
    It's an `LSUIElement` app that hands each such link to Fudge as a get-URL Apple Event (`NSWorkspace.open(_:withApplicationAt:configuration:)`, never activating): to every running Fudge, the one that holds it first, else to the one that holds it, launched in the background (`RaycastLinksHelper.targets`).
    It drops any other link, logs nothing, and quits once its links are handed on, or 10 s after a launch with none.
    Only the Sign-in page's switch, or onboarding's Open Raycast Links with Fudge, registers it with LaunchServices, so no build, launch, snapshot run, copy or Spotlight makes it, or Fudge, open Raycast's links.
  - `FudgeDiskImage` is `make dmg-image`'s tool, which lays out the disk image's Finder window (see `make dmg`); it's built, never shipped.
  - `FudgeCore` is shared code, and the only target with tests.

  Put logic in `FudgeCore`, where it can be tested.
  Keep the app, the tools and Fudge Links thin.
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

    stdout carries nothing but the protocol: in the host, `console.log` goes to stderr, and a worker's `console` and output arrive as `log` messages, named and bounded by the host (see the log files).
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
    An extension with an OAuth app of its own signs in to its service directly instead (SPEC-132), coming back through Raycast's return address for its `RedirectMethod`, which is the redirect its app has registered.
    The relay lives in its own repository, `jakeobsen/fudge-oauth`; it holds the OAuth apps' secrets, so Fudge holds none.
    `OAuth.PKCEClient` can be built with any `RedirectMethod`, as `@raycast/utils`' `OAuthService` does when an extension loads.
    `authorizationRequest()` asks the app for the request (`oauth.prepare`, with the client's `redirectMethod`): for one of `OAuthProviders`' authorize URLs the app refuses while sign-in is off, and otherwise starts the loopback listener and answers with the relay's authorize URL and the redirect.
    For any other endpoint it answers as the direct path decides (see the Sign-in page): no provider, the endpoint itself and Raycast's redirect for the method.
    The client makes the PKCE verifier (64 unreserved characters from `crypto.getRandomValues`), its S256 challenge and the `state`, and `toURL()` puts them on the URL with the extension's `clientId`, `scope` and extra parameters.
    The `state` is the base64url of `{"id":"<16 random bytes, base64url>"}`, 42 characters with nothing else in it (`randomState`), which raycast.com's return page passes on unchanged.
    On the direct path the extension's `extraParameters.redirect_uri` wins over Raycast's and becomes the request's `redirectURI`, as Raycast documents; the relay's loopback redirect is never overridden.
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
    Todoist's, `raycast-pomodoro-notion`'s, `github-copilot`'s and `bangumi`'s entries refresh at their token URL too, so the grant picks the endpoint there as well.
    Being Raycast's addresses, they always go to the relay, never to their own host: a table match on any of Raycast's hosts (`isRaycastDomainHost`, or the proxy hosts) isn't an own host (`ownHost`).
    **Nothing is ever sent to Raycast's proxy hosts** (`*.oauth.raycast.com`, with or without a trailing dot): what isn't rewritten there is refused, with sign-in on or off.
    **Token and refresh grants to any of Raycast's hosts are refused too** (SPEC-132 §2 step 5, `isRaycastDomainHost`, by the domains core hands over in `FUDGE_RAYCAST_DOMAINS`), through `fetch`, `http` and `https` alike.
    Any other request there, a plain `GET` to raycast.com included, goes where it was going, and only a request with a body is read for its grant (`needsDecision`).
    A rewritten request goes to the relay through Node's `http`/`https` (`sendToRelay`), never undici, as the `Request` `fetch` would send (its method, headers and serialized body, its `signal`), and comes back as the `Response` `fetch` would give, streamed and decoded.
    Its connection always verifies (`relayTLSOptions`: `rejectUnauthorized: true` and TLS 1.2 at least), whatever the worker's `NODE_TLS_REJECT_UNAUTHORIZED` says, since it carries the code and verifier or the refresh token.
    A redirect from the relay is an error, never followed, since a 307 or 308 would send that body on.
    Every other request keeps `fetch`'s own redirects, as in Raycast (D-65), so a third party's redirect to `*.oauth.raycast.com` isn't intercepted.
    The table holds the seven providers `OAuthService` has built in, at their default URLs, and Raycast's proxies for Jira and Zoom (`jira.oauth.raycast.com`, `zoom.oauth.raycast.com`), which the store's Jira and Zoom extensions set (FUD-137).
    The table also holds the addresses of store extensions that sign in through Raycast's other proxies (FUD-166).
    Those are Notion's (`notion.oauth.raycast.com`) and Todoist's (`todoist.oauth-proxy.raycast.com`) proxies, and the exact shared-proxy addresses (`oauth.raycast.com/v1/…`) of `raycast-pomodoro-notion`, `trek`, `gumroad`, `moneybird`, `github-copilot`, `freeagent`, `mollie-for-raycast`, `plane`, `homey` and `figma-files`.
    They go to the relay's `notion`, `todoist`, `basecamp`, `gumroad`, `moneybird`, `github`, `freeagent`, `mollie`, `plane`, `homey` and `figma` providers, where the relay's own app takes the place of the extension author's.
    The table also holds the exact shared-proxy addresses of `42-api`, `ticktick-plus`, `zoho-mail` and `webflow-sites`, which go to the relay's `intra42`, `ticktick`, `zoho` and `webflow` providers.
    The table also holds WHOOP's and Miro's proxies (`whoop.oauth.raycast.com`, `miro.oauth.raycast.com`) and the exact shared-proxy addresses of `bangumi`, `wave` and `tesla-energy`, which go to the relay's `whoop`, `miro`, `bangumi`, `wave` and `tesla` providers.
    A shared-proxy entry stops matching when the extension's author makes new addresses.
    These entries are the one allowed exception to the rule against fixes for particular extensions (Conventions).
    The Jira and Zoom entries go to the relay's `atlassian` and `zoom` providers, beside Atlassian's and Zoom's own URLs, so two entries can share a relay provider (`OAuthProvider.id`), and an entry is known by its authorize URL.
    One Atlassian app covers Jira and Confluence, so both Atlassian entries are named **Atlassian (Jira, Confluence)**.
    A sign-in stored with `relayProvider: "jira"`, the relay's Atlassian provider before fudge-oauth v0.3.0, counts as Atlassian's (`OAuthProviders.currentRelayProvider`).
    The table is core's (`OAuthProviders`), handed to the host as JSON in `FUDGE_OAUTH_PROVIDERS`; `runtime/test/fixtures/oauth-providers.json` is the same table, pinned by a Swift test, for the runtime's tests.
    `src/api/oauth-table.ts` reads it and Raycast's domains, and holds both host checks (`isRaycastHost`, `isRaycastDomainHost`); it imports nothing, so the Extension Store uses it too, and `oauth-fetch.ts` re-exports it.
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
    `CommandMetadata` (core) keeps it in `command-metadata.json`, by `<id>/<command>`, keeps keys it doesn't know, and drops the entries of commands that aren't installed when the file is loaded (never from an empty listing); the manifest is never touched.
    It never overwrites a file it can't read (`Unreadable`): the update fails instead, and the extension's promise rejects saying why.
    A command's root item shows that subtitle, else the manifest's `subtitle`, else its extension's title, and search matches the extension's title either way.
    The extension's title is left out when it only repeats the command's title, ignoring case and spaces around them (`RootItem.subtitle(_:unlessItRepeats:)`, SPEC-120), so a one-command extension named like its command shows its name once; a subtitle the author set is shown as set, and a built-in group's title falls back the same way.
  - **`launchCommand`** (`src/api/launch-command.ts`) checks its options in the worker, makes the arguments strings, and encodes `context` with `encode` (`src/protocol.ts`): Dates as `{ "$date": iso }`, Buffers as `{ "$buffer": base64 }`.
    It then sends `command.launch`.
    In the app, `LaunchRequest` reads the call and `CommandLocator` (core) finds the command: in the caller's extension, or in the one with that name and owner (else author).
    When several installs have that name and owner, it takes the caller itself, then the one from the caller's repository, then Raycast's, then the development build, and refuses two or more left after that (`LaunchCommandError.ambiguous`); a bundled extension is the only one with its name.
    It fills every manifest argument, and its checks turn away what can't run: view commands in the background, a menu-bar command in the background unless it's active (`checkMode`), and missing required arguments or preferences in the background.
    A menu-bar command goes to `MenuBarController`: Background refreshes it like an interval tick, and UserInitiated activates it if needed and refreshes it, without opening its menu.
    A user-initiated launch with a required argument empty shows root search with the command's fields instead; an unset required preference opens Settings.
    The first time an extension opens another extension's command, the user is asked through `confirm`, and `LaunchPermissions` keeps the answer in `launch-permissions.json`, by the caller's and the target's ids; only a call from a session the user is using may ask, whatever `LaunchType` it requests.
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
    Git isn't run until `xcode-select -p` succeeds and the developer folder it names holds `usr/bin/git` (checked with `stat`, since that folder can outlive its tools), so macOS's offer to install the Command Line Tools never shows.
    Without them the store shows `NeedsGit` (`failure-view.tsx`): ↵ Install Command Line Tools runs `xcode-select --install`, macOS's own installer, only from that action (`installCommandLineTools`), and ⌘R Refresh checks again.
    A failure whose cause is Git missing has the same action.
    Unloading the store ends its running git (`stopRunningGit`, in the command's effect cleanup, which `unload` runs), and turning the store off unloads its sessions and waits for them to exit (`LauncherModel.unloadSessions(ofExtension:)`) before Part A deletes `repo/`.
    A copy that can't be read, such as a clone stopped halfway, is deleted and cloned again.
    A failure before the list has ever loaded, which can only be the clone, shows in the load-error view (`LoadFailure` in `failure-view.tsx`), whose Refresh (↵, ⌘R) opens the copy again the same way and then refreshes it.
    That view has the failure view's cause line (a clone that can't reach GitHub says so), ⌘C Copy Error and ⌘D Show Details, which pushes the failure view with the end of git's output.
    A refresh runs only once the list has loaded from the copy, so a failed one, a default branch name `isValidBranch` refuses included, shows as a toast over the list, which stays usable.
  - **Files from the copy are read as regular files only** (`files.ts`, `readRegularFile`: opened with `O_NOFOLLOW` and `O_NONBLOCK`, then `fstat`), each kind with a size cap: every `package.json` for the list, a README, and the package-source check's `package.json` and lockfiles. git checks out a committed link as a link, so `README.md -> /dev/zero` would otherwise read forever.
  - `catalog.ts` gives each row two things, each checked by its own rule before it's used.
    `name` is the manifest's name (`isValidName`, the app's rule, pinned to `ExtensionManifest.isValidName` by `runtime/test/fixtures/extension-names.json`): the extension's identity, its installed folder (`<extensions>/raycast/extensions/<name>`, `installFolder`) and its `installed.json` key.
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
    A scan's result (`Compatibility`: the categories Fudge doesn't support, the APIs it lacks, signing in, whether that goes through raycast.com, unreadable source;
    or `notChecked`) is cached by the folder's git tree id in `compatibility.json` in the store's data folder (the newest 4,000, entries checked on reading, API names identifiers only), with the scanner that wrote it: the `fudge` tool's size and modification time, so a new build of Fudge, which may support more, scans again (`scannerIdentity`).
    The file has a `version` (`cacheVersion`, 2 since `signsInThroughRaycast`), and a file of another version reads as empty, so no result from before a new field is used.
    **Signing in goes through raycast.com** (`signsInThroughRaycast`, SPEC-132 §7) when the extension's own code names `OAuth.RedirectMethod.Web` and one of its authorize URLs (the scan's `signIn`), an unresolved one included, is neither the table's, exactly as `oauth.prepare` matches it, nor on Raycast's hosts (`isRaycastDomainHost`).
    Such a sign-in takes the direct path, whose Web redirect is raycast.com's page; App and AppURI come straight back, so they never count.
    The table and the domains are the ones the app hands every worker (`signInTableFromEnvironment`: `FUDGE_OAUTH_PROVIDERS`, `FUDGE_RAYCAST_DOMAINS`), never a copy.
    The detail pane and the install confirmation then say "Signing in goes through raycast.com. The extension's author chose that, so Fudge can't change it." (`throughRaycastSentence`) in place of the sign-in server's sentence, which doesn't apply.
    The list never scans: a row whose cached result uses something Fudge doesn't support gets a tag (`compatibilityTag`), a red **Not compatible** when every command does, or an orange **Partly compatible** when only some do.
    A result keeps which commands do (`byCommand`, from the scan's per-command results); one without it, or whose scan has none, counts the whole extension, as before SPEC-109.
    What only an AI tool uses counts for no command, so it isn't mentioned.
    The detail pane's first fact is **Compatibility** (`compatibilityText`): Checking…, Compatible, Partly compatible: 2 of 9 commands use Raycast AI: and their titles, Not compatible: Raycast AI, Missing: the APIs, Signs in with OAuth or the raycast.com sentence, Couldn't check, or Not checked.
    **Browsing never turns into downloading** (`CompatibilityChecks`): only the row the selection rests on, with the detail showing, is checked, after half a second, and moving on cancels its timer, or the check itself: its download ends at once, and the check stops between its other steps; selecting the same row again changes nothing, and a cached row is never fetched.
    Only the download (`fetchSource`) is ever ended, since it writes nothing but new packs: it runs in a process group of its own, which the cancel's `signal` sends SIGTERM, then SIGKILL after `cancelGrace` (a second).
    Every other git step runs to its end, since one that writes the index holds `index.lock`, and ending it would leave that behind for every later checkout and install.
    The README waits the same way: both run through `RestingWork` (`resting.ts`), and only the resting row's README is fetched (`fetchReadme`), once per folder tree, since READMEs are kept by tree id.
    It's selected before the check, so its quick fetch goes ahead of the check's download in the git queue.
    A README git couldn't fetch isn't kept: the detail says so (`readmeNotFetched`), and ⌘R fetches it again (`RestingWork.again`), as does coming back to its row.
    While a fetch is on its way, waiting or running, the detail shows it as loading (`RestingWork`'s `scheduled` clears the failure, `shownReadme`), so showing no README means the folder has none.
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
    A press of Install, Update or Try Again on a row whose name is already installing or updating does nothing (`InstallPresses`, SPEC-153 B): every row with that manifest name says `Installing…` or `Updating…` and offers no Install, Update or Uninstall until the install's run ends.
    No refresh rewrites `repo/` while a build from a closed store session runs: the refresh, and the removal and clone after a copy that can't be read, wait before they enter the queue (`OtherBuilds.hold`, `heldRefresh`), never in it, since a record settles in the queue.
    Before asking, it takes this version's cached result, or runs `$FUDGE_CLI scan <source> --json` and caches it, and the confirmation says what it found (`compatibilityLine`).
    For Raycast AI or the Raycast Browser Extension, which Fudge doesn't support, it's "Partly compatible with Fudge", naming the commands its scan found, which the build turns off, or "Not compatible with Fudge" when that's every command; installing stays possible either way.
    The build scans the source again, exactly what it installs, so its `compatibility.json` is what's true: after the build, the store reads it (`builtCompatibility`), and when it isn't what the confirmation named, the done toast says what is (`installNote`, SPEC-121 §2).
    That's "Turned off: …" for commands the confirmation didn't name (its scan failed, say), "Every command is on" when the build found none, and that Fudge couldn't check, so every command is on, when the build's scan failed after the confirmation named some.
    Then it names up to five APIs it doesn't have yet and how many more; that it signs in with OAuth, which works if the chosen sign-in server supports its provider, or the raycast.com sentence (never called not compatible); everything supported; or that the scan couldn't run, which doesn't stop the install.
    Every install or update that finishes ends in a Success toast, `Installed <title>` or `Updated <title>` with that note as its message when there is one, and the store stays open on its list (`doneToast`, SPEC-130); it never calls `showHUD`, `closeMainWindow` or `popToRoot`, which close the launcher.
    It records the folder's git tree id in `installed.json` ("Update available" when the id changes), and uninstalls only what it recorded.
    **Unloading the store doesn't stop a `fudge build` it started** (or npm under it), unlike its git: the worker's timeout goes with it, so the build runs to the end, or until npm's own network timeouts give up.
    That's acceptable because nothing is installed half-way: the build writes into a staging folder and swaps it in only at the end, and the extensions watcher picks the result up like any install.
    **The store records each running build** in `installing/<pid>.json` in its support folder (`build-records.ts`, SPEC-153 C), written atomically once the build has a pid (`Run`'s `started`) and removed when its run ends, after the write has settled; a record it can't write or remove is logged, and never changes the install.
    A reopened store reads them before its list (`openCopy`), apart from the copy, and while one runs its rows say `Installing…` and the open store checks it every 2 s (`OtherBuilds`).
    An orphaned build stays a child of the host, so once it ends it's a zombie that `kill(pid, 0)` still finds: a build counts as running only while `ps -ww -o stat=,args=` shows a state that doesn't start with `Z` and exactly the recorded command, so a reused pid isn't taken for it.
    An ended one is settled in the queue: it's adopted into `installed.json` only when its install folder was made between its start and the end bound (when the open store saw it end, or its deadline when it ended before the store opened) and the record has a tree, and dropped otherwise.
    That folder is `installFolder`'s, or, when that isn't there, the unmoved `<extensions>/<name>` an older `fudge build` finished at the top level, which the next move files in Raycast's folder.
    One still running past its deadline gets SIGTERM, as the closed session's timer would have sent; this session's own records end through their own run.
    A build that exits 75 (another build of that extension is running, `fudge build`'s lock) is neither a failure nor an install: the toast says it's already being installed.
    **A build's output and outcome** (SPEC-156 A): `recordedBuild` passes `--outcome <support>/installing`, and the build's stdout and stderr go to two files in `installing/` instead of pipes (`Run`'s `output`), so a build that outlives its worker never gets SIGPIPE and its whole output stays.
    `spawnProgram` opens them `wx+` with mode 0600, gives them to the child as fd 1 and 2, and reads back at most the last 1 MiB of each through its own descriptors; git and `fudge scan` keep their pipes.
    `recordBuild` makes them under dot names and renames them to `<pid>.out` and `<pid>.err` before it writes `<pid>.json`, and its `ended()` removes `<pid>.out`, `<pid>.err`, `<pid>.ended.json` and then the record.
    The reader keeps these files while their record exists, deletes one without it once it's an hour old, and uses an `.ended.json` only when it's valid (`parseBuildOutcome`).
    **Settling with an outcome** (D.2): status 0 is adopted when the folder was made between `startedAt` and the outcome's `endedAt`, and is otherwise dropped quietly with one Fudge.log line; 75 is dropped quietly; any other status is a failed drop.
    A record without an outcome (killed, or crashed) is settled as before, and a failed drop's output then ends with `Its build stopped before it finished.` (`stoppedLine`).
    A failed drop has details like `BuildFailed`'s (the two files' output, the command and the exit status), is logged and marks its row (`settledNotice`), and all of the pid's files are deleted.
    **The report** (D.1): `installPressed` reports every install or update it ends, apart from `AlreadyBuilding` and a cancel, through `installEnded` with the last build's pid and `startedAt` (`reportEnd`), and a record seen ending is reported the same way.
    A report that fails or isn't answered within 5 s counts as on screen and not notified.
    The answer decides: notified hides the animated toast; a success not on screen selects its row once; a notified failure is logged, marked, selected and saved for a click, with no `FailureView`; a failure not notified pushes `FailureView` as before.
    **The row mark** (D.3, `RowMarks`, in memory for the store session only) is `Couldn't install` or `Couldn't update` in red in place of the row's tag (a busy tag wins), with Try Again (↵) and Show Error (⌘↵) first; it goes when that name installs or updates.
    `accessoryTexts` and `rowActions` take the mark as they take `busy`.
    **A failure saved for a click** (D.4) is `<support>/failures/<name>.json` (`saveFailure`, atomic, mode 0600), written only for a failure that got a notification, and deleted when a click or Show Error opens it, when the name is pressed again, and at the store's open once it's 7 days old.
    **The launch context** (D.5, `LaunchTarget`): `launchContext.storeNotification` (`{ name, dir, failed }`, checked by `noticeTarget`) selects that row once after the first load, once the records found at open have settled (held outside the queue).
    With `failed`, it pushes `FailureView` from the session's mark, or else from the saved file, which then goes (`openNoticeTarget`).
    A click while the store is loaded comes through one waiting `nextNotificationClick` call, made again after each answer (`followClicks`).
    Right after the user confirms an install or update, before the build, the store calls `askForNotifications` without waiting for it (SPEC-156 G).
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
  - **The layout** (FUD-183): the extensions folder holds each repository's installs in a folder of their own, where `<name>` is always the manifest's name.
    `raycast/extensions/<name>` is Raycast's official repository (the Extension Store's installs), `<owner>/<repository>/<name>` one on GitHub, `<host>/<path…>/<name>` one on another server, and `fudgeapp/development/<name>` the development builds.
    `fudge build --repository <folder>` (`BuildArguments`, checked with `ExtensionRepositoryFolder.isValid`) installs into `<into>/<folder>/<name>`; without it, or with `fudgeapp/development`, the build is a development build, with the id `fudgeapp+development+<name>`, beside any other install of that name.
    Only the address `https://github.com/fudgeapp/development` is refused as a repository (SPEC-157), never the folder: the GitHub organization `fudgeapp` is Fudge's own, so no one else's repository has it.
    Before writing anything, the build checks that the destination isn't the source (`checkSource`), and that no folder on the way from `--into` to the repository's folder holds `package.json`: "That repository's folder is inside an installed extension."
    A destination that doesn't exist yet passes `checkDestination`, so without that check a build could write inside an install.
    Then it makes the folders on the way (0755), and they go again when the build fails.
    An id over `ExtensionID.maxBytes` is refused ("That extension's name is too long for Fudge to keep its files."), so `Extensions/<id>.old.log` stays a valid file name.
    A build never checks, refuses or replaces an install in another repository's folder: `--repository raycast/extensions` replaces the store's install of that name and keeps its bare-name keys, and never writes the store's `installed.json`, so the store's next Update puts its version back.
  - **One build per id** (SPEC-153 A): after the move below, and before anything is written, the build takes a non-blocking `flock` on `<extensions>/.build-<id>.lock` at the top whatever the repository (`lockBuild`), opened with `O_CLOEXEC` on top of `ChildProcesses.spawn`'s `POSIX_SPAWN_CLOEXEC_DEFAULT`, so no program it starts holds the lock.
    So Raycast's, a development build and an added repository's extension of one name each have their own lock (`.build-github.lock`, `.build-fudgeapp+development+github.lock`, `.build-someone+tools+github.lock`).
    A second build of that id stops with `BuildError.alreadyBuilding` and exits with status 75 (`EX_TEMPFAIL`, used for nothing else), which the Extension Store reads; `runtime/test/fixtures/build-statuses.json` pins both sides.
    The kernel drops the lock when the build's process ends, however it ends, and the empty dot file stays, since deleting a lock file another build may have open would break the lock.
    The build gives it back with `LOCK_UN` before it closes the file (`unlockBuild`): a program another thread is starting holds a copy of every descriptor until its exec, so `close` alone could leave the lock with that copy for a moment.
  - **`--outcome <folder>`** (SPEC-156 A.3), an absolute path to a folder that exists, checked as `--into` is: on every exit the tool makes itself (0, 1, 75, and 128+n from `endChildrenOnSignals`), it first writes `<folder>/<pid>.ended.json` atomically, `{ pid, status, endedAt }` (`BuildOutcomeFile`, `BuildOutcomeRecorder`, where the first status wins).
    A file it can't write prints `fudge: couldn't save the build's outcome in <folder>: <reason>` to stderr and never changes the exit status; SIGKILL or a crash writes nothing.
    The Extension Store passes `--outcome <support>/installing` on every build, and `runtime/test/fixtures/build-outcome.json` pins the format on both sides.
  - It reads `package.json` (`ExtensionManifest`) and compiles every command's `src/<command>.{tsx,ts,jsx,js}` with esbuild into `<extensions>/<repository folder>/<name>/<command>.cjs`, beside `package.json` and `assets/`, as Raycast installs it (SPEC-123).
    So a command's `__dirname` is the extension's folder, and `${__dirname}/assets/…` and `${__dirname}/package.json` are its own, as extensions such as the store's amazon-aws expect.
    esbuild writes into a folder of its own inside the staging folder, and only the commands' files move up, so anything else it writes (a stylesheet an import pulls in) never reaches the install.
    The modules the host provides (`ExtensionBuilder.providedModules`) stay external.
  - **The compile step** (SPEC-144) is esbuild's JavaScript API rather than its command line, which can't take plugins: `runtime/scripts/compile/bundle.ts`, which `npm run build` bundles with esbuild's JavaScript inside (`scripts/compile/make-bundler.ts`) into `dist/bundle-extension.cjs`, and `make app` ships as `Contents/Resources/runtime/bundle-extension.cjs`.
    The tool finds it there beside itself, or at `$FUDGE_BUNDLER` (`ExtensionBuilder.locateBundler`), and runs it with Fudge's own Node.js in the source folder, driving the esbuild program it found (`ESBUILD_BINARY_PATH`).
    esbuild's options go to it in a JSON file in the build's scratch folder (`ExtensionBuilder.BundleOptions`), one for one the flags the tool passed the command line before, so an extension without `rust:` or `swift:` imports compiles to the same bytes, and esbuild prints its warnings and errors as the command line did.
    That includes the command line's default `logLimit` of 6, which the JavaScript API doesn't share: a build shows at most 6 errors or warnings, then how many there were.
    So every build needs Fudge's Node.js and the script: a `fudge` without them beside it, as outside Fudge.app, stops with `BuildError.noBundler`.
    A `rust:` import is handled as Raycast handles it on a Mac (`scripts/compile/rust.ts`, from `@raycast/api`'s `rust-files.js` and `rust-parser.js`): Rust parts are for Windows, so nothing is compiled, and the module written in the package's place exports each `#[raycast]` function, the same functions as its default export, and `RustError`.
    Every call rejects with Raycast's own `Rust functions are not supported on macOS`.
    The functions are found with Raycast's own patterns, in the `.rs` files under the package's `src/`, reading only regular files and following no link.
    The package's folder must hold a `Cargo.toml` and be inside the extension's folder, links resolved, both checked at the import, and nothing of it goes into the install.
    A `swift:` import (SPEC-145 §2, `scripts/compile/swift.ts`, from `@raycast/api` 2.13.1's `swift-files.js`) is a Swift package whose `@raycast` functions the extension calls, and `fudge build` must be told what to do with it: `--swift-parts build` or `--swift-parts leave-out` (`BuildArguments.SwiftParts`, `ExtensionBuilder.swiftParts`).
    Without either, the build stops at the import, asking for one; without such an import, the flag changes nothing.
    The package's folder must hold a `Package.swift` and be inside the extension's folder, links resolved, both checked at the import.
    **build** needs the Command Line Tools (`ExtensionBuilder.commandLineTools`, `CommandLineTools.resolve`, asked only then), else stops saying where to set them up.
    The plugin copies the package, keeping its folder's name, into the build's scratch folder, never building in the extension's source.
    There it runs the tools' own `swift` with `DEVELOPER_DIR` added to the environment `fudge build` has, nothing else added or taken away: `package dump-package` (exactly one executable target, else Raycast's messages), then `swift build -c release --product <target> --cache-path <cache>` and its `--show-bin-path`.
    The cache is one shared SwiftPM cache (`FudgePaths.swiftPackageCache`: `~/Library/Caches/Fudge/SwiftPM`, or under `$FUDGE_SUPPORT_DIR`), so a later build doesn't fetch the packages again.
    The program goes into the install's `assets/compiled_raycast_swift/<package folder name>` with mode 755, Raycast's path, which its JavaScript runs (`ExtensionBuilder.installSwiftParts`), and the `.build` folder goes with the scratch folder.
    The module is Raycast's: its `runSwiftFunction` without the Windows check (JSON arguments, `JSON.parse` of the trimmed stdout, a `SwiftError` with stderr, else stdout, as its message), the `raycast.js` the package's own plugin wrote (at `.build/plugins/outputs/<folder name lowercased>/<target>/destination/RaycastTypeScriptPlugin/`), and `SwiftError`.
    A build that fails stops the install with SwiftPM's output after `the part written in Swift didn't build`, and a signal that ends the script ends `swift` too.
    `swift` runs in a process group of its own, which gets SIGINT, the signal SwiftPM answers by cancelling its compile jobs (they run in process groups of their own, so no other signal reaches them), and the script waits up to 0.8 s for that, inside `ChildProcesses.endAll`'s 1 s before SIGKILL.
    **leave-out** runs nothing: the module exports `SwiftError` and the package's functions, each refusing every call with a `SwiftError` saying the part wasn't installed and where to set up the tools.
    The functions are found in every `.swift` file of the package's folder outside `.build` (targets can keep their sources elsewhere, `path: "src"`), comments stripped: `@raycast`, then any whitespace, attributes and modifiers, then `func <name>`, and the older `#exportFunction(<name>)`.
    A build with a `swift:` import writes `swift-parts.json` into the install (`SwiftPartsRecord`: `build` or `leave-out`), one of `installedItems`, so the store can say an extension was installed without its part.
    Extension names are lowercase letters, digits, `-` and `_`, starting with a letter or digit, as Raycast's rule allows (`notion_researcher`): `ExtensionManifest.isValidName` is the one extension name rule, which every check of an extension's name uses (the build, backups and their paths, settings keys, built-in group names).
    The runtime's `src/extension-id.ts` mirrors it, for the id rule and the store's `catalog.ts` alike.
    **Extension ids** (FUD-183) keep two extensions of one name from different repositories apart.
    `ExtensionID` (core) is an installed extension's key: Raycast's extensions and the bundled ones keep their manifest name, and an extension from any other repository, the development folder `fudgeapp/development` included, has its repository folder's segments, then its name, joined with `+` (`someone+tools+github`, `fudgeapp+development+github`).
    `+` is in no extension name, folder segment or command name, so an id splits back one way only and no qualified id equals a name; it isn't `/`, which joins an id and a command in `<id>/<command>` keys.
    An id comes from where an install is (`ExtensionID(name:repositoryFolder:)`), from the bundled extensions' constants (`ExtensionStore.id`, `ClipboardHistory.id`, `FileSearch.id`, `BundledExtensions.emojiID`), or from a key read back (`ExtensionID(stored:)`, checked by `ExtensionID.isValid`).
    There's no unchecked init and no conversion from a manifest, so a key never comes from `manifest.name` by accident.
    It's `Codable` and `CodingKeyRepresentable` as its string, so a dictionary keyed by it is still a JSON object; one bad key fails a whole dictionary, so a store reads its keys as strings and keeps those the rule accepts.
    `ExtensionRepositoryFolder` (core) gives a repository's folder from its parsed address (`folder(host:port:segments:)`): two lowercase segments on GitHub, else the server's name, `_<port>` for a port other than 443, and one to six lowercase segments, at most 160 bytes.
    `isValid(_:)` accepts exactly those folders, `conflict(_:with:)` refuses an equal or nesting folder, and each refusal's sentence is defined there once (`Refusal`).
    The runtime has both rules in `src/extension-id.ts` (`isValidExtensionId`, `isValidRepositoryFolder`) and the Extension Store's `repository-folder.ts`, pinned to Swift's by `runtime/test/fixtures/extension-ids.json` and `repository-folders.json`.
    `InstalledExtension` carries its `id` and its `repository` (`.raycast`, `.development`, `.added(folder)` or `.bundled`), both from where it was found, and `displayTitle` adds " (development)" or " (<folder>)".
    **The loader walks the layout** (`ExtensionWalk`, `InstalledExtension.load(walking:)`, which `all(in:)` uses).
    A top-level folder holding `package.json` itself is an unmoved install (below), loaded as Raycast's under its manifest name unless Raycast's folder has that id, which wins.
    Any other top-level folder without a dot is a GitHub owner (`raycast` and `fudgeapp` included): each of its folders is a repository's, and each folder in that holding `package.json` is an install.
    A top-level folder with a dot is a host: below it, the first folder holding `package.json` on each path is an install, at most seven folders down (six path segments and the extension).
    At every level, entries starting with `.` and links are skipped, and nothing is followed (`lstat`); a link at the top level gets a line in `Fudge.log`.
    An install loads only when its folder's name is its manifest's name and, outside Raycast's, its repository folder passes `isValid` (`fudgeapp/development` does), so each id is found once; the check is in the walk, not `load(from:)`, since the bundled extensions load from folders named differently.
    Each folder skipped gets one line in `Fudge.log`, naming it relative to the extensions folder, once per run (`ExtensionsFolderLog`).
    **The move into the layout** (`ExtensionLayout.moveIntoRepositories`, `ExtensionMove.swift`) files every install from before, at the top level, in `raycast/extensions/<manifest name>`, whether the store recorded it or not, so it keeps its name as its id, and with it its settings, data and sign-ins; it reads no store record.
    The app runs it at launch, before the extensions first load and before the watcher starts (`moveAtLaunch`, never in a snapshot run), and `fudge build` before it works out where the build goes, so a build never meets an unmoved install (a legacy `fudgeapp` one) on its way.
    Both take `<extensions>/.move.lock` first, polling `flock(LOCK_EX | LOCK_NB)` every 100 ms and never blocking: the app gives up after 5 s (`launchMoveWait`, since launch is on the main thread), writes one line and loads the extensions as they are; `fudge build` gives up after 60 s (`buildMoveWait`) with `BuildError.cantLock`.
    The lock goes back with `LOCK_UN` and then `close`, as the build's does, and `fudge build` gives it back before it takes its own.
    Each install moves by one `renamex_np` with `RENAME_EXCL`, so it's whole in one place or the other and keeps its inode and creation time; a target that's there already is never replaced, and the old folder stays with a line in `Fudge.log`, as does one whose manifest can't be read.
    A legacy install named `raycast` would land inside itself, so it's renamed to `.move-raycast` and filed from there before any other install, whatever their names, since the first one filed makes `raycast/extensions/`; every move finishes a `.move-raycast` it finds before anything else.
    One whose manifest can't be read is filed as `raycast`, since at the top it would keep `raycast/` from being Raycast's folder and every other install would stay.
    A move stopped halfway leaves both kinds, which both load, and the next launch moves the rest.
    `CommandOwner` (core) is a command id's owner, one of Fudge's groups (`BuiltInGroup`, the six `:` keys) or an `ExtensionID`, and `BundledCalls.mayCall` says whether a session's extension may make a call only one bundled extension makes, comparing whole ids.
    **Every keyed store and helper takes an `ExtensionID`**, never a `String` or `manifest.name`: the support, cache and LocalStorage folders (`FudgePaths`), `PreferenceStore`, `FormValueStore`, the dropdown values' key, `CommandMetadata`, `OAuthTokenStore` and `SignInCalls`, `LaunchPermissions`, `LogFile`, `InstallStamp` and the launcher's index (`InstalledExtension.index`).
    So a place that passes a manifest name to a store doesn't compile, and no app code makes an id from a name: a running session keeps its install's id (`LauncherModel.sessionExtensions`), as do the command screen and its notices.
    Command ids are made only by `FudgeSettings.commandID(owner:command:)` and `RootItem.commandID(owner:command:)`, which take a `CommandOwner`, as the Enabled functions do; `isEnabled(commandID:)` and `availableHotkeys` read the owner back with `CommandOwner(stored:)`, and an id whose owner is neither a group nor an id has only the command's own Enabled.
    `settings.json`'s `extensions` and `launch-permissions.json` read their keys as strings and keep those an owner or an id accepts; any other key is left out in memory and written back as the file has it.
    The only place an extension's manifest name stands for it is what it sees of itself, `environment.extensionName`: the launch message carries its id as `extensionId`, beside `environment`, and the host names its log lines by it without passing it to the worker.
    The calls only one bundled extension may make (`fudge.log`, `commandLineTools.*` and `store.*` for the Extension Store, `clipboardHistory.*`, `files.search`), and the checks for the store's own sessions, go through `BundledCalls.mayCall`, so an extension of the same name from another repository is refused like any other.
    Command names are letters of either case, digits, `.`, `-` and `_`, starting with a letter or digit, as Raycast accepts them (`caffeinateWhile`, `search-projects.command`): `ExtensionManifest.isValidCommandName`, which the build and `compatibility.json` use.
    The compatibility scan and the store share it as `isCommandName` (`scripts/compat/source-files.ts`), and `runtime/test/fixtures/command-names.json` pins both.
    A command's name keeps its case everywhere: its `src/<command>.…` file is found as the disk finds it (the Mac's usually ignores case), but its built file and its id are the name as written, and two commands whose names differ only in case are refused.
  - It writes the build into `.staging-<name>-<uuid>`, in the repository's folder beside the destination so the swap is a rename on one volume, with `package.json` and `assets/` alongside, then swaps the whole folder into place (a previous install is moved to `.old-<name>-<uuid>` first, then deleted).
    It replaces only a folder that holds what a build writes, hidden files aside (`ExtensionBuilder.holdsOnlyABuild`): `package.json`, `assets/`, `compatibility.json`, `dist/` (the old layout), and `<command>.cjs` for each command that folder's own `package.json` names, so an update that renames a command still replaces it; anything else is `BuildError.notAnInstall`.
  - **Installs from before SPEC-123** have their commands in `dist/`.
    At launch, right after the move into the layout and before the extensions first load and the watcher starts, the app moves each install the walk finds over (`ExtensionLayout.moveUp`, from `AppDelegate`; never in a snapshot run, and never the bundled extensions inside the app).
    Each `dist/<command>.cjs` is renamed up with `RENAME_EXCL`, never copied, so a command is whole in one place or the other, and then `dist/` goes with `rmdir`, only when it's empty.
    The compiled files are self-contained bundles, so moving them needs no rebuild.
    An install isn't touched unless it passes `holdsOnlyABuild`, and one whose `dist/` holds anything but regular `<command>.cjs` files its manifest names, or a command in both places, is left as it is, with one line in the unified log (category `extensions`, its folder relative to the extensions folder, private).
    `InstalledExtension.entry(for:)` finds a command at the root first, then in `dist/`, so a move stopped halfway or refused still launches every command, and the next launch finishes a stopped one.
    When a command is in both places, the root's wins and the `dist/` copy stays.
  - Before the swap it scans the source (`ExtensionBuilder.scanCommands`: the CLI runs `fudge scan --json` through `CompatScanner.commands`, reading its stdout alone) and writes which commands use Raycast AI or the Browser Extension into the install as `compatibility.json`.
    A scan that can't run or fails leaves it out, and every command is on.
  - It never writes into the source folder.
    When the source has no `node_modules`, it installs the dependencies into a temporary folder (`npm ci --ignore-scripts`; under `$TMPDIR` when it's set, which Foundation's `temporaryDirectory` ignores) and points esbuild at it with `nodePaths`, which stands for the command line's `NODE_PATH`.
  - **Ending the tool ends what it started.**
    `fudge build` and `fudge scan` run every program (esbuild, npm, node) through `ChildProcesses` (core): `posix_spawn` in a process group of its own, with default signals and only stdin, stdout and stderr passed on.
    On SIGTERM, SIGINT or SIGHUP the tool signals each child's whole group, so npm's and node's own children go too, waits up to a second, kills what's left, deletes `fudge build`'s staging and scratch folders, which `defer` would miss (`ChildProcesses.deleteOnSignal`; not a staging folder already being moved into place), and exits with 128 + the signal (`ChildProcesses.endChildrenOnSignals`).
    That's what makes the Extension Store's timeouts, which send SIGTERM, end the whole job.
  - Extensions live in `FudgePaths.extensionsDirectory`: `~/Library/Application Support/fudge/extensions`, or under `$FUDGE_SUPPORT_DIR`.
  - **The running app picks it up.**
    `ExtensionsWatcher` (core) watches the extensions folder through FSEvents, with file-level events.
    Its stream is made, started, stopped and released on a serial queue of its own, which it delivers on, never on the main thread, since each of those calls asks `fseventsd`, which can take seconds or not answer (FUD-153); `start` and `stop` return at once, and a batch goes on to the main queue.
    FSEvents reports nothing from before the stream exists, so the stamps of every folder an install can land in (`FolderStamps`: each folder's `FolderStamp`, its modification time and inode) are read at `start` and again once the stream has started, and a difference counts as a batch for the folder (FUD-156).
    Those folders are the top, `raycast/extensions`, `fudgeapp/development` and every folder the walk reads on its way to an install, since an install renamed into `raycast/extensions/` changes that folder's time, not the top one's; a folder added or gone differs too.
    A test that counts reloads waits for the stream's queue first (`streamStarted`, with a deadline), then for the watcher to go quiet.
    A path counts unless any of its components under the folder starts with `.` (`.staging-*`, `.old-*`, the locks and `.DS_Store`), in a repository's folder as at the top.
    A trailing 0.3 s debounce makes each install, rebuild or removal one reload: `LauncherModel.reloadExtensions()` (the installed extensions only, keeping the scanned applications, the query and the selection), the command hotkeys, and the Settings window if it's open.
    A first build into a repository folder that doesn't exist yet can be two reloads, since it makes the folder before it compiles and the compile can outlast the debounce.
    The menu's Reload Extensions also scans applications again.
    Snapshot runs don't watch.
- **The Makefile assembles the app bundle** (`make app`):
  - the `FudgeApp` binary becomes `Contents/MacOS/Fudge`
  - the `fudge` tool and esbuild's native binary go into `Contents/Helpers/`, where `ExtensionBuilder.locateEsbuild` finds esbuild next to the tool
  - `fudge build`'s compile step (`runtime/dist/bundle-extension.cjs`) goes into `Contents/Resources/runtime/`, before the bundled extensions are built through it
  - `Fudge Links.app` goes into `Contents/Helpers/` too, the `FudgeLinks` binary with `App/Links/Info.plist` and Fudge's versions: a nested app there is registered by nothing but `LSRegisterURL` on it (one in `Contents/Library/LoginItems` is registered at every launch)
  - **Node.js** (SPEC-115): an official build from nodejs.org, `NODE_VERSION` in the `Makefile`, for the architecture the Mac builds for (arm64 or x64, never both: the app itself is built for one).
    Its tarball's SHA-256, copied from the release's `SHASUMS256.txt`, is pinned beside the version, and `make` checks it before unpacking anything; a tarball that doesn't match is deleted, and the build fails.
    It's downloaded once into `.cache/node` (ignored, and kept by `make clean`), and every Node step of the build runs it (`npm ci`, esbuild, the runtime's tests), since the `Makefile` puts it first on `PATH`.
    To update it, change the version and both checksums together.
    The bundle gets the binary as `Contents/Helpers/node`, npm from the same distribution as `Contents/Resources/node/npm`, and its `LICENSE` (Node.js's, with what it bundles) as `Contents/Resources/node/LICENSE`.
    `fudge build` runs npm as `node npm-cli.js` (`BundledNode.npm`), with the helpers first on `PATH` so whatever npm starts gets the same Node.js.
    Its entitlements are in `App/Helpers/node.entitlements`, which `scripts/sign-app.sh` gives it (below), so a release's Developer ID signature keeps them: `allow-jit`, without which V8 can't start, and `disable-library-validation`, without which an extension's native addon (`.node`), signed by whoever built it, is refused ("different Team IDs").
  - `App/Info.plist` gets three versions from `git describe --tags --always --dirty` (`VERSION`, which the release workflow sets to the version it releases, or `RELEASE_TAG`):
    `CFBundleShortVersionString` is the version tag's major, minor and patch, as macOS expects (`runtime/scripts/bundle-version.ts`: `v0.3.0-14-ga539cdd` is `0.3.0`, and with no version tag `0.0.0`), `CFBundleVersion` is `git rev-list --count HEAD`, and `FudgeGitDescribe` is the describe itself.
    Fudge shows its own form of the describe (`FudgeVersion.display`: `0.3.0`, `1.2.0-rc.1`, or after a tag `0.3.0-dev+14.a539cdd.dirty`), in the menu, General's update row, About, `fudge version` and its `User-Agent`s.
    `FudgeVersion` (core) reads the keys in the app, and in the `fudge` tool from the app's `Info.plist` beside `Contents/Helpers` (through a symlink too), only when its bundle id is Fudge's; anywhere else it's `0.0.0-dev`.
    **A release build stops rather than number itself wrong** (`make release-check`, before anything is built): with `CONFIG=release`, a shallow clone, which has no tags and would make the build number 1; with `RELEASE_TAG`, a tag that isn't on this commit.
    The release workflow checks out the whole history and its tags, and passes the version it releases as `VERSION` (`scripts/release.sh --version`), since its tag doesn't exist until the release is published.
  - `App/AppIcon.icon` (an Icon Composer icon) is compiled by `actool` into `Assets.car` and an `AppIcon.icns` fallback.
    That needs Xcode 26 or later.
  - the bundled extensions (`BUNDLED_EXTENSIONS`, as `BundledExtensions.folders` lists them) are built with `fudge build` from `runtime/<folder>` into a scratch folder's `fudgeapp/development/`, without `--repository`, and moved from there to `Contents/Resources/<folder>`
  - the host and worker bundles go into `Contents/Resources/runtime/`, with `fudge scan`'s `compat-scan.js` and Raycast's types beside it (`raycast-api.d.ts`, with its MIT notice as `raycast-api.LICENSE`)
  - Fudge's `LICENSE` goes into `Contents/Resources/LICENSE.txt`, and `runtime/scripts/notices.ts --text` writes `Contents/Resources/Third-Party Notices.txt`: each third-party component the app ships, with its version and its own license file's text.
    Its `components` list is the one place they're named, and the repo's `THIRD-PARTY-NOTICES.md` is the same, written by `npm run generate`.
    Node.js's entry is the `LICENSE` of the Node.js the `Makefile` pins (`NODE_VERSION`), read from `.cache/node`: the same file `make app` copies to `Contents/Resources/node/LICENSE`.
    `npm run typecheck` fails while that file is stale, or when a bundle Fudge ships (the host, the worker, `compat-scan.js`, a bundled extension) takes in an npm package the list doesn't have; anything else the app ships, such as a binary in `Helpers/`, adds its entry by hand.
  - with `CONFIG=release`, `strip -S -x` takes the debug and local symbols out of `Contents/MacOS/Fudge`, `Contents/Helpers/fudge` and Fudge Links' executable, which otherwise name the builder's folders (`/Users/…`, about 300 paths each) and double their size
  - `scripts/sign-app.sh` signs it inside-out, each item in `Contents/Helpers` (the `fudge` tool, esbuild, Node.js and Fudge Links), then the app with `App/Fudge.entitlements`, all with the hardened runtime (FUD-44).
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
    And `signIn` (SPEC-132 §7): the `OAuth.RedirectMethod`s the extension's own code names, its authorize URLs (`authorizeUrl` in an object, as `OAuthService` takes it, and `endpoint` in `authorizationRequest({ … })`), and whether any was left unresolved.
    A URL is resolved through string literals, templates, sums and constants declared in any of its files (`resolveString`); one from a preference, a parameter, a call or a name with two values is unresolved.
    It's a pattern search, so an extension that picks its URL in a way the scan doesn't read could be missed.
    A command is traced from its entry (`src/<name>.{tsx,ts,jsx,js}`, as the build finds it) through every import esbuild leaves, re-exports, `import()` and `require` included (`imports`), resolved among the files the scan read, ignoring case as APFS does (`resolveImport`): relative paths, `@/…` and `~/…` as `src/…`, and TypeScript's `./x.js` for `x.ts`.
    A bare import is a package's only when the manifest lists that package in any of its dependency sections, it's one of Node's built-ins, or the host provides it (`packages`), and a data file (`.json`, `.css`, an image) can't reach the API.
    A `rust:` import counts as a package's too, with nothing to follow, since the build writes its module from the Rust sources (SPEC-144).
    So does a `swift:` import (SPEC-145 §3): its module runs a program or refuses, and holds none of the extension's JavaScript.
    The report names the `swift:` imports (`swiftParts`), which the store reads.
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
- **Fudge.app declares no URL schemes** (D-107).
  Spotlight registers a new build in an indexed folder within seconds, and it then claims its schemes; any launch of it (`make run`, a snapshot run, a probe) makes it the app that opens them.
  Raycast's schemes are declared only by Fudge Links, which only the user's click registers.
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
  A pool that's full for good can still stop the run, so CI's 15-minute job timeout is the last net.
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
  CI has no identity and stays ad hoc; a release is signed again with the Developer ID identity (see Branches, CI and releases).
  No certificate, key, name or team ID ever goes into the repo.
- **The hardened runtime refuses a protected resource without its entitlement**, with no prompt, whatever the user allowed.
  `App/Fudge.entitlements` has what Fudge and its extensions may use, each with a comment: Apple Events (Finder, System Events, the login window and extensions' AppleScript), Calendars (My Schedule's EventKit, and extensions' events and reminders), and, for extensions only, Contacts, location, Photos, the camera and the microphone (SPEC-151).
  Fudge starts extensions' processes and never disclaims them, so macOS counts their requests as Fudge's, and one answer for Fudge covers every extension.
  Each has the text macOS asks with in `App/Info.plist`; Bluetooth has no hardened-runtime entitlement, only its text (`NSBluetoothAlwaysUsageDescription`).
  Nothing asks for them at launch: macOS asks when an extension first uses one, and My Schedule asks for Calendars.
  `AppPermissionsTests` pins both files' keys and texts, so changing either means changing the test too.
  A feature that starts using another protected resource adds its entitlement and its text in the same change.
  Accessibility, Input Monitoring, Screen Recording and Full Disk Access are permissions the user grants, with no entitlement.
- **The local-network check reads the URL, not DNS.**
  A public name that resolves to a private address isn't caught. https mostly covers it, since a LAN device rarely has a certificate for a public name.
- **AppKit draws nothing inside an SVG `<a>` element**, so `RemoteImageDecoder.svgForDrawing` unwraps links before `NSImage(data:)` sees the SVG.
- **Tests must not touch the user's system.**
  Never trash, open, copy, read the selection, post key events or send Apple Events for real in a test, and smoke-run extensions with a throwaway `HOME`: commands do what they say.
- **Swift tests that build extensions need esbuild** from `runtime/node_modules`, and Fudge's Node.js (`FUDGE_TEST_NODE`), with which they make the compile step once, as it ships (`Fixtures.bundler`).
  `make test` gives both; without them, `swift test` skips those tests.
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
- **Fudge has no fixes for particular extensions** (D-83).
  When an extension misbehaves, first check whether Fudge differs from Raycast's documented behaviour.
  If it does, the fix goes in Fudge's implementation of `@raycast/api` (`runtime/src/api/`, or the app code behind it, such as the window calls), applies to every extension, and stays compatible with Raycast.
  If it doesn't, the bug is the extension's, and Fudge changes nothing: no special case, setting or workaround keyed on any extension's name, owner or files, wherever it came from (Fudge's bundled extensions aside, see below).
  **The one exception is sign-in** (D-84).
  The sign-in table (`OAuthProviders`) sends Raycast's sign-in addresses to the relay: GitHub, Linear, Slack and Asana, which `OAuthService` uses by default, and Jira and Zoom, which only the store's Jira and Zoom extensions set.
  It also sends Notion's, Todoist's, WHOOP's and Miro's proxies, and the shared-proxy addresses of seventeen store extensions, which only those extensions set (FUD-166).
  Every other `*.oauth.raycast.com` address is refused (see "The fetch rewrite" above).
  A new entry in that table is built from a reviewed spec like any other change, and needs an app on the relay before its sign-in works.
  Fudge's bundled extensions (the Extension Store, Search Files, Search Emoji & Symbols and Clipboard History, in `runtime/`) are Fudge's own code: changing them isn't a fix for an extension, and Fudge's own code may name them and give them what other extensions don't get.
- **Docs are one sentence per line.**
  In `CLAUDE.md` and `README.md`, start each sentence on a new line, and add an item to a list as its own line, so two changes rarely touch the same line.
  `make lint` fails on a line over 400 characters outside code blocks and tables.
- **The product's name is Fudge**, capitalized, in all text people read.
  `fudge` is only the CLI command, paths, env variables and identifiers.
- **No em dash (U+2014) in Fudge's text**: write a colon or a comma instead, and join two parts of a message with `MessageText.joined`.
  `make lint` fails on one in any file git tracks or would track, except Unicode's own data in `runtime/vendor/`; the en dash in ranges such as "09:00 – 09:30" stays.

## Branches, CI and releases

- **All work is based on and goes into `development`.**
  Open every pull request with `--base development`: `mainline` is the default branch, so a pull request without it targets `mainline`.
  Never open a pull request into `mainline` yourself.
- **`mainline` changes only by a release**, in four steps, with the maintainer's yes before the second and the fourth:
  1. The maintainer is asked: release `vX.Y.Z` from a `development` commit?
     The version is `scripts/next-version.sh <commit>`'s, run locally.
  2. On a yes, `release/vX.Y.Z` is pushed at exactly that commit, and its pull request into `mainline` opened.
     CI runs on it once, and the reviewer runs `make lint` and `make test` locally at that commit.
  3. When CI is green and the pull request approved, the maintainer is asked: merge, and so publish `vX.Y.Z`?
  4. On a yes, it's merged with a merge commit (never a squash or a rebase) and GitHub's own title for it, `Merge pull request #N from jakeobsen/release/vX.Y.Z`, which starts the release, and `release/vX.Y.Z` is deleted.
- **A release branch is never pushed to again** once it's created: no merge from `development`, no fix.
  If CI is red, the pull request is closed and the branch deleted, nothing is published, and the fix goes into `development` and a later release.
- **GitHub Actions run only on a release's pull request into `mainline` (CI) and on its merge (the release)**, because macOS runners cost money.
  Never run, re-run or dispatch a workflow by hand, and never add another trigger.
  The one other workflow, "Update GeoNames database" (the calculator's places), runs on Linux and only when the repository's owner starts it.
  Pull requests into `development` run nothing: their builder and the reviewer run `make lint` and `make test` locally.
- **The version is worked out, never written down.**
  `scripts/next-version.sh [<commit>]` prints the next version, with its `v`, from the conventional commit subjects since the highest `v1.2.3` tag in the commit's history, merges left out:
  a breaking change (`type!:`, or a `BREAKING CHANGE:` or `BREAKING-CHANGE:` footer) bumps the major version from 1.0.0 on and the minor below it, otherwise a `feat` the minor, otherwise the patch.
  With no release yet it's `v0.1.0`, and with nothing since the last one, or in a shallow clone, it fails.
  Commit subjects must stay conventional, since they decide the version.
  A release's tag is on its release commit, which is in `development`, so `git describe` there finds it; `runtime/test/next-version.test.ts` tries the script in throwaway repositories.
- **CI** (`.github/workflows/ci.yml`) runs on pull requests into `mainline` only, in three jobs:
  - **`release-branch`** (Linux, seconds) fails unless the head is this repository's `release/vX.Y.Z` (both passed through `env:`), so a pull request into `mainline` from anything else never starts a macOS runner and can't merge.
  - **`macos`** runs `make lint` and `make test`, capped at 15 minutes (`timeout-minutes`), so a hang fails the job instead of holding a paid runner.
    `swift test` compiles every target, so the app's code is checked, but the app bundle is not assembled.
  - **`test`** (Linux) always runs and passes only when both did, since a skipped job counts as passed.
    It's the check `mainline`'s ruleset requires, so its name stays `test`.
- **The release workflow** (`.github/workflows/release.yml`) is the only place a release is built, and it runs on a push to `mainline`, a release's merge.
  No one pushes a `v*` tag: the workflow creates it, on the release commit, once everything has passed.
  Runs never overlap (`concurrency`), and if any job fails, nothing is published and there's no tag.
  Three jobs:
  - **`version`** (Linux, 3 minutes at most, the whole history): the pushed commit must be a merge whose tree is its second parent's, the release commit's, so what's published is what CI and the reviewer tested.
    `scripts/next-version.sh` names the version from the release commit, and the run stops if it fails, if the merge's title isn't GitHub's for `release/<that version>` (so the version published is the one the maintainer said yes to, and a merge of any other branch never publishes), or if that tag exists.
  - **`build`** (macOS, 30 minutes at most, a read-only token) checks out the release commit itself, with the whole history, so its build number is the one any later build of the tag gets.
    It runs `make test`, then `scripts/release.sh --version <version>` and a `.sha256`, uploaded as an artifact.
    The tag doesn't exist yet, so the version goes to `make` as `VERSION`, in the tag's form (`v0.2.0`), and the app and the disk image show it as a tag build would.
    `release.sh` refuses a bare `0.2.0`, which the app would show as 0.0.0, and takes anything else `git describe` gives, as `make release` passes it (`runtime/test/release-version.test.ts`).
    In jakeobsen/fudge, missing signing secrets fail it; a fork, which has none, gets an ad hoc build (`--ad-hoc-without-secrets`).
  - **`publish`** has the only write token, and runs none of the repo's code: it runs `gh release create <version> --target <release commit>`, which creates the tag with the Release, with GitHub's generated notes and one line on opening the app, which depends on how `build` signed it (its `signing` output).
    The "Release Tags" ruleset must let the workflow's token create `v*` tags, or this last step is refused.
    Before that, a step copies the one `Fudge-<version>.dmg` as `Fudge.dmg` and writes its checksum, `Fudge.dmg.sha256`, so the release attaches both too; with no image or more than one, it fails and nothing is published.
    The website's Download button links to `https://github.com/jakeobsen/fudge/releases/latest/download/Fudge.dmg`, which GitHub sends to that file in the newest full release.
    So the name `Fudge.dmg` must never change, or the button breaks.
    **The first release** gets that line and the hand-written `.github/first-release-notes.md` instead of generated notes, which would list every pull request so far (SPEC-117 §5).
    `build` decides it (its `first` output) with `scripts/first-release.sh <version>`: a version is the first when no full release (`v1.2.3`, no pre-release suffix) other than itself is in its history (`git tag --merged HEAD`).
    That needs the whole history, so a shallow checkout fails the step rather than guess; `build` then uploads the file as a second artifact, `notes`.
    The step only runs in a release, so `runtime/test/first-release.test.ts` tries the script in throwaway repositories.
  - **The secrets are the `release` environment's**, not the repository's: only `mainline` may use that environment, and only `build` names it, so no workflow on another branch or a tag can read them, one an unreviewed branch adds included.
    Never add them as repository secrets again.
- **Release signing** (`scripts/release.sh`, FUD-44) reads five secrets, which the workflow gives to that one step only:
  - `APPLE_CERTIFICATE_BASE64`: the Developer ID Application certificate with its private key, a `.p12` in base64
  - `APPLE_CERTIFICATE_PASSWORD`: the `.p12`'s password
  - `APPLE_ID` and `APPLE_APP_SPECIFIC_PASSWORD`: the Apple Account that notarizes, and an app-specific password of it
  - `APPLE_TEAM_ID`: the identity's team

  It builds the app ad hoc first (`make app`), with none of them in its environment, so no code the build runs can reach them.
  Then it imports the certificate into a keychain of its own in a temporary folder, its key usable by codesign alone and not exportable, deleted however the script ends.
  It signs again with the Developer ID identity (`scripts/sign-app.sh`), notarizes the app with `notarytool` and staples it, makes the disk image from it (`make dmg-image`), signs, notarizes and staples that, and checks both with `spctl`.
  Both signings take the identity from that keychain alone (`codesign --keychain`, `sign-app.sh`'s third argument), so on a Mac whose login keychain has the same Developer ID, `make release` neither finds it twice nor asks for that key's password.
  It never prints a secret or the identity's name: the tools' output shows only when one fails, with those values as `***`.
  Notarization waits 10 minutes at most for each submission (`notarytool --timeout 10m`), so a stuck one fails the release rather than hold a paid runner.
  Without any of the five, a fork's release is built ad hoc (`--ad-hoc-without-secrets`), and its notes say so; anywhere else that's a failure, as is any run with only some of them.
- **`make release`** does the same on the maintainer's Mac, for a release built without CI, after `secret env apple`, which sets the same five variables.
  It refuses a tree with changes, never pushes or tags, and writes no secret to disk but the temporary keychain.
  `make release RELEASE_TAG=<tag>` builds that tag's release (`--tag`), and without it the version is `git describe`'s (`--version`).
  It's for a build by hand: a published release always comes from the release workflow.
- **Dev builds** still sign with the Apple Development identity (or "fudge local signing", or ad hoc; see `make app`), so only a release has the Developer ID, and switching between the two asks for permissions again.
- **`make dmg`** builds the app, then `build/Fudge-<version>.dmg` (the version without its `v`) with `make dmg-image`, which packs the app as it is: the app and a link to `/Applications`, UDZO, volume name Fudge.
  `make dmg-image` builds only `FudgeDiskImage`, never the app, and runs `scripts/disk-image.sh`, so the notarized and stapled app the release script hands it goes in untouched.
  **The Finder window** (SPEC-150): 600 × 400 points of content, icon view with no toolbar, sidebar or status bar, Fudge on the left and Applications on the right at 128 points, over a light picture with an arrow between them.
  It's all in the volume's `.DS_Store`, which `FudgeDiskImage layout` writes (`DiskImageLayout`, `DSStore`, `AliasRecord` in core), so nothing scripts Finder, and a build machine with no one logged in makes the same image.
  The script makes a writable HFS+ image from a staging folder, mounts it `-nobrowse -noautoopen` at `build/dmg/mount`, so no Finder window opens, lets the tool write the layout, detaches it (tried 5 times, then forced) and compresses it; a trap detaches and deletes the scratch image however it ends.
  HFS+ rather than APFS is Apple's advice for a disk image whose window has a background picture, which older macOS doesn't show from APFS.
  The picture is `.background/background.tiff` on the volume, a TIFF with the 1× and 2× images (`App/DiskImage/background.tiff`, which `FudgeDiskImage background <file>` draws from `DiskImageBackground`); Finder finds it through an alias record in the icon view's settings.
  That alias is written by `AliasRecord` itself, from the volume's name and the path on it: one from `FSNewAliasFromPath`, or a bookmark from `URL.bookmarkData` (the `pBBk` record Finder adds on a writable volume), names the disk image file it was made in, so a published image would carry the build folder's path.
  `WindowBounds` sets the window's whole frame, title bar included (32 points on macOS 26, 28 before), from the bottom left of the screen.
  Finder draws the names under the icons dark over a background picture, in dark mode too, which is why the picture is light.
- **Linting the workflows:** actionlint isn't in CI; run it by hand after changing one: `go run github.com/rhysd/actionlint/cmd/actionlint@v1.7.12 .github/workflows/*.yml`.
