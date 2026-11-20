import AppKit
import FudgeCore

/// fudge runs as an accessory app: no Dock icon, one menu bar item, and a launcher panel
/// that a global hotkey shows and hides.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let paths = FudgePaths.standard()
    private var statusItem: NSStatusItem?
    private var model: LauncherModel!
    private var panel: LauncherPanel!
    private let hotKeys = CarbonHotKeys()
    private lazy var registry = HotKeyRegistry(registrar: hotKeys)
    private var settingsWindow: SettingsWindowController!
    private let hud = HUDWindow()
    private var keyMonitor: Any?
    /// The app that was frontmost when a FilePicker's open panel activated fudge; it gets the keyboard back when the
    /// launcher hides.
    private var appToRestore: NSRunningApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.mainMenu()
        model = LauncherModel(paths: paths)
        panel = LauncherPanel(content: LauncherView(model: model))
        let settingsModel = SettingsModel(paths: paths)
        settingsWindow = SettingsWindowController(model: settingsModel)
        model.hide = { [weak self] in self?.hidePanel() }
        model.show = { [weak self] in self?.showPanel() }
        model.openSettings = { [weak self] name in self?.settingsWindow.show(extension: name) }
        model.showHUD = { [weak self] title in self?.hud.show(title) }
        model.isVisible = { [weak self] in self?.panel.isVisible ?? false }
        model.confirm = { [weak self] request in await self?.confirm(request) ?? false }
        model.openPanel = { [weak self] options in await self?.chooseFiles(options) }
        panel.onEscape = { [weak self] in self?.model.escape() }
        panel.onResign = { [weak self] in
            // An alert sheet takes the keyboard; that's not the user leaving.
            guard let self, self.panel.attachedSheet == nil else { return }
            self.hidePanel()
        }

        // A snapshot renders off-screen and quits. It installs no status item or hotkey, and nothing in it takes
        // the keyboard, so it can't put a second icon in the menu bar or catch anyone's typing.
        if let snapshot = Snapshot(arguments: CommandLine.arguments) {
            panel.refusesKey = true
            if snapshot.settings {
                snapshot.take(of: settingsWindow)
            } else {
                snapshot.take(of: panel, model: model)
            }
            return
        }

        // ⌘K, ⌘↵ and the extensions' shortcuts, before the search field sees them.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let pressed = Self.shortcut(for: event) else { return event }
            let window = event.window
            let handled = MainActor.assumeIsolated {
                guard let self, window === self.panel else { return false }
                // While an input method is composing (Japanese, Chinese, …), its keys are its own: ↑↓ pick a
                // candidate, Esc cancels and ↵ confirms.
                if (self.panel.firstResponder as? NSTextView)?.hasMarkedText() == true { return false }
                return self.model.handleKey(pressed)
            }
            return handled ? nil : event
        }

        // The launcher's hotkey and every command's, through one Carbon handler.
        hotKeys.onPress = { [weak self] id in
            guard let self else { return }
            if id == HotKeyRegistry.launcherID {
                self.togglePanel()
            } else if let command = self.registry.command(for: id) {
                self.model.openFromHotkey(command)
            }
        }
        let settings = FudgeSettings.load(from: paths.settingsFile)
        let spec = settings.hotkey.flatMap(HotKeySpec.parse) ?? .default
        let registered = registry.setLauncher(spec)
        if !registered {
            FileHandle.standardError.write(Data("fudge: couldn't register the shortcut \(spec)\n".utf8))
        }
        installStatusItem(shortcut: registered ? spec : nil)
        applyCommandHotkeys()
        settingsModel.launcherHotkey = spec
        settingsModel.suspendHotkeys = { [weak self] in self?.registry.suspend() }
        settingsModel.resumeHotkeys = { [weak self] in self?.registry.resume() }
        settingsModel.applyHotkeys = { [weak self] in self?.applyCommandHotkeys() ?? [] }
    }

    /// Registers the hotkeys of the installed commands from `settings.json`. Hotkeys of commands that aren't
    /// installed stay in the file, unregistered, so reinstalling the extension brings them back. Returns the
    /// command ids whose hotkey the system refused.
    @discardableResult
    private func applyCommandHotkeys() -> Set<String> {
        let installed = Set(model.installedCommandIDs)
        let wanted = FudgeSettings.load(from: paths.settingsFile).commandHotkeys.filter { installed.contains($0.key) }
        registry.apply(wanted)
        model.refreshCommandHotkeys()
        return registry.refused
    }

    private func installStatusItem(shortcut: HotKeySpec?) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "command", accessibilityDescription: "fudge")

        let menu = NSMenu()
        let open = menu.addItem(withTitle: "Open fudge", action: #selector(showPanel), keyEquivalent: "")
        open.target = self
        if let shortcut { open.title = "Open fudge (\(shortcut))" }
        let reload = menu.addItem(
            withTitle: "Reload Extensions", action: #selector(reloadExtensions), keyEquivalent: "")
        reload.target = self
        let settings = menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "fudge \(FudgeVersion.current)", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Quit fudge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    /// A main menu with the standard Edit menu. An accessory app never shows it, but text fields get ⌘Z, ⇧⌘Z,
    /// ⌘X, ⌘C, ⌘V and ⌘A from its key equivalents; without them those keys beep.
    private static func mainMenu() -> NSMenu {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        // An uppercase key equivalent means ⇧.
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let menu = NSMenu()
        // The first item is the application menu, by convention.
        menu.addItem(withTitle: "fudge", action: nil, keyEquivalent: "").submenu = NSMenu(title: "fudge")
        menu.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit
        return menu
    }

    private func togglePanel() {
        if panel.isVisible { hidePanel() } else { showPanel() }
    }

    @objc private func showPanel() {
        panel.present()
        model.presented()
    }

    private func hidePanel() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        // A FilePicker's open panel made fudge the active app. Give the keyboard back to the app that had it, unless
        // the user has moved on to another one.
        if let app = appToRestore {
            appToRestore = nil
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                app.activate()
            }
        }
    }

    /// A FilePicker's open panel, as a sheet on the launcher, so the launcher doesn't hide (`onResign` ignores
    /// sheets). The open panel only takes typing (⌘⇧G, its search field) while fudge is the active app, so fudge
    /// activates for it, and `hidePanel` gives the keyboard back to the app that had it.
    private func chooseFiles(_ options: FilePickerOptions) async -> [String]? {
        let open = NSOpenPanel()
        open.canChooseFiles = options.canChooseFiles
        open.canChooseDirectories = options.canChooseDirectories
        open.allowsMultipleSelection = options.allowsMultipleSelection
        open.showsHiddenFiles = options.showsHiddenFiles
        if let frontmost = NSWorkspace.shared.frontmostApplication,
            frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier
        {
            appToRestore = frontmost
        }
        NSApp.activate()
        let response = await withCheckedContinuation { continuation in
            open.beginSheetModal(for: panel) { continuation.resume(returning: $0) }
        }
        panel.makeKey()
        return response == .OK ? open.urls.map(\.path) : nil
    }

    /// The key as it types with no modifier at all, so ⌘⇧, is "," with cmd and shift. `charactersIgnoringModifiers`
    /// still applies ⇧ and would give "<" (US) or ";" (Danish). Read through the keyboard layout, punctuation
    /// follows the user's layout rather than the key's position.
    private nonisolated static func shortcut(for event: NSEvent) -> KeyShortcut? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: Set<String> = []
        if flags.contains(.command) { modifiers.insert("cmd") }
        if flags.contains(.control) { modifiers.insert("ctrl") }
        if flags.contains(.option) { modifiers.insert("opt") }
        if flags.contains(.shift) { modifiers.insert("shift") }
        let unmodified = event.characters(byApplyingModifiers: []).flatMap { $0.isEmpty ? nil : $0 }
        return KeyShortcut(
            keyCode: event.keyCode, characters: unmodified ?? event.charactersIgnoringModifiers, modifiers: modifiers)
    }

    /// confirmAlert: a sheet on the panel when it's open, otherwise a standalone alert.
    private func confirm(_ request: LauncherModel.AlertRequest) async -> Bool {
        let alert = NSAlert()
        alert.messageText = request.title
        alert.informativeText = request.message ?? ""
        let primary = alert.addButton(withTitle: request.primary)
        primary.hasDestructiveAction = request.destructive
        alert.addButton(withTitle: request.dismiss)
        if panel.isVisible {
            return await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: panel) { [weak self] response in
                    // The sheet had the keyboard; give it back to the screen's field.
                    self?.model.restoreKeyboard()
                    continuation.resume(returning: response == .alertFirstButtonReturn)
                }
            }
        }
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    @objc private func reloadExtensions() {
        model.reload()
        applyCommandHotkeys()
    }

    @objc private func showSettings() {
        settingsWindow.show()
    }
}

/// `--snapshot <file.png> [--query <text>] [--activate]`: renders the panel, saves a picture of it and quits.
/// `--activate` presses ↵ after typing the query, then waits for the result. In the command that opened,
/// `--search <text>` types into its search field, `--dropdown <value>` picks a value in its search bar dropdown,
/// `--actions` presses ⌘K, and `--open-dropdown` presses ⌘P, or in a Form opens its first Dropdown (`--open-tags`: its
/// first TagPicker).
/// `--snapshot <file.png> --settings [<extension>]` renders the Settings window instead.
/// For checking the layout without looking at the screen.
@MainActor
struct Snapshot {
    let file: URL
    let query: String?
    let activate: Bool
    let search: String?
    let dropdown: String?
    let actions: Bool
    let openDropdown: Bool
    let openTags: Bool
    let settings: Bool
    let settingsExtension: String?

    init?(arguments: [String]) {
        guard let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count else { return nil }
        file = URL(fileURLWithPath: arguments[index + 1])
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        query = value("--query")
        search = value("--search")
        dropdown = value("--dropdown")
        activate = arguments.contains("--activate")
        actions = arguments.contains("--actions")
        openDropdown = arguments.contains("--open-dropdown")
        openTags = arguments.contains("--open-tags")
        if let settingsIndex = arguments.firstIndex(of: "--settings") {
            settings = true
            let next = settingsIndex + 1
            settingsExtension = next < arguments.count && !arguments[next].hasPrefix("--") ? arguments[next] : nil
        } else {
            settings = false
            settingsExtension = nil
        }
    }

    func take(of controller: SettingsWindowController) {
        controller.renderOffscreen(extension: settingsExtension)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard let view = controller.contentView else { exit(1) }
            save(view)
        }
    }

    /// Whether `arguments` ask for a snapshot. `main.swift` decides the activation policy with it, before launch.
    static func isRequested(_ arguments: [String]) -> Bool {
        arguments.contains("--snapshot")
    }

    private func save(_ view: NSView) -> Never {
        // The proof that the run touched nobody's keyboard: all four must be false.
        if let window = view.window {
            let state =
                "snapshot-state active=\(NSApp.isActive) appActive=\(NSRunningApplication.current.isActive) "
                + "key=\(window.isKeyWindow) canBecomeKey=\(window.canBecomeKey)\n"
            FileHandle.standardError.write(Data(state.utf8))
        }
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: file)
        exit(0)
    }

    /// Renders the panel without showing it: transparent, off-screen and never key,
    /// so taking a snapshot can't catch the user's clicks or keystrokes.
    func take(of panel: LauncherPanel, model: LauncherModel) {
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
        panel.allowsOffscreen = true
        panel.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        panel.orderFrontRegardless()
        if let query { model.searchText = query }
        if activate { model.activate() }
        let inCommand = search != nil || dropdown != nil
        if inCommand {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [search, dropdown] in
                if let dropdown { model.selectDropdownValue(dropdown) }
                if let search { model.searchText = search }
            }
        }
        if actions {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { model.toggleActionPanel() }
        }
        if openDropdown {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                if !model.openFirstFormPicker(.dropdown) { model.toggleDropdownPanel() }
            }
        }
        if openTags {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { _ = model.openFirstFormPicker(.tagPicker) }
        }
        let waits = actions || openDropdown || openTags || inCommand
        DispatchQueue.main.asyncAfter(deadline: .now() + (waits ? 3.5 : activate ? 3 : 1)) {
            guard let view = panel.contentView else { exit(1) }
            save(view)
        }
    }
}
