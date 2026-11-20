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
    }

    /// A running view command.
    struct CommandScreen: Equatable {
        var session: String
        var title: String
        var view: UINode?
        var depth = 1
        var searchText = ""
        var selectedNode: Int?
        var failure: Failure?
    }

    enum Screen: Equatable {
        case root
        case command(CommandScreen)
        case failure(Failure)
    }

    private(set) var screen: Screen = .root
    private(set) var results: [RootItem] = []
    var selectedItem: String?
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
    /// Opens the Settings window on an extension's preferences; set by the app delegate.
    @ObservationIgnored var openSettings: (String) -> Void = { _ in }
    /// Shows a HUD message; set by the app delegate.
    @ObservationIgnored var showHUD: (String) -> Void = { _ in }
    /// Whether the launcher panel is on screen; set by the app delegate.
    @ObservationIgnored var isVisible: () -> Bool = { false }
    /// Asks the user to confirm (title, message, primary, dismiss, destructive); set by the app delegate.
    @ObservationIgnored var confirm: (AlertRequest) async -> Bool = { _ in false }

    struct AlertRequest {
        var title: String
        var message: String?
        var primary: String
        var dismiss: String
        var destructive: Bool
    }

    @ObservationIgnored private let paths: FudgePaths
    @ObservationIgnored private var items: [RootItem] = []
    @ObservationIgnored private var extensions: [String: InstalledExtension] = [:]
    @ObservationIgnored private var history: LaunchHistory
    @ObservationIgnored private var host: ExtensionHost?
    @ObservationIgnored private var nextSession = 1
    /// No-view commands still running, by session.
    @ObservationIgnored private var background: [String: String] = [:]
    /// The extension each session belongs to.
    @ObservationIgnored private var sessionExtensions: [String: String] = [:]
    @ObservationIgnored private var icons: [String: NSImage] = [:]

    init(paths: FudgePaths) {
        self.paths = paths
        history = LaunchHistory.load(from: paths.historyFile)
        reload()
    }

    /// Finds applications and installed extensions again.
    func reload() {
        let installed = InstalledExtension.all(in: paths.extensionsDirectory)
        extensions = Dictionary(installed.map { ($0.manifest.name, $0) }, uniquingKeysWith: { first, _ in first })
        items = installed.flatMap(RootItem.commands(of:)) + ApplicationIndex.scan()
        refreshResults()
    }

    // MARK: - Search

    /// The search field: the root query, or the running command's search text.
    var searchText: String {
        get {
            if case .command(let command) = screen { return command.searchText }
            return rootQuery
        }
        set {
            switch screen {
            case .command(var command):
                command.searchText = newValue
                screen = .command(command)
                commandSearchChanged(command)
            case .root, .failure:
                rootQuery = newValue
                if case .failure = screen { screen = .root }
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

    private func refreshResults() {
        results = RootSearch.rank(items, query: rootQuery, history: history)
        selectedItem = results.first?.id
    }

    // MARK: - Command views

    /// The rows of the running command's List, after filtering.
    var commandItems: [UINode] {
        guard case .command(let command) = screen, let view = command.view, view.type == "List" else { return [] }
        let all = Self.listItems(in: view)
        guard Self.filtersLocally(view), !command.searchText.isEmpty else { return all }
        return all.filter { item in
            let texts =
                [item.string("title"), item.string("subtitle")].compactMap { $0 }
                + Self.keywords(of: item)
            return texts.contains { Fuzzy.match(command.searchText, in: $0) != nil }
        }
    }

    static func listItems(in view: UINode) -> [UINode] {
        view.children.flatMap { child in child.type == "List.Section" ? child.children : [child] }
            .filter { $0.type == "List.Item" }
    }

    /// Raycast filters a List itself unless the command handles search (onSearchTextChange) or says not to.
    static func filtersLocally(_ view: UINode) -> Bool {
        if let filtering = view.bool("filtering") { return filtering }
        return !view.hasCallback("onSearchTextChange")
    }

    static func keywords(of item: UINode) -> [String] {
        guard case .array(let values) = item.props["keywords"] else { return [] }
        return values.compactMap { if case .string(let keyword) = $0 { keyword } else { nil } }
    }

    /// The actions for what's selected: the selected row's, else the view's own.
    var currentActions: [ActionSection] {
        guard case .command(let command) = screen, let view = command.view else { return [] }
        let row = commandItems.first { $0.id == command.selectedNode } ?? commandItems.first
        return ActionPanelReader.sections(of: row?.node("actions") ?? view.node("actions"))
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
            guard actionPanel != nil else { return }
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
        guard case .command(let command) = screen else { return }
        if let submenu = entry.submenu {
            var state = actionPanel ?? ActionPanelState()
            state.path.append(entry.id)
            state.query = ""
            state.selected = ActionPanelReader.flat(submenu).first?.id
            actionPanel = state
            return
        }
        actionPanel = nil
        send(.event(session: command.session, node: entry.id, path: ["onAction"], args: []))
    }

    /// Keys that the launcher handles itself: ⌘K, ⌘↵ and the actions' shortcuts.
    /// Returns false for everything else, which then goes to the focused field.
    func handleKey(_ pressed: KeyShortcut) -> Bool {
        if pressed == KeyShortcut(key: "k", modifiers: ["cmd"]) {
            toggleActionPanel()
            return true
        }
        guard actionPanel == nil, case .command = screen else { return false }
        if pressed == KeyShortcut(key: "return", modifiers: ["cmd"]) {
            if let secondaryAction { run(secondaryAction) }
            return true
        }
        guard !pressed.modifiers.isEmpty, let entry = ActionPanelReader.action(for: pressed, in: currentActions) else {
            return false
        }
        run(entry)
        return true
    }

    private func commandSearchChanged(_ command: CommandScreen) {
        guard let view = command.view else { return }
        if view.hasCallback("onSearchTextChange") {
            send(
                .event(
                    session: command.session, node: view.id, path: ["onSearchTextChange"],
                    args: [.string(command.searchText)]))
        }
        if case .command(var updated) = screen {
            updated.selectedNode = commandItems.first?.id
            screen = .command(updated)
        }
    }

    // MARK: - Keys

    func moveSelection(by offset: Int) {
        switch screen {
        case .root:
            guard !results.isEmpty else { return }
            let index = results.firstIndex { $0.id == selectedItem } ?? 0
            selectedItem = results[max(0, min(results.count - 1, index + offset))].id
        case .command(var command):
            let rows = commandItems
            guard !rows.isEmpty else { return }
            let index = rows.firstIndex { $0.id == command.selectedNode } ?? 0
            command.selectedNode = rows[max(0, min(rows.count - 1, index + offset))].id
            screen = .command(command)
        case .failure:
            break
        }
    }

    /// ↵: open the selected item, or run the selected row's first action.
    func activate() {
        switch screen {
        case .root:
            if let item = results.first(where: { $0.id == selectedItem }) { open(item) }
        case .command:
            if let primaryAction { run(primaryAction) }
        case .failure:
            screen = .root
        }
    }

    /// Esc: close the action panel (a submenu at a time), pop a pushed view, clear the search,
    /// leave the command, then hide.
    func escape() {
        if var panel = actionPanel {
            if panel.path.isEmpty {
                actionPanel = nil
            } else {
                panel.path.removeLast()
                panel.query = ""
                actionPanel = panel
                let first = ActionPanelReader.flat(actionPanelSections).first?.id
                actionPanel?.selected = first
            }
            return
        }
        switch screen {
        case .root:
            if rootQuery.isEmpty { hide() } else { searchText = "" }
        case .failure:
            screen = .root
        case .command(let command):
            if command.failure == nil, command.depth > 1 {
                send(.pop(session: command.session))
            } else if command.failure == nil, !command.searchText.isEmpty {
                searchText = ""
            } else {
                leaveCommand()
            }
        }
    }

    // MARK: - Opening

    func open(_ item: RootItem) {
        history.record(item.id)
        try? history.save(to: paths.historyFile)
        switch item.kind {
        case .application(let url):
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            searchText = ""
            hide()
        case .command(let extensionName, let commandName, let mode, let entry):
            guard let installed = extensions[extensionName],
                let command = installed.manifest.commands.first(where: { $0.name == commandName })
            else {
                screen = .failure(
                    Failure(title: "Can't run \(item.title)", message: "The extension is no longer installed."))
                return
            }
            let preferences = PreferenceResolver.resolve(
                installed.manifest,
                command: command,
                stored: PreferenceStore(directory: paths.preferencesDirectory).load(extensionName)
            )
            guard preferences.missing.isEmpty else {
                let names = preferences.missing.map { $0.title ?? $0.name }.joined(separator: ", ")
                screen = .failure(
                    Failure(
                        title: "\(item.title) needs settings",
                        message: "Set \(names) in the Settings window, then run the command again."
                    )
                )
                openSettings(extensionName)
                return
            }
            let environment = LaunchEnvironment.make(
                for: installed,
                command: command,
                paths: paths,
                appearance: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? "dark" : "light"
            )
            launch(
                item.title,
                of: extensionName,
                entry: entry,
                mode: mode,
                preferences: preferences.values,
                environment: environment
            )
        }
    }

    private func launch(
        _ title: String,
        of extensionName: String,
        entry: URL,
        mode: String,
        preferences: [String: JSONValue],
        environment: LaunchEnvironment
    ) {
        let host: ExtensionHost
        do {
            host = try ensureHost()
        } catch {
            screen = .failure(Failure(title: "Can't run extensions", message: String(describing: error)))
            return
        }
        let session = "s\(nextSession)"
        nextSession += 1
        sessionExtensions[session] = extensionName
        if mode == "view" {
            screen = .command(CommandScreen(session: session, title: title))
        } else {
            background[session] = title
            status = "Running \(title)…"
        }
        do {
            try host.send(
                .launch(
                    session: session, entry: entry.path, mode: mode, launchProps: LaunchProps(),
                    preferences: preferences, environment: environment)
            )
        } catch {
            screen = .failure(Failure(title: "Can't run \(title)", message: String(describing: error)))
        }
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
                    "fudge needs Node.js 22.18 or later. Install it with `brew install node`, or set FUDGE_NODE."
            )
        }
        guard let script = Runtime.locateHostScript() else {
            throw HostUnavailable(
                description: "The extension host is missing from Fudge.app. Rebuild it with `make app`.")
        }
        let host = try ExtensionHost(node: node, script: script)
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
        if case .command(var command) = screen, command.failure == nil {
            command.failure = Failure(title: "\(command.title) stopped", message: "The extension host exited.")
            screen = .command(command)
        }
    }

    private func handle(_ message: HostMessage) {
        switch message {
        case .render(let session, let view, let depth):
            guard case .command(var command) = screen, command.session == session else { return }
            command.view = view
            command.depth = depth
            screen = .command(command)
            if case .command(var updated) = screen, !commandItems.contains(where: { $0.id == updated.selectedNode }) {
                updated.selectedNode = commandItems.first?.id
                screen = .command(updated)
            }

        case .error(let session, let message, let stack, let fatal):
            if case .command(var command) = screen, command.session == session {
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
            if let title = background.removeValue(forKey: session) {
                status = nil
                if reason == "finished", case .root = screen {
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
                if let extensionName = sessionExtensions[session] { openSettings(extensionName) }
                send(.rpcResult(session: session, id: id, result: .null, error: nil))
            case "toast.show", "toast.hide", "hud.show", "window.close", "window.popToRoot", "searchBar.clear":
                windowCall(method, params, session: session)
                send(.rpcResult(session: session, id: id, result: .null, error: nil))
            case "alert.confirm":
                Task {
                    let confirmed = await confirm(Self.alertRequest(params))
                    send(.rpcResult(session: session, id: id, result: .bool(confirmed), error: nil))
                }
            default:
                Task {
                    do {
                        let result = try await SystemCalls.handle(method, params)
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

        case .pong, .unknown:
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
    }

    /// Unloads the visible command, if any, and shows root search.
    private func leaveCommand() {
        actionPanel = nil
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
        case .command:
            image =
                item.iconFile.flatMap(NSImage.init(contentsOf:))
                ?? NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)!
        }
        icons[item.id] = image
        return image
    }
}
