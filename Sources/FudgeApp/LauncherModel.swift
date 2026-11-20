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
    private var rootQuery = ""

    /// Hides the panel; set by the app delegate.
    @ObservationIgnored var hide: () -> Void = {}
    /// Opens the Settings window on an extension's preferences; set by the app delegate.
    @ObservationIgnored var openSettings: (String) -> Void = { _ in }

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

    /// The first action of the selected row (or of the view itself): what ↵ does.
    var primaryAction: UINode? {
        guard case .command(let command) = screen, let view = command.view else { return nil }
        let row = commandItems.first { $0.id == command.selectedNode } ?? commandItems.first
        let panel = row?.node("actions") ?? view.node("actions")
        return panel?.first { $0.type == "Action" && $0.hasCallback("onAction") }
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
        case .command(let command):
            if let action = primaryAction {
                send(.event(session: command.session, node: action.id, path: ["onAction"], args: []))
            }
        case .failure:
            screen = .root
        }
    }

    /// Esc: pop a pushed view, clear the search, leave the command, then hide.
    func escape() {
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
                send(.unload(session: command.session))
                screen = .root
                status = nil
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
            launch(item.title, of: extensionName, entry: entry, mode: mode, preferences: preferences.values)
        }
    }

    private func launch(
        _ title: String,
        of extensionName: String,
        entry: URL,
        mode: String,
        preferences: [String: JSONValue]
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
                    preferences: preferences)
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

        case .rpc(let session, let id, let method, _):
            switch method {
            case "preferences.openExtension", "preferences.openCommand":
                if let extensionName = sessionExtensions[session] { openSettings(extensionName) }
                send(.rpcResult(session: session, id: id, result: .null, error: nil))
            default:
                // The other APIs that call into the app arrive with later work; until then, fail clearly.
                send(.rpcResult(session: session, id: id, result: nil, error: "\(method) isn't available in fudge yet"))
            }

        case .log(let session, let level, let message):
            log(session, level, message)

        case .protocolError(let message):
            log("host", "error", message)

        case .pong, .unknown:
            break
        }
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
