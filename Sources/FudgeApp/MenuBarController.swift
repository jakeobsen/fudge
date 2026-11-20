import AppKit
import FudgeCore

/// The active menu-bar commands (SPEC-004 B): each draws its `MenuBarExtra` as one `NSStatusItem` with an `NSMenu`.
///
/// `MenuBarLifecycle` (core) decides when a command loads and unloads; this turns its decisions into launches,
/// unloads, timers and menus. `LauncherModel` owns the extension host: it starts the controller's commands
/// (`Host.launch`) and routes their sessions' `render`, `error`, `eventSettled` and `exit` here.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    /// What the controller needs from the app.
    struct Host {
        /// Starts a command in the extension host. Returns its session, or why it couldn't start.
        var launch:
            (InstalledExtension, ExtensionManifest.Command, _ userInitiated: Bool) -> Result<String, LaunchFailed>
        var send: (AppMessage) -> Void
        var showHUD: (String) -> Void
        var log: (_ session: String, _ level: String, _ message: String) -> Void
    }

    struct LaunchFailed: Error {
        var message: String
    }

    /// One active command.
    private final class Active {
        let id: String
        var installed: InstalledExtension
        var command: ExtensionManifest.Command
        var lifecycle = MenuBarLifecycle()
        /// The last tree rendered, kept after the command is unloaded.
        var content: MenuBarContent?
        /// The session `content` came from.
        var contentSession: String?
        var statusItem: NSStatusItem?
        let menu = NSMenu()
        var timer: Timer?
        /// Picks made in a tree whose instance is gone, waiting for the new instance's first render.
        var picks: [(path: MenuBarPath, title: String, event: String)] = []

        init(id: String, installed: InstalledExtension, command: ExtensionManifest.Command) {
            self.id = id
            self.installed = installed
            self.command = command
            menu.autoenablesItems = false
        }
    }

    /// What a menu item picks: the item of a tree, in the session that drew it.
    private final class PickTarget: NSObject {
        let commandID: String
        let session: String?
        let item: MenuBarItem

        init(commandID: String, session: String?, item: MenuBarItem) {
            self.commandID = commandID
            self.session = session
            self.item = item
        }
    }

    var host = Host(
        launch: { _, _, _ in .failure(LaunchFailed(message: "not connected")) }, send: { _ in },
        showHUD: { _ in }, log: { _, _, _ in })

    private let paths: FudgePaths
    private var store: MenuBarStore
    private var active: [String: Active] = [:]
    /// The command id of each running session.
    private var sessions: [String: String] = [:]
    /// The installed menu-bar commands, by command id.
    private var installed: [String: (InstalledExtension, ExtensionManifest.Command)] = [:]
    /// `settings.json`, for which commands are enabled.
    private var settings = FudgeSettings()
    /// Snapshots never start: they put nothing in the menu bar.
    private var started = false

    init(paths: FudgePaths) {
        self.paths = paths
        store = MenuBarStore.load(from: paths.menuBarFile)
    }

    // MARK: - Activating

    /// Whether the command is active in the menu bar.
    func isActive(_ id: String) -> Bool { store.isActive(id) }

    /// Whether `session` is one of the menu bar's.
    func owns(_ session: String) -> Bool { sessions[session] != nil }

    /// Takes in the installed extensions and the settings: at launch, on Reload Extensions and after each change in
    /// Settings. Commands that are no longer installed are deactivated; the others pick up their new manifest. A
    /// disabled command leaves the menu bar and stops refreshing, but stays active (`MenuBarStore.shown`), so turning
    /// it back on puts it back, loading in the background.
    func update(installed extensions: [InstalledExtension], settings: FudgeSettings) {
        self.settings = settings
        installed = [:]
        for installedExtension in extensions {
            for command in installedExtension.manifest.commands where command.mode == "menu-bar" {
                let id = FudgeSettings.commandID(extension: installedExtension.manifest.name, command: command.name)
                installed[id] = (installedExtension, command)
            }
        }
        if store.prune(keeping: Set(installed.keys)) { save() }
        let shown = Set(store.shown(installed: Set(installed.keys), settings: settings))
        for (id, item) in active {
            guard shown.contains(id), let (installedExtension, command) = installed[id] else {
                remove(item)
                continue
            }
            let intervalChanged = command.interval != item.command.interval
            item.installed = installedExtension
            item.command = command
            if intervalChanged { schedule(item) }
        }
        if started { showMissing() }
    }

    /// Puts the active commands in the menu bar, each loading in the background. Called once, by the app.
    func start() {
        started = true
        showMissing()
    }

    /// Puts each command `MenuBarStore.shown` names, and that isn't there yet, in the menu bar, loading it in the
    /// background as at fudge's start.
    private func showMissing() {
        for id in store.shown(installed: Set(installed.keys), settings: settings) where active[id] == nil {
            guard let item = makeActive(id) else { continue }
            run(item, .startup)
        }
    }

    /// Runs a menu-bar command from root search or a hotkey: activates it, or refreshes it and opens its menu
    /// when it's active already. Throws `MenuBarStore.LimitReached` at the 51st.
    func runFromRootSearch(_ id: String) throws {
        guard started else { return }
        let wasActive = store.isActive(id)
        guard let item = try activate(id) else { return }
        run(item, .rootSearch)
        if wasActive, let button = item.statusItem?.button {
            // After the panel has gone: the menu runs its own event loop until it closes.
            DispatchQueue.main.async { button.performClick(nil) }
        }
    }

    /// `launchCommand` of a menu-bar command: Background refreshes it like an interval tick (it must be active,
    /// which `CommandLocator.checkMode` checked); UserInitiated activates it if needed and refreshes it, without
    /// opening its menu.
    func launchCommand(_ id: String, userInitiated: Bool) throws {
        guard started else { return }
        guard let item = userInitiated ? try activate(id) : active[id] else { return }
        run(item, .launchCommand(userInitiated: userInitiated))
    }

    /// Removes the command's item and unloads it. Throws `MenuBarStore.Unreadable` when `menu-bar.json` can't be
    /// read, leaving everything as it is: the change couldn't be saved.
    func deactivate(_ id: String) throws {
        guard MenuBarStore.isWritable(paths.menuBarFile) else { throw MenuBarStore.Unreadable() }
        store.deactivate(id)
        save()
        if let item = active[id] { remove(item) }
    }

    private func activate(_ id: String) throws -> Active? {
        // Root search, hotkeys and launchCommand already leave disabled commands out.
        guard settings.isEnabled(commandID: id) else { return nil }
        if !store.isActive(id) {
            // An activation that couldn't be saved would be gone at the next launch, so it's refused.
            guard MenuBarStore.isWritable(paths.menuBarFile) else { throw MenuBarStore.Unreadable() }
            try store.activate(id)
            save()
        }
        return active[id] ?? makeActive(id)
    }

    private func makeActive(_ id: String) -> Active? {
        guard let (installedExtension, command) = installed[id] else { return nil }
        let item = Active(id: id, installed: installedExtension, command: command)
        item.menu.delegate = self
        active[id] = item
        schedule(item)
        return item
    }

    private func remove(_ item: Active) {
        item.timer?.invalidate()
        if let statusItem = item.statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        if let session = item.lifecycle.session { unload(item, session) }
        active[item.id] = nil
    }

    private func save() {
        do {
            try store.save(to: paths.menuBarFile)
        } catch {
            host.log("menu-bar", "error", "couldn't save \(paths.menuBarFile.path): \(error)")
        }
    }

    /// The manifest `interval`, in the `.common` run-loop mode so it also fires while a menu is open.
    private func schedule(_ item: Active) {
        item.timer?.invalidate()
        item.timer = nil
        guard let seconds = MenuBarInterval.seconds(item.command.interval) else { return }
        let id = item.id
        let timer = Timer(timeInterval: seconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let item = self.active[id] else { return }
                self.run(item, .interval)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        item.timer = timer
    }

    // MARK: - Loading

    private func run(_ item: Active, _ trigger: MenuBarLifecycle.Trigger) {
        guard case .launch(let userInitiated) = item.lifecycle.request(trigger) else { return }
        launch(item, userInitiated: userInitiated)
    }

    private func launch(_ item: Active, userInitiated: Bool) {
        switch host.launch(item.installed, item.command, userInitiated) {
        case .success(let session):
            sessions[session] = item.id
            item.lifecycle.launched(session, userInitiated: userInitiated)
        case .failure(let failure):
            item.lifecycle.launchFailed()
            item.picks.removeAll()
            host.log(item.id, "error", "couldn't start \(item.id): \(failure.message)")
            if userInitiated { host.showHUD("\(item.command.title) failed — \(failure.message)") }
        }
    }

    private func unload(_ item: Active, _ session: String) {
        host.send(.unload(session: session))
    }

    /// Unloads the command once it's done (`MenuBarLifecycle.takeUnload`).
    private func unloadIfDone(_ item: Active) {
        if let session = item.lifecycle.takeUnload() { unload(item, session) }
    }

    // MARK: - The host's messages

    /// A message about one of the menu bar's sessions (`owns`).
    func handle(_ message: HostMessage) {
        guard let session = message.session, let id = sessions[session] else { return }
        let item = active[id]
        switch message {
        case .render(_, let view, _):
            guard let item else { return }
            let first = !item.lifecycle.hasRendered
            let content = MenuBarContent(view)
            guard item.lifecycle.rendered(session, isLoading: content?.isLoading ?? false) else { return }
            item.content = content
            item.contentSession = session
            draw(item)
            if first { sendQueuedPicks(item, session: session) }
            unloadIfDone(item)

        case .error(_, let message, _, let fatal):
            guard let item else { return }
            if fatal {
                if item.lifecycle.failed(session) {
                    host.showHUD("\(item.command.title) failed — \(message)")
                }
                draw(item)
                unloadIfDone(item)
            } else if item.lifecycle.isUserInitiated, item.lifecycle.session == session {
                host.showHUD("\(item.command.title) failed — \(message)")
            }
            if fatal { dropPicksUnlessAwaited(item, session: session) }

        case .eventSettled:
            guard let item else { return }
            item.lifecycle.eventSettled(session)
            unloadIfDone(item)

        case .exit:
            sessions[session] = nil
            guard let item else { return }
            let next = item.lifecycle.exited(session)
            if item.lifecycle.lastRefreshFailed { draw(item) }
            if let next { launch(item, userInitiated: next.isUserInitiated) }
            dropPicksUnlessAwaited(item, session: session)

        default:
            break
        }
    }

    /// The extension host stopped: every instance is gone. Their items keep their last trees.
    func hostStopped() {
        let stopped = sessions
        sessions.removeAll()
        // Picks made before the host stopped are never replayed into whatever starts next.
        for item in active.values where !item.picks.isEmpty { dropPicks(item, session: nil) }
        for (session, id) in stopped {
            guard let item = active[id], let next = item.lifecycle.exited(session) else { continue }
            launch(item, userInitiated: next.isUserInitiated)
        }
    }

    // MARK: - Picking

    /// Picks made in the last tree before the new instance rendered: matched to its first tree by position and
    /// title, else dropped.
    private func sendQueuedPicks(_ item: Active, session: String) {
        let picks = item.picks
        item.picks.removeAll()
        for pick in picks {
            if let match = item.content?.item(matching: pick.path, title: pick.title) {
                sendAction(item, session: session, node: match.node, event: pick.event)
            } else {
                host.log(
                    session, "info", "dropped a pick of \"\(pick.title)\" (\(pick.path)): it's not in the new menu")
            }
        }
    }

    /// Drops the picks waiting for a first render once no instance is still to render one
    /// (`MenuBarLifecycle.awaitsFirstRender`), so a later launch never runs them.
    private func dropPicksUnlessAwaited(_ item: Active, session: String) {
        if !item.picks.isEmpty, !item.lifecycle.awaitsFirstRender { dropPicks(item, session: session) }
    }

    private func dropPicks(_ item: Active, session: String?) {
        let titles = item.picks.map { "\"\($0.title)\"" }.joined(separator: ", ")
        item.picks.removeAll()
        host.log(session ?? item.id, "info", "dropped picks of \(titles): no instance is still to render them")
    }

    private func sendAction(_ item: Active, session: String, node: Int, event: String) {
        item.lifecycle.eventSent(session)
        host.send(.event(session: session, node: node, path: ["onAction"], args: [.object(["type": .string(event)])]))
    }

    @objc private func picked(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? PickTarget, let item = active[target.commandID] else { return }
        let event = NSApp.currentEvent
        let isRight =
            event?.type == .rightMouseUp || event?.type == .rightMouseDown
            || event?.modifierFlags.contains(.control) == true
        let type = isRight ? "right-click" : "left-click"
        if let session = target.session, item.lifecycle.isLive(session) {
            sendAction(item, session: session, node: target.item.node, event: type)
        } else if item.lifecycle.awaitsFirstRender {
            item.picks.append((target.item.path, target.item.title, type))
        } else {
            host.log(item.id, "info", "dropped a pick of \"\(target.item.title)\": the command isn't running")
        }
    }

    // MARK: - The menu

    func menuWillOpen(_ menu: NSMenu) {
        guard let item = active.values.first(where: { $0.menu === menu }) else { return }
        item.lifecycle.menuOpened()
        run(item, .click)
    }

    func menuDidClose(_ menu: NSMenu) {
        guard let item = active.values.first(where: { $0.menu === menu }) else { return }
        item.lifecycle.menuClosed()
        // On the next turn: a pick's action is sent after the menu closes, and must count as running first.
        let id = item.id
        DispatchQueue.main.async { [weak self] in
            guard let self, let item = self.active[id] else { return }
            self.unloadIfDone(item)
        }
    }

    /// Draws the item and its menu from the last tree. A command with nothing to show has no item.
    private func draw(_ item: Active) {
        guard let content = item.content, !content.isEmpty else {
            if let statusItem = item.statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            item.statusItem = nil
            return
        }
        let statusItem = item.statusItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if item.statusItem == nil {
            // Its own name, so it keeps its own position, and shown: an item only exists while its command is active.
            statusItem.autosaveName = MenuBarStore.autosaveName(item.id)
            statusItem.isVisible = true
            statusItem.menu = item.menu
            item.statusItem = statusItem
        }
        if let button = statusItem.button {
            let image = statusImage(content, of: item)
            button.image = image
            button.title = content.title ?? ""
            button.imagePosition = content.title == nil ? .imageOnly : .imageLeading
            button.toolTip = content.tooltip
        }
        item.menu.removeAllItems()
        for menuItem in menuItems(content.entries, of: item) { item.menu.addItem(menuItem) }
        if item.lifecycle.lastRefreshFailed {
            if !item.menu.items.isEmpty { item.menu.addItem(.separator()) }
            let failed = NSMenuItem(title: "⚠ Last refresh failed", action: nil, keyEquivalent: "")
            failed.isEnabled = false
            item.menu.addItem(failed)
        }
    }

    /// The `MenuBarExtra`'s icon, template-tinted unless it carries its own colours (a bitmap, or a `tintColor`);
    /// with neither icon nor title, the extension's icon.
    private func statusImage(_ content: MenuBarContent, of item: Active) -> NSImage? {
        if let icon = content.icon {
            return menuImage(icon, of: item, size: 16)
        }
        guard content.title == nil else { return nil }
        let file = (item.command.icon ?? item.installed.manifest.icon).map {
            item.installed.assetsDirectory.appendingPathComponent($0)
        }
        guard let image = file.flatMap(NSImage.init(contentsOf:)) else {
            return NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: item.command.title)
        }
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    private func menuImage(_ icon: JSONValue, of item: Active, size: CGFloat) -> NSImage? {
        guard let image = ExtensionImages.nsImage(icon, assets: item.installed.assetsDirectory, size: size) else {
            return nil
        }
        guard case .object(let object) = icon, let tint = ExtensionColor(json: object["tintColor"])?.nsColor else {
            return image
        }
        // A tinted icon carries its colour: drawn as it is, not as a template.
        let tinted = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            tint.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.isTemplate = false
        return tinted
    }

    private func menuItems(_ entries: [MenuBarEntry], of item: Active) -> [NSMenuItem] {
        var result: [NSMenuItem] = []
        for entry in entries {
            switch entry {
            case .item(let entry):
                result.append(menuItem(entry, of: item))
                if let alternate = entry.alternate {
                    let alternateItem = menuItem(alternate, of: item)
                    alternateItem.keyEquivalent = result.last?.keyEquivalent ?? ""
                    alternateItem.keyEquivalentModifierMask =
                        (result.last?.keyEquivalentModifierMask ?? []).union(.option)
                    alternateItem.isAlternate = true
                    result.append(alternateItem)
                }
            case .submenu(let submenu):
                let submenuItem = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
                submenuItem.image = submenu.icon.flatMap { menuImage($0, of: item, size: 16) }
                let menu = NSMenu(title: submenu.title)
                menu.autoenablesItems = false
                for child in menuItems(submenu.entries, of: item) { menu.addItem(child) }
                submenuItem.submenu = menu
                result.append(submenuItem)
            case .heading(let title):
                result.append(.sectionHeader(title: title))
            case .separator:
                result.append(.separator())
            }
        }
        return result
    }

    private func menuItem(_ entry: MenuBarItem, of item: Active) -> NSMenuItem {
        let menuItem = NSMenuItem(title: entry.title, action: #selector(picked(_:)), keyEquivalent: "")
        menuItem.target = self
        menuItem.isEnabled = entry.isEnabled
        menuItem.representedObject = PickTarget(commandID: item.id, session: item.contentSession, item: entry)
        if let subtitle = entry.subtitle, !subtitle.isEmpty {
            let title = NSMutableAttributedString(string: entry.title, attributes: [.font: NSFont.menuFont(ofSize: 0)])
            title.append(
                NSAttributedString(
                    string: "  \(subtitle)",
                    attributes: [.font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.secondaryLabelColor]))
            menuItem.attributedTitle = title
        }
        menuItem.image = entry.icon.flatMap { menuImage($0, of: item, size: 16) }
        menuItem.toolTip = entry.tooltip
        if let shortcut = entry.shortcut, let key = Self.keyEquivalent(shortcut.key) {
            menuItem.keyEquivalent = key
            var mask: NSEvent.ModifierFlags = []
            if shortcut.modifiers.contains("cmd") { mask.insert(.command) }
            if shortcut.modifiers.contains("opt") { mask.insert(.option) }
            if shortcut.modifiers.contains("ctrl") { mask.insert(.control) }
            if shortcut.modifiers.contains("shift") { mask.insert(.shift) }
            menuItem.keyEquivalentModifierMask = mask
        }
        return menuItem
    }

    /// A Raycast key name as an `NSMenuItem` key equivalent.
    private static func keyEquivalent(_ key: String) -> String? {
        if key.count == 1 { return key }
        let special: [String: Int] = [
            "return": 0x0D, "enter": 0x03, "tab": 0x09, "space": 0x20, "delete": 0x08, "backspace": 0x08,
            "deleteForward": NSDeleteFunctionKey, "escape": 0x1B, "arrowUp": NSUpArrowFunctionKey,
            "arrowDown": NSDownArrowFunctionKey, "arrowLeft": NSLeftArrowFunctionKey,
            "arrowRight": NSRightArrowFunctionKey, "pageUp": NSPageUpFunctionKey, "pageDown": NSPageDownFunctionKey,
            "home": NSHomeFunctionKey, "end": NSEndFunctionKey,
        ]
        return special[key].flatMap(UnicodeScalar.init).map { String(Character($0)) }
    }
}
