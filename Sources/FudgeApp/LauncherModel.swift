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

        /// A notice is drawn like an empty view. Its actions take Back's place (↵ runs the first, ⌘K lists them),
        /// and ⌘⇧, opens `extensionName`'s settings.
        struct Notice: Equatable {
            var extensionName: String
            var actions: [ActionSection]
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
        /// The search changed and the command filters itself: select the first item of what it sends back.
        var selectFirstOnRender = false
        /// The search text as the user types it, reconciled with a `searchText` the extension sets.
        var searchField = FieldValue(.string(""))
        /// How many items the List had when it was last asked for the next page.
        var requestedMoreAt: Int?
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

    private(set) var screen: Screen = .root
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
    @ObservationIgnored var hide: () -> Void = {}
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
    /// Whether the launcher panel is on screen; set by the app delegate.
    @ObservationIgnored var isVisible: () -> Bool = { false }
    /// Asks the user to confirm (title, message, primary, dismiss, destructive); set by the app delegate.
    /// Asks the user, for a call from `origin`; a background call gets `CallOrigin.unaskedAnswer` without an alert.
    @ObservationIgnored var confirm: (AlertRequest, CallOrigin) async -> Bool = { _, _ in false }

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
    @ObservationIgnored private var nextSession = 1
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
        items = RootSearch.applying(settings, to: commands) + RootSearch.builtInItems + applications
        menuBar.update(installed: installedExtensions, settings: settings)
        refreshResults(keepingSelection: keepingSelection)
        refreshCommandHotkeys()
    }

    @ObservationIgnored private var installedExtensions: [InstalledExtension] = []
    @ObservationIgnored private var applications: [RootItem] = []
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
                command.searchText = newValue
                command.searchField.edit(.string(newValue))
                refreshList(&command, selectFirst: true)
                command.selectFirstOnRender = command.view.map { !ListContent.filtersLocally($0) } ?? false
                screen = .command(command)
                commandSearchChanged(command)
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

    /// What the calculator knows about exchange rates, from the app's `ExchangeRateUpdater`. A change redraws the
    /// card, so "Downloading exchange rates…" turns into the answer when the rates arrive.
    var currency: CurrencyState = .off {
        didSet {
            guard currency != oldValue, case .root = screen else { return }
            let wasSelected = selectedItem == Self.calculatorID
            calculator = evaluateCalculator()
            if calculator == nil, wasSelected { selectedItem = results.first?.id }
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

    /// The panel was just shown.
    func presented() {
        // A dropdown argument takes no typing: showing the panel goes back to the search field, keeping the values.
        if let index = arguments.focus, arguments.arguments.indices.contains(index),
            arguments.arguments[index].type == "dropdown"
        {
            arguments.focus = nil
        }
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

    /// The selected item of the running command's List.
    var selectedListItem: ListContent.Item? {
        guard let command, let items = command.list?.items else { return nil }
        return items.first { $0.id == command.selectedNode } ?? items.first
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
    /// same item where it can.
    private func refreshList(_ command: inout CommandScreen, selectFirst: Bool) {
        guard let view = command.view, ListContent.viewTypes.contains(view.type) else {
            command.list = nil
            command.dropdown = nil
            return
        }
        let previous = command.list?.items.first { $0.id == command.selectedNode }
        let list = ListContent(view, searchText: command.searchText)
        command.list = list
        let wanted = view.string("selectedItemId")
        if let wanted, wanted != command.followedItemId,
            let match = list.items.first(where: { $0.itemId == wanted })
        {
            command.selectedNode = match.id
            command.followedItemId = wanted
        } else if selectFirst {
            command.selectedNode = list.items.first?.id
        } else {
            command.selectedNode = list.reselect(node: command.selectedNode, itemId: previous?.itemId)
        }
        if wanted == nil { command.followedItemId = nil }
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

    /// Selects an item of the List (a click).
    func select(node: Int) {
        guard var command, command.list?.items.contains(where: { $0.id == node }) == true else { return }
        command.selectedNode = node
        screen = .command(command)
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

    /// Runs an action, or opens a submenu in the action panel.
    func run(_ entry: ActionEntry) {
        if let submenu = entry.submenu {
            var state = actionPanel ?? ActionPanelState()
            state.path.append(entry.id)
            state.query = ""
            state.selected = ActionPanelReader.flat(submenu).first?.id
            actionPanel = state
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
            return command.extensionName
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
        if datePanel != nil, handleDatePanelKey(pressed) { return true }
        if pressed == KeyShortcut(key: "k", modifiers: ["cmd"]) {
            toggleActionPanel()
            return true
        }
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
            if let secondaryAction { run(secondaryAction) }
            return true
        }
        if !hasSearchField, pressed == primaryKey {
            if let primaryAction { run(primaryAction) }
            return true
        }
        guard !pressed.modifiers.isEmpty else { return false }
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
    private func commandSearchChanged(_ command: CommandScreen) {
        searchDebounce?.cancel()
        guard let view = command.view, view.hasCallback("onSearchTextChange") else { return }
        let event = AppMessage.event(
            session: command.session, node: view.id, path: ["onSearchTextChange"], args: [.string(command.searchText)])
        guard view.bool("throttle") == true else {
            send(event)
            return
        }
        searchDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.send(event)
        }
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
        screen = .command(command)
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
            if case .command = item.kind, !arguments.checkRequired() { return }
            open(item)
            // The launch couldn't start (e.g. a required preference is unset). The values stay for the next try,
            // and the failure's search field gets the keyboard.
            if case .failure = screen { arguments.focus = nil }
        case .command:
            if let primaryAction { run(primaryAction) }
        case .failure:
            // A notice's first action, else back to root search.
            if let primaryAction { run(primaryAction) } else { screen = .root }
        }
    }

    /// Esc: close a DatePicker's calendar, the dropdown's panel or the action panel (a submenu at a time), pop a pushed view, clear the
    /// search, leave the command, then hide.
    func escape() {
        // The DatePicker's calendar is a popover too: it closes first, whatever Esc is set to do.
        if datePanel != nil {
            closeDatePanel()
            return
        }
        let state = EscapeAction.State(
            dropdownOpen: dropdownPanel != nil, actionPanelOpen: actionPanel != nil, screen: escapeScreen)
        switch EscapeAction.next(behavior: settings.escapeBehavior, state: state) {
        case .closeDropdown:
            closeDropdownPanel()
        case .closeActionPanel:
            guard var panel = actionPanel else { return }
            if panel.path.isEmpty {
                actionPanel = nil
            } else {
                panel.path.removeLast()
                panel.query = ""
                actionPanel = panel
                let first = ActionPanelReader.flat(actionPanelSections).first?.id
                actionPanel?.selected = first
            }
        case .popView:
            if case .command(let command) = screen { send(.pop(session: command.session)) }
        case .clearSearch:
            searchText = ""
        case .leaveCommand:
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

    /// The `FudgeSettings` ids ("<extension>/<command>") of the installed commands, enabled or not.
    var installedCommandIDs: [String] {
        installedExtensions.flatMap { RootItem.commands(of: $0, metadata: commandMetadata) }.compactMap { item in
            guard case .command(let extensionName, let commandName, _, _) = item.kind else { return nil }
            return FudgeSettings.commandID(extension: extensionName, command: commandName)
        }
    }

    /// A command's hotkey was pressed anywhere (`HotKeyLaunch`): open it as root search would, hide the panel if
    /// it's the view command already on screen, or show root search with its fields when a required argument is
    /// needed.
    func openFromHotkey(_ commandID: String) {
        guard let item = items.first(where: { $0.id == "command:\(commandID)" }),
            case .command(let extensionName, let commandName, let mode, _) = item.kind
        else { return }
        // The reset comes first, so the hotkey's target is built on top of it. A no-view command's hotkey resets
        // too while the panel is hidden: the panel's next show would reset it anyway, so this changes nothing.
        resettingFirst {
            let onScreen =
                isVisible() && command?.extensionName == extensionName && command?.commandName == commandName
            let action = HotKeyLaunch.action(
                mode: mode, hasRequiredArgument: item.arguments.contains { $0.required == true }, isOnScreen: onScreen)
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

    /// The hotkeys of installed commands, by root item id, for their rows.
    private(set) var commandHotkeys: [String: HotKeySpec] = [:]

    /// Reads the command hotkeys from `settings.json` again, after Settings changed them.
    func refreshCommandHotkeys() {
        commandHotkeys = Dictionary(
            uniqueKeysWithValues: settings.availableHotkeys(installed: Set(installedCommandIDs))
                .map { ("command:\($0.key)", $0.value) })
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
        case .command(let extensionName, let commandName, _, _):
            guard let installed = extensions[extensionName],
                let command = installed.manifest.commands.first(where: { $0.name == commandName })
            else {
                recordLaunch(item.id)
                screen = .failure(
                    Failure(title: "Can't run \(item.title)", message: "The extension is no longer installed."))
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
    private func recordLaunch(_ item: RootItem) {
        if item.recordsLaunch { recordLaunch(item.id) }
    }

    /// "Quit Fudge" asks first: its hotkeys stop working until Fudge is opened again.
    private static let quitRequest = AlertRequest(
        title: "Quit Fudge?",
        message: "Its hotkeys stop working until you open it again.",
        primary: "Quit",
        dismiss: "Cancel",
        destructive: false
    )

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
                message: "Set \(names) in the Settings window, then run the command again."
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
        let session = "s\(nextSession)"
        nextSession += 1
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
            sessionExtensions[session] = nil
            sessionCommands[session] = nil
            quietSessions[session] = nil
            if !quiet { screen = .failure(Failure(title: "Can't run \(title)", message: String(describing: error))) }
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
        let session = "s\(nextSession)"
        nextSession += 1
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
            sessionExtensions[session] = nil
            sessionCommands[session] = nil
            return .failure(.init(message: String(describing: error)))
        }
        return .success(session)
    }

    /// A failure toast in the bottom bar that no command showed.
    private func showFailureToast(_ title: String, message: String) {
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
        let host = try ExtensionHost(
            node: node, script: script,
            environment: ExtensionStore.hostEnvironment(
                cli: FileManager.default.isExecutableFile(atPath: cli.path) ? cli : nil, paths: paths))
        self.host = host
        Task { [weak self] in
            for await message in host.messages { self?.handle(message) }
            self?.hostStopped(host)
        }
        return host
    }

    private func send(_ message: AppMessage) {
        do {
            try host?.send(message)
        } catch {
            status = "Lost the extension host: \(error)"
        }
    }

    private func hostStopped(_ stopped: ExtensionHost) {
        guard host === stopped else { return }
        host = nil
        background.removeAll()
        quietSessions.removeAll()
        menuBar.hostStopped()
        if case .command(var command) = screen, command.failure == nil {
            command.failure = Failure(title: "\(command.title) stopped", message: "The extension host exited.")
            screen = .command(command)
        }
    }

    private func handle(_ message: HostMessage) {
        // A menu-bar command's tree, errors and exit belong to the menu bar; its rpcs and logs are answered here.
        if let session = message.session, menuBar.owns(session) {
            switch message {
            case .render, .eventSettled:
                menuBar.handle(message)
                return
            case .error(_, let text, let stack, _):
                menuBar.handle(message)
                log(session, "error", stack ?? text)
                return
            case .exit:
                sessionExtensions[session] = nil
                sessionCommands[session] = nil
                menuBar.handle(message)
                return
            case .rpc, .log, .pong, .protocolError, .unknown:
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
                command.searchField = FieldValue(.string(command.searchText))
                command.requestedMoreAt = nil
                actionPanel = nil
                dropdownPanel = nil
                datePanel = nil
            }
            command.view = view
            command.depth = depth
            // The extension can set the search text (`searchText`); echoes of what was typed don't undo typing.
            if let view, ListContent.viewTypes.contains(view.type), let controlled = view.string("searchText") {
                command.searchField.render(controlled: .string(controlled))
                if case .string(let text) = command.searchField.value, text != command.searchText {
                    command.searchText = text
                    command.selectFirstOnRender = true
                }
            }
            refreshList(&command, selectFirst: command.selectFirstOnRender)
            // Results for a new search may come after a loading render or two.
            if command.list?.isLoading != true { command.selectFirstOnRender = false }
            refreshForm(&command)
            screen = .command(command)
            syncDropdownPanel()
            syncDatePanel()
            reportSelection()

        case .error(let session, let message, let stack, let fatal):
            if var quiet = quietSessions[session] {
                // A background launch: the panel stays as it is, and the failure shows in the HUD, once.
                let alreadySaid = quiet.unasked.contains { message.contains($0) }
                if !quiet.failed, !alreadySaid { showHUD("\(quiet.title) failed — \(message)") }
                quiet.failed = true
                quietSessions[session] = quiet
            } else if case .command(var command) = screen, command.session == session {
                if fatal {
                    command.failure = Failure(title: "\(command.title) failed", message: message, details: stack)
                    screen = .command(command)
                } else {
                    status = "Error: \(message)"
                }
            } else if let title = background[session] {
                screen = .failure(Failure(title: "\(title) failed", message: message, details: stack))
            }
            log(session, "error", stack ?? message)

        case .exit(let session, let reason):
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
                    screen = .failure(Failure(title: "\(title) failed", message: "The command stopped unexpectedly."))
                }
            } else if case .command(var command) = screen, command.session == session, reason != "unloaded" {
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
            case "form.storeValues":
                storeFormValues(params, session: session)
                send(.rpcResult(session: session, id: id, result: .null, error: nil))
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

    // MARK: - Icons

    func icon(for item: RootItem) -> NSImage {
        if let cached = icons[item.id] { return cached }
        let image: NSImage
        switch item.kind {
        case .application(let url):
            image = NSWorkspace.shared.icon(forFile: url.path)
        case .settings:
            image = NSApp.applicationIconImage
        case .reloadExtensions:
            image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)!
        case .quit:
            image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)!
        case .command:
            image =
                item.iconFile.flatMap(NSImage.init(contentsOf:))
                ?? NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)!
        }
        icons[item.id] = image
        return image
    }
}
