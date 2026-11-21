import AppKit
import FudgeCore
import Observation

/// Everything the launcher panel shows, and what its keys do.
@MainActor
@Observable
final class LauncherModel {
    struct Failure: Equatable {
        var title: String
        var message: String
        var details: String?
        /// Set when it's a notice rather than an error, like the Extension Store's "off" view.
        var notice: Notice?
        /// The command it stands in for, whose title the bottom bar keeps (`LauncherFooter`); nil for one that
        /// belongs to no command, which says "Fudge".
        var commandTitle: String?

        /// A notice is drawn like an empty view: `symbol`, the title and the message. Its actions take Back's place
        /// (↵ runs the first, ⌘K lists them, and their shortcuts work), and ⌘⇧, opens `extensionName`'s settings.
        struct Notice: Equatable {
            var extensionName: String
            var actions: [ActionSection]
            /// An SF Symbol.
            var symbol = "puzzlepiece.extension"
        }

        /// What opening the Extension Store shows while it's off (`ExtensionStore.isOff`), in place of the store.
        static let extensionStoreOff = Failure(
            title: ExtensionStore.Off.title, message: "",
            notice: Notice(
                extensionName: ExtensionStore.extensionName, actions: RootActions.extensionStoreOffSections))
    }

    /// A running view command.
    struct CommandScreen: Equatable {
        var session: String
        var title: String
        var extensionName = ""
        var commandName = ""
        /// The extension's assets folder, for its icons and images.
        var assets: URL?
        var view: UINode?
        var depth = 1
        var searchText = ""
        /// The search text of each view below the top one, restored when it's shown again.
        var searchStack: [String] = []
        var selectedNode: Int?
        var failure: Failure?
        /// The List the top view shows, filtered by the search text.
        var list: ListContent?
        /// The search bar dropdown on screen, by node id, and its value.
        var dropdown: DropdownState?
        /// What onSelectionChange last reported; nil until it first does.
        var reportedSelection: String??
        /// The `selectedItemId` the selection last followed.
        var followedItemId: String?
        /// The extension set the search text (`searchText`): select the first item of what it sends back.
        var selectFirstOnRender = false
        /// The user typed and the command filters itself: the first render of its results selects their first item
        /// (`TypingSelection`).
        var typing = TypingSelection()
        /// The search text as the user types it, reconciled with a `searchText` the extension sets.
        var searchField = FieldValue(.string(""))
        /// How many items the List had when it was last asked for the next page.
        var requestedMoreAt: Int?
        /// The `actions` and `detail` the host sent for List items since the last render, by node id. A render sends
        /// them only for some items (`ItemSlots`); `requestSlots()` asks for the others.
        var slots: [Int: ItemSlots] = [:]
        /// What was asked for, and what the host carries in full in every render since (`SlotRequests`).
        var slotRequests = SlotRequests()
        /// The Form the top view shows.
        var form: FormContent?
        /// The values of the Form's fields as the user edits them, by node id.
        var fieldValues: [Int: FieldValue] = [:]
        /// The values stored for this command's Form fields (`storeValue`), read when the Form first shows.
        var storedFormValues: [String: JSONValue]?
        /// Stored values still waiting for their fields' items, by node id (`FormContent.Field.start`).
        var pendingStoredValues: [Int: JSONValue] = [:]
        /// The Form field that had the keyboard last, by node id.
        var lastFormField: Int?
    }

    struct DropdownState: Equatable {
        var node: Int
        var value: String?
    }

    enum Screen: Equatable {
        case root
        case command(CommandScreen)
        case failure(Failure)
    }

    private(set) var screen: Screen = .root {
        didSet {
            followQuickLook()
            builtInFormLeft()
            dropHeldKeyIfLeft()
            switchWindowsLeft()
            menuItemsLeft()
        }
    }
    private(set) var results: [RootItem] = []
    var selectedItem: String? {
        didSet {
            syncArguments()
            // The action panel belongs to the item it opened on.
            if selectedItem != oldValue, case .root = screen { actionPanel = nil }
        }
    }
    /// The arguments of the command selected in root search, with what the user entered into them.
    private(set) var arguments = ArgumentInput()
    /// The root item `arguments` belongs to.
    @ObservationIgnored private var argumentsItem: String?
    /// Counts the times `arguments` started over. Each field's edits carry the count it was drawn with, so a late
    /// write from a field that's gone can't refill the new ones.
    private(set) var argumentsGeneration = 0
    /// A line for the bottom bar, e.g. "Running Create Scratch…".
    private(set) var status: String?

    /// A toast an extension showed: what the bottom bar displays instead of the title.
    struct ToastState: Equatable {
        var session: String
        var id: Int
        var title: String
        var message: String?
        /// "SUCCESS", "FAILURE" or "ANIMATED".
        var style: String
        var primaryAction: String?
        var secondaryAction: String?
    }

    private(set) var toast: ToastState?
    @ObservationIgnored private var toastExpiry: Task<Void, Never>?
    private var rootQuery = ""

    /// Hides the panel; set by the app delegate.
    /// Hides the panel (`AppDelegate.hidePanel`), told which model method asked, for the log.
    @ObservationIgnored var hidePanel: (String) -> Void = { _ in }

    func hide(_ caller: String = #function, line: Int = #line) {
        hidePanel("\(caller):\(line)")
    }
    /// Shows the panel; set by the app delegate.
    @ObservationIgnored var show: () -> Void = {}
    /// Opens the Settings window on an extension's preferences, or on its default page for nil; set by the app
    /// delegate.
    /// Opens Settings for a call from `origin`; only a user-initiated one opens it (SPEC-045).
    @ObservationIgnored var openSettings: (String?, CallOrigin) -> Void = { _, _ in }
    /// Shows a FilePicker's open panel and returns the chosen paths, or nil when cancelled; set by the app delegate.
    @ObservationIgnored var openPanel: (FilePickerOptions) async -> [String]? = { _ in nil }
    /// Downloads the exchange rates again at once (↵ on the "Couldn't download exchange rates" card).
    @ObservationIgnored var retryExchangeRates: () -> Void = {}
    /// The menu bar item's "Reload Extensions", for root search's item of that name; set by the app delegate.
    @ObservationIgnored var reloadAll: () -> Void = {}
    /// Shows a HUD message; set by the app delegate.
    @ObservationIgnored var showHUD: (String) -> Void = { _ in }
    /// Registers the command hotkeys again from the settings last read, after a quicklink and its hotkey went; set
    /// by the app delegate.
    @ObservationIgnored var commandHotkeysChanged: () -> Void = {}
    /// Shows the Quick Look preview of an item, or closes it for nil (SPEC-049); set by the app delegate.
    @ObservationIgnored var quickLookChanged: (QuickLookItem?) -> Void = { _ in }
    /// Whether a file exists, for Quick Look.
    @ObservationIgnored var fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    /// What the Quick Look preview shows.
    @ObservationIgnored private(set) var quickLook = QuickLookState()
    /// Whether macOS's Quick Look panel is on screen (SPEC-057); set by the app delegate. Without one (snapshot runs),
    /// the state is taken as it is.
    @ObservationIgnored var quickLookOnScreen: () -> Bool = { true }
    /// Whether the launcher panel is on screen; the app delegate sets it.
    @ObservationIgnored var panelOnScreen: () -> Bool = { true }
    /// Whether the launcher panel is on screen; set by the app delegate.
    @ObservationIgnored var isVisible: () -> Bool = { false }
    /// Pick Color's loupe. `AppDelegate` gives snapshot runs one that never shows it.
    @ObservationIgnored var colorSampler: any ColorSampling = ScreenColorSampler()
    /// Define Word's dictionary. `AppDelegate` gives snapshot runs `--definitions`' made-up ones.
    @ObservationIgnored var definitionLookup: any DefinitionLookup = DictionaryServicesLookup()
    /// The frontmost app's selected text, for Define Word with no word typed, read as the user's own call. Snapshot
    /// runs read none.
    @ObservationIgnored var selectedText: @MainActor () async -> String? = {
        guard case .string(let text) = try? await SystemCalls.handle("selection.text", .null, origin: .userInitiated)
        else { return nil }
        return text
    }
    /// Asks the user to confirm (title, message, primary, dismiss, destructive); set by the app delegate.
    /// Asks the user, for a call from `origin`; a background call gets `CallOrigin.unaskedAnswer` without an alert.
    @ObservationIgnored var confirm: (AlertRequest, CallOrigin) async -> Bool = { _, _ in false }
    /// The system's part of the System commands. `AppDelegate` gives snapshot runs inert ones, which do nothing.
    @ObservationIgnored var systemActions: any SystemActions = MacSystemActions()
    /// My Schedule's calendars: EventKit's, or a snapshot run's made-up ones (`FixedCalendarSource`).
    @ObservationIgnored var calendarSource: any CalendarSource = EventKitCalendarSource()

    /// "Sign in to <provider>" on screen, over whatever the command shows (SPEC-056).
    private(set) var signIn: SignInPrompt?
    /// Where sign-ins are kept: the Keychain, set by the app delegate; memory in snapshot runs.
    @ObservationIgnored var tokenSecrets: any SecretStore = MemorySecretStore()
    /// Opens a sign-in's URL in the default browser; false when it couldn't.
    @ObservationIgnored var openInBrowser: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    /// Each session's latest `oauth.prepare` and the one the prompt shows, with their loopback listeners, and the relay
    /// sign-ins pending (`SignInCalls.pending`).
    @ObservationIgnored private var signInRequests = SignInRequests<OAuthLoopback>()
    /// `node --version` per binary, read off the main actor (SPEC-084).
    @ObservationIgnored private let nodeVersions = NodeVersionCache()
    /// The user's answer to the prompt on screen: true for ↵, false for Esc or the command going away.
    @ObservationIgnored private var signInAnswer: CheckedContinuation<Bool, Never>?

    struct AlertRequest {
        var title: String
        var message: String?
        var primary: String
        var dismiss: String
        var destructive: Bool
        /// A last paragraph with a link in it, which a sheet draws below the message (the Extension Store's).
        var footnote: Footnote? = nil

        struct Footnote {
            var text: String
            var linkText: String
            var url: URL
        }
    }

    @ObservationIgnored private let paths: FudgePaths
    @ObservationIgnored private var items: [RootItem] = []
    @ObservationIgnored private var extensions: [String: InstalledExtension] = [:]
    @ObservationIgnored private var history: LaunchHistory
    @ObservationIgnored private var host: ExtensionHost?
    /// The sessions host messages may name (SPEC-067).
    @ObservationIgnored private var hostSessions = HostSessions()
    /// Answers Search Files' `files.search` through Spotlight. `AppDelegate` gives snapshot runs fixed results.
    @ObservationIgnored var fileSearch = FileSearch { SpotlightFileQuery() }
    /// The clipboard's text for a quicklink's or snippet's `{clipboard}`: none when it's concealed or transient
    /// (`QuicklinkTemplate.clipboardText`). In snapshot runs it's always none, so no snapshot shows the user's clipboard.
    @ObservationIgnored var templateClipboard: @MainActor () -> String? = {
        let pasteboard = NSPasteboard.general
        return QuicklinkTemplate.clipboardText(
            pasteboard.string(forType: .string), types: (pasteboard.types ?? []).map(\.rawValue))
    }
    /// Clipboard history (SPEC-077): its watcher, its encrypted store and its calls. `AppDelegate` gives snapshot
    /// runs a fixed history, never the real clipboard or Keychain.
    @ObservationIgnored lazy var clipboardHistory = ClipboardHistoryService(
        paths: paths, secrets: KeychainSecretStore(service: ClipboardHistoryStore.keychainService),
        turns: SystemCalls.pasteboardTurns)
    /// Whether clipboard history may watch the pasteboard: never in snapshot runs.
    @ObservationIgnored let watchesClipboard = !Snapshot.isRequested(CommandLine.arguments)
    /// No-view commands still running, by session.
    @ObservationIgnored private var background: [String: String] = [:]
    /// No-view commands that `launchCommand` started in the background, by session. They leave the panel alone.
    @ObservationIgnored private var quietSessions: [String: QuietSession] = [:]
    /// HUDs for background calls that were refused without asking, each shown once per run.
    @ObservationIgnored private var backgroundNotices = OncePerRun()

    struct QuietSession {
        var title: String
        /// A failure was already shown, so the crash that follows it isn't shown again.
        var failed = false
        /// Its `launchCommand` calls refused without asking (`permissionNeeded`). The HUD already said so once per
        /// pair, so the command failing with one of these, uncaught, is only logged.
        var unasked: Set<String> = []
    }
    /// The extension each session belongs to.
    @ObservationIgnored private var sessionExtensions: [String: String] = [:]

    /// Unloads every running session of `extensionName`'s commands and waits until each has exited (the host stops a
    /// worker 1 s after `unload` at the latest), or 2 s. Turning the Extension Store off calls it before deleting the
    /// copy the store's git works in; the store ends its git when it's unloaded. A view of it on screen goes back to
    /// root search.
    func unloadSessions(ofExtension extensionName: String) async {
        let sessions = sessionExtensions.filter { $0.value == extensionName }.map(\.key)
        guard !sessions.isEmpty else { return }
        for session in sessions {
            // A view under Fudge's form goes; the form then closes to root search.
            if builtInForm?.returnTo?.session == session { builtInForm?.returnTo = nil }
            if case .command(let command) = screen, command.session == session {
                leaveCommand()
                refreshResults()
            } else {
                send(.unload(session: session))
            }
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while sessions.contains(where: { sessionExtensions[$0] != nil }), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
    /// The command each session runs, by name.
    @ObservationIgnored private var sessionCommands: [String: String] = [:]
    /// The subtitles commands set for themselves (`updateCommandMetadata`).
    @ObservationIgnored private var commandMetadata = CommandMetadata()
    @ObservationIgnored private var icons: [String: NSImage] = [:]
    @ObservationIgnored private let dropdownStore: SearchBarDropdown.Store
    @ObservationIgnored private var searchDebounce: Task<Void, Never>?
    /// The active menu-bar commands. Their sessions run in this model's extension host.
    @ObservationIgnored let menuBar: MenuBarController

    /// When the panel was hidden, and whether it starts over on root search when it's shown again (FUD-48).
    @ObservationIgnored let panelReset: PanelReset

    init(paths: FudgePaths) {
        self.paths = paths
        panelReset = PanelReset(setting: FudgeSettings.load(from: paths.settingsFile).resetAfter)
        history = LaunchHistory.load(from: paths.historyFile)
        dropdownStore = SearchBarDropdown.Store(file: paths.dropdownValuesFile)
        menuBar = MenuBarController(paths: paths)
        menuBar.host = MenuBarController.Host(
            launch: { [weak self] installed, command, userInitiated in
                self?.launchMenuBarCommand(installed, command: command, userInitiated: userInitiated)
                    ?? .failure(MenuBarController.LaunchFailed(message: "Fudge is quitting"))
            },
            send: { [weak self] message in self?.send(message) },
            showHUD: { [weak self] title in self?.showHUD(title) },
            log: { [weak self] session, level, message in self?.log(session, level, message) }
        )
        reload()
        // The extension host's first start shouldn't wait for `node --version` (SPEC-084).
        if let node = Runtime.locateNode() { warmNodeVersion(node) }
    }

    /// Clear Search History: root search forgets which results were opened, in memory and in `history.json`.
    func clearHistory() {
        history.clear()
        do {
            try history.save(to: paths.historyFile)
        } catch {
            FileHandle.standardError.write(Data("fudge: couldn't clear the search history: \(error)\n".utf8))
        }
        refreshResults()
    }

    /// After an import: root search's ranking comes from the imported `history.json`, and everything else is
    /// read again.
    func reloadAfterImport() {
        history = LaunchHistory.load(from: paths.historyFile)
        reload()
    }

    /// Finds applications and installed extensions again: the menu's Reload Extensions, and launch.
    func reload() {
        readInstalledExtensions()
        applications = ApplicationIndex.scan()
        quicklinkApplicationList = nil
        applySettings()
    }

    /// Reads the installed extensions again and keeps the applications already scanned: the extensions folder
    /// changed (`ExtensionsWatcher`). The root query stays, and so does the selection while its item is still
    /// there, with the action panel open on it. A running command keeps the code it loaded.
    func reloadExtensions() {
        readInstalledExtensions()
        applySettings(keepingSelection: true)
    }

    private func readInstalledExtensions() {
        // The bundled Extension Store is listed with them; its Enabled is off by default (`FudgeSettings`).
        installedExtensions = InstalledExtension.all(paths: paths, resources: Bundle.main.resourceURL)
        extensions = Dictionary(
            installedExtensions.map { ($0.manifest.name, $0) }, uniquingKeysWith: { first, _ in first })
        loadCommandMetadata(installedExtensions)
    }

    /// Rebuilds root search and the menu bar from `settings.json`: commands that are disabled leave them, and the rest
    /// get their aliases and hotkeys. Settings calls it after each change.
    func applySettings(keepingSelection: Bool = false) {
        settings = FudgeSettings.load(from: paths.settingsFile)
        panelReset.setting = settings.resetAfter
        let commands = installedExtensions.flatMap { RootItem.commands(of: $0, metadata: commandMetadata) }
        windowLayouts = WindowLayoutStore.load(from: paths.windowLayoutsFile)
        items =
            RootSearch.applying(settings, to: commands + builtInGroups.flatMap(RootItem.builtInCommands))
            + RootSearch.builtInItems + RootSearch.applying(settings, to: loadQuicklinks()) + applications
        menuBar.update(installed: installedExtensions, settings: settings)
        clipboardHistory.apply(settings, watch: watchesClipboard)
        refreshResults(keepingSelection: keepingSelection)
        refreshCommandHotkeys()
    }

    @ObservationIgnored private var installedExtensions: [InstalledExtension] = []
    @ObservationIgnored private var applications: [RootItem] = []

    /// The user's custom window positions and saved layouts (SPEC-094), read again with the settings.
    @ObservationIgnored private var windowLayouts = WindowLayoutStore()

    /// Fudge's command groups, with the user's own window commands (`BuiltInCommandGroup.all(with:)`).
    var builtInGroups: [BuiltInCommandGroup] { BuiltInCommandGroup.all(with: windowLayouts) }

    /// Reads `quicklinks.json` for root search. Their icons are looked up again, since an app may have changed.
    private func loadQuicklinks() -> [RootItem] {
        icons = icons.filter { !$0.key.hasPrefix("quicklink:") }
        quicklinks = QuicklinkStore.load(from: paths.quicklinksFile).quicklinks
        return quicklinks.map(RootItem.quicklink)
    }

    /// Every quicklink, enabled or not, as `applySettings` last read them.
    @ObservationIgnored private var quicklinks: [Quicklink] = []
    /// `settings.json`: command hotkeys, aliases and enabled states.
    @ObservationIgnored private(set) var settings = FudgeSettings()

    /// Reads `command-metadata.json`, dropping the entries of commands that aren't installed.
    private func loadCommandMetadata(_ installed: [InstalledExtension]) {
        var metadata = CommandMetadata.load(from: paths.commandMetadataFile)
        let ids = installed.flatMap { installed in
            installed.manifest.commands.map {
                FudgeSettings.commandID(extension: installed.manifest.name, command: $0.name)
            }
        }
        if metadata.prune(keeping: Set(ids)) { try? metadata.save(to: paths.commandMetadataFile) }
        commandMetadata = metadata
    }

    /// `updateCommandMetadata` from the command running in `session`: stores its subtitle, which root search
    /// shows the next time it's drawn. The results keep their order and selection.
    private func updateCommandMetadata(_ params: JSONValue, from session: String) throws {
        guard let extensionName = sessionExtensions[session], let commandName = sessionCommands[session],
            let installed = extensions[extensionName]
        else { throw CommandMetadata.InvalidMetadata("the calling command isn't running") }
        let subtitle = try CommandMetadata.subtitle(fromParams: params)
        var metadata = commandMetadata
        metadata.setSubtitle(subtitle, extension: extensionName, command: commandName)
        try metadata.save(to: paths.commandMetadataFile)
        commandMetadata = metadata
        // Through the settings too, so the command keeps its alias.
        let fresh = Dictionary(
            RootSearch.applying(settings, to: RootItem.commands(of: installed, metadata: metadata)).map { ($0.id, $0) },
            uniquingKeysWith: { a, _ in a })
        items = items.map { fresh[$0.id] ?? $0 }
        results = results.map { fresh[$0.id] ?? $0 }
    }

    // MARK: - Search

    /// The search field: the root query, or the running command's search text.
    var searchText: String {
        get {
            if case .command(let command) = screen { return command.searchText }
            return rootQuery
        }
        set {
            // SwiftUI's TextField writes its unchanged text back now and then, three times on ↵ before onSubmit.
            // Taken as a new search, that would move the selection back to the first item. The action panel's
            // and the dropdown's search fields ignore such writes for the same reason.
            guard newValue != searchText else { return }
            switch screen {
            case .command(var command):
                // Typing after a key that waits for the selected item's actions means the user has moved on.
                hold(nil)
                command.searchText = newValue
                command.searchField.edit(.string(newValue))
                // The command hears the new text first, so it works on its results while the list is filtered here.
                let told = commandSearchChanged(command)
                refreshList(&command, selectFirst: true, reread: false)
                // A command that filters itself sends its results later: the first render of them selects their first
                // item too (`TypingSelection`).
                if let view = command.view, !ListContent.filtersLocally(view) {
                    command.typing.typed()
                    if told { command.typing.told(items: command.list?.items.map(\.id) ?? []) }
                }
                screen = .command(command)
                requestSlots()
                reportSelection()
            case .root, .failure:
                if case .failure = screen { screen = .root }
                // An alias and a space hand the rest of the query to that command's first argument (as in Raycast).
                if let handed = CommandAliases.handOff(newValue, in: items) {
                    rootQuery = String(newValue.prefix { $0 != " " })
                    refreshResults()
                    selectedItem = handed.item.id
                    arguments.set(handed.rest, at: 0)
                    arguments.focus = 0
                    return
                }
                rootQuery = newValue
                refreshResults()
            }
        }
    }

    var placeholder: String {
        if case .command(let command) = screen {
            return command.view?.string("searchBarPlaceholder") ?? "Search \(command.title)…"
        }
        return "Search for apps and commands…"
    }

    /// Ranks root search again. The first row is selected, unless `keepingSelection` and the selected row is still
    /// there: then the selection doesn't change, so the action panel open on it stays open.
    private func refreshResults(keepingSelection: Bool = false) {
        calculator = evaluateCalculator()
        results = RootSearch.rank(items, query: rootQuery, history: history)
        let rows = rootRows
        if keepingSelection, let selectedItem, rows.contains(where: { $0.id == selectedItem }) {
            // A rebuild may have changed the command's arguments.
            syncArguments()
            return
        }
        selectedItem = rows.first?.id
    }

    /// Root search's rows in the order they're drawn and moved through (`RootSearch.rows`): a command whose alias
    /// the query is exactly, then the Calculator card, then the other results.
    var rootRows: [RootRow] {
        RootSearch.rows(results, query: rootQuery, hasCalculator: calculator != nil)
    }

    // MARK: - The calculator

    /// The Calculator card's answer to the root query, when it's a calculation.
    private(set) var calculator: CalculatorResult?

    /// What the calculator knows about exchange rates, from the app's `ExchangeRateUpdater`. A change evaluates a
    /// currency card again (`Calculator.afterRatesChange`), so "Downloading exchange rates…" turns into the answer
    /// when the rates arrive, keeping the selection. That happens with a command open too, so the card is right when
    /// the user comes back to root search.
    var currency: CurrencyState = .off {
        didSet {
            guard currency != oldValue else { return }
            let wasSelected = selectedItem == Self.calculatorID
            calculator = Calculator.afterRatesChange(calculator, evaluate: evaluateCalculator)
            if case .root = screen, calculator == nil, wasSelected { selectedItem = results.first?.id }
        }
    }

    /// "Same as macOS" is resolved here, for each query, so a change in System Settings applies at once.
    private func evaluateCalculator() -> CalculatorResult? {
        let locale = Locale.current
        return Calculator.evaluate(
            rootQuery, locale: locale, format: settings.numberFormat.resolve(locale), now: Date(), timeZone: .current,
            currency: currency)
    }

    /// ↵ on the Calculator card: copy its answer, or what the card offers instead (turning currency on, retrying).
    private func activateCalculator() {
        switch calculator?.enter {
        case .copy: copyCalculatorAnswer()
        case .turnOnCurrencyConversion: showSettings(extension: nil)
        case .retryExchangeRates: retryExchangeRates()
        case .nothing, nil: break
        }
    }

    /// The `selectedItem` of the Calculator card.
    static let calculatorID = RootRow.calculatorID

    private var rootRowIDs: [String] { rootRows.map(\.id) }

    /// Copies the calculator's answer (or the question and answer), then closes the panel with a HUD, as Raycast
    /// does. The clipboard is written the way extensions' `Clipboard.copy` writes it.
    func copyCalculatorAnswer(withQuestion: Bool = false) {
        guard let calculator else { return }
        let text = withQuestion ? calculator.questionAndAnswer : calculator.copyText
        Task {
            _ = try? await SystemCalls.handle(
                "clipboard.copy", .object(["text": .string(text)]), origin: .userInitiated)
        }
        hide()
        showHUD("Copied to Clipboard")
    }

    /// The item selected in root search.
    var selectedRootItem: RootItem? {
        results.first { $0.id == selectedItem }
    }

    // MARK: - The keyboard

    /// Counts the requests to put the keyboard back in the field the screen wants (`keyboardTarget`). The view
    /// answers each one. Requests come each time the panel is shown and after a click on a row: either can leave
    /// AppKit's first responder outside every field, so typing would go nowhere.
    private(set) var keyboardRequests = 0

    /// The panel was just hidden (`AppDelegate.hidePanel`, which every hide goes through). A held key is dropped,
    /// saying nothing, so it never runs or times out out of sight.
    func panelHidden() {
        hold(nil)
        switchWindowsHidden()
        menuItemsHidden()
    }

    /// The panel was just shown.
    func presented() {
        // A dropdown argument takes no typing: showing the panel goes back to the search field, keeping the values.
        if let index = arguments.focus, arguments.arguments.indices.contains(index),
            arguments.arguments[index].type == "dropdown"
        {
            arguments.focus = nil
        }
        // Switch Windows reads the windows again each time it's shown.
        if windowListStale, switchWindowsOnScreen { readWindows(selectFirst: true) }
        // Search Menu Items reads the menus of the app the user is in now.
        if menuItemsStale, menuItemsOnScreen { readMenuItems() }
        restoreKeyboard()
    }

    /// Asks the view to put the keyboard back in the field the screen wants.
    func restoreKeyboard() {
        keyboardRequests += 1
    }

    /// The field that should have the keyboard now.
    var keyboardTarget: KeyboardFocus.Target {
        KeyboardFocus.target(
            for: keyboardScreen, actionPanelOpen: actionPanel != nil, dropdownPanelOpen: dropdownPanel != nil)
    }

    private var keyboardScreen: KeyboardFocus.Screen {
        switch screen {
        case .root:
            let index = arguments.focus
            let isDropdown = index.map {
                arguments.arguments.indices.contains($0) && arguments.arguments[$0].type == "dropdown"
            }
            return .root(argument: index, argumentIsDropdown: isDropdown ?? false)
        case .failure:
            return .failure
        case .command(let command):
            if command.failure != nil || command.view == nil || command.list != nil { return .search }
            guard let form = command.form else { return .noField }
            let editable = form.fields.filter(\.isEditable)
            let first = (editable.first(where: \.autoFocus) ?? editable.first)?.id
            let last = command.lastFormField.flatMap { id in editable.contains { $0.id == id } ? id : nil }
            return .form(lastField: last, firstField: first)
        }
    }

    /// A Form field took the keyboard: the one that had it hears `onBlur`, this one `onFocus`. Moments without a
    /// field (the keyboard going back through nil, the action panel) don't count, so each fires once per change.
    func formFieldFocused(_ node: Int) {
        guard var command, command.lastFormField != node else { return }
        let previous = command.lastFormField
        command.lastFormField = node
        screen = .command(command)
        if let previous, let field = formField(previous), field.hasOnBlur {
            let event = field.focusEvent("blur", value: fieldValue(previous) ?? .null)
            send(.event(session: command.session, node: previous, path: ["onBlur"], args: [event]))
        }
        if let field = formField(node), field.hasOnFocus {
            let event = field.focusEvent("focus", value: fieldValue(node) ?? .null)
            send(.event(session: command.session, node: node, path: ["onFocus"], args: [event]))
        }
    }

    // MARK: - Arguments

    /// Gives a command selected in root search empty argument fields, and drops them when the selection moves on
    /// or the command's arguments change (Reload Extensions). They're kept while a command or a failure is on
    /// screen, so a launch that couldn't start doesn't lose what was typed; a launch clears them.
    private func syncArguments() {
        let item = selectedRootItem
        guard item?.id != argumentsItem || (item?.arguments ?? []) != arguments.arguments else { return }
        resetArguments(for: item)
    }

    private func resetArguments(for item: RootItem?) {
        argumentsItem = item?.id
        arguments = ArgumentInput(arguments: item?.arguments ?? [])
        argumentsGeneration += 1
    }

    /// The user edited an argument field drawn for `generation`.
    func setArgument(_ value: String, at index: Int, generation: Int) {
        guard generation == argumentsGeneration else { return }
        arguments.set(value, at: index)
    }

    /// The user clicked into an argument field (an index) or the search field (nil).
    func focusArgument(_ index: Int?) {
        if arguments.focus != index { arguments.focus = index }
    }

    // MARK: - Command views

    /// The running command's screen, if one is showing.
    var command: CommandScreen? {
        if case .command(let command) = screen { return command }
        return nil
    }

    /// Whether the top view says it's loading.
    var isLoading: Bool {
        command?.view?.bool("isLoading") == true
    }

    /// The selected item of the running command's List, with its deferred `actions` and `detail` once they've come.
    var selectedListItem: ListContent.Item? {
        guard let command, let items = command.list?.items,
            let item = items.first(where: { $0.id == command.selectedNode }) ?? items.first
        else { return nil }
        return item.filled(with: command.slots[item.id])
    }

    /// The actions for what's selected: in root search, fudge's own for the selected item (`RootActions`); in a
    /// command, the selected item's; with no items, the empty view's or the List's own; for other views, the
    /// view's own.
    var currentActions: [ActionSection] {
        if case .failure(let failure) = screen { return failure.notice?.actions ?? [] }
        if case .root = screen {
            if selectedItem == Self.calculatorID {
                return RootActions.calculatorSections(for: calculator?.enter ?? .copy)
            }
            var isActiveInMenuBar = false
            if case .command(let extensionName, let commandName, "menu-bar", _) = selectedRootItem?.kind {
                isActiveInMenuBar = menuBar.isActive(
                    FudgeSettings.commandID(extension: extensionName, command: commandName))
            }
            return RootActions.sections(for: selectedRootItem, isActiveInMenuBar: isActiveInMenuBar)
        }
        guard let command, let view = command.view else { return [] }
        guard let list = command.list else { return ActionPanelReader.sections(of: view.node("actions")) }
        if let item = selectedListItem { return ActionPanelReader.sections(of: item.actions) }
        return ActionPanelReader.sections(of: list.emptyView?.actions ?? view.node("actions"))
    }

    /// Reads the top view's List or Grid again, after it or the search text changed, and keeps the selection on the
    /// same item where it can. Without `reread`, only the search text changed: the items read at the last render are
    /// filtered again. `rendered` is a render from the host, which may bring the results of the user's typing.
    private func refreshList(
        _ command: inout CommandScreen, selectFirst: Bool, reread: Bool = true, rendered: Bool = false
    ) {
        guard let view = command.view, ListContent.viewTypes.contains(view.type) else {
            command.list = nil
            command.dropdown = nil
            return
        }
        let previous = command.list?.items.first { $0.id == command.selectedNode }
        var list: ListContent
        if !reread, let read = command.list {
            list = read
            list.search(command.searchText)
        } else {
            list = ListContent(view, searchText: command.searchText)
        }
        command.list = list
        let typedResults = rendered && command.typing.rendered(items: list.items.map(\.id))
        let selection = list.selection(
            selectedItemId: view.string("selectedItemId"), followed: command.followedItemId,
            selectFirst: selectFirst || typedResults, node: command.selectedNode, itemId: previous?.itemId)
        command.selectedNode = selection.node
        command.followedItemId = selection.followed
        syncDropdown(&command, list.dropdown)
    }

    /// Tells the command which item is selected (`onSelectionChange`) when that changed.
    private func reportSelection() {
        guard var command, let view = command.view, let list = command.list,
            view.hasCallback("onSelectionChange")
        else { return }
        let item = list.items.first { $0.id == command.selectedNode }
        // Nothing to report until the first items arrive.
        if item == nil, list.isLoading { return }
        let id = item.map { $0.itemId ?? String($0.id) }
        if let reported = command.reportedSelection, reported == id { return }
        command.reportedSelection = .some(id)
        screen = .command(command)
        send(
            .event(
                session: command.session, node: view.id, path: ["onSelectionChange"],
                args: [id.map { .string($0) } ?? .null]))
    }

    /// Asks the host for the `actions` and `detail` (`ItemSlots`) of the selected item and those around it, when
    /// `SlotRequests` says so: the selection came near the edge of the last request, or an item near it is still
    /// held back. Renders carry the items of the last request in full, so the selection keeps its actions. Called
    /// before `reportSelection()`, so the host takes the request before the render `onSelectionChange` may cause.
    private func requestSlots() {
        guard var command, let items = command.list?.items else { return }
        let answers = command.slots
        guard
            let ids = command.slotRequests.request(
                items: items, selected: command.selectedNode, answered: { answers[$0] != nil })
        else { return }
        screen = .command(command)
        send(.slots(session: command.session, nodes: ids))
    }

    /// A key pressed before the selected item's actions came, waiting for them (`HeldKey`), and the timer that
    /// drops it at its deadline.
    @ObservationIgnored private var heldKey: HeldKey?
    @ObservationIgnored private var heldKeyTimer: Task<Void, Never>?

    /// Holds `key` until the selected item's actions come, when they haven't yet; false when they're here. It
    /// replaces a key already held, and its time starts over.
    private func waitForActions(_ key: HeldKey.Key) -> Bool {
        guard let command, let item = selectedListItem, item.deferred.contains(.actions) else { return false }
        hold(HeldKey(key, session: command.session, depth: command.depth, node: item.id, pressedAt: .now))
        return true
    }

    /// What the held key is settled against.
    private var heldKeyScreen: HeldKey.Screen {
        let item = selectedListItem
        return HeldKey.Screen(
            panelShown: panelOnScreen(), session: command?.session, depth: command?.depth ?? 0, selected: item?.id,
            actionsCame: item.map { !$0.deferred.contains(.actions) } ?? false)
    }

    /// Drops the held key, and its timer, once the command or view it was pressed in has gone: a push, a pop,
    /// another command or root search.
    private func dropHeldKeyIfLeft() {
        guard let heldKey else { return }
        if case .command(let command) = screen, command.session == heldKey.session, command.depth == heldKey.depth {
            return
        }
        hold(nil)
    }

    /// Sets the held key, or drops it (nil), with a timer that settles it at its deadline.
    private func hold(_ key: HeldKey?) {
        heldKeyTimer?.cancel()
        heldKeyTimer = nil
        heldKey = key
        guard let key else { return }
        heldKeyTimer = Task { [weak self] in
            try? await Task.sleep(until: key.deadline, clock: .continuous)
            guard !Task.isCancelled else { return }
            self?.settleHeldKey()
        }
    }

    /// Runs the held key once the selected item's actions have come. It's dropped when the panel hid, the view
    /// changed or the selection moved meanwhile, and dropped with a failure toast when they didn't come in time.
    private func settleHeldKey() {
        guard let held = heldKey else { return }
        switch held.outcome(at: .now, on: heldKeyScreen) {
        case .wait:
            return
        case .drop:
            hold(nil)
        case .timedOut:
            hold(nil)
            showFailureToast(HeldKey.timeoutMessage)
        case .run(let key):
            hold(nil)
            switch key {
            case .primary: if let primaryAction { run(primaryAction) }
            case .secondary: if let secondaryAction { run(secondaryAction) }
            case .actionPanel: if actionPanel == nil { toggleActionPanel() }
            case .shortcut(let pressed):
                if let entry = ActionPanelReader.action(for: pressed, in: currentActions) { run(entry) }
            }
        }
    }

    /// Selects an item of the List (a click).
    func select(node: Int) {
        guard var command, command.list?.items.contains(where: { $0.id == node }) == true else { return }
        command.selectedNode = node
        command.typing.cancel()
        screen = .command(command)
        requestSlots()
        reportSelection()
    }

    /// Calls a function prop of a node, e.g. a metadata tag's `onAction`.
    func call(node: Int, _ path: [String]) {
        guard let command else { return }
        send(.event(session: command.session, node: node, path: path, args: []))
    }

    // MARK: - Forms

    /// Reads the top view's Form again, keeping what the user typed (see `FieldValue`). Each field's value comes from
    /// `FormContent.Field.start`: a field seen for the first time may start on a value stored for it
    /// (`storeValue`), one whose items haven't arrived keeps its stored value pending until they do, and a dropdown
    /// whose items arrive later takes the first one. When that isn't what the extension's Form holds, the extension
    /// hears it through `onChange`, as with the List's dropdown.
    private func refreshForm(_ command: inout CommandScreen) {
        guard let view = command.view, view.type == "Form" else {
            command.form = nil
            command.fieldValues = [:]
            command.storedFormValues = nil
            command.pendingStoredValues = [:]
            return
        }
        let form = FormContent(view)
        if command.storedFormValues == nil {
            command.storedFormValues = FormValueStore(directory: paths.formValuesDirectory)
                .load(extension: command.extensionName, command: command.commandName)
        }
        var values: [Int: FieldValue] = [:]
        var pending: [Int: JSONValue] = [:]
        var changes: [(node: Int, value: JSONValue)] = []
        for field in form.fields where field.isEditable {
            let existing = command.fieldValues[field.id]
            let stored =
                existing == nil
                ? field.fieldId.flatMap { command.storedFormValues?[$0] } : command.pendingStoredValues[field.id]
            let start = field.start(current: existing?.value, stored: stored)
            var value = existing.flatMap { $0.value == start.value ? $0 : nil } ?? FieldValue(start.value)
            if start.reports { changes.append((field.id, start.value)) }
            if let waiting = start.pending { pending[field.id] = waiting }
            value.render(controlled: field.value)
            values[field.id] = value
        }
        command.form = form
        command.fieldValues = values
        command.pendingStoredValues = pending
        for change in changes {
            send(.event(session: command.session, node: change.node, path: ["onChange"], args: [change.value]))
        }
    }

    /// The submitted form's values to keep (`form.storeValues`, sent by `Action.SubmitForm`): only for fields with
    /// `storeValue`, never a PasswordField's, saved by extension, command and field `id`.
    private func storeFormValues(_ params: JSONValue, session: String) {
        guard case .command(var command) = screen, command.session == session, let form = command.form,
            case .object(let object) = params, case .object(let submitted) = object["values"]
        else { return }
        try? FormValueStore(directory: paths.formValuesDirectory)
            .save(form.valuesToStore(submitted), extension: command.extensionName, command: command.commandName)
        command.storedFormValues = nil
        screen = .command(command)
    }

    /// A Form field, by node id.
    func formField(_ node: Int) -> FormContent.Field? {
        command?.form?.fields.first { $0.id == node }
    }

    /// The user picked a date in a DatePicker, or cleared it (nil): local midnight for a `Date` picker, whole
    /// minutes for `DateTime`, within `min` and `max` (`FormDates.value`).
    func pickDate(_ picked: Date?, for node: Int) {
        guard let options = formField(node)?.dates else { return }
        edit(field: node, to: FormDates.json(picked.map { FormDates.value(for: $0, options: options) }))
    }

    /// A FilePicker's Select…: the open panel, then the chosen paths added (or, without multiple selection, in place
    /// of the old one).
    func chooseFiles(for node: Int) async {
        guard let options = formField(node)?.files, let chosen = await openPanel(options), !chosen.isEmpty else {
            return
        }
        let paths = FilePicking.choosing(chosen, to: TagPicking.values(fieldValue(node)), options: options)
        edit(field: node, to: .array(paths.map(JSONValue.string)))
    }

    /// Takes a path off a FilePicker (its ×).
    func removeFile(_ path: String, from node: Int) {
        let paths = FilePicking.removing(path, from: TagPicking.values(fieldValue(node)))
        edit(field: node, to: .array(paths.map(JSONValue.string)))
    }

    /// A Form field's value as shown.
    func fieldValue(_ node: Int) -> JSONValue? {
        command?.fieldValues[node]?.value
    }

    /// The user changed a Form field: show it, and tell the command (`onChange`).
    func edit(field node: Int, to value: JSONValue) {
        guard var command, command.fieldValues[node] != nil, command.fieldValues[node]?.value != value else { return }
        command.fieldValues[node]?.edit(value)
        // The user's choice wins over a stored value still waiting for the field's items.
        command.pendingStoredValues[node] = nil
        screen = .command(command)
        send(.event(session: command.session, node: node, path: ["onChange"], args: [value]))
    }

    /// The title shown in place of the search field in views that have none (Detail, Form).
    var viewTitle: String? {
        guard let command, let view = command.view, command.list == nil, command.failure == nil else { return nil }
        return view.string("navigationTitle") ?? command.title
    }

    // MARK: - The search bar dropdown

    /// What the search bar dropdown shows: the extension's value when it controls it, else the user's pick.
    var dropdownValue: String? {
        command?.list?.dropdown?.value ?? command?.dropdown?.value
    }

    /// Starts a newly shown dropdown on its first value and tells the command (`onChange`), as Raycast does;
    /// afterwards follows the value when the extension controls it.
    private func syncDropdown(_ command: inout CommandScreen, _ dropdown: SearchBarDropdown?) {
        guard let dropdown else {
            command.dropdown = nil
            return
        }
        if command.dropdown?.node == dropdown.id, command.dropdown?.value != nil {
            if let controlled = dropdown.value { command.dropdown?.value = controlled }
            return
        }
        let key = SearchBarDropdown.Store.key(
            extension: command.extensionName, command: command.commandName, dropdown: dropdown.name)
        let stored = dropdown.storesValue ? dropdownStore.value(for: key) : nil
        let initial = dropdown.initialValue(stored: stored)
        command.dropdown = DropdownState(node: dropdown.id, value: initial)
        if let initial, dropdown.hasOnChange {
            send(.event(session: command.session, node: dropdown.id, path: ["onChange"], args: [.string(initial)]))
        }
    }

    /// The user picked a value in the search bar dropdown.
    func selectDropdownValue(_ value: String) {
        guard var command, let dropdown = command.list?.dropdown else { return }
        command.dropdown = DropdownState(node: dropdown.id, value: value)
        screen = .command(command)
        if dropdown.storesValue {
            let key = SearchBarDropdown.Store.key(
                extension: command.extensionName, command: command.commandName, dropdown: dropdown.name)
            try? dropdownStore.set(value, for: key)
        }
        if dropdown.hasOnChange {
            send(.event(session: command.session, node: dropdown.id, path: ["onChange"], args: [.string(value)]))
        }
    }

    // MARK: - The dropdown's panel (⌘P), also a Form dropdown's and a TagPicker's

    /// What the dropdown panel belongs to.
    enum DropdownPanelSource: Equatable {
        /// The List's search bar dropdown, at the top right.
        case searchBar
        /// A Form.Dropdown, by node id: the panel opens under it.
        case formDropdown(Int)
        /// A Form.TagPicker: the panel lists the items not picked yet, and picking adds one.
        case tagPicker(Int)
    }

    struct DropdownPanelState: Equatable {
        var source: DropdownPanelSource = .searchBar
        var query = ""
        /// The highlighted item's value.
        var selected: String?
    }

    /// The open dropdown panel: its own search field and items.
    private(set) var dropdownPanel: DropdownPanelState?
    @ObservationIgnored private var dropdownSearchDebounce: Task<Void, Never>?

    /// The dropdown the open panel shows, for a search bar or Form dropdown.
    private var panelDropdown: SearchBarDropdown? {
        switch dropdownPanel?.source {
        case .searchBar?: command?.list?.dropdown
        case .formDropdown(let node)?: formField(node)?.options
        case .tagPicker?, nil: nil
        }
    }

    /// The items the open dropdown panel shows, filtered by its search text when fudge filters them. A TagPicker's
    /// are the items not picked yet.
    var dropdownPanelSections: [SearchBarDropdown.Section] {
        guard let dropdownPanel else { return [] }
        if case .tagPicker(let node) = dropdownPanel.source {
            guard let field = formField(node) else { return [] }
            let items = TagPicking.suggestions(
                field.tags, chosen: TagPicking.values(fieldValue(node)), query: dropdownPanel.query)
            return items.isEmpty ? [] : [SearchBarDropdown.Section(title: nil, items: items)]
        }
        return panelDropdown?.sections(matching: dropdownPanel.query) ?? []
    }

    /// The Form field whose panel is open (a Dropdown or TagPicker), if any.
    var formPanelField: Int? {
        switch dropdownPanel?.source {
        case .formDropdown(let node)?, .tagPicker(let node)?: node
        case .searchBar?, nil: nil
        }
    }

    /// The open panel's search field placeholder.
    var dropdownPanelPlaceholder: String {
        if case .tagPicker = dropdownPanel?.source { return "Search tags…" }
        return panelDropdown?.placeholder ?? "Search…"
    }

    var dropdownPanelIsLoading: Bool { panelDropdown?.isLoading == true }

    /// Whether the open panel's item `value` is the current choice, for its checkmark.
    func dropdownPanelChecks(_ value: String) -> Bool {
        switch dropdownPanel?.source {
        case .searchBar?: value == dropdownValue
        case .formDropdown(let node)?: fieldValue(node) == .string(value)
        case .tagPicker?, nil: false
        }
    }

    var dropdownPanelQuery: String {
        get { dropdownPanel?.query ?? "" }
        set {
            guard dropdownPanel != nil, newValue != dropdownPanelQuery, let command else { return }
            dropdownPanel?.query = newValue
            let first = dropdownPanelSections.flatMap(\.items).first?.value
            dropdownPanel?.selected = first
            if let dropdown = panelDropdown {
                dropdownSearchChanged(newValue, dropdown: dropdown, session: command.session)
            }
        }
    }

    func toggleDropdownPanel() {
        if dropdownPanel != nil {
            closeDropdownPanel()
        } else if command?.list?.dropdown != nil {
            actionPanel = nil
            dropdownPanel = DropdownPanelState(selected: dropdownValue)
        }
    }

    /// Opens a Form.Dropdown's panel under it (Space, ↵ or a click).
    func openFormDropdown(_ node: Int) {
        guard formField(node)?.kind == .dropdown else { return }
        actionPanel = nil
        datePanel = nil
        let current: String? = if case .string(let value) = fieldValue(node) { value } else { nil }
        dropdownPanel = DropdownPanelState(source: .formDropdown(node), selected: current)
        syncDropdownPanel()
    }

    /// Opens the panel of the Form's first field of `kind` (a Dropdown, TagPicker or DatePicker), for snapshots.
    /// False when there's none.
    func openFirstFormPicker(_ kind: FormContent.Kind) -> Bool {
        guard let field = command?.form?.fields.first(where: { $0.kind == kind }) else { return false }
        formFieldFocused(field.id)
        switch kind {
        case .tagPicker: openTagPicker(field.id)
        case .datePicker: openDatePanel(field.id)
        default: openFormDropdown(field.id)
        }
        return dropdownPanel != nil || datePanel != nil
    }

    /// Opens a TagPicker's list of items to pick, starting the search with what was typed, if anything.
    func openTagPicker(_ node: Int, typing text: String = "") {
        guard formField(node)?.kind == .tagPicker else { return }
        actionPanel = nil
        datePanel = nil
        dropdownPanel = DropdownPanelState(source: .tagPicker(node), query: text)
        syncDropdownPanel()
    }

    func closeDropdownPanel() {
        guard let panel = dropdownPanel else { return }
        let dropdown = panelDropdown
        dropdownPanel = nil
        // The dropdown's search text clears with it.
        if !panel.query.isEmpty, let command, let dropdown {
            dropdownSearchChanged("", dropdown: dropdown, session: command.session)
        }
    }

    func moveDropdownSelection(by offset: Int) {
        let items = dropdownPanelSections.flatMap(\.items)
        guard !items.isEmpty else { return }
        let index = items.firstIndex { $0.value == dropdownPanel?.selected } ?? 0
        dropdownPanel?.selected = items[max(0, min(items.count - 1, index + offset))].value
    }

    /// Picks an item in the dropdown's panel: the search bar's or a Form dropdown's value, then the panel closes; or
    /// another tag for a TagPicker, with the panel staying open for the next.
    func pickDropdownItem(_ value: String? = nil) {
        guard let panel = dropdownPanel, let value = value ?? panel.selected else { return }
        switch panel.source {
        case .searchBar:
            closeDropdownPanel()
            selectDropdownValue(value)
        case .formDropdown(let node):
            closeDropdownPanel()
            edit(field: node, to: .string(value))
        case .tagPicker(let node):
            guard let field = formField(node) else { return }
            let chosen = TagPicking.adding(value, to: TagPicking.values(fieldValue(node)), items: field.tags)
            edit(field: node, to: .array(chosen.map(JSONValue.string)))
            dropdownPanel?.query = ""
            // Read before writing: assigning while reading dropdownPanel is an exclusivity violation.
            let next = dropdownPanelSections.flatMap(\.items).first?.value
            dropdownPanel?.selected = next
        }
    }

    /// ⌫ in the open panel's empty search field: for a TagPicker, takes the last tag off. Returns false otherwise.
    func dropdownPanelDeleteBackward() -> Bool {
        guard let panel = dropdownPanel, panel.query.isEmpty, case .tagPicker(let node) = panel.source else {
            return false
        }
        let chosen = TagPicking.values(fieldValue(node))
        guard let last = chosen.last else { return true }
        removeTag(last, from: node)
        return true
    }

    /// Takes a tag off a TagPicker (its ×, or ⌫).
    func removeTag(_ value: String, from node: Int) {
        let chosen = TagPicking.removing(value, from: TagPicking.values(fieldValue(node)))
        edit(field: node, to: .array(chosen.map(JSONValue.string)))
        if case .tagPicker(node)? = dropdownPanel?.source, dropdownPanel?.selected == nil {
            let next = dropdownPanelSections.flatMap(\.items).first?.value
            dropdownPanel?.selected = next
        }
    }

    /// ↑↓ on a focused Form.Dropdown with its panel closed: the previous or next item, as Raycast does.
    func stepFormDropdown(_ node: Int, by offset: Int) {
        guard let items = formField(node)?.options?.items, !items.isEmpty else { return }
        let current: String? = if case .string(let value) = fieldValue(node) { value } else { nil }
        let index = items.firstIndex { $0.value == current }
        let next = index.map { max(0, min(items.count - 1, $0 + offset)) } ?? (offset > 0 ? 0 : items.count - 1)
        edit(field: node, to: .string(items[next].value))
    }

    /// Keeps the open panel's highlight on an item that's still shown, as the extension's search results change,
    /// and closes it when what it belongs to is gone.
    private func syncDropdownPanel() {
        guard let panel = dropdownPanel else { return }
        let present =
            switch panel.source {
            case .searchBar: command?.list?.dropdown != nil
            case .formDropdown(let node): formField(node)?.kind == .dropdown
            case .tagPicker(let node): formField(node)?.kind == .tagPicker
            }
        guard present else {
            dropdownPanel = nil
            return
        }
        let items = dropdownPanelSections.flatMap(\.items)
        if !items.contains(where: { $0.value == dropdownPanel?.selected }) {
            let first = items.first?.value
            dropdownPanel?.selected = first
        }
    }

    // MARK: - A DatePicker's calendar

    struct DatePanelState: Equatable {
        /// The DatePicker's node id: the calendar opens under it.
        let node: Int
        var calendar: DateCalendar
    }

    /// The open DatePicker calendar. The field keeps the keyboard, and `handleKey` gives the calendar its keys.
    private(set) var datePanel: DatePanelState?

    /// Opens a DatePicker's calendar (Space, ↵ or a click) on its day, or today. Opening picks nothing.
    func openDatePanel(_ node: Int) {
        guard let options = formField(node)?.dates else { return }
        actionPanel = nil
        closeDropdownPanel()
        datePanel = DatePanelState(
            node: node, calendar: DateCalendar(value: FormDates.date(fieldValue(node)), options: options))
    }

    func closeDatePanel() {
        datePanel = nil
    }

    func moveDatePanel(days: Int) {
        datePanel?.calendar.move(days: days)
    }

    func moveDatePanel(months: Int) {
        datePanel?.calendar.move(months: months)
    }

    /// Picks the highlighted day, or a clicked one, as the field's value, and closes the calendar. A clicked day
    /// outside `min` and `max` does nothing.
    func pickDatePanelDay(_ day: Date? = nil) {
        guard var panel = datePanel else { return }
        if let day, !panel.calendar.highlight(day) { return }
        datePanel = nil
        pickDate(panel.calendar.value(current: FormDates.date(fieldValue(panel.node))), for: panel.node)
    }

    /// The calendar's keys while it's open: ←→ a day, ↑↓ a week, ⇞⇟ a month, ↵ or Space picks, Esc closes it. Any
    /// other key closes it and then does what it always does (Tab moves on, ⌘↵ submits, ⌫ clears the field).
    private func handleDatePanelKey(_ pressed: KeyShortcut) -> Bool {
        guard pressed.modifiers.isEmpty else {
            closeDatePanel()
            return false
        }
        switch pressed.key {
        case "arrowLeft": moveDatePanel(days: -1)
        case "arrowRight": moveDatePanel(days: 1)
        case "arrowUp": moveDatePanel(days: -7)
        case "arrowDown": moveDatePanel(days: 7)
        case "pageUp": moveDatePanel(months: -1)
        case "pageDown": moveDatePanel(months: 1)
        case "return", "enter", "space": pickDatePanelDay()
        case "escape": closeDatePanel()
        default:
            closeDatePanel()
            return false
        }
        return true
    }

    /// Closes the calendar when its field is gone, or is no longer a DatePicker.
    private func syncDatePanel() {
        guard let panel = datePanel, formField(panel.node)?.dates == nil else { return }
        datePanel = nil
    }

    /// Tells the dropdown its search text changed (`onSearchTextChange`); with `throttle`, once typing pauses.
    private func dropdownSearchChanged(_ text: String, dropdown: SearchBarDropdown, session: String) {
        dropdownSearchDebounce?.cancel()
        guard dropdown.handlesSearch else { return }
        let event = AppMessage.event(
            session: session, node: dropdown.id, path: ["onSearchTextChange"], args: [.string(text)])
        guard dropdown.throttle else {
            send(event)
            return
        }
        dropdownSearchDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.send(event)
        }
    }

    // MARK: - Pages

    /// Asks the List for its next page (`pagination.onLoadMore`) when the item `node` is near the end,
    /// at most once for each length the list has had.
    func loadMoreIfNeeded(near node: Int) {
        guard var command, let view = command.view, let list = command.list,
            let index = list.items.firstIndex(where: { $0.id == node }),
            list.wantsMore(near: index), command.requestedMoreAt != list.items.count
        else { return }
        command.requestedMoreAt = list.items.count
        // The next page is appended: what's selected stays.
        command.typing.cancel()
        screen = .command(command)
        send(.event(session: command.session, node: view.id, path: ["pagination", "onLoadMore"], args: []))
    }

    /// What ↵ does.
    var primaryAction: ActionEntry? { ActionPanelReader.primary(currentActions) }

    /// What ⌘↵ does.
    var secondaryAction: ActionEntry? { ActionPanelReader.secondary(currentActions) }

    // MARK: - The action panel (⌘K)

    struct ActionPanelState: Equatable {
        /// The submenus opened, outermost first.
        var path: [Int] = []
        var query = ""
        var selected: Int?
        /// An `Action.PickDate`'s picker, shown in place of the action list.
        var pick: DatePick?
    }

    private(set) var actionPanel: ActionPanelState?

    /// The entries the open action panel shows: the current submenu's, filtered by its search.
    var actionPanelSections: [ActionSection] {
        guard let actionPanel else { return [] }
        var sections = currentActions
        for id in actionPanel.path {
            guard let submenu = ActionPanelReader.flat(sections).first(where: { $0.id == id })?.submenu else {
                return []
            }
            sections = submenu
        }
        return ActionPanelReader.filter(sections, query: actionPanel.query)
    }

    var actionPanelQuery: String {
        get { actionPanel?.query ?? "" }
        set {
            guard actionPanel != nil, newValue != actionPanelQuery else { return }
            actionPanel?.query = newValue
            // Read before writing: assigning while reading actionPanel is an exclusivity violation.
            let first = ActionPanelReader.flat(actionPanelSections).first?.id
            actionPanel?.selected = first
        }
    }

    func toggleActionPanel() {
        if actionPanel != nil {
            actionPanel = nil
        } else if !currentActions.isEmpty {
            closeDropdownPanel()
            datePanel = nil
            actionPanel = ActionPanelState(selected: ActionPanelReader.flat(currentActions).first?.id)
        }
    }

    func moveActionSelection(by offset: Int) {
        let entries = ActionPanelReader.flat(actionPanelSections)
        guard !entries.isEmpty else { return }
        let index = entries.firstIndex { $0.id == actionPanel?.selected } ?? 0
        actionPanel?.selected = entries[max(0, min(entries.count - 1, index + offset))].id
    }

    func runSelectedAction() {
        if let entry = ActionPanelReader.flat(actionPanelSections).first(where: { $0.id == actionPanel?.selected }) {
            run(entry)
        }
    }

    /// Runs an action, or opens a submenu or an `Action.PickDate`'s picker in the action panel.
    func run(_ entry: ActionEntry) {
        if let options = entry.pickDate {
            openDatePick(entry, options: options)
            return
        }
        if let submenu = entry.submenu {
            // Picked in the panel, or run by its shortcut with the panel shut or showing another submenu.
            var state = actionPanel ?? ActionPanelState()
            state.path = ActionPanelReader.path(to: entry.id, in: currentActions) ?? state.path + [entry.id]
            state.query = ""
            state.selected = ActionPanelReader.flat(submenu).first?.id
            actionPanel = state
            // `Action.Submenu`'s `onOpen`: e.g. Open With lists the applications only now.
            if entry.hasOnOpen, case .node(let node) = entry.target, case .command(let command) = screen {
                send(.event(session: command.session, node: node, path: ["onOpen"], args: []))
            }
            return
        }
        actionPanel = nil
        switch entry.target {
        case .node(let node):
            guard case .command(let command) = screen else { return }
            send(.event(session: command.session, node: node, path: ["onAction"], args: []))
        case .root(let action):
            switch screen {
            case .root, .failure: perform(action)  // a failure's are its notice's
            case .command: return
            }
        case .createQuicklink(let request):
            guard case .command(let command) = screen, !Self.builtInSessions.contains(command.session) else {
                return
            }
            showQuicklinkForm(
                QuicklinkDraft(request: request, commandTitle: command.title, applications: quicklinkApplications()),
                over: command)
        case .createSnippet(let request):
            guard case .command(let command) = screen, !Self.builtInSessions.contains(command.session) else {
                return
            }
            showSnippetForm(SnippetDraft(request: request, commandTitle: command.title), over: command)
        case .toggleQuickLook:
            toggleQuickLook()
        }
    }

    // MARK: - Action.PickDate

    /// Opens an `Action.PickDate`'s picker in the action panel overlay, in place of the action list, as a submenu
    /// takes its place. Run without the overlay (↵, ⌘↵, its shortcut), the overlay opens straight to the picker.
    private func openDatePick(_ entry: ActionEntry, options: DatePickerOptions) {
        guard case .node(let node) = entry.target, case .command = screen else { return }
        closeDropdownPanel()
        datePanel = nil
        var state = actionPanel ?? ActionPanelState()
        state.pick = DatePick(node: node, title: entry.title, options: options, openedFromList: actionPanel != nil)
        actionPanel = state
    }

    /// The open picker's keys, ahead of everything but ⌘K. False lets the time field have the key.
    private func handleDatePickKey(_ pressed: KeyShortcut) -> Bool {
        guard var pick = actionPanel?.pick else { return false }
        let outcome = pick.handle(pressed)
        actionPanel?.pick = pick
        return finishDatePick(outcome)
    }

    /// A click on a day in the picker.
    func clickDatePickDay(_ day: Date) {
        guard var pick = actionPanel?.pick else { return }
        let outcome = pick.click(day)
        actionPanel?.pick = pick
        _ = finishDatePick(outcome)
    }

    func moveDatePick(months: Int) {
        actionPanel?.pick?.move(months: months)
    }

    func setDatePickTime(_ date: Date) {
        actionPanel?.pick?.setTime(date)
    }

    func focusDatePick(_ part: DatePick.Focus) {
        guard actionPanel?.pick?.focus != part else { return }
        actionPanel?.pick?.focus(part)
    }

    /// Does what a key or click in the picker asked for. A pick or a clear calls the action's `onChange` once and
    /// closes the overlay; the view stays as it is.
    private func finishDatePick(_ outcome: DatePick.Outcome) -> Bool {
        guard let pick = actionPanel?.pick else { return false }
        switch outcome {
        case .handled:
            return true
        case .ignored:
            return false
        case .pick(let date):
            actionPanel = nil
            sendDatePick(FormDates.json(date), to: pick.node)
        case .clear:
            actionPanel = nil
            sendDatePick(.null, to: pick.node)
        case .backToList:
            closeDatePick()
        case .close:
            actionPanel = nil
        }
        return true
    }

    private func sendDatePick(_ value: JSONValue, to node: Int) {
        guard case .command(let command) = screen else { return }
        send(.event(session: command.session, node: node, path: ["onChange"], args: [value]))
    }

    /// Leaves the picker: back to the action list it was opened from, or the overlay closes.
    private func closeDatePick() {
        guard let pick = actionPanel?.pick else { return }
        if pick.openedFromList {
            actionPanel?.pick = nil
        } else {
            actionPanel = nil
        }
    }

    /// After a render: the picker stays while its action is there, with the action's title as its heading, within
    /// any new `min` and `max`. When the action is gone, or is no longer an `Action.PickDate`, the picker closes
    /// without calling anything.
    private func syncDatePick() {
        guard let pick = actionPanel?.pick else { return }
        guard let following = pick.following(ActionPanelReader.entry(id: pick.node, in: currentActions)) else {
            closeDatePick()
            return
        }
        if following != pick { actionPanel?.pick = following }
    }

    /// For snapshots: opens the picker of the `Action.PickDate` titled `title`, as ↵ on it would.
    func openDatePick(titled title: String) {
        if let entry = ActionPanelReader.entry(titled: title, in: currentActions, where: { $0.pickDate != nil }) {
            run(entry)
        }
    }

    /// For snapshots: runs the first action titled `title` of the selected item or view, as picking it would.
    func runAction(titled title: String) {
        if let entry = ActionPanelReader.entry(titled: title, in: currentActions) { run(entry) }
    }

    // MARK: - Form.LinkAccessory

    /// A click on the Form's link accessory opens its `target` as `Action.OpenInBrowser` does, then hides the panel
    /// as that action does. The Form stays as it is.
    func openLinkAccessory() {
        guard let link = command?.form?.linkAccessory else { return }
        Task {
            do {
                // The user's own click.
                _ = try await SystemCalls.handle(
                    "open", .object(["target": .string(link.target)]), origin: .userInitiated)
                closeWindow(clearRootSearch: false, popToRootType: "default")
            } catch {
                showFailureToast("Can't open \(link.target)", message: String(describing: error))
            }
        }
    }

    /// Runs one of fudge's own actions on the selected root search item.
    private func perform(_ action: RootAction) {
        switch action {
        case .open:
            activate()
        case .configureExtension(let name):
            showSettings(extension: name)
        case .deactivateMenuBarItem(let id):
            do {
                try menuBar.deactivate(id)
            } catch {
                showFailureToast("Can't deactivate the menu bar item", message: String(describing: error))
            }
        case .showInFinder(let url):
            hide()
            SystemCalls.showInFinder(url.path)
        case .copyAnswer:
            copyCalculatorAnswer()
        case .copyQuestionAndAnswer:
            copyCalculatorAnswer(withQuestion: true)
        case .turnOnCurrencyConversion:
            showSettings(extension: nil)
        case .retryExchangeRates:
            retryExchangeRates()
        case .copyQuicklink(let link):
            Task {
                _ = try? await SystemCalls.handle(
                    "clipboard.copy", .object(["text": .string(link)]), origin: .userInitiated)
            }
            hide()
            showHUD("Copied Link")
        case .editQuicklink(let id):
            guard let quicklink = QuicklinkStore.load(from: paths.quicklinksFile).quicklink(id: id) else { return }
            showQuicklinkForm(QuicklinkDraft(editing: quicklink))
        case .deleteQuicklink(let id):
            deleteQuicklink(id)
        case .openSignInSettings:
            showSettings(extension: SettingsModel.signInPage)
        case .retryCommand(let id):
            retryCommand(id)
        }
    }

    // MARK: - Sign-in notices

    /// The notice for an error `session` reported as refused on purpose (SPEC-095), or nil for any other error.
    private func signInNotice(
        _ notice: String?, message: String, session: String, commandTitle: String?
    ) -> SignInNotice? {
        guard notice != nil else { return nil }
        let name = sessionExtensions[session] ?? ""
        return SignInNotice(
            notice: notice, message: message, extensionName: name,
            extensionTitle: extensions[name]?.manifest.title ?? "",
            commandID: sessionCommands[session].map { FudgeSettings.commandID(extension: name, command: $0) },
            commandTitle: commandTitle)
    }

    /// Try Again, on a cancelled or refused sign-in's notice: runs the command again as root search would, or shows
    /// root search with its fields when it has a required argument.
    private func retryCommand(_ commandID: String) {
        guard let item = items.first(where: { $0.id == "command:\(commandID)" }) else { return }
        screen = .root
        if item.arguments.contains(where: { $0.required == true }) {
            rootQuery = ""
            refreshResults()
            selectedItem = item.id
            arguments.focus = 0
            return
        }
        open(item)
    }

    // MARK: - Quicklinks

    /// Opens a quicklink: fills in its placeholders, then opens the result with its app, or the default one, through
    /// `SystemCalls`' open. The panel hides once it has opened; a link that can't be opened shows a failure toast
    /// and the panel stays. From its hotkey (`fromHotkey`), with every field at its default, it's filled in at the
    /// press, root search's query and fields stay as they are, and a failure shows in the HUD, since the panel
    /// may not be up.
    private func openQuicklink(_ quicklink: Quicklink, item: RootItem, fromHotkey: Bool = false) {
        let entered =
            !fromHotkey && argumentsItem == item.id ? arguments : ArgumentInput(arguments: item.arguments)
        let clipboard = QuicklinkTemplate(quicklink.link).usesClipboard ? templateClipboard() : nil
        let failed = { [weak self] (message: String) in
            if fromHotkey {
                self?.showHUD("Can't open \(quicklink.name) — \(message)")
            } else {
                self?.showFailureToast("Can't open \(quicklink.name)", message: message)
            }
        }
        let target: QuicklinkOpening.Target
        switch QuicklinkOpening.target(
            for: quicklink, arguments: entered.launchArguments, context: .init(clipboard: clipboard))
        {
        case .success(let opened): target = opened
        case .failure(let failure):
            failed(failure.description)
            return
        }
        var params: [String: JSONValue] = ["target": .string(target.openText)]
        if let application = quicklink.application { params["application"] = .string(application) }
        Task {
            do {
                // The user's own pick in root search, or their own hotkey.
                _ = try await SystemCalls.handle("open", .object(params), origin: .userInitiated)
            } catch {
                failed(SystemCalls.message(of: error))
                return
            }
            recordLaunch(item)
            if fromHotkey {
                if isVisible() { hide() }
                return
            }
            searchText = ""
            if argumentsItem == item.id { resetArguments(for: item) }
            hide()
        }
    }

    // MARK: - Fudge's own forms: Create Quicklink and Create Snippet

    /// Fudge's own form while it's on screen: Create Quicklink (SPEC-052 B1–B3) or Create Snippet (SPEC-078 §3). It's
    /// drawn as a Form view whose session is the form's own (`QuicklinkForm.session`, `SnippetForm.session`): `send`
    /// answers its events here, and nothing of it reaches the host.
    struct BuiltInFormState {
        enum Content {
            /// What it opened on: an empty draft, a saved one to edit, or an extension's `Action.CreateQuicklink` or
            /// `Action.CreateSnippet`, with the problems shown on its fields after a refused save, each until its
            /// field is edited.
            case quicklink(QuicklinkDraft, applications: [QuicklinkApplication], problems: QuicklinkDraft.Problems)
            case snippet(SnippetDraft, problems: SnippetDraft.Problems)
            /// Save Layout… (SPEC-094 §2): the windows it read, and the name's problem after a refused save.
            case layout(LayoutDraft, problem: String?)
        }

        var content: Content
        /// The extension's view it was opened over, which it goes back to.
        var returnTo: CommandScreen?
        /// That view's renders, errors and exit while the form covered it, handled once it's shown again.
        var deferred: [HostMessage] = []

        var session: String {
            switch content {
            case .quicklink: QuicklinkForm.session
            case .snippet: SnippetForm.session
            case .layout: LayoutForm.session
            }
        }

        var title: String {
            switch content {
            case .quicklink(let draft, _, _): QuicklinkForm.title(for: draft)
            case .snippet(let draft, _): SnippetForm.title(for: draft)
            case .layout: LayoutForm.title
            }
        }

        var view: UINode {
            switch content {
            case .quicklink(let draft, let applications, let problems):
                QuicklinkForm.view(draft: draft, problems: problems, applications: applications)
            case .snippet(let draft, let problems):
                SnippetForm.view(draft: draft, problems: problems)
            case .layout(let draft, let problem):
                LayoutForm.view(draft: draft, problem: problem)
            }
        }

        var saveNode: Int {
            switch content {
            case .quicklink: QuicklinkForm.Node.save
            case .snippet: SnippetForm.Node.save
            case .layout: LayoutForm.Node.save
            }
        }

        /// Clears the problem of the field `node`, after an edit; false when it had none.
        mutating func clearProblem(of node: Int) -> Bool {
            switch content {
            case .quicklink(let draft, let applications, var problems):
                switch node {
                case QuicklinkForm.Node.name where problems.name != nil: problems.name = nil
                case QuicklinkForm.Node.link where problems.link != nil: problems.link = nil
                default: return false
                }
                content = .quicklink(draft, applications: applications, problems: problems)
            case .snippet(let draft, var problems):
                switch node {
                case SnippetForm.Node.name where problems.name != nil: problems.name = nil
                case SnippetForm.Node.text where problems.text != nil: problems.text = nil
                case SnippetForm.Node.keyword where problems.keyword != nil: problems.keyword = nil
                default: return false
                }
                content = .snippet(draft, problems: problems)
            case .layout(let draft, let problem):
                guard node == LayoutForm.Node.name, problem != nil else { return false }
                content = .layout(draft, problem: nil)
            }
            return true
        }
    }

    /// The sessions of Fudge's own views, its forms, Search Snippets, Switch Windows, Search Menu Items, Recent Colors,
    /// Define Word and My Schedule, which never reach the host.
    static let builtInSessions: Set<String> = [
        QuicklinkForm.session, SnippetForm.session, SnippetList.session, SwitchWindowsList.session, LayoutForm.session,
        MenuItemsList.session, RecentColorsGrid.session, DefineWordView.session, ScheduleList.session,
    ]

    @ObservationIgnored private var builtInForm: BuiltInFormState?
    @ObservationIgnored private var quicklinkApplicationList: [QuicklinkApplication]?

    /// Open With's choices: root search's applications, with their bundle ids.
    private func quicklinkApplications() -> [QuicklinkApplication] {
        if let quicklinkApplicationList { return quicklinkApplicationList }
        let list = applications.compactMap { item -> QuicklinkApplication? in
            guard case .application(let url) = item.kind, let bundleId = Bundle(url: url)?.bundleIdentifier else {
                return nil
            }
            return QuicklinkApplication(name: item.title, bundleId: bundleId, path: url.path)
        }
        quicklinkApplicationList = list
        return list
    }

    /// Shows the Create Quicklink form on `draft`: from root search, or over an extension's view (`over`), which
    /// it goes back to when it closes.
    private func showQuicklinkForm(_ draft: QuicklinkDraft, over returnTo: CommandScreen? = nil) {
        showBuiltInForm(
            BuiltInFormState(
                content: .quicklink(draft, applications: quicklinkApplications(), problems: .init()), returnTo: returnTo
            ))
    }

    /// Shows the Create Snippet form on `draft`, as `showQuicklinkForm` does.
    private func showSnippetForm(_ draft: SnippetDraft, over returnTo: CommandScreen? = nil) {
        showBuiltInForm(BuiltInFormState(content: .snippet(draft, problems: .init()), returnTo: returnTo))
    }

    private func showBuiltInForm(_ state: BuiltInFormState) {
        actionPanel = nil
        dropdownPanel = nil
        datePanel = nil
        builtInForm = state
        var form = CommandScreen(session: state.session, title: state.title)
        form.storedFormValues = [:]
        form.view = state.view
        refreshForm(&form)
        screen = .command(form)
    }

    /// Draws the form again with its problems, keeping what was typed.
    private func renderBuiltInForm() {
        guard let form = builtInForm, case .command(var command) = screen, command.session == form.session else {
            return
        }
        command.view = form.view
        refreshForm(&command)
        screen = .command(command)
    }

    /// The form's events, as `send` hands them over: its Save action's `onAction`, and each edit's `onChange`, which
    /// clears that field's problem.
    private func builtInFormEvent(node: Int, path: [String]) {
        guard var form = builtInForm else { return }
        switch path {
        case ["onAction"] where node == form.saveNode:
            saveBuiltInForm()
        case ["onChange"]:
            guard form.clearProblem(of: node) else { return }
            builtInForm = form
            renderBuiltInForm()
        default:
            break
        }
    }

    /// ⌘↵ Save: refused with each field's problem (`QuicklinkDraft.problems`, `SnippetDraft.problems`), else saved
    /// in place of the edited one or as a new one, with a HUD, and the form closes. A file Fudge can't read stays as
    /// it is, and a toast says why.
    private func saveBuiltInForm() {
        guard var form = builtInForm, let command, command.session == form.session, let content = command.form else {
            return
        }
        var values: [String: JSONValue] = [:]
        for field in content.fields {
            if let id = field.fieldId, let value = command.fieldValues[field.id]?.value { values[id] = value }
        }
        let saved: String
        switch form.content {
        case .quicklink(let draft, let applications, _):
            let draft = QuicklinkForm.draft(draft, with: values)
            let file = paths.quicklinksFile
            var store = QuicklinkStore.load(from: file)
            let problems = draft.problems(among: store.quicklinks)
            guard problems.isEmpty else {
                form.content = .quicklink(draft, applications: applications, problems: problems)
                builtInForm = form
                renderBuiltInForm()
                return
            }
            draft.save(into: &store)
            do {
                try store.save(to: file)
            } catch {
                showFailureToast("Can't save the quicklink", message: String(describing: error))
                return
            }
            saved = "Quicklink saved"
        case .snippet(let draft, _):
            let draft = SnippetForm.draft(draft, with: values)
            let file = paths.snippetsFile
            var store = SnippetStore.load(from: file)
            let problems = draft.problems(among: store.snippets)
            guard problems.isEmpty else {
                form.content = .snippet(draft, problems: problems)
                builtInForm = form
                renderBuiltInForm()
                return
            }
            draft.save(into: &store)
            do {
                try store.save(to: file)
            } catch {
                showFailureToast("Can't save the snippet", message: String(describing: error))
                return
            }
            saved = "Snippet saved"
        case .layout(let draft, _):
            let draft = LayoutForm.draft(draft, with: values)
            let file = paths.windowLayoutsFile
            var store = WindowLayoutStore.load(from: file)
            if let problem = draft.problem(among: store.layouts) {
                form.content = .layout(draft, problem: problem)
                builtInForm = form
                renderBuiltInForm()
                return
            }
            draft.save(into: &store)
            do {
                try store.save(to: file)
            } catch {
                showFailureToast("Can't save the layout", message: String(describing: error))
                return
            }
            saved = "Layout saved"
            windowLayoutsChanged()
        }
        let fromRootSearch = form.returnTo == nil
        closeBuiltInForm()
        applySettings()
        if fromRootSearch { searchText = "" }
        showHUD(saved)
    }

    /// Closes Fudge's form (Esc, or a save): back to the extension's view it was opened over, with what that
    /// rendered meanwhile, or to root search. False when the form isn't on screen.
    @discardableResult
    private func closeBuiltInForm() -> Bool {
        guard let form = builtInForm, case .command(let command) = screen, command.session == form.session else {
            return false
        }
        builtInForm = nil
        actionPanel = nil
        dropdownPanel = nil
        datePanel = nil
        if var returnTo = form.returnTo {
            if returnTo.session == SnippetList.session { renderSnippetList(&returnTo) }
            screen = .command(returnTo)
            for message in form.deferred { handle(message) }
        } else {
            screen = .root
        }
        restoreKeyboard()
        return true
    }

    /// The screen changed. When Fudge's form went some other way than closing (a launch, Pop to Root Search, the
    /// panel's reset), the extension's view under it is unloaded too, as the one on screen would be.
    private func builtInFormLeft() {
        guard let form = builtInForm else { return }
        if case .command(let command) = screen, command.session == form.session { return }
        builtInForm = nil
        guard let covered = form.returnTo?.session else { return }
        for case .exit(let session, let reason) in form.deferred { handle(.exit(session: session, reason: reason)) }
        if case .command(let command) = screen, command.session == covered { return }
        send(.unload(session: covered))
    }

    // MARK: - My Schedule

    /// What My Schedule was last drawn from, which its actions' nodes are read in (`ScheduleList.target`). It's in
    /// memory only: no event is logged or kept (SPEC-092).
    @ObservationIgnored private var scheduleContent = ScheduleList.Content.asking
    /// Whether My Schedule shows its detail pane (Show Details, ⌘D), for the run.
    @ObservationIgnored private var scheduleShowsDetail = false
    /// The read of the calendars under way, off the main thread; a newer one replaces it.
    @ObservationIgnored private var scheduleRead: Task<Void, Never>?

    /// Shows My Schedule (SPEC-092), from root search or its hotkey. Its hotkey hides it again when it's on screen,
    /// as a view command's does. It shows as loading until the calendars are read, off the main thread. Calendar
    /// access is asked for here, the first time, and nowhere else.
    private func showSchedule(fromHotkey: Bool) {
        if fromHotkey, isVisible(), case .command(let command) = screen, command.session == ScheduleList.session {
            hide()
            return
        }
        let access = calendarSource.authorization
        scheduleContent = access.canRead || access == .notDetermined ? .asking : .refused
        let build = {
            if case .command = self.screen { self.leaveCommand() }
            self.actionPanel = nil
            self.dropdownPanel = nil
            self.datePanel = nil
            var command = CommandScreen(session: ScheduleList.session, title: ScheduleList.title)
            self.renderSchedule(&command)
            self.screen = .command(command)
        }
        if fromHotkey {
            resettingFirst(build)
            show()
        } else {
            build()
        }
        guard access == .notDetermined else {
            if access.canRead { readSchedule() }
            return
        }
        let source = calendarSource
        Task {
            _ = await source.requestAccess()
            readSchedule()
        }
    }

    /// Reads the calendars off the main thread, since every EventKit call waits on the calendar agent, then draws the
    /// list if it's still on screen: the days from today to Days Ahead, of the calendars not unticked on the Calendar
    /// page.
    private func readSchedule() {
        scheduleRead?.cancel()
        let source = calendarSource
        let chosen = FudgeSettings.load(from: paths.settingsFile)
        scheduleRead = Task {
            let content = await Task.detached(priority: .userInitiated) {
                Self.scheduleContent(from: source, chosen: chosen, now: Date(), calendar: .current)
            }.value
            guard !Task.isCancelled else { return }
            scheduleContent = content
            drawSchedule()
        }
    }

    /// What My Schedule shows, read from `source`: called off the main thread.
    nonisolated private static func scheduleContent(
        from source: any CalendarSource, chosen: FudgeSettings, now: Date, calendar: Calendar
    ) -> ScheduleList.Content {
        switch source.authorization {
        case .fullAccess:
            let calendars = source.calendars()
            let window = Schedule.window(now: now, daysAhead: chosen.calendarDaysAhead, calendar: calendar)
            let events = source.events(
                from: window.start, to: window.end,
                calendars: Schedule.shownCalendars(calendars, hidden: chosen.calendarHidden))
            return .days(
                Schedule.days(
                    events, now: now, daysAhead: chosen.calendarDaysAhead, calendar: calendar, locale: .current),
                calendars: calendars, daysAhead: chosen.calendarDaysAhead)
        case .notDetermined:
            return .asking
        default:
            return .refused
        }
    }

    /// Draws the list from what was last read, keeping the search text and the selection where it can.
    private func renderSchedule(_ command: inout CommandScreen) {
        command.view = ScheduleList.view(
            scheduleContent, showingDetail: scheduleShowsDetail, now: Date(), calendar: .current, locale: .current)
        refreshList(&command, selectFirst: false)
    }

    /// Draws My Schedule again from what was last read, if it's on screen.
    private func drawSchedule() {
        guard case .command(var command) = screen, command.session == ScheduleList.session else { return }
        renderSchedule(&command)
        screen = .command(command)
    }

    /// Reads and draws My Schedule again, if it's on screen: after the calendars change, or the Calendar page
    /// changes what it shows.
    func reloadSchedule() {
        guard case .command(let command) = screen, command.session == ScheduleList.session else { return }
        readSchedule()
    }

    /// One of its actions, as `send` hands it over.
    private func scheduleListAction(node: Int) {
        guard case .command(let list) = screen, list.session == ScheduleList.session,
            let target = ScheduleList.target(of: node, in: scheduleContent, calendar: .current, locale: .current)
        else { return }
        switch target {
        case .join(let url), .openInCalendar(let url):
            // The user's own pick; a meeting link is one `MeetingLinks` accepted.
            if NSWorkspace.shared.open(url) {
                hide()
            } else {
                showFailureToast("Can't open it", message: "No app on this Mac opens this link.")
            }
        case .copyLink(let url):
            copyScheduleText(url.absoluteString, hud: "Copied Meeting Link")
        case .copyDetails(let text):
            copyScheduleText(text, hud: "Copied to Clipboard")
        case .openPrivacySettings:
            NSWorkspace.shared.open(ScheduleList.privacySettingsURL)
            hide()
        case .openSettings:
            showSettings(extension: SettingsModel.calendarPage)
        case .toggleDetail:
            scheduleShowsDetail.toggle()
            drawSchedule()
        }
    }

    private func copyScheduleText(_ text: String, hud: String) {
        Task {
            _ = try? await SystemCalls.handle(
                "clipboard.copy", .object(["text": .string(text)]), origin: .userInitiated)
        }
        hide()
        showHUD(hud)
    }

    // MARK: - Search Snippets

    /// The snippets Search Snippets was last drawn from, which its actions' nodes are read in (`SnippetList.target`).
    @ObservationIgnored private var listedSnippets: [Snippet] = []

    /// Shows Search Snippets (SPEC-078 §3), from root search.
    private func showSnippetList() {
        actionPanel = nil
        dropdownPanel = nil
        datePanel = nil
        var command = CommandScreen(session: SnippetList.session, title: SnippetList.title)
        renderSnippetList(&command)
        screen = .command(command)
    }

    /// Reads `snippets.json` again and draws the list, keeping the search text and the selection on the same
    /// snippet where it can. The detail's preview fills `{clipboard}` only when a snippet uses it.
    private func renderSnippetList(_ command: inout CommandScreen) {
        let snippets = SnippetStore.load(from: paths.snippetsFile).snippets
        listedSnippets = snippets
        let usesClipboard = snippets.contains { SnippetTemplate($0.text).usesClipboard }
        command.view = SnippetList.view(
            snippets: snippets, context: .init(clipboard: usesClipboard ? templateClipboard() : nil))
        refreshList(&command, selectFirst: false)
    }

    /// Draws Search Snippets again, if it's on screen: after a delete, or a change on the Settings window's page.
    func reloadSnippetList() {
        guard case .command(var command) = screen, command.session == SnippetList.session else { return }
        renderSnippetList(&command)
        screen = .command(command)
    }

    /// One of its actions, as `send` hands it over.
    private func snippetListAction(node: Int) {
        guard let target = SnippetList.target(of: node, in: listedSnippets),
            case .command(let list) = screen, list.session == SnippetList.session
        else { return }
        let file = paths.snippetsFile
        func saved(_ id: String) -> Snippet? {
            if let snippet = SnippetStore.load(from: file).snippet(id: id) { return snippet }
            showFailureToast("The snippet is gone", message: "It was deleted outside Search Snippets.")
            reloadSnippetList()
            return nil
        }
        switch target {
        case .paste(let id):
            if let snippet = saved(id) { pasteSnippet(snippet) }
        case .copy(let id):
            if let snippet = saved(id) { copySnippet(snippet) }
        case .edit(let id):
            if let snippet = saved(id) { showSnippetForm(SnippetDraft(editing: snippet), over: list) }
        case .delete(let id):
            if let snippet = saved(id) { deleteSnippet(snippet) }
        case .create:
            showSnippetForm(SnippetDraft(), over: list)
        }
    }

    /// The snippet's text with its placeholders filled in, and how far from its end `{cursor}` was; nil, with a
    /// toast, when its text has a problem (only a hand-edited file can hold one).
    private func filledSnippet(_ snippet: Snippet) -> (text: String, afterCursor: Int?)? {
        let template = SnippetTemplate(snippet.text)
        if let problem = template.problem {
            showFailureToast("Can't use \(snippet.name)", message: problem)
            return nil
        }
        return template.fill(context: .init(clipboard: template.usesClipboard ? templateClipboard() : nil))
    }

    /// ↵ Paste Snippet: pastes it into the app the user was in through `Clipboard.paste`'s path and turn (the panel
    /// hides first, and the clipboard is put back), then puts the caret where `{cursor}` was with ← presses.
    private func pasteSnippet(_ snippet: Snippet) {
        guard let filled = filledSnippet(snippet) else { return }
        Task {
            do {
                try await SystemCalls.pasteSnippet(
                    filled.text, leftArrows: filled.afterCursor ?? 0, hideWindow: { await self.hideForPaste() })
            } catch PasteError.noTarget {
                showHUD("There is no app to paste into")
            } catch {
                // Without Accessibility permission, the panel is still up, and the text is on the clipboard.
                showFailureToast("Can't paste \(snippet.name)", message: SystemCalls.message(of: error))
            }
        }
    }

    /// ⌘↵ Copy to Clipboard: the filled-in text, then the panel hides with a HUD, as Raycast's Copy does.
    private func copySnippet(_ snippet: Snippet) {
        guard let filled = filledSnippet(snippet) else { return }
        Task {
            _ = try? await SystemCalls.handle(
                "clipboard.copy", .object(["text": .string(filled.text)]), origin: .userInitiated)
        }
        hide()
        showHUD("Copied to Clipboard")
    }

    /// ⌃X Delete Snippet…: asks, then removes it from `snippets.json` and draws the list again. A file Fudge can't
    /// read stays as it is, and a toast says why.
    private func deleteSnippet(_ snippet: Snippet) {
        let file = paths.snippetsFile
        let request = AlertRequest(
            title: "Delete “\(snippet.name)”?", message: "It's removed from Search Snippets.", primary: "Delete",
            dismiss: "Cancel", destructive: true)
        Task {
            guard await confirm(request, .userInitiated) else { return }
            var store = SnippetStore.load(from: file)
            store.remove(id: snippet.id)
            do {
                try store.save(to: file)
            } catch {
                showFailureToast("Can't delete \(snippet.name)", message: String(describing: error))
                return
            }
            reloadSnippetList()
        }
    }

    // MARK: - Color Picker

    /// One of the Tools group's commands (SPEC-090).
    private func runTool(_ command: ToolCommand, item: RootItem, fromHotkey: Bool) {
        switch command {
        case .pickColor:
            // The loupe needs the screen, so the panel goes first, as for window commands; it never shows.
            if !fromHotkey { searchText = "" }
            if isVisible() { hide() }
            pickColor()
        case .recentColors:
            guard fromHotkey else {
                showRecentColors()
                return
            }
            // As a view command's hotkey does: it hides the panel when Recent Colors is already on screen.
            resettingFirst {
                if isVisible(), case .command(let command) = screen, command.session == RecentColorsGrid.session {
                    hide()
                    return
                }
                if case .command = screen { leaveCommand() }
                showRecentColors()
                show()
            }
        case .defineWord:
            defineWord(item, fromHotkey: fromHotkey)
        }
    }

    // MARK: - Define Word

    /// The word Define Word shows, and its definition (nil: none), which its actions use.
    @ObservationIgnored private var definedWord: (word: String, definition: String?)?

    /// Define Word (SPEC-091): the typed word, else the selected text's first line, looked up in the Mac's
    /// dictionaries and shown as a Detail. With neither, root search shows its Word field, with the keyboard in it.
    private func defineWord(_ item: RootItem, fromHotkey: Bool) {
        let typed = !fromHotkey && argumentsItem == item.id ? arguments.value(at: 0) : ""
        let readSelection = selectedText
        let lookup = definitionLookup
        Task {
            switch await DefineWord.start(argument: typed, selection: readSelection) {
            case .lookUp(let word):
                let definition = await lookup.definition(of: word)
                showDefinition(word: word, definition: definition, item: item, fromHotkey: fromHotkey)
            case .askForWord:
                askForWord(item, fromHotkey: fromHotkey)
            }
        }
    }

    /// Whether root search is still where Define Word was run from: the panel up, on root search, with it selected.
    /// The user may have moved on while the selection and the dictionary were read.
    private func stillOnDefineWord(_ item: RootItem) -> Bool {
        guard isVisible(), case .root = screen else { return false }
        return selectedItem == item.id
    }

    private func showDefinition(word: String, definition: String?, item: RootItem, fromHotkey: Bool) {
        func build() {
            actionPanel = nil
            dropdownPanel = nil
            datePanel = nil
            var command = CommandScreen(session: DefineWordView.session, title: DefineWordView.title)
            command.view = DefineWordView.view(word: word, definition: definition)
            definedWord = (word, definition)
            screen = .command(command)
            // As after a command's launch, the fields start empty for when the user comes back to root search.
            if argumentsItem == item.id { resetArguments(for: item) }
        }
        if fromHotkey {
            resettingFirst {
                if case .command = screen { leaveCommand() }
                build()
                show()
            }
        } else if stillOnDefineWord(item) {
            build()
        }
    }

    /// No word and no selection: root search with Define Word selected and the keyboard in its Word field.
    private func askForWord(_ item: RootItem, fromHotkey: Bool) {
        if fromHotkey {
            resettingFirst {
                if case .command = screen { leaveCommand() }
                screen = .root
                rootQuery = ""
                refreshResults()
                selectedItem = item.id
                arguments.focus = 0
                show()
            }
        } else if stillOnDefineWord(item) {
            arguments.focus = 0
        }
    }

    /// One of its actions, as `send` hands it over.
    private func defineWordAction(node: Int) {
        guard let target = DefineWordView.target(of: node), let shown = definedWord,
            case .command(let command) = screen, command.session == DefineWordView.session
        else { return }
        switch target {
        case .lookUpInDictionary:
            guard let url = DefineWord.dictionaryURL(for: shown.word) else { return }
            Task {
                do {
                    _ = try await SystemCalls.handle(
                        "open", .object(["target": .string(url.absoluteString)]), origin: .userInitiated)
                    hide()
                } catch {
                    showFailureToast("Can't open Dictionary", message: SystemCalls.message(of: error))
                }
            }
        case .copyDefinition:
            guard let definition = shown.definition else { return }
            Task {
                guard await Self.copyText(definition) else {
                    showFailureToast("Couldn't copy the definition")
                    return
                }
                hide()
                showHUD("Copied to Clipboard")
            }
        }
    }

    /// Whether the loupe is open: a second Pick Color meanwhile (its hotkey again) does nothing.
    @ObservationIgnored private var pickingColor = false

    /// Pick Color: macOS's loupe, then the color copied in the Copy Format, with a HUD, and added to Recent Colors.
    /// Esc copies nothing. Recent Colors, if it's the screen under the hidden panel, is drawn again.
    private func pickColor() {
        guard !pickingColor else { return }
        pickingColor = true
        let format = FudgeSettings.load(from: paths.settingsFile).colorFormat
        let pick = ColorPick(sampler: colorSampler, copy: { await Self.copyText($0) }, file: paths.colorsFile)
        Task {
            let message = await pick.run(format: format)
            pickingColor = false
            if let message { showHUD(message) }
            reloadRecentColors()
        }
    }

    /// Puts `text` on the clipboard as `Clipboard.copy` does.
    private static func copyText(_ text: String) async -> Bool {
        (try? await SystemCalls.handle("clipboard.copy", .object(["text": .string(text)]), origin: .userInitiated))
            != nil
    }

    /// The colors Recent Colors was last drawn from, which its actions' nodes are read in (`RecentColorsGrid.target`).
    @ObservationIgnored private var listedColors: [RecentColor] = []

    /// Shows Recent Colors (SPEC-090), from root search or its hotkey.
    private func showRecentColors() {
        actionPanel = nil
        dropdownPanel = nil
        datePanel = nil
        var command = CommandScreen(session: RecentColorsGrid.session, title: RecentColorsGrid.title)
        renderRecentColors(&command)
        screen = .command(command)
    }

    /// Reads `colors.json` and the Copy Format again and draws the grid, keeping the search text and the selection
    /// on the same color where it can.
    private func renderRecentColors(_ command: inout CommandScreen) {
        let colors = RecentColorStore.load(from: paths.colorsFile).colors
        listedColors = colors
        command.view = RecentColorsGrid.view(
            colors: colors, format: FudgeSettings.load(from: paths.settingsFile).colorFormat)
        refreshList(&command, selectFirst: false)
    }

    /// Draws Recent Colors again, if it's on screen: after a pick, a removal, or a new Copy Format in Settings.
    func reloadRecentColors() {
        guard case .command(var command) = screen, command.session == RecentColorsGrid.session else { return }
        renderRecentColors(&command)
        screen = .command(command)
    }

    /// One of its actions, as `send` hands it over.
    private func recentColorsAction(node: Int) {
        guard let target = RecentColorsGrid.target(of: node, in: listedColors),
            case .command(let grid) = screen, grid.session == RecentColorsGrid.session
        else { return }
        switch target {
        case .copy(let id, let format):
            guard let color = listedColors.first(where: { $0.id == id }) else { return }
            let text = format.string(for: color.color)
            Task {
                guard await Self.copyText(text) else {
                    showFailureToast("Couldn't copy \(text)")
                    return
                }
                hide()
                showHUD("Copied \(text)")
            }
        case .remove(let id):
            changeRecentColors("Can't remove the color") { $0.remove(id: id) }
        case .clear:
            let count = listedColors.count
            let request = AlertRequest(
                title: "Clear Recent Colors?",
                message: count == 1 ? "The color is removed." : "All \(count) colors are removed.", primary: "Clear",
                dismiss: "Cancel", destructive: true)
            Task {
                guard await confirm(request, .userInitiated) else { return }
                changeRecentColors("Can't clear Recent Colors") { $0.clear() }
            }
        case .pick:
            hide()
            pickColor()
        }
    }

    /// Changes `colors.json` and draws the grid again. A file Fudge can't read stays as it is, and a toast says why.
    private func changeRecentColors(_ failure: String, _ edit: (inout RecentColorStore) -> Void) {
        let file = paths.colorsFile
        var store = RecentColorStore.load(from: file)
        edit(&store)
        do {
            try store.save(to: file)
        } catch {
            showFailureToast(failure, message: String(describing: error))
        }
        reloadRecentColors()
    }

    /// Delete Quicklink…: asks, then removes it from `quicklinks.json`. A file Fudge can't read stays as it is,
    /// and a toast says why.
    private func deleteQuicklink(_ id: String) {
        let file = paths.quicklinksFile
        guard let quicklink = QuicklinkStore.load(from: file).quicklink(id: id) else { return }
        let request = AlertRequest(
            title: "Delete “\(quicklink.name)”?", message: "It's removed from root search.", primary: "Delete",
            dismiss: "Cancel", destructive: true)
        Task {
            guard await confirm(request, .userInitiated) else { return }
            var store = QuicklinkStore.load(from: file)
            store.remove(id: id)
            do {
                try store.save(to: file)
            } catch {
                showFailureToast("Can't delete \(quicklink.name)", message: String(describing: error))
                return
            }
            pruneQuicklinkSettings(keeping: store.quicklinks)
            applySettings()
            commandHotkeysChanged()
        }
    }

    /// Takes a deleted quicklink's alias, hotkey and Enabled out of `settings.json` (`QuicklinkCommands.prune`).
    /// A `settings.json` Fudge can't read stays as it is: the leftovers do no harm, since no quicklink has that id.
    private func pruneQuicklinkSettings(keeping quicklinks: [Quicklink]) {
        var pruned = FudgeSettings.load(from: paths.settingsFile)
        guard QuicklinkCommands.prune(&pruned, keeping: quicklinks) else { return }
        do {
            try pruned.save(to: paths.settingsFile)
        } catch {
            FileHandle.standardError.write(
                Data("fudge: couldn't remove a deleted quicklink's settings: \(error)\n".utf8))
        }
    }

    /// Opens the Settings window, on an extension's preferences or on its default page, and hides the panel.
    private func showSettings(extension name: String?) {
        hide()
        openSettings(name, .userInitiated)
    }

    /// ⌘, opens Settings on its default page; ⌘⇧, on the extension of the command that's selected in root search
    /// or running. With no such command, ⌘⇧, does nothing.
    private func handleSettingsKey(_ pressed: KeyShortcut) -> Bool {
        if pressed == RootActions.settingsShortcut {
            showSettings(extension: nil)
            return true
        }
        if pressed == RootActions.configureExtensionShortcut {
            if let name = currentExtensionName { showSettings(extension: name) }
            return true
        }
        return false
    }

    /// The extension of the command selected in root search, or of the one running.
    private var currentExtensionName: String? {
        switch screen {
        case .root:
            if case .command(let name, _, _, _) = selectedRootItem?.kind { return name }
            return nil
        case .command(let command):
            return command.extensionName.isEmpty ? nil : command.extensionName
        case .failure(let failure):
            return failure.notice?.extensionName
        }
    }

    /// ↵ runs the primary action, except in a Form, where ↵ belongs to the fields and ⌘↵ submits.
    var primaryKey: KeyShortcut {
        command?.form != nil
            ? KeyShortcut(key: "return", modifiers: ["cmd"]) : KeyShortcut(key: "return", modifiers: [])
    }

    /// ⌘↵ runs the secondary action; ⌘⇧↵ in a Form.
    var secondaryKey: KeyShortcut {
        KeyShortcut(key: "return", modifiers: command?.form != nil ? ["cmd", "shift"] : ["cmd"])
    }

    /// Keys that the launcher handles itself: ⌘K, the primary and secondary actions' keys, and the actions'
    /// shortcuts; in views without a search field (Detail, Form) also ↵ and Esc; in root search, the keys of the
    /// argument fields (`ArgumentInput.handle`) and the root actions' shortcuts; everywhere, ⌘, and ⌘⇧, for the
    /// Settings window, after the running command's own shortcuts.
    /// Returns false for everything else, which then goes to the focused field.
    func handleKey(_ pressed: KeyShortcut) -> Bool {
        if signIn != nil { return handleSignInKey(pressed) }
        if datePanel != nil, handleDatePanelKey(pressed) { return true }
        if pressed == KeyShortcut(key: "k", modifiers: ["cmd"]) {
            if actionPanel != nil || !waitForActions(.actionPanel) { toggleActionPanel() }
            return true
        }
        if actionPanel?.pick != nil { return handleDatePickKey(pressed) }
        // ⌘P opens and closes the search bar dropdown, unless an action takes the shortcut.
        let commandP = KeyShortcut(key: "p", modifiers: ["cmd"])
        if pressed == commandP, dropdownPanel != nil {
            closeDropdownPanel()
            return true
        }
        guard actionPanel == nil, dropdownPanel == nil else { return false }
        let command: CommandScreen
        switch screen {
        case .root:
            switch arguments.handle(pressed) {
            case .ignored: break
            case .handled: return true
            case .submit:
                activate()
                return true
            }
            // ↵ stays with the fields, which submit on their own.
            if !pressed.modifiers.isEmpty, let entry = ActionPanelReader.action(for: pressed, in: currentActions) {
                run(entry)
                return true
            }
            return handleSettingsKey(pressed)
        case .failure:
            // A notice's actions' shortcuts, such as ⌘⌥, on "Sign-in is off".
            if !pressed.modifiers.isEmpty, let entry = ActionPanelReader.action(for: pressed, in: currentActions) {
                run(entry)
                return true
            }
            return handleSettingsKey(pressed)
        case .command(let running):
            guard running.failure == nil else { return handleSettingsKey(pressed) }
            command = running
        }
        let hasSearchField = command.view == nil || command.list != nil
        if !hasSearchField, pressed == KeyShortcut(key: "escape", modifiers: []) {
            escape()
            return true
        }
        if pressed == secondaryKey {
            if waitForActions(.secondary) { return true }
            if let secondaryAction { run(secondaryAction) }
            return true
        }
        if !hasSearchField, pressed == primaryKey {
            if let primaryAction { run(primaryAction) }
            return true
        }
        guard !pressed.modifiers.isEmpty else { return false }
        // A shortcut of the selected item's actions works before they've come: it waits for them, as ↵ does.
        if selectedListItem?.waitsForActions(pressed) == true, waitForActions(.shortcut(pressed)) { return true }
        if let entry = ActionPanelReader.action(for: pressed, in: currentActions) {
            run(entry)
            return true
        }
        if pressed == commandP, command.list?.dropdown != nil {
            toggleDropdownPanel()
            return true
        }
        return handleSettingsKey(pressed)
    }

    /// Tells the command the search text changed; with `throttle`, once typing pauses.
    /// Sends the new search text to the command's `onSearchTextChange`: at once, or 250 ms after the last change with
    /// `throttle`. Returns whether it went at once; a throttled one tells `TypingSelection` when it goes.
    @discardableResult
    private func commandSearchChanged(_ command: CommandScreen) -> Bool {
        searchDebounce?.cancel()
        guard let view = command.view, view.hasCallback("onSearchTextChange") else { return false }
        let event = AppMessage.event(
            session: command.session, node: view.id, path: ["onSearchTextChange"], args: [.string(command.searchText)])
        guard view.bool("throttle") == true else {
            send(event)
            return true
        }
        let session = command.session
        searchDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            self.send(event)
            guard case .command(var current) = self.screen, current.session == session else { return }
            current.typing.told(items: current.list?.items.map(\.id) ?? [])
            self.screen = .command(current)
        }
        return false
    }

    // MARK: - Switch Windows

    /// What Switch Windows reads and does: the system's windows, or a snapshot run's made-up ones (`--windows`). The
    /// app delegate sets it.
    @ObservationIgnored var windowSwitching: any WindowSwitching = NoWindowSwitching()
    /// The read on screen, whose rows its actions name by place (`SwitchWindowsList.target`). It's dropped when the
    /// list goes or the panel hides, so window titles are kept only while they're shown.
    @ObservationIgnored private var windowListing: WindowListing?
    /// Counts reads, so only the latest one is drawn.
    @ObservationIgnored private var windowReads = 0
    @ObservationIgnored private var readingWindows = false
    /// The panel hid with Switch Windows on screen: the windows are read again when it shows.
    @ObservationIgnored private var windowListStale = false

    private var switchWindowsOnScreen: Bool {
        if case .command(let command) = screen { return command.session == SwitchWindowsList.session }
        return false
    }

    /// Switch Windows from root search, or from its hotkey, which works as a view command's does: it opens it over
    /// whatever the panel shows (after Pop to Root Search's reset, when that's due), or hides the panel when it's on
    /// screen already.
    private func openSwitchWindows(_ item: RootItem, fromHotkey: Bool) {
        guard fromHotkey else {
            recordLaunch(item)
            showSwitchWindows()
            return
        }
        resettingFirst {
            if isVisible(), switchWindowsOnScreen {
                hide()
                return
            }
            recordLaunch(item)
            if case .command = screen { leaveCommand() }
            showSwitchWindows()
            show()
        }
    }

    /// Shows Switch Windows (FUD-120): the list loading, then the windows once they're read.
    private func showSwitchWindows() {
        actionPanel = nil
        dropdownPanel = nil
        datePanel = nil
        var command = CommandScreen(session: SwitchWindowsList.session, title: SwitchWindowsList.title)
        command.view = SwitchWindowsList.loading()
        refreshList(&command, selectFirst: true)
        screen = .command(command)
        readWindows(selectFirst: true)
    }

    /// Reads the windows, off the main thread, and draws them, keeping the search text. `selectFirst` selects the
    /// first row, for a new look at the list; otherwise (after Close Window or Quit App) the selection follows the
    /// window it's on when the new read arrives, or stays in its place when that window is gone. Without
    /// Accessibility permission, the list says so instead, and the check asks for macOS's prompt or
    /// shows Fudge's offer as it does for Paste (`AccessibilityGate`).
    private func readWindows(selectFirst: Bool) {
        windowListStale = false
        windowReads += 1
        let read = windowReads
        guard windowSwitching.mayRead() else {
            readingWindows = false
            windowListing = nil
            drawWindows(SwitchWindowsList.accessibilityNeeded(), selectFirst: true)
            return
        }
        readingWindows = true
        Task {
            let listing = await windowSwitching.read()
            guard read == windowReads else { return }
            readingWindows = false
            guard switchWindowsOnScreen else { return }
            // Read now, not when the re-read was asked for: the user may have moved the selection meanwhile.
            var sameWindow: Int?
            if !selectFirst, let previous = windowListing, let row = selectedWindowRow {
                sameWindow = listing.row(sameWindowAs: row, in: previous)
            }
            windowListing = listing
            drawWindows(
                SwitchWindowsList.view(rows: listing.rows, silentApps: listing.silentApps), selectFirst: selectFirst,
                selectingRow: sameWindow)
        }
    }

    /// The selected row's place in the read on screen.
    private var selectedWindowRow: Int? {
        guard case .command(let command) = screen, command.session == SwitchWindowsList.session else { return nil }
        return command.list?.items.first { $0.id == command.selectedNode }?.itemId.flatMap { Int($0) }
    }

    /// Draws `view`; `selectingRow` selects that row when it's shown (the search may hide it), else the selection
    /// goes as `selectFirst` says.
    private func drawWindows(_ view: UINode, selectFirst: Bool, selectingRow row: Int? = nil) {
        guard case .command(var command) = screen, command.session == SwitchWindowsList.session else { return }
        command.view = view
        refreshList(&command, selectFirst: selectFirst)
        if let row, let item = command.list?.items.first(where: { $0.itemId == String(row) }) {
            command.selectedNode = item.id
        }
        screen = .command(command)
    }

    /// The panel is hiding with Switch Windows on screen: its read goes, and the list shows as loading until the
    /// windows are read again when the panel shows.
    private func switchWindowsHidden() {
        guard switchWindowsOnScreen else { return }
        windowListStale = true
        windowListing = nil
        windowReads += 1
        readingWindows = false
        drawWindows(SwitchWindowsList.loading(), selectFirst: true)
    }

    /// The screen changed: once Switch Windows is gone, its read goes too, and one still running is dropped.
    private func switchWindowsLeft() {
        guard !switchWindowsOnScreen, windowListing != nil || readingWindows || windowListStale else { return }
        windowListing = nil
        windowReads += 1
        readingWindows = false
        windowListStale = false
    }

    /// One of its actions, as `send` hands it over. Nothing about the window is recorded: only the command's own
    /// launch is in the launch history.
    private func switchWindowsAction(node: Int) {
        guard switchWindowsOnScreen,
            let target = SwitchWindowsList.target(of: node, rows: windowListing?.rows.count ?? 0)
        else { return }
        if target == .openAccessibilitySettings {
            hide()
            NSWorkspace.shared.open(AccessibilitySettingsAlert.paneURL)
            return
        }
        guard let listing = windowListing else { return }
        switch target {
        case .switchTo(let row):
            // The panel goes first, then a turn for it to be gone, so the window's app takes the keyboard after it.
            hide()
            Task {
                await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
                if let problem = await Self.offMain({ listing.switchTo(row: row) }) { showHUD(problem) }
            }
        case .close(let row):
            Task {
                if let problem = await Self.offMain({ listing.close(row: row) }) {
                    showFailureToast("Can't close the window", message: problem)
                    return
                }
                await readWindowsAgain(after: listing)
            }
        case .quit(let row):
            let name = listing.rows[row].appName
            let request = AlertRequest(
                title: "Quit \(name)?", message: "It quits as if you chose Quit in its menu.", primary: "Quit",
                dismiss: "Cancel", destructive: true)
            Task {
                guard await confirm(request, .userInitiated) else { return }
                guard listing.quit(row: row) else {
                    showFailureToast("Can't quit \(name)")
                    return
                }
                await readWindowsAgain(after: listing)
            }
        case .openAccessibilitySettings:
            break
        }
    }

    /// After Close Window or Quit App: a moment for the app to do it, then the windows read again, the selection
    /// following its window (`readWindows`), unless the list has gone or been read again meanwhile.
    private func readWindowsAgain(after listing: WindowListing) async {
        try? await Task.sleep(for: .milliseconds(400))
        guard switchWindowsOnScreen, windowListing === listing else { return }
        readWindows(selectFirst: false)
    }

    /// Runs `work`, which waits on other apps, off the main thread.
    nonisolated private static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
        }
    }

    // MARK: - Search Menu Items

    /// Where Search Menu Items reads menus: the system's, or a snapshot run's made-up ones (`--menu-items`). The app
    /// delegate sets it.
    @ObservationIgnored var menuItemsAccess: any MenuItemsAccess = NoMenuItemsAccess()
    /// The app whose menus are on screen, and the read its rows come from, whose actions name them by place
    /// (`MenuItemsList.target`). Both go when the list goes or the panel hides.
    @ObservationIgnored private var menuTarget: MenuTarget?
    @ObservationIgnored private var menuListing: MenuItemsListing?
    /// Each app's last read, shown at once the next time and read again meanwhile. In memory for the run only.
    @ObservationIgnored private var menuCache = MenuItemsCache<MenuItemsListing>()
    /// Counts reads, so only the latest one is drawn.
    @ObservationIgnored private var menuReads = 0
    /// The panel hid with Search Menu Items on screen: the menus are read again when it shows.
    @ObservationIgnored private var menuItemsStale = false
    /// A row's item is being found to run: another ↵ meanwhile (a key repeat) runs nothing, so it's pressed once.
    @ObservationIgnored private var findingMenuItem = false
    /// Moves on when the panel hides or the list goes, so a run still finding its item then does nothing.
    @ObservationIgnored private var menuItemsGeneration = MenuItemsGeneration()

    private var menuItemsOnScreen: Bool {
        if case .command(let command) = screen { return command.session == MenuItemsList.session }
        return false
    }

    /// Search Menu Items from root search, or from its hotkey, which works as a view command's does: it opens it over
    /// whatever the panel shows (after Pop to Root Search's reset, when that's due), or hides the panel when it's on
    /// screen already. Only the command's launch is recorded, never anything about a menu item.
    private func openMenuItems(_ item: RootItem, fromHotkey: Bool) {
        guard fromHotkey else {
            recordLaunch(item)
            showMenuItems()
            return
        }
        resettingFirst {
            if isVisible(), menuItemsOnScreen {
                hide()
                return
            }
            recordLaunch(item)
            if case .command = screen { leaveCommand() }
            showMenuItems()
            show()
        }
    }

    /// Shows Search Menu Items (FUD-121) for the app the user is in.
    private func showMenuItems() {
        actionPanel = nil
        dropdownPanel = nil
        datePanel = nil
        var command = CommandScreen(session: MenuItemsList.session, title: MenuItemsList.title)
        command.view = MenuItemsList.loading()
        refreshList(&command, selectFirst: true)
        screen = .command(command)
        readMenuItems()
    }

    /// Reads the frontmost app's menus, off the main thread, and draws them, keeping the search text. Its cached read,
    /// if any, is drawn at once, and the new one replaces it, the selection staying on the same item. Without
    /// Accessibility permission, the list says so instead, and the check asks for macOS's prompt or shows Fudge's
    /// offer as it does for Paste (`AccessibilityGate`).
    private func readMenuItems() {
        menuItemsStale = false
        menuReads += 1
        let read = menuReads
        menuListing = nil
        guard let target = menuItemsAccess.target() else {
            menuTarget = nil
            drawMenuItems(MenuItemsList.noApp())
            return
        }
        guard menuItemsAccess.mayRead() else {
            menuTarget = nil
            drawMenuItems(MenuItemsList.accessibilityNeeded())
            return
        }
        menuTarget = target
        if let cached = menuCache.value(for: target.cacheKey) {
            drawMenuItems(cached, of: target)
        } else {
            drawMenuItems(MenuItemsList.loading())
        }
        let source = menuItemsAccess.source
        Task {
            let result = await Self.offMain { source.read(target, deadline: .milliseconds(1500)) }
            guard read == menuReads, menuItemsOnScreen else { return }
            switch result {
            case .listing(let listing):
                menuCache.set(listing, for: target.cacheKey)
                drawMenuItems(listing, of: target)
            case .noAnswer:
                // The cached read stays, if there was one: its items are found again by their paths when run.
                if menuListing == nil { drawMenuItems(MenuItemsList.noAnswer(app: target)) }
            }
        }
    }

    /// Draws a view that has no rows: the first row of whatever comes next is selected.
    private func drawMenuItems(_ view: UINode) {
        guard case .command(var command) = screen, command.session == MenuItemsList.session else { return }
        command.view = view
        refreshList(&command, selectFirst: true)
        screen = .command(command)
    }

    /// Draws `listing`'s rows. When it replaces rows on screen, the selection stays on the same item, where it's
    /// still there and shown.
    private func drawMenuItems(_ listing: MenuItemsListing, of target: MenuTarget) {
        guard case .command(var command) = screen, command.session == MenuItemsList.session else { return }
        let previous = menuListing
        menuListing = listing
        if let previous, previous.rows == listing.rows, previous.complete == listing.complete { return }
        let selected = command.selectedNode.flatMap { node in
            command.list?.items.first { $0.id == node }?.itemId.flatMap(Int.init)
        }
        command.view = MenuItemsList.view(rows: listing.rows, app: target, complete: listing.complete)
        refreshList(&command, selectFirst: previous == nil)
        if let previous, let selected,
            let place = MenuItemsList.place(of: selected, in: previous.rows, among: listing.rows),
            command.list?.items.contains(where: { $0.id == MenuItemsList.itemNode(place) }) == true
        {
            command.selectedNode = MenuItemsList.itemNode(place)
        }
        screen = .command(command)
    }

    /// The panel is hiding with Search Menu Items on screen: its read goes, and the list shows as loading until the
    /// menus are read again when the panel shows, perhaps another app's.
    private func menuItemsHidden() {
        guard menuItemsOnScreen else { return }
        menuItemsGeneration.dismissed()
        menuItemsStale = true
        menuReads += 1
        menuTarget = nil
        menuListing = nil
        drawMenuItems(MenuItemsList.loading())
    }

    /// The screen changed: once Search Menu Items is gone, its read goes too, and one still running is dropped.
    private func menuItemsLeft() {
        guard !menuItemsOnScreen, menuListing != nil || menuTarget != nil || menuItemsStale else { return }
        menuItemsGeneration.dismissed()
        menuReads += 1
        menuTarget = nil
        menuListing = nil
        menuItemsStale = false
    }

    /// One of its actions, as `send` hands it over. ↵ on a row finds its item first, with the panel still up: the one
    /// read, else the one at the same path, once (`MenuItemsListing.item`). Found, the panel hides, the app is made
    /// active if it isn't, and the item is pressed. Nothing about the item is recorded.
    private func menuItemsAction(node: Int) {
        guard menuItemsOnScreen, let action = MenuItemsList.target(of: node, rows: menuListing?.rows.count ?? 0)
        else { return }
        switch action {
        case .openAccessibilitySettings:
            hide()
            NSWorkspace.shared.open(AccessibilitySettingsAlert.paneURL)
        case .tryAgain:
            readMenuItems()
        case .run(let row):
            guard let listing = menuListing, let target = menuTarget, !findingMenuItem else { return }
            findingMenuItem = true
            let generation = menuItemsGeneration
            Task {
                let outcome = await MenuItemRun.run(
                    find: { await Self.offMain { listing.item(row: row, in: target.pid) } },
                    // Still the list the run came from, on screen: the panel hasn't hidden and the list hasn't gone.
                    isCurrent: { menuItemsGeneration == generation && menuItemsOnScreen && isVisible() },
                    hide: {
                        hide()
                        // A turn for the panel to be gone, so the app's own window has the keyboard back first.
                        await withCheckedContinuation { continuation in
                            DispatchQueue.main.async { continuation.resume() }
                        }
                        try? await Task.sleep(for: .milliseconds(50))
                    },
                    activate: { await menuItemsAccess.activate(target) },
                    press: { press in await Self.offMain { press() } })
                findingMenuItem = false
                switch outcome {
                case .pressed(.pressed), .pressed(.noAnswer), .dismissed:
                    // No answer in time can mean the item opened a dialog, which holds the answer back.
                    break
                case .pressed(.gone):
                    showHUD(MenuItemsList.gone)
                case .pressed(.failed):
                    showHUD("\(target.name) didn't run that menu item.")
                case .gone:
                    showFailureToast(MenuItemsList.gone)
                    if menuListing === listing { readMenuItems() }
                case .noAnswer:
                    showFailureToast("\(target.name) didn't answer")
                }
            }
        }
    }

    // MARK: - Quick Look

    /// The view on screen, as Quick Look tells views apart: the command's session and how deep it is.
    private var quickLookView: String? {
        command.map { "\($0.session)/\($0.depth)" }
    }

    /// `Action.ToggleQuickLook`: the preview of the selected item's file, or closing it.
    private func toggleQuickLook() {
        reconcileQuickLook()
        let toggled = quickLook.toggle(selected: selectedListItem?.quickLook, in: quickLookView, exists: fileExists)
        // The case only: `missing` carries a file name, which the log never holds.
        LauncherLog.note("toggleQuickLook → \(String(describing: toggled).prefix { $0 != "(" })")
        switch toggled {
        case .opened, .closed:
            quickLookChanged(quickLook.shown)
        case .nothingToPreview:
            showFailureToast("Nothing to preview")
        case .missing(let name):
            showFailureToast("\(name) doesn't exist")
        }
    }

    /// Every screen change: an open preview follows the selection, and closes for another view.
    private func followQuickLook() {
        guard quickLook.isOpen else { return }
        reconcileQuickLook()
        let before = quickLook.shown
        quickLook.follow(selected: selectedListItem?.quickLook, in: quickLookView, exists: fileExists)
        if quickLook.shown != before { quickLookChanged(quickLook.shown) }
    }

    /// The launcher hid: the preview closes with it.
    func closeQuickLook() {
        guard quickLook.isOpen else { return }
        quickLook.close()
        quickLookChanged(nil)
    }

    /// The user closed the preview with its own button.
    func quickLookClosedByUser() {
        quickLook.close()
    }

    /// Before any Quick Look decision: a preview the user closed with its own button is closed here too, even if
    /// `windowWillClose` hasn't arrived yet, so ↓ doesn't reopen it and one ⌘Y does.
    private func reconcileQuickLook() {
        if quickLook.reconcile(panelVisible: quickLookOnScreen()) { quickLookChanged(nil) }
    }

    /// An arrow key the Quick Look preview got because the user clicked it: it does what it does in the launcher,
    /// in the action panel, the dropdown's panel, or the List or Grid. False leaves it to the preview. The caller
    /// leaves keys alone while an input method is composing in the search field.
    func previewArrow(
        _ move: GridNavigation.Move, modifiers: Set<String>, textLength: Int, selection: (location: Int, length: Int)?
    ) -> Bool {
        let step = move == .up ? -1 : 1
        switch PreviewArrow.target(move, actionPanelOpen: actionPanel != nil, dropdownOpen: dropdownPanel != nil) {
        case .actionPanel:
            moveActionSelection(by: step)
        case .dropdown:
            moveDropdownSelection(by: step)
        case .selection:
            guard move == .up || move == .down else {
                return moveGridSelection(
                    move, modifiers: modifiers, composing: false, textLength: textLength, selection: selection)
            }
            moveSelection(by: step)
        case .none:
            return false
        }
        return true
    }

    // MARK: - Keys

    func moveSelection(by offset: Int) {
        switch screen {
        case .root:
            let rows = rootRowIDs
            guard !rows.isEmpty else { return }
            let index = rows.firstIndex { $0 == selectedItem } ?? 0
            selectedItem = rows[max(0, min(rows.count - 1, index + offset))]
        case .command(let command):
            guard let list = command.list, !list.items.isEmpty else { return }
            let index = list.items.firstIndex { $0.id == command.selectedNode } ?? 0
            if let sections = list.gridSections {
                selectListItem(at: GridNavigation.target(from: index, move: offset < 0 ? .up : .down, in: sections))
            } else {
                selectListItem(at: max(0, min(list.items.count - 1, index + offset)))
            }
        case .failure:
            break
        }
    }

    /// ← or → in a Grid's search field: moves the selection when `GridNavigation.arrowMovesSelection` says so,
    /// and returns false to leave the key to the field's cursor or the input method otherwise (and outside a Grid).
    func moveGridSelection(
        _ move: GridNavigation.Move, modifiers: Set<String>, composing: Bool, textLength: Int,
        selection: (location: Int, length: Int)?
    ) -> Bool {
        guard let command, let list = command.list, let sections = list.gridSections, !list.items.isEmpty,
            GridNavigation.arrowMovesSelection(
                move, modifiers: modifiers, composing: composing, textLength: textLength, selection: selection)
        else { return false }
        let index = list.items.firstIndex { $0.id == command.selectedNode } ?? 0
        selectListItem(at: GridNavigation.target(from: index, move: move, in: sections))
        return true
    }

    /// Selects the running command's item at `index`, as the arrow keys do.
    private func selectListItem(at index: Int) {
        guard var command, let items = command.list?.items, items.indices.contains(index) else { return }
        command.selectedNode = items[index].id
        // The user picked: a render of their search's results keeps it.
        command.typing.cancel()
        screen = .command(command)
        requestSlots()
        reportSelection()
        if let node = command.selectedNode { loadMoreIfNeeded(near: node) }
    }

    /// ↵: open the selected item, or run the selected row's first action.
    func activate() {
        switch screen {
        case .root:
            if selectedItem == Self.calculatorID {
                activateCalculator()
                return
            }
            guard let item = selectedRootItem else { return }
            // A required argument left empty takes the keyboard instead.
            switch item.kind {
            case .command, .quicklink: guard arguments.checkRequired() else { return }
            default: break
            }
            open(item)
            // The launch couldn't start (e.g. a required preference is unset). The values stay for the next try,
            // and the failure's search field gets the keyboard.
            if case .failure = screen { arguments.focus = nil }
        case .command:
            if waitForActions(.primary) { return }
            if let primaryAction { run(primaryAction) }
        case .failure:
            // A notice's first action, else back to root search.
            if let primaryAction { run(primaryAction) } else { screen = .root }
        }
    }

    /// Esc: close a DatePicker's calendar, the dropdown's panel or the action panel (a submenu at a time), pop a pushed view, clear the
    /// search, leave the command, then hide.
    func escape() {
        // A key waiting for the selected item's actions is dropped first; Esc then does what it always does.
        hold(nil)
        if signIn != nil {
            answerSignIn(false)
            return
        }
        // The DatePicker's calendar is a popover too: it closes first, whatever Esc is set to do.
        if datePanel != nil {
            closeDatePanel()
            return
        }
        reconcileQuickLook()
        let state = EscapeAction.State(
            dropdownOpen: dropdownPanel != nil, actionPanelOpen: actionPanel != nil,
            quickLookOpen: quickLook.isOpen, screen: escapeScreen)
        switch EscapeAction.next(behavior: settings.escapeBehavior, state: state) {
        case .closeDropdown:
            closeDropdownPanel()
        case .closeActionPanel:
            guard var panel = actionPanel else { return }
            if panel.pick != nil {
                closeDatePick()
            } else if panel.path.isEmpty {
                actionPanel = nil
            } else {
                panel.path.removeLast()
                panel.query = ""
                actionPanel = panel
                let first = ActionPanelReader.flat(actionPanelSections).first?.id
                actionPanel?.selected = first
            }
        case .closeQuickLook:
            quickLook.close()
            quickLookChanged(nil)
        case .popView:
            if case .command(let command) = screen { send(.pop(session: command.session)) }
        case .clearSearch:
            searchText = ""
        case .leaveCommand:
            if closeBuiltInForm() { return }
            leaveCommand()
        case .dismissFailure:
            screen = .root
        case .hide:
            hide()
        case .hideAndReset:
            // "Close window and pop to root": as Pop to Root Search's reset, but at once.
            resetToRoot(keeping: nil)
            hide()
        }
    }

    /// The screen as Esc sees it (`EscapeAction.State.Screen`).
    private var escapeScreen: EscapeAction.State.Screen {
        switch screen {
        case .root:
            return .root(queryEmpty: rootQuery.isEmpty)
        case .failure:
            return .failure
        case .command(let command):
            // A command that failed has nothing to go back through.
            guard command.failure == nil else { return .command(depth: 1, searchEmpty: true, isForm: false) }
            return .command(depth: command.depth, searchEmpty: command.searchText.isEmpty, isForm: command.form != nil)
        }
    }

    // MARK: - Command hotkeys

    /// The `FudgeSettings` ids ("<extension>/<command>") of the installed commands, Fudge's own
    /// (`BuiltInCommandGroup`) and the quicklinks (`QuicklinkCommands`), enabled or not.
    var installedCommandIDs: [String] {
        installedExtensions.flatMap { RootItem.commands(of: $0, metadata: commandMetadata) }
            .compactMap(\.commandSettingsID) + BuiltInCommandGroup.commandIDs(in: builtInGroups)
            + QuicklinkCommands.commandIDs(quicklinks)
    }

    /// A command's or quicklink's hotkey was pressed anywhere (`HotKeyLaunch`): open it as root search would, hide
    /// the panel if it's the view command already on screen, or show root search with its fields when a required
    /// argument is needed. A quicklink opens as a no-view command does (`QuicklinkCommands.hotkeyLaunch`).
    func openFromHotkey(_ commandID: String) {
        guard let item = items.first(where: { $0.id == RootItem.id(forCommandSettingsID: commandID) }) else { return }
        if case .builtInCommand(let group, let command) = item.kind {
            runBuiltIn(item, group: group, command: command, fromHotkey: true)
            return
        }
        let mode: String
        var running: (extensionName: String, commandName: String)?
        switch item.kind {
        case .command(let extensionName, let commandName, let commandMode, _):
            mode = commandMode
            running = (extensionName, commandName)
        case .quicklink:
            mode = "no-view"
        default:
            return
        }
        // The reset comes first, so the hotkey's target is built on top of it. A no-view command's hotkey resets
        // too while the panel is hidden: the panel's next show would reset it anyway, so this changes nothing.
        resettingFirst {
            let onScreen =
                isVisible() && running != nil && command?.extensionName == running?.extensionName
                && command?.commandName == running?.commandName
            let action: HotKeyLaunch
            if case .quicklink(let quicklink) = item.kind {
                action = QuicklinkCommands.hotkeyLaunch(quicklink)
            } else {
                action = HotKeyLaunch.action(
                    mode: mode, hasRequiredArgument: item.arguments.contains { $0.required == true },
                    isOnScreen: onScreen)
            }
            switch action {
            case .hidePanel:
                hide()
            case .askForArguments:
                if case .command = screen { leaveCommand() }
                screen = .root
                rootQuery = ""
                refreshResults()
                selectedItem = item.id
                arguments.focus = 0
                show()
            case .open:
                if case .quicklink(let quicklink) = item.kind {
                    openQuicklink(quicklink, item: item, fromHotkey: true)
                    return
                }
                if mode == "view", case .command = screen { leaveCommand() }
                launchOrigin = .hotkey
                open(item)
                launchOrigin = .rootSearch
                if mode == "view" { show() }
            }
        }
    }

    // MARK: - Reset after inactivity

    /// Starts over on an empty root search when the panel was hidden long enough (`PanelReset`). The launcher
    /// hotkey and the menu bar item call this before they show the panel.
    func resetIfDue() {
        resettingFirst {}
    }

    /// Runs `build`, a path that shows the panel, after resetting the panel if that's due. Every such path goes
    /// through here first; `presented()` never resets, since it runs after the path has built its screen.
    /// `keeping` is a command on screen that the path unloads itself (a `launchCommand` caller, answered first).
    private func resettingFirst<T>(keeping session: String? = nil, _ build: () -> T) -> T {
        panelReset.enter(reset: { resetToRoot(keeping: session) }, build: build)
    }

    /// Root search as on a first show: the command on screen unloaded as Esc to root does, an empty query and
    /// fresh argument fields, no action or dropdown panel, and the first row selected. A no-view command still
    /// running in the background isn't touched.
    private func resetToRoot(keeping session: String?) {
        actionPanel = nil
        dropdownPanel = nil
        if case .command(let command) = screen {
            if command.session != session { send(.unload(session: command.session)) }
            status = nil
            toast = nil
        }
        screen = .root
        rootQuery = ""
        refreshResults()
        resetArguments(for: selectedRootItem)
    }

    /// The hotkeys of installed commands and quicklinks, by root item id, for their rows.
    private(set) var commandHotkeys: [String: HotKeySpec] = [:]

    /// Reads the command hotkeys from `settings.json` again, after Settings changed them.
    func refreshCommandHotkeys() {
        commandHotkeys = Dictionary(
            settings.availableHotkeys(installed: Set(installedCommandIDs))
                .map { (RootItem.id(forCommandSettingsID: $0.key), $0.value) },
            uniquingKeysWith: { first, _ in first })
    }

    /// Where the launch being opened came from.
    @ObservationIgnored private var launchOrigin = LaunchOrigin.rootSearch
    /// No-view sessions started by a hotkey, whose exit leaves root search alone.
    @ObservationIgnored private var hotkeySessions: Set<String> = []

    // MARK: - Opening

    func open(_ item: RootItem) {
        switch item.kind {
        case .application(let url):
            recordLaunch(item.id)
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            searchText = ""
            hide()
        case .settings:
            recordLaunch(item.id)
            searchText = ""
            showSettings(extension: nil)
        case .command(let extensionName, let commandName, "menu-bar", _):
            // Activates it, or refreshes it and opens its menu; the panel closes either way.
            recordLaunch(item)
            do {
                try menuBar.runFromRootSearch(FudgeSettings.commandID(extension: extensionName, command: commandName))
            } catch {
                showFailureToast("Can't activate \(item.title)", message: String(describing: error))
                return
            }
            // As with a no-view command, a hotkey leaves the root query alone.
            if launchOrigin.clearsRootSearchWhenFinished {
                rootQuery = ""
                refreshResults()
            }
            hide()
        case .reloadExtensions:
            recordLaunch(item)
            searchText = ""
            reloadAll()
        case .quit:
            recordLaunch(item)
            Task {
                if await confirm(Self.quitRequest, .userInitiated) { NSApp.terminate(nil) }
            }
        case .quicklink(let quicklink):
            openQuicklink(quicklink, item: item)
        case .createQuicklink:
            recordLaunch(item)
            showQuicklinkForm(QuicklinkDraft())
        case .searchSnippets:
            recordLaunch(item)
            showSnippetList()
        case .createSnippet:
            recordLaunch(item)
            showSnippetForm(SnippetDraft())
        case .builtInCommand(let group, let command):
            runBuiltIn(item, group: group, command: command, fromHotkey: false)
        case .command(let extensionName, let commandName, _, _):
            guard let installed = extensions[extensionName],
                let command = installed.manifest.commands.first(where: { $0.name == commandName })
            else {
                recordLaunch(item.id)
                screen = .failure(
                    Failure(
                        title: "Can't run \(item.title)", message: "The extension is no longer installed.",
                        commandTitle: item.title))
                return
            }
            let prepared = prepareLaunch(of: installed, command: command, userInitiated: true)
            guard prepared.preferences.missing.isEmpty else {
                showNeedsSettings(
                    item.title, extension: extensionName, missing: prepared.preferences.missing,
                    origin: .userInitiated)
                return
            }
            let entered = argumentsItem == item.id ? arguments : ArgumentInput(arguments: item.arguments)
            launch(
                item.title,
                of: installed,
                command: command,
                launchProps: LaunchProps(arguments: entered.launchArguments),
                prepared: prepared
            )
            // The fields start empty again, for a no-view command (root search stays on screen) and for when a
            // view command returns to root search; not when the extension host couldn't run it.
            if case .failure = screen { return }
            if argumentsItem == item.id { resetArguments(for: item) }
        }
    }

    private func recordLaunch(_ id: String) {
        history.record(id)
        try? history.save(to: paths.historyFile)
    }

    /// Records a root item's launch, unless it's one that never counts (`RootItem.recordsLaunch`: Quit).
    /// Runs one of Fudge's own commands (`BuiltInCommandGroup`), from root search or its hotkey, which goes no other
    /// way: each group's commands decide whether the panel shows.
    private func runBuiltIn(_ item: RootItem, group: String, command: String, fromHotkey: Bool) {
        if group == BuiltInCommandGroup.windowManagement.name, command == SwitchWindowsList.commandName {
            openSwitchWindows(item, fromHotkey: fromHotkey)
            return
        }
        if group == BuiltInCommandGroup.apps.name, command == MenuItemsList.commandName {
            openMenuItems(item, fromHotkey: fromHotkey)
            return
        }
        recordLaunch(item)
        if group == BuiltInCommandGroup.windowManagement.name, let command = windowLayouts.command(named: command) {
            runUserWindowCommand(command, fromHotkey: fromHotkey)
            return
        }
        if group == BuiltInCommandGroup.windowManagement.name, let command = WindowCommand(rawValue: command) {
            // The window to move is the frontmost app's, which the panel never takes from it. A window command never
            // shows the panel, and from root search (or with the panel up) the panel goes first.
            if !fromHotkey { searchText = "" }
            if isVisible() { hide() }
            Task {
                if let message = await SystemCalls.windowCommand(command) { showHUD(message) }
            }
        } else if group == BuiltInCommandGroup.system.name, let command = SystemCommand(rawValue: command) {
            // As the window commands do: the panel goes first, so Hide All Apps, Lock Screen and the rest act on
            // the Mac as the user left it. A command that asks does it in an alert of its own.
            if !fromHotkey { searchText = "" }
            if isVisible() { hide() }
            let runner = SystemCommandRunner(actions: systemActions, ownPid: ProcessInfo.processInfo.processIdentifier)
            Task {
                let message = await runner.run(command) { [weak self] confirmation in
                    await self?.confirm(Self.alertRequest(confirmation), .userInitiated) ?? false
                }
                if let message { showHUD(message) }
            }
        } else if group == BuiltInCommandGroup.tools.name, let command = ToolCommand(rawValue: command) {
            runTool(command, item: item, fromHotkey: fromHotkey)
        } else if group == BuiltInCommandGroup.calendar.name, command == ScheduleList.commandName {
            showSchedule(fromHotkey: fromHotkey)
        }
    }

    private static func alertRequest(_ confirmation: SystemConfirmation) -> AlertRequest {
        AlertRequest(
            title: confirmation.title, message: confirmation.message, primary: confirmation.primary,
            dismiss: confirmation.dismiss, destructive: true)
    }

    private func recordLaunch(_ item: RootItem) {
        if item.recordsLaunch { recordLaunch(item.id) }
    }

    // MARK: - Custom positions and saved layouts (SPEC-094)

    /// What the user's own window commands read and move: the system's windows, or none in a snapshot run, which the
    /// app delegate gives made-up windows (`--layout-windows`) and nothing to move.
    @ObservationIgnored var windowLayoutActions = WindowLayoutActions.system
    /// The Settings window reads the positions and layouts again, after Save Layout… saved one; set by the app
    /// delegate.
    @ObservationIgnored var windowLayoutsChanged: () -> Void = {}

    /// A custom position, or "Apply <name>", works as the window commands do: the panel goes first, since the window
    /// to move is the frontmost app's, and the HUD says what happened. Save Layout… reads the windows, then asks for
    /// a name in the panel.
    private func runUserWindowCommand(_ command: UserWindowCommand, fromHotkey: Bool) {
        switch command {
        case .position(let position):
            if !fromHotkey { searchText = "" }
            if isVisible() { hide() }
            Task {
                if let message = await windowLayoutActions.position(position.frame) { showHUD(message) }
            }
        case .layout(let layout):
            if !fromHotkey { searchText = "" }
            if isVisible() { hide() }
            Task { showHUD(await windowLayoutActions.apply(layout)) }
        case .saveLayout:
            Task { await saveLayout(fromHotkey: fromHotkey) }
        }
    }

    /// Save Layout…: reads every standard window on the screens, then shows the Save Layout form for its name. From
    /// its hotkey, it works as a view command's does: over whatever the panel shows (after Pop to Root Search's reset,
    /// when that's due), or it hides the panel when the form is on screen already. From root search, the form shows
    /// only if the panel is still up once the windows are read.
    private func saveLayout(fromHotkey: Bool) async {
        if fromHotkey, isVisible(), builtInForm?.session == LayoutForm.session {
            hide()
            return
        }
        guard let windows = await windowLayoutActions.capture() else {
            showHUD(SystemCalls.accessibilityNeededForWindows)
            return
        }
        guard !windows.isEmpty else {
            showHUD("There are no windows to save.")
            return
        }
        let form = BuiltInFormState(content: .layout(LayoutDraft(windows: windows), problem: nil))
        guard fromHotkey else {
            if isVisible(), case .root = screen { showBuiltInForm(form) }
            return
        }
        resettingFirst {
            if case .command = screen { leaveCommand() }
            showBuiltInForm(form)
            show()
        }
    }

    /// "Quit Fudge" asks first: its hotkeys stop working until Fudge is opened again.
    private static let quitRequest = AlertRequest(
        title: "Quit Fudge?",
        message: "Its hotkeys stop working until you open it again.",
        primary: "Quit",
        dismiss: "Cancel",
        destructive: false
    )

    /// The preferences of `session`'s command as they are now, resolved as a launch resolves them.
    private func preferenceValues(of session: String) -> [String: JSONValue] {
        guard let name = sessionExtensions[session], let installed = extensions[name],
            let command = installed.manifest.commands.first(where: { $0.name == sessionCommands[session] })
        else { return [:] }
        let stored = PreferenceStore(directory: paths.preferencesDirectory).load(name)
        return PreferenceResolver.resolve(installed.manifest, command: command, stored: stored).values
    }

    /// What a command needs before it launches: its preferences (with the required ones that aren't set in
    /// `missing`) and its environment. Root search and `launchCommand` both prepare launches here, and a
    /// user-initiated launch counts in the launch history.
    private func prepareLaunch(
        of installed: InstalledExtension, command: ExtensionManifest.Command, userInitiated: Bool
    ) -> (preferences: ResolvedPreferences, environment: LaunchEnvironment) {
        let name = installed.manifest.name
        if userInitiated { recordLaunch(RootItem.commandID(extension: name, command: command.name)) }
        let preferences = PreferenceResolver.resolve(
            installed.manifest,
            command: command,
            stored: PreferenceStore(directory: paths.preferencesDirectory).load(name)
        )
        let environment = LaunchEnvironment.make(
            for: installed,
            command: command,
            paths: paths,
            appearance: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light"
        )
        return (preferences, environment)
    }

    /// A required preference isn't set: say so, and open Settings on the extension instead of running the command.
    /// Settings comes forward only for a user-initiated `origin`.
    private func showNeedsSettings(
        _ title: String, extension name: String, missing: [ExtensionManifest.Preference], origin: CallOrigin
    ) {
        let names = missing.map { $0.title ?? $0.name }.joined(separator: ", ")
        screen = .failure(
            Failure(
                title: "\(title) needs settings",
                message: "Set \(names) in the Settings window, then run the command again.", commandTitle: title
            )
        )
        openSettings(name, origin)
    }

    /// Starts a prepared command in the extension host: the one way commands launch, from root search and from
    /// `launchCommand`. A view command takes the screen; a no-view one shows "Running …" until it exits, unless
    /// it's `quiet` (a background launch), which leaves the panel and the status line alone.
    /// Returns why it couldn't start, if it couldn't; except for quiet launches, that's also shown as a failure.
    @discardableResult
    private func launch(
        _ title: String,
        of installed: InstalledExtension,
        command: ExtensionManifest.Command,
        launchProps: LaunchProps,
        prepared: (preferences: ResolvedPreferences, environment: LaunchEnvironment),
        quiet: Bool = false
    ) -> String? {
        let extensionName = installed.manifest.name
        // The app decides whether the store is on, from settings.json as it is now, before any of its code runs.
        if ExtensionStore.isOff(extensionName, settings: FudgeSettings.load(from: paths.settingsFile)) {
            if !quiet { screen = .failure(.extensionStoreOff) }
            return ExtensionStore.Off.title
        }
        let host: ExtensionHost
        do {
            host = try ensureHost()
        } catch {
            if !quiet { screen = .failure(Failure(title: "Can't run extensions", message: String(describing: error))) }
            return String(describing: error)
        }
        let session = SessionID.make()
        hostSessions.started(session)
        sessionExtensions[session] = extensionName
        sessionCommands[session] = command.name
        if command.mode == "view" {
            screen = .command(
                CommandScreen(
                    session: session, title: title, extensionName: extensionName, commandName: command.name,
                    assets: installed.assetsDirectory))
        } else if quiet {
            quietSessions[session] = QuietSession(title: title)
        } else {
            background[session] = title
            status = "Running \(title)…"
            if !launchOrigin.clearsRootSearchWhenFinished { hotkeySessions.insert(session) }
        }
        do {
            try host.send(
                .launch(
                    session: session, entry: installed.entry(for: command.name).path, mode: command.mode,
                    launchProps: launchProps, preferences: prepared.preferences.values,
                    environment: prepared.environment)
            )
        } catch {
            hostSessions.ended(session)
            sessionExtensions[session] = nil
            sessionCommands[session] = nil
            quietSessions[session] = nil
            if !quiet {
                screen = .failure(
                    Failure(title: "Can't run \(title)", message: String(describing: error), commandTitle: title))
            }
            return String(describing: error)
        }
        return nil
    }

    /// Starts a menu-bar command for `MenuBarController`, prepared as root search prepares launches. Its session's
    /// messages go to the controller. A missing required preference opens Settings when the launch is
    /// UserInitiated.
    private func launchMenuBarCommand(
        _ installed: InstalledExtension, command: ExtensionManifest.Command, userInitiated: Bool
    ) -> Result<String, MenuBarController.LaunchFailed> {
        let prepared = prepareLaunch(of: installed, command: command, userInitiated: false)
        guard prepared.preferences.missing.isEmpty else {
            let origin = CallOrigin.launched(userInitiated: userInitiated)
            if origin.mayComeForward { openSettings(installed.manifest.name, origin) }
            let names = prepared.preferences.missing.map { $0.title ?? $0.name }.joined(separator: ", ")
            return .failure(.init(message: "set \(names) in the Settings window first"))
        }
        let host: ExtensionHost
        do {
            host = try ensureHost()
        } catch {
            return .failure(.init(message: String(describing: error)))
        }
        let session = SessionID.make()
        hostSessions.started(session)
        sessionExtensions[session] = installed.manifest.name
        sessionCommands[session] = command.name
        let launchProps = LaunchProps(launchType: userInitiated ? "userInitiated" : "background")
        do {
            try host.send(
                .launch(
                    session: session, entry: installed.entry(for: command.name).path, mode: command.mode,
                    launchProps: launchProps, preferences: prepared.preferences.values,
                    environment: prepared.environment))
        } catch {
            hostSessions.ended(session)
            sessionExtensions[session] = nil
            sessionCommands[session] = nil
            return .failure(.init(message: String(describing: error)))
        }
        return .success(session)
    }

    /// A failure toast in the bottom bar that no command showed.
    private func showFailureToast(_ title: String, message: String? = nil) {
        let shown = ToastState(session: "", id: 0, title: title, message: message, style: "FAILURE")
        toast = shown
        expireToast(shown)
    }

    // MARK: - launchCommand

    /// `launchCommand` from the command running in `session` (the `command.launch` rpc). Finds the command
    /// (`CommandLocator`), asks the user the first time an extension opens another extension's commands, then
    /// launches it the way root search does. The call is answered once the launch has started, before the command
    /// on screen is unloaded, so code after `await launchCommand(…)` still runs. Throws why it can't launch.
    /// `origin` is the caller's, read when the call came in: a background caller's request runs as Background
    /// (`LaunchRequest.asCalled(from:)`), so it never shows the panel or Settings.
    private func launchCommand(
        _ params: JSONValue, from session: String, call id: Int, origin: CallOrigin
    ) async throws {
        guard let callerName = sessionExtensions[session], let caller = extensions[callerName] else {
            throw LaunchCommandError.invalid("the calling command isn't running")
        }
        let request = try LaunchRequest(params: params).asCalled(from: origin)
        let target = try CommandLocator.locate(
            request, caller: callerName, in: Array(extensions.values), settings: settings)
        let targetID = FudgeSettings.commandID(extension: target.installed.manifest.name, command: target.command.name)
        try CommandLocator.checkMode(target.command, type: request.type, isActiveInMenuBar: menuBar.isActive(targetID))
        if target.isOtherExtension {
            try await checkPermission(of: caller, toOpen: target, origin: origin, from: session)
        }

        let userInitiated = request.type == .userInitiated
        let answer = { self.send(.rpcResult(session: session, id: id, result: .null, error: nil)) }
        // A user-initiated view launch, or what replaces it, takes the place of the command on screen.
        let onScreen = command?.session

        guard try CommandLocator.checkArguments(target, type: request.type) else {
            answer()
            if onScreen != nil { leaveCommand() }
            showArguments(of: target)
            return
        }
        let prepared = prepareLaunch(of: target.installed, command: target.command, userInitiated: userInitiated)
        guard try CommandLocator.checkPreferences(prepared.preferences.missing, of: target, type: request.type) else {
            answer()
            if onScreen != nil { leaveCommand() }
            showNeedsSettings(
                target.command.title, extension: target.installed.manifest.name,
                missing: prepared.preferences.missing, origin: origin)
            return
        }
        if target.command.mode == "menu-bar" {
            // A refresh (SPEC-004 C): the menu bar starts it, or skips it while it's loaded.
            try menuBar.launchCommand(targetID, userInitiated: userInitiated)
            answer()
            return
        }
        let start = {
            self.launch(
                target.command.title, of: target.installed, command: target.command, launchProps: target.launchProps,
                prepared: prepared, quiet: !userInitiated)
        }
        // A user-initiated view launch shows the panel, so a due reset comes first. The command on screen is left
        // to `unloadReplaced`, after the call is answered.
        let showsPanel = userInitiated && target.command.mode == "view"
        if let failure = showsPanel ? resettingFirst(keeping: onScreen, start) : start() {
            // A view launch has put its failure on screen in place of the command that was there.
            let error = LaunchCommandError.invalid("couldn't start \"\(target.command.name)\": \(failure)")
            send(.rpcResult(session: session, id: id, result: nil, error: error.description))
            if target.command.mode == "view", let onScreen { unloadReplaced(onScreen) }
            return
        }
        answer()
        if target.command.mode == "view" {
            if let onScreen { unloadReplaced(onScreen) }
            if !isVisible() { show() }
        }
    }

    /// Where a session's calls come from (SPEC-045): a menu-bar session as its lifecycle says; the command the user
    /// opened (the view on screen, or a no-view command showing "Running …") as user-initiated; anything else,
    /// such as a background `launchCommand`'s session or one that's been replaced, as background.
    private func origin(of session: String) -> CallOrigin {
        if menuBar.owns(session) { return menuBar.origin(of: session) }
        if command?.session == session || background[session] != nil { return .userInitiated }
        return .background
    }

    /// `openExtensionPreferences()` from a command the user isn't using: Settings won't come to the front for it.
    static let backgroundSettingsError =
        "Fudge opens Settings only for a command you're using: open the command from Fudge first."

    /// The first time an extension opens another extension's command, the user decides, once for that pair. Only
    /// a call from a session the user is using may ask (`LaunchPermissions.step`); a background one is refused
    /// without saving anything, so the question comes when the user next opens the caller, and a HUD says so once
    /// per pair per run.
    private func checkPermission(
        of caller: InstalledExtension, toOpen target: LaunchTarget, origin: CallOrigin, from session: String
    ) async throws {
        let file = paths.launchPermissionsFile
        var permissions = LaunchPermissions.load(from: file)
        let callerName = caller.manifest.name
        let targetName = target.installed.manifest.name
        let allowed: Bool
        switch LaunchPermissions.step(
            answer: permissions.answer(caller: callerName, target: targetName), origin: origin)
        {
        case .allowed:
            allowed = true
        case .refused:
            allowed = false
        case .refusedUnasked:
            if backgroundNotices.first("launch:\(callerName)/\(targetName)") {
                showHUD(
                    LaunchPermissions.unaskedNotice(
                        callerTitle: caller.manifest.title, targetTitle: target.installed.manifest.title))
            }
            let refusal = LaunchCommandError.permissionNeeded(extensionTitle: target.installed.manifest.title)
            quietSessions[session]?.unasked.insert(refusal.description)
            throw refusal
        case .ask:
            allowed = await confirm(
                AlertRequest(
                    title:
                        "“\(caller.manifest.title)” wants to open “\(target.command.title)” from “\(target.installed.manifest.title)”.",
                    message: nil,
                    primary: "Allow",
                    dismiss: "Don't Allow",
                    destructive: false
                ), origin)
            // Read again: another call may have stored an answer while this one waited.
            permissions = LaunchPermissions.load(from: file)
            permissions.record(allowed, caller: callerName, target: targetName)
            try? permissions.save(to: file)
        }
        guard allowed else { throw LaunchCommandError.notAllowed(extensionTitle: target.installed.manifest.title) }
    }

    /// A required argument has no value: root search shows the command, its fields filled with what was given and the
    /// keyboard in the first empty required one, as ↵ on it would. The panel opens if it's hidden.
    private func showArguments(of target: LaunchTarget) {
        resettingFirst {
            screen = .root
            rootQuery = ""
            refreshResults()
            selectedItem = target.rootItemID
            // Fresh fields, even if the command was already selected with something typed into them.
            resetArguments(for: selectedRootItem)
            for (index, argument) in arguments.arguments.enumerated() {
                if let value = target.launchProps.arguments[argument.name], !value.isEmpty {
                    arguments.set(value, at: index)
                }
            }
            _ = arguments.checkRequired()
            if !isVisible() { show() }
        }
    }

    /// Unloads the command a `launchCommand` view launch replaced on screen.
    private func unloadReplaced(_ session: String) {
        send(.unload(session: session))
        if toast?.session == session { toast = nil }
        actionPanel = nil
        dropdownPanel = nil
        datePanel = nil
    }

    // MARK: - The extension host

    struct HostUnavailable: Error, CustomStringConvertible {
        var description: String
    }

    private func ensureHost() throws -> ExtensionHost {
        if let host, host.isRunning { return host }
        guard let node = Runtime.locateNode() else {
            throw HostUnavailable(
                description:
                    "Fudge needs Node.js 22.18 or later. Install it with `brew install node`, or set FUDGE_NODE."
            )
        }
        guard let script = Runtime.locateHostScript() else {
            throw HostUnavailable(
                description: "The extension host is missing from Fudge.app. Rebuild it with `make app`.")
        }
        let cli = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/fudge")
        // Extensions trust the certificates the Mac trusts (SPEC-081). The Node version comes from the cache, never
        // read here (SPEC-084): while it isn't known, this start takes the NODE_EXTRA_CA_CERTS path, which works on any
        // Node, and it's read in the background for the next.
        let version: String?
        if case .known(let known) = nodeVersions.cached(node) {
            version = known
        } else {
            version = nil
            warmNodeVersion(node)
        }
        let trust = NodeTrust.launch(
            nodeVersion: version, certificates: SystemTrustSettings.certificates, rootsFile: paths.trustRootsFile)
        let host = try ExtensionHost(
            node: node, script: script, nodeArguments: trust.arguments,
            environment: ExtensionStore.hostEnvironment(
                cli: FileManager.default.isExecutableFile(atPath: cli.path) ? cli : nil, paths: paths
            ).merging([OAuthProviders.environmentKey: OAuthProviders.environmentValue]) { _, new in new }
                .merging(trust.environment) { _, new in new })
        self.host = host
        let startedWithFlag = trust.arguments.contains(NodeTrust.systemCAFlag)
        let started = ContinuousClock.now
        Task { [weak self] in
            var heard = false
            for await message in host.messages {
                heard = true
                self?.receive(message)
            }
            // A host that ends at once, saying nothing, on `--use-system-ca`: its Node refused the flag (a version
            // manager's shim can change Node underneath), so the next start takes the other path.
            if startedWithFlag, !heard, ContinuousClock.now - started < .seconds(5) {
                self?.nodeVersions.refuseSystemCA(node)
            }
            self?.hostStopped(host)
        }
        return host
    }

    /// Reads the Node version in the background, for the next host start.
    private func warmNodeVersion(_ node: URL) {
        let versions = nodeVersions
        Task.detached(priority: .utility) { versions.load(node) }
    }

    private func send(_ message: AppMessage) {
        // Fudge's own views answer their events themselves, and nothing of theirs reaches the host.
        if case .event(let session, let node, let path, _) = message, Self.builtInSessions.contains(session) {
            if session == builtInForm?.session {
                builtInFormEvent(node: node, path: path)
            } else if session == SnippetList.session, path == ["onAction"] {
                snippetListAction(node: node)
            } else if session == SwitchWindowsList.session, path == ["onAction"] {
                switchWindowsAction(node: node)
            } else if session == MenuItemsList.session, path == ["onAction"] {
                menuItemsAction(node: node)
            } else if session == RecentColorsGrid.session, path == ["onAction"] {
                recentColorsAction(node: node)
            } else if session == DefineWordView.session, path == ["onAction"] {
                defineWordAction(node: node)
            } else if session == ScheduleList.session, path == ["onAction"] {
                scheduleListAction(node: node)
            }
            return
        }
        switch message {
        case .pop(let session), .unload(let session), .slots(let session, _), .rpcResult(let session, _, _, _, _),
            .toastAction(let session, _, _):
            if Self.builtInSessions.contains(session) { return }
        default:
            break
        }
        // Nothing goes to a command that has ended: a late pick or action from an overlay left open is dropped.
        guard hostSessions.mayReceive(message) else { return }
        do {
            try host?.send(message)
        } catch {
            status = "Lost the extension host: \(error)"
        }
    }

    private func hostStopped(_ stopped: ExtensionHost) {
        guard host === stopped else { return }
        host = nil
        hostSessions.endAll()
        background.removeAll()
        quietSessions.removeAll()
        menuBar.hostStopped()
        if case .command(var command) = screen, command.failure == nil,
            !Self.builtInSessions.contains(command.session)
        {
            command.failure = Failure(title: "\(command.title) stopped", message: "The extension host exited.")
            screen = .command(command)
        }
        // Fudge's forms need no host; the view under one shows that it stopped once it's back.
        if var covered = builtInForm?.returnTo, covered.failure == nil {
            covered.failure = Failure(title: "\(covered.title) stopped", message: "The extension host exited.")
            builtInForm?.returnTo = covered
        }
    }

    /// A message from the host. One naming a session Fudge didn't start in this host, or one that has exited, is
    /// dropped, and logged once (`HostSessions`), so it can't reach another command's screen or calls, or Fudge's own
    /// Create Quicklink form. Messages put aside meanwhile (the form's `deferred`) go to `handle` straight.
    private func receive(_ message: HostMessage) {
        switch hostSessions.admit(message) {
        case .handle:
            handle(message)
        case .drop(let logIt):
            if logIt, let session = message.session {
                log(session, "debug", "dropped a host message for a session Fudge isn't running")
            }
        }
    }

    private func handle(_ message: HostMessage) {
        // The extension's view under Fudge's form gets its renders, errors and exit once it's shown again; its calls
        // are answered meanwhile.
        if let covered = builtInForm?.returnTo?.session, message.session == covered {
            switch message {
            case .render, .error, .exit:
                builtInForm?.deferred.append(message)
                return
            default:
                break
            }
        }
        // A menu-bar command's tree, errors and exit belong to the menu bar; its rpcs and logs are answered here.
        if let session = message.session, menuBar.owns(session) {
            switch message {
            case .render, .eventSettled:
                menuBar.handle(message)
                return
            case .error(_, let text, let stack, _, _):
                menuBar.handle(message)
                log(session, "error", stack ?? text)
                return
            case .exit:
                sessionExtensions[session] = nil
                sessionCommands[session] = nil
                menuBar.handle(message)
                return
            case .slots, .rpc, .log, .pong, .protocolError, .unknown:
                break
            }
        }
        switch message {
        case .render(let session, let view, let depth):
            guard case .command(var command) = screen, command.session == session else { return }
            if depth != command.depth {
                // A view was pushed or popped. Each view has its own search text and selection.
                if depth > command.depth {
                    command.searchStack.append(command.searchText)
                    command.searchText = ""
                } else {
                    while command.searchStack.count >= depth { command.searchText = command.searchStack.removeLast() }
                }
                command.selectedNode = nil
                command.dropdown = nil
                command.reportedSelection = nil
                command.followedItemId = nil
                command.selectFirstOnRender = false
                command.typing = TypingSelection()
                command.searchField = FieldValue(.string(command.searchText))
                command.requestedMoreAt = nil
                command.slotRequests = SlotRequests()
                actionPanel = nil
                dropdownPanel = nil
                datePanel = nil
            }
            command.view = view
            command.depth = depth
            // Slots that came before this render may be out of date; it carries those of the items asked for last.
            command.slots = [:]
            // The extension can set the search text (`searchText`); echoes of what was typed don't undo typing.
            if let view, ListContent.viewTypes.contains(view.type), let controlled = view.string("searchText") {
                command.searchField.render(controlled: .string(controlled))
                if case .string(let text) = command.searchField.value, text != command.searchText {
                    command.searchText = text
                    command.selectFirstOnRender = true
                }
            }
            refreshList(&command, selectFirst: command.selectFirstOnRender, rendered: true)
            // Results for a new search may come after a loading render or two.
            if command.list?.isLoading != true { command.selectFirstOnRender = false }
            refreshForm(&command)
            screen = .command(command)
            syncDropdownPanel()
            syncDatePanel()
            syncDatePick()
            requestSlots()
            reportSelection()
            settleHeldKey()

        case .slots(let session, let items):
            guard case .command(var command) = screen, command.session == session else { return }
            for item in items { command.slots[item.id] = item }
            command.slotRequests.answered(items.map(\.id))
            screen = .command(command)
            settleHeldKey()

        case .error(let session, let message, let stack, let fatal, let notice):
            // Refused on purpose (SPEC-095), such as signing in while sign-in is off: a notice, never a trace.
            let commandTitle: String? =
                if case .command(let command) = screen, command.session == session { command.title } else {
                    background[session]
                }
            let signIn = signInNotice(notice, message: message, session: session, commandTitle: commandTitle)
            if var quiet = quietSessions[session] {
                // A background launch: the panel stays as it is, and the failure shows in the HUD, once.
                let alreadySaid = quiet.unasked.contains { message.contains($0) }
                if !quiet.failed, !alreadySaid { showHUD(signIn?.hud ?? "\(quiet.title) failed — \(message)") }
                quiet.failed = true
                quietSessions[session] = quiet
            } else if case .command(var command) = screen, command.session == session {
                if fatal, let signIn {
                    // The command can't go on: the notice takes its place, as the store's "off" one does.
                    leaveCommand()
                    screen = .failure(Failure(signIn, extensionName: command.extensionName))
                } else if fatal {
                    command.failure = Failure(title: "\(command.title) failed", message: message, details: stack)
                    screen = .command(command)
                } else {
                    status = signIn?.hud ?? "Error: \(message)"
                }
            } else if let title = background[session] {
                screen = .failure(
                    signIn.map { Failure($0, extensionName: sessionExtensions[session] ?? "") }
                        ?? Failure(title: "\(title) failed", message: message, details: stack, commandTitle: title))
            }
            log(session, "error", stack ?? message)

        case .exit(let session, let reason):
            endSignIn(of: session)
            if sessionExtensions[session] == ClipboardHistory.extensionName { clipboardHistory.clearPreviews() }
            sessionExtensions[session] = nil
            sessionCommands[session] = nil
            if let quiet = quietSessions.removeValue(forKey: session) {
                // Unlike root search, a background launch's exit neither clears the query nor hides the panel.
                if reason == "crashed", !quiet.failed { showHUD("\(quiet.title) failed") }
            } else if let title = background.removeValue(forKey: session) {
                status = nil
                let fromHotkey = hotkeySessions.remove(session) != nil
                if reason == "finished", case .root = screen, !fromHotkey {
                    rootQuery = ""
                    refreshResults()
                    hide()
                } else if reason == "crashed", case .root = screen {
                    screen = .failure(
                        Failure(
                            title: "\(title) failed", message: "The command stopped unexpectedly.", commandTitle: title)
                    )
                }
            } else if case .command(var command) = screen, command.session == session, reason != "unloaded" {
                // Its ⌘K panel or date picker goes with it, so nothing in them can be picked for a command that ended.
                actionPanel = nil
                if command.failure == nil {
                    command.failure = Failure(
                        title: "\(command.title) stopped", message: "The command exited (\(reason)).")
                }
                screen = .command(command)
            }

        case .rpc(let session, let id, let method, let params):
            switch method {
            case "preferences.openExtension", "preferences.openCommand":
                // Settings comes to the front, so only for a command the user is using (SPEC-045).
                let origin = origin(of: session)
                guard origin.mayComeForward else {
                    send(.rpcResult(session: session, id: id, result: nil, error: Self.backgroundSettingsError))
                    break
                }
                if let extensionName = sessionExtensions[session] { openSettings(extensionName, origin) }
                send(.rpcResult(session: session, id: id, result: .null, error: nil))
            case let method where method.hasPrefix("clipboardHistory."):
                // Clipboard History's own calls (SPEC-077), refused for any other extension.
                let caller = sessionExtensions[session]
                let origin = origin(of: session)
                Task {
                    do {
                        let result = try await clipboardHistory.handle(
                            method, params, caller: caller, origin: origin, hideWindow: { await self.hideForPaste() })
                        send(.rpcResult(session: session, id: id, result: result, error: nil))
                    } catch {
                        send(.rpcResult(session: session, id: id, result: nil, error: String(describing: error)))
                    }
                }
            case "clipboard.read" where ClipboardOffset(params: params) != .current:
                // Raycast's `offset`, 1 to 5: a previous copy from clipboard history, for any extension.
                let result: JSONValue =
                    if case .previous(let offset) = ClipboardOffset(params: params) {
                        clipboardHistory.read(offset: offset)
                    } else {
                        .null
                    }
                send(.rpcResult(session: session, id: id, result: result, error: nil))
            case "form.storeValues":
                storeFormValues(params, session: session)
                send(.rpcResult(session: session, id: id, result: .null, error: nil))
            case "files.search":
                // Search Files (SPEC-069): its own preferences say where, read now so a change applies at once.
                let caller = sessionExtensions[session]
                let options = FileSearchOptions(
                    preferences: preferenceValues(of: session), home: FileSearchOptions.home())
                Task {
                    do {
                        let found = try await fileSearch.search(
                            params, options: options, session: session, caller: caller)
                        send(.rpcResult(session: session, id: id, result: .array(found.map(\.json)), error: nil))
                    } catch {
                        send(.rpcResult(session: session, id: id, result: nil, error: String(describing: error)))
                    }
                }
            case "toast.show", "toast.hide", "hud.show", "window.close", "window.popToRoot", "searchBar.clear":
                windowCall(method, params, session: session)
                send(.rpcResult(session: session, id: id, result: .null, error: nil))
            case "alert.confirm":
                let origin = origin(of: session)
                Task {
                    let confirmed = await confirm(Self.alertRequest(params), origin)
                    send(.rpcResult(session: session, id: id, result: .bool(confirmed), error: nil))
                }
            case "clipboard.paste":
                let origin = origin(of: session)
                Task {
                    do {
                        try await SystemCalls.paste(params, origin: origin, hideWindow: { await self.hideForPaste() })
                        send(.rpcResult(session: session, id: id, result: .null, error: nil))
                    } catch {
                        send(.rpcResult(session: session, id: id, result: nil, error: String(describing: error)))
                    }
                }
            case "command.updateMetadata":
                do {
                    try updateCommandMetadata(params, from: session)
                    send(.rpcResult(session: session, id: id, result: .null, error: nil))
                } catch {
                    send(.rpcResult(session: session, id: id, result: nil, error: String(describing: error)))
                }
            case "oauth.server", "oauth.prepare", "oauth.authorize", "oauth.tokens.get", "oauth.tokens.set",
                "oauth.tokens.remove":
                let origin = origin(of: session)
                Task {
                    do {
                        let result = try await signInCall(method, params, session: session, origin: origin)
                        send(.rpcResult(session: session, id: id, result: result, error: nil))
                    } catch let refusal as SignInRefusal {
                        send(
                            .rpcResult(
                                session: session, id: id, result: nil, error: refusal.message,
                                notice: refusal.notice?.rawValue))
                    } catch {
                        send(.rpcResult(session: session, id: id, result: nil, error: String(describing: error)))
                    }
                }
            case "command.launch":
                // Read now: by the time the Task runs, an `eventSettled` may have made a real pick look background.
                let origin = origin(of: session)
                Task {
                    do {
                        try await launchCommand(params, from: session, call: id, origin: origin)
                    } catch {
                        send(.rpcResult(session: session, id: id, result: nil, error: String(describing: error)))
                    }
                }
            default:
                let origin = origin(of: session)
                Task {
                    do {
                        let result = try await SystemCalls.handle(method, params, origin: origin)
                        send(.rpcResult(session: session, id: id, result: result, error: nil))
                    } catch {
                        send(.rpcResult(session: session, id: id, result: nil, error: String(describing: error)))
                    }
                }
            }

        case .log(let session, let level, let message):
            log(session, level, message)

        case .protocolError(let message):
            log("host", "error", message)

        case .pong, .eventSettled, .unknown:
            break
        }
    }

    // MARK: - Toasts, the HUD and the window

    private func windowCall(_ method: String, _ params: JSONValue, session: String) {
        let values: [String: JSONValue]
        if case .object(let object) = params { values = object } else { values = [:] }
        func string(_ key: String) -> String? { if case .string(let value) = values[key] { value } else { nil } }
        func flag(_ key: String) -> Bool { values[key] == .bool(true) }
        func actionTitle(_ key: String) -> String? {
            if case .object(let action) = values[key], case .string(let title) = action["title"] { title } else { nil }
        }

        switch method {
        case "toast.show":
            guard case .number(let id) = values["id"] else { return }
            let toast = ToastState(
                session: session,
                id: Int(id),
                title: string("title") ?? "",
                message: string("message"),
                style: string("style") ?? "SUCCESS",
                primaryAction: actionTitle("primaryAction"),
                secondaryAction: actionTitle("secondaryAction")
            )
            if isVisible() {
                self.toast = toast
                expireToast(toast)
            } else if toast.style != "ANIMATED" {
                // With the window closed, a finished toast still deserves to be seen.
                showHUD([toast.title, toast.message].compactMap { $0 }.joined(separator: " — "))
            }
        case "toast.hide":
            if case .number(let id) = values["id"], toast?.id == Int(id), toast?.session == session { toast = nil }
        case "hud.show":
            closeWindow(clearRootSearch: flag("clearRootSearch"), popToRootType: string("popToRootType"))
            showHUD(string("title") ?? "")
        case "window.close":
            closeWindow(clearRootSearch: flag("clearRootSearch"), popToRootType: string("popToRootType"))
        case "window.popToRoot":
            leaveCommand()
            if flag("clearSearchBar") { rootQuery = "" }
            refreshResults()
        case "searchBar.clear":
            searchText = ""
        default:
            break
        }
    }

    /// `Clipboard.paste` hides the panel first, as `closeMainWindow()` does, and waits until it's really gone: key
    /// status goes back to the app the user was in asynchronously, so ⌘V waits a run-loop turn plus about 50 ms.
    private func hideForPaste() async {
        closeWindow(clearRootSearch: false, popToRootType: nil)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        try? await Task.sleep(for: .milliseconds(50))
    }

    /// Success and failure toasts go away after a few seconds; an animated one stays until it changes.
    private func expireToast(_ shown: ToastState) {
        toastExpiry?.cancel()
        guard shown.style != "ANIMATED" else { return }
        toastExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(shown.primaryAction == nil ? 3 : 6))
            guard !Task.isCancelled, let self, self.toast == shown else { return }
            self.toast = nil
        }
    }

    /// Runs the shown toast's primary action (clicking the toast).
    func runToastAction() {
        guard let toast, toast.primaryAction != nil else { return }
        send(.toastAction(session: toast.session, toast: toast.id, action: "primary"))
    }

    private func closeWindow(clearRootSearch: Bool, popToRootType: String?) {
        if popToRootType == "immediate" { leaveCommand() }
        if clearRootSearch {
            rootQuery = ""
            refreshResults()
        }
        hide()
        // "Suspended" keeps the command for when the panel opens again, however long it stays hidden.
        if popToRootType == "suspended" { panelReset.suspend() }
    }

    /// Unloads the visible command, if any, and shows root search.
    private func leaveCommand() {
        actionPanel = nil
        dropdownPanel = nil
        datePanel = nil
        if case .command(let command) = screen { send(.unload(session: command.session)) }
        screen = .root
        status = nil
        toast = nil
    }

    static func alertRequest(_ params: JSONValue) -> AlertRequest {
        var values: [String: JSONValue] = [:]
        if case .object(let object) = params { values = object }
        func action(_ key: String) -> (title: String?, style: String?) {
            guard case .object(let action) = values[key] else { return (nil, nil) }
            let title: String? = if case .string(let title) = action["title"] { title } else { nil }
            let style: String? = if case .string(let style) = action["style"] { style } else { nil }
            return (title, style)
        }
        let primary = action("primaryAction")
        let dismiss = action("dismissAction")
        let title: String = if case .string(let title) = values["title"] { title } else { "" }
        let message: String? = if case .string(let message) = values["message"] { message } else { nil }
        return AlertRequest(
            title: title,
            message: message,
            primary: primary.title ?? "OK",
            dismiss: dismiss.title ?? "Cancel",
            destructive: primary.style == "destructive"
        )
    }

    private func log(_ session: String, _ level: String, _ message: String) {
        FileHandle.standardError.write(Data("[\(session)] \(level): \(message)\n".utf8))
    }

    // MARK: - Sign-in (SPEC-056)

    private func signInCall(_ method: String, _ params: JSONValue, session: String, origin: CallOrigin) async throws
        -> JSONValue
    {
        let values: [String: JSONValue] = if case .object(let object) = params { object } else { [:] }
        func string(_ key: String) -> String? { if case .string(let value) = values[key] { value } else { nil } }
        switch method {
        case "oauth.server":
            let server = FudgeSettings.load(from: paths.settingsFile).signIn
            let signedIn = try signInCalls(session).flatMap {
                try $0.hasRelaySignIn(provider: string("provider") ?? "")
            }
            return .object([
                "server": server.url.map { .string($0.absoluteString) } ?? .null, "signedIn": .bool(signedIn ?? false),
            ])
        case "oauth.prepare":
            let server = FudgeSettings.load(from: paths.settingsFile).signIn
            let (provider, authorize) = try PreparedSignIn.provider(
                for: string("endpoint") ?? "", providerName: string("providerName") ?? "", server: server
            ).get()
            let loopback = try await OAuthLoopback.start()
            let request = PreparedSignIn(provider: provider, authorizeURL: authorize, redirectURI: loopback.redirectURI)
            // An earlier request this session never used stops listening. One the prompt shows isn't among them.
            signInRequests.prepare((request, loopback), for: session)?.close()
            // A request that's never used to sign in stops listening after 5 minutes.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(300))
                guard let self, self.signInRequests.expire(loopback, of: session) else { return }
                loopback.close()
            }
            return .object([
                "provider": .string(provider.id), "authorizeURL": .string(authorize),
                "redirectURI": .string(loopback.redirectURI),
            ])
        case "oauth.authorize":
            return .object([
                "authorizationCode": .string(try await authorizeSignIn(values, session: session, origin: origin))
            ])
        default:
            guard let calls = signInCalls(session) else { throw SignInRefusal.notPrepared }
            return try calls.answer(method, params)
        }
    }

    /// The token calls of `session`'s extension: the extension comes from the session, never from the call.
    private func signInCalls(_ session: String) -> SignInCalls? {
        guard let extensionName = sessionExtensions[session] else { return nil }
        return SignInCalls(
            store: OAuthTokenStore(secrets: tokenSecrets), extensionName: extensionName,
            pending: signInRequests.pending(of: session))
    }

    /// Signs in for `session`: shows "Sign in to <provider>", opens the browser on ↵, and waits up to 5 minutes for
    /// the loopback callback. Brings the launcher back to the command when the browser returns.
    private func authorizeSignIn(_ values: [String: JSONValue], session: String, origin: CallOrigin) async throws
        -> String
    {
        guard origin.mayComeForward else { throw SignInRefusal.background }
        guard signIn == nil else { throw SignInRefusal.busy }
        let url: String = if case .string(let url) = values["url"] { url } else { "" }
        guard let prepared = signInRequests.preparedRequest(of: session),
            let state = prepared.request.state(ofAuthorizeURL: url), let target = URL(string: url)
        else { throw SignInRefusal.notPrepared }
        // The prompt takes the request: Esc and the session ending reach its listener, whatever the session prepares
        // meanwhile.
        guard signInRequests.show(session) != nil else { throw SignInRefusal.busy }
        let loopback = prepared.listener
        func text(_ key: String) -> String? {
            if case .string(let value) = values[key], !value.isEmpty { value } else { nil }
        }
        signIn = SignInPrompt(
            session: session, providerName: text("providerName") ?? prepared.request.provider.name,
            description: text("description"), icon: values["providerIcon"].flatMap { $0 == .null ? nil : $0 })
        actionPanel = nil
        // Nothing reaches the command while the prompt is up, a key held for the selected item's actions included.
        hold(nil)
        // Nor does Pop to Root Search: the user is in the browser, and a reset would unload the command signing in.
        panelReset.hold(session)
        if !isVisible() { show() }
        let proceed = await withCheckedContinuation { signInAnswer = $0 }
        guard proceed, signIn?.session == session else {
            finishSignIn(loopback, signedIn: false)
            throw SignInRefusal.cancelled
        }
        guard openInBrowser(target) else {
            finishSignIn(loopback, signedIn: false)
            throw SignInRefusal.browser
        }
        signIn?.waiting = true
        let outcome = await loopback.wait(state: state, timeout: 300)
        let provider = signIn?.providerName ?? prepared.request.provider.name
        // Only a code keeps the provider pending, for the token exchange that follows.
        finishSignIn(loopback, signedIn: outcome.isCode)
        switch outcome {
        case .callback(.code(let code)):
            if !isVisible() { show() }
            return code
        case .callback(.error(let error, let description)):
            throw SignInRefusal.refused(provider: provider, error: error, description: description)
        case .timedOut:
            throw SignInRefusal.timedOut
        case .cancelled, .callback:
            throw SignInRefusal.cancelled
        }
    }

    /// ↵ continues in the browser and Esc cancels; while the prompt is up, nothing else reaches the command.
    private func handleSignInKey(_ pressed: KeyShortcut) -> Bool {
        if pressed == KeyShortcut(key: "escape", modifiers: []) {
            answerSignIn(false)
            return true
        }
        if pressed == KeyShortcut(key: "return", modifiers: []) || pressed == KeyShortcut(key: "enter", modifiers: []) {
            if signIn?.waiting == false { answerSignIn(true) }
            return true
        }
        return !pressed.modifiers.contains("cmd")
    }

    /// The prompt's ↵ (true) or Esc (false). Esc while the browser is open cancels the wait.
    func answerSignIn(_ proceed: Bool) {
        guard let prompt = signIn else { return }
        if let answer = signInAnswer {
            signInAnswer = nil
            answer.resume(returning: proceed)
        } else if !proceed, prompt.waiting {
            signInRequests.waitedOn?.cancel()
        }
    }

    /// The sign-in on `loopback` is over, with a code or without: its listener closes, and the prompt goes when it was
    /// the prompt's.
    private func finishSignIn(_ loopback: OAuthLoopback, signedIn: Bool) {
        let session = signInRequests.shown?.session
        if signInRequests.finish(loopback, signedIn: signedIn) {
            signIn = nil
            if let session { panelReset.release(session) }
        }
        loopback.close()
    }

    /// A session that exits takes its sign-in with it.
    private func endSignIn(of session: String) {
        let (unused, waitedOn) = signInRequests.end(session)
        unused?.close()
        guard let waitedOn else { return }
        if let answer = signInAnswer {
            signInAnswer = nil
            answer.resume(returning: false)
        }
        waitedOn.cancel()
    }

    // MARK: - Icons

    func icon(for item: RootItem) -> NSImage {
        if let cached = icons[item.id] { return cached }
        let image: NSImage
        switch item.kind {
        case .application(let url):
            image = NSWorkspace.shared.icon(forFile: url.path)
        case .settings:
            image = NSApp.applicationIconImage
        case .reloadExtensions, .quit, .createQuicklink, .searchSnippets, .createSnippet:
            image = NSImage(systemSymbolName: item.kind.symbol!, accessibilityDescription: nil)!
        case .builtInCommand(let group, let command):
            let symbol = BuiltInCommandGroup.command(group: group, command: command, in: builtInGroups)?.command
                .symbol
            image =
                symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
                ?? NSImage(systemSymbolName: "command", accessibilityDescription: nil)!
        case .quicklink(let quicklink):
            image = Self.quicklinkIcon(quicklink)
        case .command:
            image =
                item.iconFile.flatMap(NSImage.init(contentsOf:))
                ?? NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)!
        }
        icons[item.id] = image
        return image
    }

    /// The icon of the app that opens a quicklink: its `application`'s, else the default app for its scheme, else a
    /// path's own Finder icon. Nothing is fetched from a site.
    private static func quicklinkIcon(_ quicklink: Quicklink) -> NSImage {
        let workspace = NSWorkspace.shared
        if let application = quicklink.application,
            let url = workspace.urlForApplication(withBundleIdentifier: application)
        {
            return workspace.icon(forFile: url.path)
        }
        let template = QuicklinkTemplate(quicklink.link)
        if template.isPath {
            if case .text(let text) = template.segments.first, template.segments.count == 1 {
                let path = (text as NSString).expandingTildeInPath
                if FileManager.default.fileExists(atPath: path) { return workspace.icon(forFile: path) }
            }
            return workspace.icon(for: .folder)
        }
        if let scheme = template.scheme, let probe = URL(string: "\(scheme):"),
            let app = workspace.urlForApplication(toOpen: probe)
        {
            return workspace.icon(forFile: app.path)
        }
        return NSImage(systemSymbolName: "link", accessibilityDescription: nil)!
    }
}

extension LauncherModel.Failure {
    /// A sign-in notice (SPEC-095), drawn like the store's "off" notice: no trace, and nothing red.
    init(_ notice: SignInNotice, extensionName: String) {
        self.init(
            title: notice.title, message: notice.message,
            notice: Notice(extensionName: extensionName, actions: notice.actions, symbol: "person.badge.key"),
            commandTitle: notice.commandTitle)
    }
}
