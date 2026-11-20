import AppKit
import FudgeCore

/// fudge runs as an accessory app: no Dock icon, one menu bar item, and a launcher panel
/// that a global hotkey shows and hides.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let paths = FudgePaths.standard()
    private var statusItem: NSStatusItem?
    /// The menu bar item's autosave name, which its saved visibility and position are kept under.
    static let statusItemName = "fudge"
    private var model: LauncherModel!
    private var panel: LauncherPanel!
    private let hotKeys = CarbonHotKeys()
    private lazy var registry = HotKeyRegistry(registrar: hotKeys)
    private var settingsModel: SettingsModel!
    private var settingsWindow: SettingsWindowController!
    private var onboardingWindow: OnboardingWindowController!
    /// The menu bar item's "Open fudge (⌥Space)".
    private var openItem: NSMenuItem?
    private let hud = HUDWindow()
    private var keyMonitor: Any?
    /// The app that was frontmost when a FilePicker's open panel activated fudge; it gets the keyboard back when the
    /// launcher hides.
    private var appToRestore: NSRunningApplication?
    private var exchangeRates: ExchangeRateUpdater!
    private let exchangeRateSchedule = ExchangeRateSchedule()
    /// Not in snapshot runs, which install nothing that outlives them.
    private var extensionsWatcher: ExtensionsWatcher?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.mainMenu()
        model = LauncherModel(paths: paths)
        panel = LauncherPanel(content: LauncherView(model: model))
        settingsModel = SettingsModel(paths: paths)
        settingsModel.launcherHotkey = FudgeSettings.load(from: paths.settingsFile).launcherHotkey
        // Snapshots and tests never register fudge as a login item; only the real app talks to the system.
        settingsModel.loginItem =
            Snapshot.isRequested(CommandLine.arguments)
            ? FixedLoginItem(Snapshot(arguments: CommandLine.arguments)?.loginItem ?? .notRegistered)
            : SMAppServiceLoginItem()
        // Snapshots get a fixed Accessibility answer: no prompt, nothing read from the system.
        settingsModel.accessibility =
            Snapshot.isRequested(CommandLine.arguments)
            ? AccessibilityStatus(
                access: FixedAccessibility(trusted: Snapshot(arguments: CommandLine.arguments)?.accessibility ?? false),
                openPane: { _ in })
            : AccessibilityStatus(
                access: SystemAccessibility(), promptShownElsewhere: { SystemAccessibility.promptShown })
        settingsWindow = SettingsWindowController(model: settingsModel)
        onboardingWindow = OnboardingWindowController(settings: settingsModel, file: paths.onboardingFile)
        onboardingWindow.openLauncher = { [weak self] in self?.showPanel() }
        settingsModel.showOnboarding = { [weak self] in self?.onboardingWindow.showAgain() }
        model.hide = { [weak self] in self?.hidePanel() }
        model.show = { [weak self] in self?.showPanel() }
        model.openSettings = { [weak self] name in self?.settingsWindow.show(extension: name) }
        model.reloadAll = { [weak self] in self?.reloadExtensions() }
        settingsModel.clearSearchHistory = { [weak self] in self?.model.clearHistory() }
        model.showHUD = { [weak self] title in self?.hud.show(title) }
        model.isVisible = { [weak self] in self?.panel.isVisible ?? false }
        model.confirm = { [weak self] request in await self?.confirm(request) ?? false }
        model.openPanel = { [weak self] options in await self?.chooseFiles(options) }
        // The calculator's exchange rates: the cached ones now, downloads only while the setting is on.
        exchangeRates = ExchangeRateUpdater(
            fetcher: ECBRatesFetcher(), cacheFile: paths.exchangeRatesFile,
            enabled: FudgeSettings.load(from: paths.settingsFile).currencyRates)
        model.currency = exchangeRates.state
        exchangeRates.onChange = { [weak self] in
            guard let self else { return }
            self.model.currency = self.exchangeRates.state
        }
        model.retryExchangeRates = { [weak self] in
            guard let self else { return }
            Task { await self.exchangeRates.updateIfNeeded(now: Date(), explicit: true) }
        }
        settingsModel.extensionStoreChanged = { [weak self] in
            guard let self else { return }
            self.model.reload()
            self.applyCommandHotkeys()
        }
        settingsModel.currencyRatesChanged = { [weak self] on in
            guard let self else { return }
            Task { await self.exchangeRates.setEnabled(on, now: Date()) }
        }
        // The model reads the setting again, and the open query's card is evaluated again in the new format.
        settingsModel.numberFormatChanged = { [weak self] in self?.model.applySettings() }
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
            if snapshot.onboarding {
                snapshot.take(of: onboardingWindow, file: paths.onboardingFile)
            } else if snapshot.settings {
                snapshot.take(of: settingsWindow)
            } else {
                snapshot.take(of: panel, model: model)
            }
            return
        }

        SystemCalls.accessibilitySettingsOffer = AccessibilitySettingsOffer(
            panel: panel, restoreKeyboard: { [weak self] in self?.model.restoreKeyboard() })

        // Snapshots never download; the app checks the rates now and every hour.
        exchangeRateSchedule.start(exchangeRates)

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
        let spec = FudgeSettings.load(from: paths.settingsFile).launcherHotkey
        if !registry.setLauncher(spec) {
            FileHandle.standardError.write(Data("fudge: couldn't register the shortcut \(spec)\n".utf8))
        }
        installStatusItem()
        launcherHotkeyChanged()
        applyCommandHotkeys()
        settingsModel.registerLauncherHotkey = { [weak self] spec in
            guard let self else { return false }
            let registered = self.registry.setLauncher(spec)
            self.launcherHotkeyChanged()
            return registered
        }
        settingsModel.suspendHotkeys = { [weak self] in self?.registry.suspend() }
        settingsModel.resumeHotkeys = { [weak self] in
            guard let self else { return }
            self.registry.resume()
            // Resuming tries a refused launcher hotkey again: the app that had it may have let go.
            self.launcherHotkeyChanged()
        }
        settingsModel.applyHotkeys = { [weak self] in self?.applyCommandHotkeys() ?? [] }

        // `fudge build` while fudge runs: the new, rebuilt or removed extension shows without a reload.
        let watcher = ExtensionsWatcher(directory: paths.extensionsDirectory) { [weak self] in
            self?.extensionsChanged()
        }
        do {
            try watcher.start()
        } catch {
            FileHandle.standardError.write(Data("fudge: couldn't watch \(watcher.directory.path): \(error)\n".utf8))
        }
        extensionsWatcher = watcher

        // Onboarding opens at every launch until it's completed; only the real app's launch opens it.
        let onboarding = Onboarding.load(from: paths.onboardingFile)
        if !onboarding.isComplete { onboardingWindow.show(onboarding) }
    }

    /// Applies `settings.json` to root search (aliases, disabled commands) and registers the hotkeys of the
    /// installed, enabled commands. Hotkeys of commands that aren't installed stay in the file, unregistered, so
    /// reinstalling the extension brings them back. Returns the command ids whose hotkey the system refused.
    @discardableResult
    private func applyCommandHotkeys() -> Set<String> {
        model.applySettings()
        return registerCommandHotkeys()
    }

    /// Registers the hotkeys of the installed, enabled commands, from the settings the model last read.
    @discardableResult
    private func registerCommandHotkeys() -> Set<String> {
        registry.apply(model.settings.availableHotkeys(installed: Set(model.installedCommandIDs)))
        return registry.refused
    }

    /// The extensions folder changed: an extension was installed, rebuilt or removed. Root search, the command
    /// hotkeys and an open Settings window catch up; the applications aren't scanned again.
    private func extensionsChanged() {
        model.reloadExtensions()
        registerCommandHotkeys()
        settingsWindow.reloadIfShown()
    }

    /// Shows the launcher's hotkey as it's registered: on the General page, and in the menu bar item's "Open fudge"
    /// title, which leaves it out while another app has it.
    private func launcherHotkeyChanged() {
        let spec = registry.launcher ?? .default
        settingsModel.launcherHotkey = spec
        settingsModel.launcherHotkeyInUse = registry.launcherRefused
        openItem?.title = registry.launcherRefused ? "Open fudge" : "Open fudge (\(spec))"
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // macOS saves whether a status item is shown in the app's preferences, under its autosave name. Unnamed, it
        // would be "Item-0", a key every build with this bundle id shares; a stale "hidden" there hid fudge's icon.
        item.autosaveName = Self.statusItemName
        // ⌘-dragging can't remove it, so it's never hidden by accident.
        item.behavior = []
        item.isVisible = true
        item.button?.image = MenuBarIcon.image

        let menu = NSMenu()
        let open = menu.addItem(withTitle: "Open fudge", action: #selector(showPanel), keyEquivalent: "")
        open.target = self
        openItem = open
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
        // The sheet had the keyboard; give it back to the field.
        model.restoreKeyboard()
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
/// first TagPicker; `--open-date`: its first DatePicker's calendar).
/// `--snapshot <file.png> --settings [<extension>]` renders the Settings window instead, with a fake login item
/// whose status `--login-item <status>` sets (`enabled`, `requiresApproval`, `notRegistered`, `notFound`), and a fake
/// Accessibility answer that `--accessibility allowed|missing` sets (`missing` by default). `--settings :permissions`
/// shows the Permissions page.
/// `--snapshot <file.png> --onboarding [<step>]` renders the onboarding window, with the same fakes, on its pending
/// steps from `onboarding.json`; with a step id, on every step from the start, at that one.
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
    let openDate: Bool
    let settings: Bool
    let settingsExtension: String?
    /// `--login-item <status>`: what the General page's Open at Login shows (`notRegistered` by default).
    let loginItem: LoginItemStatus
    /// `--accessibility allowed`: Accessibility shows as allowed (else not allowed).
    let accessibility: Bool
    /// `--onboarding [<step>]`: the onboarding window instead, optionally on one step.
    let onboarding: Bool
    let onboardingStep: OnboardingStep?

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
        openDate = arguments.contains("--open-date")
        loginItem = value("--login-item").flatMap(LoginItemStatus.init(rawValue:)) ?? .notRegistered
        accessibility = value("--accessibility") == "allowed"
        onboarding = arguments.contains("--onboarding")
        onboardingStep = value("--onboarding").flatMap(OnboardingStep.init(rawValue:))
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

    /// Renders onboarding: on `onboardingStep` among every step, else on the pending steps from `file`.
    func take(of controller: OnboardingWindowController, file: URL) {
        let onboarding = onboardingStep == nil ? Onboarding.load(from: file) : Onboarding()
        guard controller.renderOffscreen(onboarding, step: onboardingStep) != nil else { exit(1) }
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
        if openDate {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { _ = model.openFirstFormPicker(.datePicker) }
        }
        let waits = actions || openDropdown || openTags || openDate || inCommand
        DispatchQueue.main.asyncAfter(deadline: .now() + (waits ? 3.5 : activate ? 3 : 1)) {
            guard let view = panel.contentView else { exit(1) }
            save(view)
        }
    }
}
