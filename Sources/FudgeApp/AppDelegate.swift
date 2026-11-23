import AppKit
import EventKit
import FudgeCore
import Quartz
import os

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
    /// Expanding snippets as they're typed (SPEC-078 B). Never in snapshot runs.
    private var snippetExpansion: SnippetExpansion?
    /// The observer that redraws My Schedule when the calendars change.
    private var calendarChanges: NSObjectProtocol?
    private var settingsWindow: SettingsWindowController!
    private var onboardingWindow: OnboardingWindowController!
    /// The menu bar item's "Open Fudge (⌥Space)".
    private var openItem: NSMenuItem?
    private let hud = HUDWindow()
    private var keyMonitor: Any?
    /// The standard About panel, once About Fudge has opened it, so Esc, ⌘W and ⌘Q close it (`AboutFudge.closesPanel`).
    private weak var aboutPanel: NSWindow?
    /// The app that was frontmost when a FilePicker's open panel activated fudge; it gets the keyboard back when the
    /// launcher hides.
    private var appToRestore: NSRunningApplication?
    /// In a snapshot run, the alert a `confirm` would have shown, which the run saves instead of the panel.
    private var snapshotAlert: NSWindow?
    private var exchangeRates: ExchangeRateUpdater!
    private let exchangeRateSchedule = ExchangeRateSchedule()
    private var updates: UpdateChecker!
    private let updateSchedule = UpdateCheckSchedule()
    /// The menu bar item's "Fudge <version> Is Available…" and the separator under it, hidden until a newer release
    /// is known.
    private var availableItem: NSMenuItem?
    private var availableSeparator: NSMenuItem?
    /// Not in snapshot runs, which install nothing that outlives them.
    private var extensionsWatcher: ExtensionsWatcher?
    /// The only code that touches `UNUserNotificationCenter` (SPEC-156 C.6), made in `applicationWillFinishLaunching`
    /// so a click that launches Fudge is delivered. Never in snapshot runs.
    private var systemNotifications: SystemInstallNotifications?
    /// The notifications picked at launch (`FixedInstallNotifications.pick`): the system's, or a snapshot run's fixed one.
    private var installNotifications: (any InstallNotifications)?
    /// The store's builds' outcomes in `installing/` (SPEC-156 C.2). Not in snapshot runs.
    private var installOutcomes: InstallOutcomeWatcher?
    /// The Quick Look preview (SPEC-049). Never in snapshot runs.
    private var quickLook: QuickLookPreview?
    /// Hyperkey (SPEC-093): Caps Lock as ⌘⌥⌃⇧. Never in snapshot runs.
    private var hyperkey: HyperkeyService?
    /// SIGTERM quits as Quit does, so what `applicationWillTerminate` puts back (Hyperkey's mapping) goes with a kill
    /// or a restart too. Never in snapshot runs.
    private var terminationSignal: DispatchSourceSignal?

    func applicationWillTerminate(_ notification: Notification) {
        // The last log lines reach their files.
        FudgeLog.flush()
        // Clipboard History's decrypted image copies don't outlive the run.
        model?.clipboardHistory.clearPreviews()
        // Nor does Hyperkey's Caps Lock mapping.
        hyperkey?.quit()
    }

    /// Raycast's return links (SPEC-132 §3.1), handed on by Fudge Links (SPEC-140), since Fudge.app declares no URL
    /// types: the get-URL handler goes in before launch finishes, so a link that launches Fudge isn't missed. Such a
    /// link finds no sign-in waiting, and is ignored.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(openLink(_:withReplyEvent:)), forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL))
        // Install notifications' delegate goes in before launch finishes too, so a click that launches Fudge is
        // delivered; a snapshot run never touches Notification Center, and gets a fixed answer (`--notifications`).
        let picked = FixedInstallNotifications.pick(
            snapshot: Snapshot.isRequested(CommandLine.arguments), arguments: CommandLine.arguments
        ) { SystemInstallNotifications() }
        installNotifications = picked
        systemNotifications = picked as? SystemInstallNotifications
    }

    /// A `raycast:` or `com.raycast:` link Fudge Links handed on. Only the direct sign-in waiting for it takes it;
    /// nothing logs it or its query.
    @objc private func openLink(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard let link = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue else { return }
        model?.receiveLink(link)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Fudge's own lines and every extension's go to their files from here on (SPEC-124); a snapshot run's go to
        // its own support folder.
        FudgeLog.start(
            writer: LogWriter(
                folder: FudgePaths.logsDirectory(),
                header: "Fudge \(FudgeVersion.current) (\(FudgeVersion.describe))"),
            level: FudgeSettings.load(from: paths.settingsFile).logLevel)
        NSApp.mainMenu = Self.mainMenu()
        // Before the extensions first load (in the model's `init`) and before the watcher starts, so it never sees
        // the moves. Snapshot runs change nothing.
        if !Snapshot.isRequested(CommandLine.arguments) {
            // Every install from before goes into Raycast's folder, keeping its name as its id (FUD-183). A move
            // another Fudge is running (`fudge build`) is waited for at most 5 s; then the extensions load as they are.
            ExtensionLayout.moveAtLaunch(extensions: paths.extensionsDirectory)
            Self.moveInstallsUp(in: paths.extensionsDirectory)
        }
        model = LauncherModel(paths: paths)
        // Snapshots never ask Spotlight: Search Files gets `--found-files`' results, or none.
        if let snapshot = Snapshot(arguments: CommandLine.arguments) {
            let files = snapshot.foundFiles.map { FixedFileQuery.load($0, home: FileSearchOptions.home()) } ?? []
            model.fileSearch = FileSearch { FixedFileQuery(files) }
            model.templateClipboard = { nil }
            // Nor the window list or the Accessibility API: Switch Windows gets `--windows`' made-up windows.
            model.windowSwitching = FixedWindowSwitching(file: snapshot.windows)
            // Nor do the System commands do anything: no lock, sleep, restart, Apple Event, eject, hide or quit.
            model.systemActions = InertSystemActions(trashCount: snapshot.trashCount)
            // Nor does Pick Color show the loupe: it picks nothing, as Esc would.
            model.colorSampler = InertColorSampler()
            // Nor the windows: Save Layout… gets `--layout-windows`' made-up ones, and nothing is moved.
            model.windowLayoutActions = .inert(windows: snapshot.layoutWindows)
            // Nor other apps' menus: Search Menu Items gets `--menu-items`' made-up app and menus.
            model.menuItemsAccess = FixedMenuItemsAccess(file: snapshot.menuItems)
            // Define Word reads no selection and no dictionary: it gets `--definitions`' made-up ones, or none.
            model.selectedText = { nil }
            model.definitionLookup = snapshot.definitions.map(FixedDefinitions.load) ?? FixedDefinitions([:])
            // Nor the calendars: My Schedule gets `--calendar-events`' made-up ones, and asks no one for access.
            model.calendarSource =
                snapshot.calendarEvents.map { FixedCalendarSource.load($0, now: Date()) }
                ?? FixedCalendarSource(access: .notDetermined)
            // Nor the clipboard or the Keychain: Clipboard History gets `--clipboard-entries`' made-up entries.
            if let file = snapshot.clipboardEntries {
                model.clipboardHistory = ClipboardHistoryService(
                    paths: paths, secrets: MemorySecretStore(), turns: SystemCalls.pasteboardTurns,
                    fixed: ClipboardHistoryService.fixedHistory(from: file))
            }
        }
        panel = LauncherPanel(content: LauncherView(model: model))
        settingsModel = SettingsModel(paths: paths)
        if let editing = Snapshot(arguments: CommandLine.arguments)?.editPosition {
            settingsModel.snapshotPositionDraft =
                settingsModel.windowPositions.first { $0.name == editing }.map(PositionDraft.init(editing:))
                ?? PositionDraft()
        }
        if Snapshot(arguments: CommandLine.arguments)?.signInServicesList == true {
            settingsModel.snapshotServicesList = []
        }
        if let snapshot = Snapshot(arguments: CommandLine.arguments), let address = snapshot.addRepository {
            var draft = ExtensionRepositoryDraft()
            draft.address = address
            // Add goes through the page's own path, so a refusal's reason shows as the user would see it, and an
            // accepted address closes the window.
            let closes = snapshot.addRepositoryAdd && settingsModel.addRepository(&draft)
            settingsModel.snapshotAddRepository = closes ? nil : draft
        }
        // One calendar source for both, so the Calendar and Permissions pages say what My Schedule reads.
        settingsModel.calendarSource = model.calendarSource
        settingsModel.loadCalendars()
        settingsModel.calendarChanged = { [weak self] in self?.model.reloadSchedule() }
        settingsModel.launcherHotkey = FudgeSettings.load(from: paths.settingsFile).launcherHotkey
        // Snapshots and tests never register fudge as a login item; only the real app talks to the system.
        settingsModel.loginItem =
            Snapshot.isRequested(CommandLine.arguments)
            ? FixedLoginItem(Snapshot(arguments: CommandLine.arguments)?.loginItem ?? .notRegistered)
            : SMAppServiceLoginItem()
        // Where the app runs from: the disk image or a translocated copy can't become a login item. Snapshot runs
        // count as installed.
        settingsModel.appLocation = Snapshot.isRequested(CommandLine.arguments) ? .installed : AppMover.location()
        // Snapshots get a fixed Accessibility answer: no prompt, nothing read from the system.
        settingsModel.accessibility =
            Snapshot.isRequested(CommandLine.arguments)
            ? AccessibilityStatus(
                access: FixedAccessibility(trusted: Snapshot(arguments: CommandLine.arguments)?.accessibility ?? false),
                openPane: { _ in })
            : AccessibilityStatus(
                access: SystemAccessibility(), promptShownElsewhere: { SystemAccessibility.promptShown })
        // Sign-ins live in the Keychain; a snapshot run keeps them in memory, from `--sign-ins`, and never reads it.
        let secrets: any SecretStore =
            Snapshot.isRequested(CommandLine.arguments)
            ? Snapshot(arguments: CommandLine.arguments)?.signIns ?? MemorySecretStore() : KeychainSecretStore()
        model.tokenSecrets = secrets
        settingsModel.tokenSecrets = secrets
        // The services the chosen sign-in server offers, picked once here: the server, or in a snapshot run
        // `--sign-in-services`' fixed answer, never the network, even with a server chosen in `settings.json`.
        settingsModel.signInServicesFetcher = SignInServices.fetcher(
            snapshot: Snapshot.isRequested(CommandLine.arguments),
            snapshotValue: Snapshot(arguments: CommandLine.arguments)?.signInServices,
            network: { URLSessionSignInServices(userAgent: UpdateCheck.userAgent(version: FudgeVersion.current)) })
        // Who opens Raycast's links: LaunchServices; a snapshot run's fixed answer (`--raycast-links`), so it never
        // reads or changes the Mac's handlers, or registers Fudge Links.
        let raycastLinks: any RaycastLinks =
            Snapshot.isRequested(CommandLine.arguments)
            ? FixedRaycastLinks(
                snapshotValue: Snapshot(arguments: CommandLine.arguments)?.raycastLinks ?? "",
                helper: RaycastLinksHelper.url(in: Bundle.main.bundleURL))
            : SystemRaycastLinks()
        model.raycastLinks = raycastLinks
        settingsModel.raycastLinks = raycastLinks
        settingsModel.snapshotOwnAppSignIn = Snapshot(arguments: CommandLine.arguments)?.ownAppSignIn ?? false
        // Install notifications (SPEC-156): macOS's in the real app, a fixed answer (`--notifications`) in a snapshot
        // run, which never posts or asks; both picked at launch.
        let notifications = installNotifications ?? FixedInstallNotifications(.unknown)
        let settingsFile = paths.settingsFile
        let notices = InstallNoticeCenter(notifications: notifications) {
            InstallNotificationSwitches(FudgeSettings.load(from: settingsFile))
        }
        model.installNotices = notices
        settingsModel.notifications = notifications
        settingsModel.askForNotifications = { needsSwitch in await notices.ask(needsSwitch: needsSwitch) }
        settingsWindow = SettingsWindowController(model: settingsModel)
        onboardingWindow = OnboardingWindowController(settings: settingsModel, file: paths.onboardingFile)
        onboardingWindow.openLauncher = { [weak self] in self?.showPanel() }
        settingsModel.showOnboarding = { [weak self] in self?.onboardingWindow.showAgain() }
        model.hidePanel = { [weak self] caller in self?.hidePanel("model \(caller)") }
        model.panelOnScreen = { [weak self] in self?.panel?.isVisible ?? false }
        model.show = { [weak self] in self?.showPanel() }
        model.openSettings = { [weak self] name, origin in self?.settingsWindow.show(extension: name, origin: origin) }
        model.reloadAll = { [weak self] in self?.reloadExtensions() }
        settingsModel.clearSearchHistory = { [weak self] in self?.model.clearHistory() }
        settingsModel.imported = { [weak self] in self?.afterImport() }
        model.showHUD = { [weak self] title in self?.hud.show(title) }
        model.isVisible = { [weak self] in self?.panel.isVisible ?? false }
        model.confirm = { [weak self] request, origin in await self?.confirm(request, origin: origin) ?? false }
        model.openPanel = { [weak self] options in await self?.chooseFiles(options) }
        // The calculator's towns and countries, read from the app's resources; nothing is downloaded.
        model.loadPlaces(waiting: Snapshot(arguments: CommandLine.arguments) != nil)
        // Other places with Apple Maps, only while the setting is on. A snapshot run never asks Apple, even with the
        // setting on in its settings.
        let asksApple = Snapshot(arguments: CommandLine.arguments) == nil
        model.placeLookups = PlaceLookups(
            enabled: FudgeSettings.load(from: paths.settingsFile).appleMapsPlaces,
            makeLookup: {
                if asksApple { return MapKitPlaceLookup() }
                return InertPlaceLookup()
            })
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
        settingsModel.resetAfterChanged = { [weak self] setting in self?.model.panelReset.setting = setting }
        // The store stays installed either way; the launcher reads settings.json again.
        settingsModel.extensionStoreChanged = { [weak self] in self?.model.applySettings() }
        // A quicklink deleted in Settings takes its hotkey with it.
        settingsModel.quicklinksChanged = { [weak self] in _ = self?.applyCommandHotkeys() }
        model.commandHotkeysChanged = { [weak self] in self?.registerCommandHotkeys() }
        settingsModel.snippetsChanged = { [weak self] in
            self?.model.reloadSnippetList()
            self?.snippetExpansion?.update()
        }
        settingsModel.snippetExpansionChanged = { [weak self] in self?.snippetExpansion?.update() }
        model.snippetsChanged = { [weak self] in self?.snippetExpansion?.update() }
        if Snapshot.isRequested(CommandLine.arguments) {
            // Snapshots get a fixed Input Monitoring answer, and no keyboard tap.
            let allowed = Snapshot(arguments: CommandLine.arguments)?.inputMonitoring ?? false
            settingsModel.inputMonitoring = InputMonitoringStatus(read: { allowed })
            // …and a fixed answer about the Command Line Tools, so no run asks the Mac.
            let tools = CommandLineTools.fixedStatus(Snapshot(arguments: CommandLine.arguments)?.commandLineTools)
            settingsModel.resolveCommandLineTools = { _ in tools }
            model.resolveCommandLineTools = { _ in tools }
        } else {
            let expansion = SnippetExpansion(paths: paths)
            // Typing into the launcher (a non-activating panel) or a Fudge window never expands.
            expansion.fudgeHasKeyboard = { [weak self] in NSApp.isActive || self?.panel?.isKeyWindow == true }
            expansion.showHUD = { [weak self] title in self?.hud.show(title) }
            expansion.clipboard = { [weak self] in self?.model.templateClipboard() }
            snippetExpansion = expansion
            expansion.update()
        }
        settingsModel.colorFormatChanged = { [weak self] in self?.model.reloadRecentColors() }
        model.windowLayoutsChanged = { [weak self] in self?.settingsModel.loadWindowLayouts() }
        settingsModel.clipboardHistoryChanged = { [weak self] in self?.model.applySettings() }
        settingsModel.deleteClipboardHistory = { [weak self] in self?.model.clipboardHistory.deleteAll() }
        settingsModel.stopExtensionStore = { [weak self] in
            await self?.model.unloadSessions(ofExtension: ExtensionStore.id)
        }
        settingsModel.currencyRatesChanged = { [weak self] on in
            guard let self else { return }
            Task { await self.exchangeRates.setEnabled(on, now: Date()) }
        }
        settingsModel.appleMapsPlacesChanged = { [weak self] on in self?.model.placeLookups?.setEnabled(on) }
        // The model reads the setting again, and the open query's card is evaluated again in the new format.
        settingsModel.numberFormatChanged = { [weak self] in self?.model.applySettings() }
        // Update checks: only the real app asks GitHub, and only once a setting is chosen. A snapshot run never asks
        // it and keeps nothing on disk; it counts as untagged, so `--update-available`'s version is always newer.
        let snapshotRun = Snapshot(arguments: CommandLine.arguments)
        updates = UpdateChecker(
            fetcher: snapshotRun == nil ? GitHubReleaseFetcher() : SnapshotReleaseFetcher(),
            stateFile: snapshotRun == nil ? paths.updateCheckFile : nil,
            running: snapshotRun == nil ? RunningVersion(FudgeVersion.describe) : .untagged,
            setting: FudgeSettings.load(from: paths.settingsFile).updateCheck)
        if let release = snapshotRun?.updateAvailable { updates.show(release, checkedAt: Date()) }
        settingsModel.updateStatus = updates.status
        updates.onChange = { [weak self] in self?.updatesChanged() }
        updates.onNewRelease = { [weak self] release in self?.hud.show(UpdateCheck.availableText(release)) }
        settingsModel.updateCheckChanged = { [weak self] setting in
            guard let self else { return }
            Task { await self.updates.setSetting(setting, now: Date()) }
        }
        settingsModel.checkForUpdates = { [weak self] in self?.checkForUpdatesNow() }
        settingsModel.openReleasePage = { release in NSWorkspace.shared.open(release.pageURL) }
        panel.onEscape = { [weak self] in self?.model.escape() }
        panel.onResign = { [weak self] in
            LauncherLog.note("launcher resigned key: \(LauncherLog.keyboard)")
            // Decided a turn later, once AppKit has made the new key window key (`LauncherResign`).
            DispatchQueue.main.async { [weak self] in self?.settleResign() }
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
                snapshot.take(of: panel, model: model) { [weak self] in self?.snapshotAlert?.contentView }
            }
            return
        }

        // An event added, changed or removed in any app: My Schedule, if it's on screen, shows it.
        calendarChanges = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.reloadSchedule() }
        }

        SystemCalls.accessibilitySettingsOffer = AccessibilitySettingsOffer(
            panel: panel, restoreKeyboard: { [weak self] in self?.model.restoreKeyboard() })
        // Switch Windows reads the system's windows; it notes which apps become active from now on.
        model.windowSwitching = SystemWindowSwitching(accessibility: { SystemCalls.mayReadWindows() })
        model.menuItemsAccess = SystemMenuItemsAccess(mayReadMenus: { SystemCalls.mayReadMenus() })

        let hyperkey = HyperkeyService(paths: paths)
        hyperkey.problemChanged = { [weak self] problem in self?.settingsModel.hyperkeyProblem = problem }
        settingsModel.mayUseAccessibility = { SystemCalls.mayPostKeysForUser() }
        settingsModel.turnOnHyperkey = { [weak hyperkey] quickPress, done in
            guard let hyperkey else { return done(nil) }
            hyperkey.turnOn(quickPress: quickPress, done: done)
        }
        settingsModel.turnOffHyperkey = { [weak hyperkey] in hyperkey?.turnOff() }
        settingsModel.hyperkeyQuickPressChanged = { [weak hyperkey] in hyperkey?.update() }
        self.hyperkey = hyperkey
        hyperkey.update()

        signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termination.setEventHandler { NSApp.terminate(nil) }
        termination.resume()
        terminationSignal = termination

        let quickLook = QuickLookPreview()
        quickLook.launcherLevel = panel.level
        quickLook.closedByUser = { [weak self] in self?.model.quickLookClosedByUser() }
        quickLook.forwardKey = { [weak self] event in self?.previewKey(event) ?? false }
        model.quickLookChanged = { [weak self] item in
            guard let self, let quickLook = self.quickLook else { return }
            // Remember the app the user is in, for when a click on the preview makes Fudge the active app. Never
            // with nil: the preview may reopen while Fudge is frontmost, after such a click.
            if item != nil, quickLook.item == nil, let app = Self.otherFrontmostApp() { self.appBeforeQuickLook = app }
            quickLook.show(item)
        }
        model.quickLookOnScreen = { [weak self] in self?.quickLook?.isOnScreen ?? false }
        self.quickLook = quickLook

        // Snapshots never download; the app checks the rates now and every hour.
        exchangeRateSchedule.start(exchangeRates)
        // Snapshots never ask GitHub; the app asks whether a check is due now and every hour.
        updateSchedule.start(updates)

        // ⌘K, ⌘↵ and the extensions' shortcuts, before the search field sees them.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let pressed = Self.shortcut(for: event) else { return event }
            let window = event.window
            let handled = MainActor.assumeIsolated {
                guard let self else { return false }
                if let about = self.aboutPanel, window === about {
                    guard AboutFudge.closesPanel(pressed) else { return false }
                    about.close()
                    return true
                }
                guard window === self.panel else { return false }
                // While an input method is composing (Japanese, Chinese, …), its keys are its own: ↑↓ pick a
                // candidate, Esc cancels and ↵ confirms.
                if (self.panel.firstResponder as? NSTextView)?.hasMarkedText() == true { return false }
                let handled = self.model.handleKey(pressed)
                // Shortcuts only (⌘ or ⌃), never typing.
                if !pressed.modifiers.isDisjoint(with: ["cmd", "ctrl"]) {
                    let keys = (pressed.modifiers.sorted() + [pressed.key]).joined(separator: "+")
                    LauncherLog.note("key \(keys) handled=\(handled): \(LauncherLog.keyboard)")
                }
                return handled
            }
            return handled ? nil : event
        }

        // For the launcher's log: Fudge becoming active, inactive or hidden, and any of its windows (the launcher's,
        // the Quick Look preview's) taking or losing the keyboard, or coming on or off screen.
        let center = NotificationCenter.default
        for name in [
            NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
            NSApplication.didHideNotification,
        ] {
            _ = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { LauncherLog.note("\(name.rawValue): \(LauncherLog.keyboard)") }
            }
        }
        for name in [
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSWindow.didChangeOcclusionStateNotification,
        ] {
            _ = center.addObserver(forName: name, object: nil, queue: .main) { note in
                let window = note.object as? NSWindow
                MainActor.assumeIsolated {
                    LauncherLog.note(
                        "\(name.rawValue) \(LauncherLog.name(window)) visible=\(window?.isVisible == true): "
                            + LauncherLog.keyboard)
                }
            }
        }

        // The launcher's hotkey and every command's, through one Carbon handler.
        hotKeys.onPress = { [weak self] id in
            guard let self else { return }
            if id == HotKeyRegistry.launcherID {
                self.togglePanel()
            } else if let command = self.registry.command(for: id) {
                // In the launcher, an action with the hotkey's keys runs instead (SPEC-127).
                if let spec = self.registry.commands[command],
                    self.model.pressHotkey(spec, launcherHoldsKeyboard: self.panel.holdsKeyboard)
                {
                    return
                }
                self.model.openFromHotkey(command)
            }
        }
        let spec = FudgeSettings.load(from: paths.settingsFile).launcherHotkey
        if !registry.setLauncher(spec) {
            FudgeLog.error("couldn't register the shortcut \(spec)")
        }
        installStatusItem()
        launcherHotkeyChanged()
        model.menuBar.start()
        applyCommandHotkeys()
        settingsModel.changeLauncherHotkey = { [weak self] spec, save in
            guard let self else { return .notSaved }
            let result = self.registry.changeLauncher(to: spec, save: save)
            self.launcherHotkeyChanged()
            return result
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
            FudgeLog.error("couldn't watch \(watcher.directory.path): \(error)")
        }
        extensionsWatcher = watcher

        // The store's builds that end while no store session is loaded (SPEC-156 C.2): the stream starts first, then
        // the folder is read once, and outcomes already there count as decided.
        if !Snapshot.isRequested(CommandLine.arguments), let notices = model.installNotices {
            let outcomes = InstallOutcomeWatcher(
                folder: ExtensionStore.installingDirectory(paths), found: { notices.foundAtLaunch($0) },
                ended: { [weak self] ends in
                    let loaded = self?.model.storeSessionLoaded ?? false
                    Task { await notices.outcomes(ends, storeLoaded: loaded) }
                })
            outcomes.start()
            installOutcomes = outcomes
            model.readInstallOutcomes = { then in outcomes.readAll(then: then) }
            // A click, the one that launched Fudge included, opens the store now that the extensions have loaded.
            systemNotifications?.onClick { [weak self] target in self?.model.notificationClicked(target) }
        }

        // Run from the disk image or a translocated copy, Fudge offers to move itself first (SPEC-114 §1), before
        // onboarding; moving quits this copy and opens the one in Applications.
        if AppMover.offer(settingsModel.appLocation) { return }

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

    /// Installs from before SPEC-123 keep their commands in `dist/`. Each install the walk finds moves to Raycast's
    /// layout once, at launch (`ExtensionLayout.moveUp`); one stopped halfway finishes at the next launch, and
    /// `entry(for:)`'s fallback covers it until then. One that can't move is left on the fallback, with a log line
    /// naming its folder relative to the extensions folder. The bundled extensions, built with the app, are never
    /// touched.
    private static func moveInstallsUp(in extensionsDirectory: URL) {
        let log = Logger(subsystem: "io.github.jakeobsen.fudge", category: "extensions")
        for (folder, outcome) in ExtensionLayout.moveUp(in: extensionsDirectory) {
            guard case .leftAlone(let refusal) = outcome else { continue }
            log.notice("install left in dist/: \(refusal.description, privacy: .public) \(folder, privacy: .private)")
        }
    }

    /// The extensions folder changed: an extension was installed, rebuilt or removed. Root search, the command
    /// hotkeys and an open Settings window catch up; the applications aren't scanned again.
    private func extensionsChanged() {
        model.reloadExtensions()
        registerCommandHotkeys()
        settingsWindow.reloadIfShown()
    }

    /// Shows the launcher's hotkey as it's registered: on the General page, and in the menu bar item's "Open Fudge"
    /// title, which leaves it out while another app has it.
    private func launcherHotkeyChanged() {
        let spec = registry.launcher ?? .default
        settingsModel.launcherHotkey = spec
        settingsModel.launcherHotkeyInUse = registry.launcherRefused
        openItem?.title = registry.launcherRefused ? "Open Fudge" : "Open Fudge (\(spec))"
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
        let available = menu.addItem(withTitle: "", action: #selector(openAvailableRelease), keyEquivalent: "")
        available.target = self
        availableItem = available
        let separator = NSMenuItem.separator()
        menu.addItem(separator)
        availableSeparator = separator
        let open = menu.addItem(withTitle: "Open Fudge", action: #selector(openFromMenu), keyEquivalent: "")
        open.target = self
        openItem = open
        let reload = menu.addItem(
            withTitle: "Reload Extensions", action: #selector(reloadExtensions), keyEquivalent: "")
        reload.target = self
        let settings = menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        let check = menu.addItem(
            withTitle: "Check for Updates…", action: #selector(checkForUpdatesFromMenu), keyEquivalent: "")
        check.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Fudge \(FudgeVersion.current)", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "About Fudge", action: #selector(showAbout), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit Fudge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
        updatesChanged()
    }

    /// Shows what the update checker knows: on the General page, and as the menu's "Fudge <version> Is
    /// Available…" while a newer release is known.
    private func updatesChanged() {
        settingsModel.updateStatus = updates.status
        let available = updates.available
        availableItem?.title = available.map(UpdateCheck.menuTitle) ?? ""
        availableItem?.isHidden = available == nil
        availableSeparator?.isHidden = available == nil
    }

    /// Check Now, on the General page and in the menu bar item.
    private func checkForUpdatesNow() {
        Task { await updates.checkNow(now: Date()) }
    }

    /// About Fudge (SPEC-113 §3): the standard About panel with the version Fudge shows, the build number, the
    /// copyright (`NSHumanReadableCopyright`) and `AboutFudge.credits`, linking the license and third-party notices in
    /// the app. It's the user's own click, so Fudge comes forward first, as Settings does. Snapshot runs have no menu.
    @objc private func showAbout() {
        NSApp.activateFromUserAction(origin: .userInitiated)
        let resources = Bundle.main.resourceURL
        func file(_ name: String) -> URL? {
            guard let url = resources?.appendingPathComponent(name),
                FileManager.default.fileExists(atPath: url.path)
            else { return nil }
            return url
        }
        let markdown = AboutFudge.credits(
            describe: FudgeVersion.describe, license: file("LICENSE.txt"), notices: file("Third-Party Notices.txt"))
        let parsed =
            (try? AttributedString(
                markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)
        let credits = NSMutableAttributedString(parsed)
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        credits.addAttributes(
            [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.labelColor,
                .paragraphStyle: centered,
            ], range: NSRange(location: 0, length: credits.length))
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationVersion: FudgeVersion.current, .credits: credits,
        ]
        if let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
            options[.version] = build
        }
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        NSApp.orderFrontStandardAboutPanel(options: options)
        if aboutPanel == nil { aboutPanel = NSApp.windows.first { !before.contains(ObjectIdentifier($0)) } }
        aboutPanel?.makeKeyAndOrderFront(nil)
    }

    /// The menu's Check for Updates…: Settings opens on the General page, where the result shows, and it checks.
    @objc private func checkForUpdatesFromMenu() {
        settingsWindow.show(origin: .userInitiated)
        checkForUpdatesNow()
    }

    /// The menu's "Fudge <version> Is Available…": the release's page in the browser. Nothing is downloaded.
    @objc private func openAvailableRelease() {
        guard let release = updates.available else { return }
        NSWorkspace.shared.open(release.pageURL)
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
        menu.addItem(withTitle: "Fudge", action: nil, keyEquivalent: "").submenu = NSMenu(title: "Fudge")
        menu.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit
        return menu
    }

    /// The launcher's hotkey: hides the panel, or shows it, starting over on root search after a long hide.
    private func togglePanel() {
        if panel.isVisible {
            // A sheet on the panel (a `confirm`) is waiting for an answer: hiding it, and a reset after, would
            // unload the command behind it.
            guard panel.attachedSheet == nil else { return }
            hidePanel("launcher hotkey")
        } else {
            model.resetIfDue()
            showPanel()
        }
    }

    /// The menu bar item's "Open Fudge", which shows the panel as the launcher's hotkey does.
    @objc private func openFromMenu() {
        if !panel.isVisible { model.resetIfDue() }
        showPanel()
    }

    /// Every path that shows the panel ends here, after it has built its screen.
    private func showPanel() {
        model.panelReset.panelShown()
        panel.present(on: chosenScreen())
        model.presented()
    }

    /// The screen "Show Fudge on" picks (`PanelScreen`).
    private func chosenScreen() -> NSScreen? {
        let screens = NSScreen.screens
        let setting = model.settings.showOnScreen
        let window = setting == .activeWindow ? activeWindowFrame(primaryHeight: screens.first?.frame.height ?? 0) : nil
        let index = PanelScreen.choose(
            setting: setting, screens: screens.map(\.frame), mouse: NSEvent.mouseLocation, activeWindowFrame: window)
        return index.map { screens[$0] }
    }

    /// The frontmost app's topmost window on screen, in Cocoa coordinates. Window bounds need no permission; nil
    /// when there's no such window.
    private func activeWindowFrame(primaryHeight: CGFloat) -> CGRect? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return nil }
        for window in windows
        where (window[kCGWindowOwnerPID as String] as? pid_t) == pid && (window[kCGWindowLayer as String] as? Int) == 0
        {
            guard let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                let rect = CGRect(dictionaryRepresentation: bounds)
            else { continue }
            return PanelScreen.cocoaFrame(windowListBounds: rect, primaryHeight: primaryHeight)
        }
        return nil
    }

    /// Every path that hides the panel ends here: Esc, the hotkey, the model's `hide`, and the panel resigning key.
    /// `reason` names the path, for the log.
    private func hidePanel(_ reason: String) {
        LauncherLog.note("hidePanel (\(reason)) visible=\(panel.isVisible): \(LauncherLog.keyboard)")
        guard panel.isVisible else { return }
        model.closeQuickLook()
        model.panelHidden()
        LinkPointer.shared.release()
        panel.hideReason = reason
        panel.orderOut(nil)
        model.panelReset.panelHidden()
        // A FilePicker's open panel, or a click on the Quick Look preview, made Fudge the active app. Give the
        // keyboard back to the app that had it, unless the user has moved on to another one.
        appBeforeQuickLook = nil
        if let app = appToRestore {
            appToRestore = nil
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                app.activate()
            }
        }
    }

    /// The launcher stopped being the key window a turn ago. An alert sheet takes the keyboard, and so does the Quick
    /// Look preview, when the user clicks it or Quick Look takes it as the preview opens; none of them is the user
    /// leaving.
    private func settleResign() {
        let settled = LauncherResign.Settled(
            launcherShown: panel.isVisible, sheetAttached: panel.attachedSheet != nil, launcherIsKey: panel.isKeyWindow,
            previewOpen: quickLook?.item != nil, previewIsKey: quickLook?.isKey == true,
            previewSaysKey: quickLook?.previewKey.saysKey == true)
        let decision = LauncherResign.decide(settled)
        LauncherLog.note("resign settled \(settled) → \(decision): \(LauncherLog.keyboard)")
        switch decision {
        case .stay:
            break
        case .takeKeyBack:
            takeKeyBackFromQuickLook()
        case .hide:
            hidePanel("resign")
        }
    }

    /// The app the user was in when the Quick Look preview opened. Forgotten when the panel hides, so a later
    /// session never restores it.
    private var appBeforeQuickLook: NSRunningApplication?

    /// The frontmost app, unless it's Fudge.
    private static func otherFrontmostApp() -> NSRunningApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication,
            app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return nil }
        return app
    }

    /// The Quick Look preview took the keyboard (and may have made Fudge the active app), usually because the user
    /// clicked it:
    /// the launcher takes it back, so ↑↓, Esc and ⌘Y keep working, and `hidePanel` later gives the keyboard back to
    /// the app the user was in, as after a FilePicker's open panel. That app is set whether or not
    /// `frontmostApplication` names Fudge yet, since it can lag behind the click; `hidePanel` only activates it if
    /// Fudge is frontmost by then.
    private func takeKeyBackFromQuickLook() {
        if appToRestore == nil { appToRestore = appBeforeQuickLook }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.panel.makeKey()
        }
    }

    /// A key the Quick Look preview got because the user clicked it: it does what it does in the launcher. The
    /// launcher's shortcuts (⌘Y, ⌘K, …) and a date picker's keys go through `handleKey` first, as the key monitor
    /// sends them; then the arrows move what the launcher's arrows would (`LauncherModel.previewArrow`: the action
    /// panel, the dropdown's panel, or the List or Grid, ←→ included), and Esc does what it does there.
    private func previewKey(_ event: NSEvent) -> Bool {
        guard panel.isVisible else { return false }
        // The launcher's field keeps its editor while the preview is key.
        let editor = panel.firstResponder as? NSTextView
        // While an input method is composing, its keys are its own, as the key monitor leaves them.
        guard editor?.hasMarkedText() != true, let pressed = Self.shortcut(for: event) else { return false }
        if model.handleKey(pressed) { return true }
        let moves: [UInt16: GridNavigation.Move] = [123: .left, 124: .right, 125: .down, 126: .up]
        if let move = moves[event.keyCode] {
            let range = editor?.selectedRange()
            return model.previewArrow(
                move, modifiers: pressed.modifiers,
                textLength: editor?.string.utf16.count ?? model.searchText.utf16.count,
                selection: range.map { ($0.location, $0.length) })
        }
        if event.keyCode == 53 {
            model.escape()
            return true
        }
        return false
    }

    // MARK: - Quick Look control

    // The preview panel looks for its controller along the responder chain, which ends with the app delegate, so
    // this works whether or not Fudge is active and whichever window is key.

    // AppKit calls these on the main thread.

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { quickLook?.acceptsControl == true }
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { quickLook?.begin(panel) }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { quickLook?.end(panel) }
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
    nonisolated static func shortcut(for event: NSEvent) -> KeyShortcut? {
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

    /// confirmAlert: a sheet on the panel when it's open, otherwise a standalone alert brought to the front. Only a
    /// user-initiated call gets one (SPEC-045); the model answers background calls without asking.
    private func confirm(_ request: LauncherModel.AlertRequest, origin: CallOrigin) async -> Bool {
        if let answer = origin.unaskedAnswer { return answer }
        let alert = NSAlert()
        alert.messageText = request.title
        alert.informativeText = request.message ?? ""
        let primary = alert.addButton(withTitle: request.primary)
        primary.hasDestructiveAction = request.destructive
        alert.addButton(withTitle: request.dismiss)
        // A snapshot run shows no alert and asks no one: it lays the alert out off-screen for the run to save, and the
        // answer is no.
        if Snapshot.isRequested(CommandLine.arguments) {
            snapshotAlert = SnapshotSheet.laidOut(alert)
            return false
        }
        if panel.isVisible {
            return await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: panel) { [weak self] response in
                    // The sheet had the keyboard; give it back to the screen's field.
                    self?.model.restoreKeyboard()
                    continuation.resume(returning: response == .alertFirstButtonReturn)
                }
            }
        }
        // The plain `activate()` can be declined since macOS 14, which would leave the alert behind the app in front.
        NSApp.activateFromUserAction(origin: origin)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// An import replaced `settings.json`, the history and extensions' data: read everything again, and register
    /// the imported hotkeys.
    private func afterImport() {
        model.reloadAfterImport()
        let settings = FudgeSettings.load(from: paths.settingsFile)
        _ = registry.setLauncher(settings.launcherHotkey)
        launcherHotkeyChanged()
        applyCommandHotkeys()
        Task { await exchangeRates.setEnabled(settings.currencyRates, now: Date()) }
        model.placeLookups?.setEnabled(settings.appleMapsPlaces)
        Task { await updates.setSetting(settings.updateCheck, now: Date()) }
        snippetExpansion?.update()
        hyperkey?.update()
    }

    @objc private func reloadExtensions() {
        model.reload()
        applyCommandHotkeys()
    }

    @objc private func showSettings() {
        settingsWindow.show(origin: .userInitiated)
    }
}

/// `--snapshot <file.png> [--query <text>] [--activate]`: renders the panel, saves a picture of it and quits.
/// `--activate` presses ↵ after typing the query, then waits for the result. In the command that opened,
/// `--search <text>` types into its search field, `--dropdown <value>` picks a value in its search bar dropdown,
/// `--actions` presses ⌘K, `--pick-date <title>` runs the Action.PickDate titled so (after ⌘K with `--actions`, else
/// straight), and `--open-dropdown` presses ⌘P, or in a Form opens its first Dropdown (`--open-tags`: its first
/// TagPicker; `--open-date`: its first DatePicker's calendar). `--windows <file>` gives Switch Windows made-up
/// windows.
/// `--snapshot <file.png> --settings [<page or extension id>]` renders the Settings window instead, with a fake login
/// item whose status `--login-item <status>` sets (`enabled`, `requiresApproval`, `notRegistered`, `notFound`), and a
/// fake Accessibility answer that `--accessibility allowed|missing` sets (`missing` by default). `--settings
/// :permissions` shows the Permissions page, and `--settings someone+tools+github` that extension's.
/// `--snapshot <file.png> --onboarding [<step>]` renders the onboarding window, with the same fakes, on its pending
/// steps from `onboarding.json`; with a step id, on every step from the start, at that one.
/// `--own-app-sign-in` shows **Extensions with their own sign-in** as on, and `--raycast-links fudge|<app name>` says
/// who opens Raycast's links (`fudge,<app name>`: Fudge Links does, and that app claims them too), on the Sign-in page
/// and onboarding's Raycast step; neither touches LaunchServices. `--sign-in-services "<id>|…"` is the sign-in server's
/// answer, and `--sign-in-services-list` with `--settings :sign-in` draws Show All's list over the page, in place of
/// its popover.
/// `--command-line-tools found|old|missing` is what Settings → Development and the Extension Store take Apple's Command
/// Line Tools to be (missing by default); no snapshot run asks the Mac.
/// `--notifications not-asked|allowed|quiet|off|unknown` is macOS's answer for Fudge's notifications on Settings →
/// Notifications (`FixedInstallNotifications`, not asked by default); no snapshot run asks macOS or posts one.
/// `--update-available <version>` shows that version as found by an update check, wherever Fudge shows one (the
/// General page). No snapshot run asks GitHub. `--menu-items <file>` gives Search Menu Items a made-up app and menus.
/// For checking the layout without looking at the screen.
@MainActor
struct Snapshot {
    let file: URL
    let query: String?
    let activate: Bool
    let search: String?
    let dropdown: String?
    let actions: Bool
    /// `--pick-date <title>`: the Action.PickDate to open the picker of.
    let pickDate: String?
    /// `--run-action <title>`, once or more: actions to run in order, half a second apart, as picking them would
    /// (e.g. an extension's Create Quicklink, then Save Quicklink).
    let runActions: [String]
    let openDropdown: Bool
    let openTags: Bool
    let openDate: Bool
    let settings: Bool
    let settingsExtension: String?
    /// `--login-item <status>`: what the General page's Open at Login shows (`notRegistered` by default).
    let loginItem: LoginItemStatus
    /// `--accessibility allowed`: Accessibility shows as allowed (else not allowed).
    let accessibility: Bool
    /// `--input-monitoring allowed`: the Snippets page shows Input Monitoring as allowed (else not allowed).
    let inputMonitoring: Bool
    /// `--command-line-tools found|old|missing`: what Settings → Development and the Extension Store take the
    /// Command Line Tools to be (`CommandLineTools.fixedStatus`; missing without it). Nothing asks the Mac.
    let commandLineTools: String?
    /// `--onboarding [<step>]`: the onboarding window instead, optionally on one step.
    let onboarding: Bool
    let onboardingStep: OnboardingStep?
    /// `--sign-ins <extension id>/<providerId>=<Provider>,…`: sign-ins the Sign-in page lists, kept in memory, each
    /// under the Keychain account its extension's id gives (`someone+tools+github/github`); one whose id the id rule
    /// refuses is left out.
    let signIns: MemorySecretStore
    /// `--sign-in-services "<id>|<id>|…"`: what the chosen sign-in server answers it offers (`FixedSignInServices`),
    /// so the line under the choice names up to five of those services, or gives their number with Show All. Without
    /// it there's no answer and the line is the plain one.
    let signInServices: String?
    /// `--sign-in-services-list`: the Sign-in page draws Show All's list in place, over the page, since a snapshot
    /// run never opens a popover; nothing while the line names five services or fewer.
    let signInServicesList: Bool
    /// `--sign-in-consent`: picks Fudge's sign-in server on the Sign-in page and saves its consent sheet instead. It
    /// implies `--settings`, as `--clipboard-consent` does.
    let signInConsent: Bool
    /// `--clipboard-consent`: turns on Clipboard History's switch and saves its consent sheet instead.
    let clipboardConsent: Bool
    /// `--add-repository <address>`: the Extension Store's page with the **Add Repository** window drawn over it, the
    /// address typed (SPEC-160). It implies `--settings`, as `--clipboard-consent` does.
    let addRepository: String?
    /// `--add-repository-add`: presses Add in that window, so a refused address shows its reason.
    let addRepositoryAdd: Bool
    /// `--own-app-sign-in`: **Extensions with their own sign-in** shows as on, in memory only.
    let ownAppSignIn: Bool
    /// `--raycast-links fudge|<app name>[,<app name>]`: who opens Raycast's links (no app without it), and who else
    /// claims them. Nothing reads or changes LaunchServices.
    let raycastLinks: String?
    /// `--found-files <file>`: Search Files' results, a JSON array of `files.search` entries (`~/` paths are in the
    /// home folder). Snapshots never ask Spotlight, so without it there are none.
    let foundFiles: URL?
    /// `--calendar-events <file>`: My Schedule's made-up calendars and events (`FixedCalendarSource.load`).
    let calendarEvents: URL?
    /// `--clipboard-entries <file>`: Clipboard History's made-up entries, a JSON array of `clipboardHistory.list`
    /// entries. Snapshots never read the clipboard.
    let clipboardEntries: URL?
    /// Made-up definitions for Define Word (a JSON object of word to definition), so no run reads the dictionaries.
    let definitions: URL?
    /// `--update-available <version>` (`0.9.0` or `v0.9.0`): an update check found that release.
    let updateAvailable: Release?
    /// `--trash-count <n>`: what Empty Trash's made-up count of the Trash gives (12 without it); anything but a number
    /// is a count Finder couldn't give.
    let trashCount: Int?
    /// `--windows <file>`: Switch Windows' made-up windows (`FixedWindowSystem`). Snapshots never read the window
    /// list or the Accessibility API, so without it Switch Windows shows that it needs Accessibility.
    let windows: URL?
    /// `--layout-windows <file>`: the windows Save Layout… reads, a JSON array of `window-layouts.json`'s window
    /// entries. Snapshots never read or move real windows, so without it there are none.
    let layoutWindows: [SavedWindow]
    /// `--edit-position [<name>]`: the Window Management page shows its position sheet in place, editing that
    /// position, or a new one.
    let editPosition: String?
    /// `--menu-items <file>`: Search Menu Items' made-up app and menus (`FixedMenuFile`). Snapshots never read
    /// another app's menus, so without it Search Menu Items has no app to search.
    let menuItems: URL?

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
        pickDate = value("--pick-date")
        runActions = arguments.indices.compactMap { index in
            arguments[index] == "--run-action" && index + 1 < arguments.count ? arguments[index + 1] : nil
        }
        openDropdown = arguments.contains("--open-dropdown")
        openTags = arguments.contains("--open-tags")
        openDate = arguments.contains("--open-date")
        loginItem = value("--login-item").flatMap(LoginItemStatus.init(rawValue:)) ?? .notRegistered
        accessibility = value("--accessibility") == "allowed"
        inputMonitoring = value("--input-monitoring") == "allowed"
        commandLineTools = value("--command-line-tools")
        onboarding = arguments.contains("--onboarding")
        onboardingStep = value("--onboarding").flatMap(OnboardingStep.init(rawValue:))
        signIns = MemorySecretStore()
        for entry in (value("--sign-ins") ?? "").split(separator: ",") {
            let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
            // An id has no "/", so the account splits at its first one.
            guard parts.count == 2, let slash = parts[0].firstIndex(of: "/"),
                ExtensionID(stored: String(parts[0][..<slash])) != nil
            else { continue }
            let tokens = StoredTokenSet(
                accessToken: "snapshot",
                updatedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-7200)),
                providerName: parts[1])
            try? signIns.write(JSONEncoder().encode(tokens), account: parts[0])
        }
        signInServices = value("--sign-in-services")
        signInServicesList = arguments.contains("--sign-in-services-list")
        signInConsent = arguments.contains("--sign-in-consent")
        clipboardConsent = arguments.contains("--clipboard-consent")
        addRepository = value("--add-repository")
        addRepositoryAdd = arguments.contains("--add-repository-add")
        ownAppSignIn = arguments.contains("--own-app-sign-in")
        raycastLinks = value("--raycast-links")
        foundFiles = value("--found-files").map { URL(fileURLWithPath: $0) }
        calendarEvents = value("--calendar-events").map { URL(fileURLWithPath: $0) }
        clipboardEntries = value("--clipboard-entries").map { URL(fileURLWithPath: $0) }
        menuItems = value("--menu-items").map { URL(fileURLWithPath: $0) }
        definitions = value("--definitions").map { URL(fileURLWithPath: $0) }
        updateAvailable = value("--update-available").flatMap { Release(tag: $0.hasPrefix("v") ? $0 : "v" + $0) }
        trashCount = value("--trash-count").map { Int($0) } ?? InertSystemActions.trashCount
        windows = value("--windows").map { URL(fileURLWithPath: $0) }
        layoutWindows =
            value("--layout-windows").flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
            .flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }.map(SavedWindow.list(from:)) ?? []
        if let index = arguments.firstIndex(of: "--edit-position") {
            let next = index + 1
            editPosition = next < arguments.count && !arguments[next].hasPrefix("--") ? arguments[next] : ""
        } else {
            editPosition = nil
        }
        if let settingsIndex = arguments.firstIndex(of: "--settings") {
            settings = true
            let next = settingsIndex + 1
            let page = next < arguments.count && !arguments[next].hasPrefix("--") ? arguments[next] : nil
            // A page of Fudge's own starts with ":"; any other is an extension's, by its id (FUD-183).
            settingsExtension = page.flatMap { $0.hasPrefix(":") ? $0 : ExtensionID(stored: $0)?.key }
        } else {
            // A consent sheet belongs to its Settings page, so its flag implies `--settings` (FUD-135 §4).
            settings = signInConsent || clipboardConsent || addRepository != nil
            settingsExtension = nil
        }
    }

    func take(of controller: SettingsWindowController) {
        let page =
            signInConsent
            ? SettingsModel.signInPage
            : clipboardConsent
                ? ClipboardHistory.id.key
                : addRepository != nil ? ExtensionStore.id.key : settingsExtension
        // `--settings :commands --search text` searches the Commands page, as typing in its field does.
        controller.model.commandsSearch = search
        controller.renderOffscreen(extension: page)
        if signInConsent || clipboardConsent {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [signInConsent] in
                if signInConsent {
                    controller.model.setSignInServer(.fudge)
                } else {
                    controller.model.setClipboardHistory(true)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard let view = controller.snapshotSheet?.contentView else { exit(1) }
                save(view)
            }
            return
        }
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
    /// When the run ends on a `confirm` (`--query "empty trash" --activate`), `alert` gives the alert it laid out,
    /// which is saved instead.
    func take(of panel: LauncherPanel, model: LauncherModel, alert: @escaping @MainActor () -> NSView? = { nil }) {
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
        if let pickDate {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) { model.openDatePick(titled: pickDate) }
        }
        for (index, title) in runActions.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5 + 0.5 * Double(index)) {
                model.runAction(titled: title)
            }
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
        let waits =
            actions || pickDate != nil || !runActions.isEmpty || openDropdown || openTags || openDate || inCommand
        let afterActions = runActions.isEmpty ? 0 : 2.5 + 0.5 * Double(runActions.count) + 0.5
        DispatchQueue.main.asyncAfter(deadline: .now() + max(waits ? 3.5 : activate ? 3 : 1, afterActions)) {
            guard let view = alert() ?? panel.contentView else { exit(1) }
            save(view)
        }
    }
}
