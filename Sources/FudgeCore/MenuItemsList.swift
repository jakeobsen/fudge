import Foundation

/// Fudge's own Search Menu Items view (FUD-121): a List built here as an extension's would arrive, so the launcher
/// draws it, filters it and takes its keys like any other. As with Search Snippets, it never reaches the extension
/// host: its session is Fudge's (`session`), and the launcher answers its actions itself. Its rows are known by their
/// place in the read they come from: an item's `id` prop and its nodes' ids are positions, never anything about a
/// menu item.
public enum MenuItemsList {
    public static let session = "fudge:menu-items"
    public static let title = "Search Menu Items"
    /// Its name in the Apps group (`:apps/search-menu-items`).
    public static let commandName = "search-menu-items"
    public static let placeholder = "Search menu items"
    /// The bottom bar's line when the read missed some menus.
    public static let incomplete = "Some menus didn't load"
    /// The toast when the item can't be found again.
    public static let gone = "That menu item isn't there anymore."
    public static let turnedOff = "That menu item is turned off right now."

    /// One menu item's row.
    public struct Row: Sendable, Equatable {
        public var title: String
        /// The menus above it as the list shows them, the app's own menu by the app's name.
        public var path: [String]
        /// Its shortcut's keycaps (`MenuShortcut.keycaps`); empty when it has none.
        public var keycaps: [String]

        public init(title: String, path: [String], keycaps: [String] = []) {
            self.title = title
            self.path = path
            self.keycaps = keycaps
        }

        /// The row of an item a read found in `app`'s menus.
        init<Handle>(_ item: FoundMenuItem<Handle>, appName: String) {
            var path = item.path
            if item.inAppMenu, !path.isEmpty { path[0] = appName }
            self.init(title: item.title, path: path, keycaps: item.shortcut?.keycaps ?? [])
        }

        /// The subtitle: the menus above it, each followed by ›.
        public var subtitle: String {
            path.map { $0 + " ›" }.joined(separator: " ")
        }
    }

    /// What one of its actions does.
    public enum Target: Sendable, Equatable {
        /// ↵: runs the row's menu item.
        case run(row: Int)
        /// The Accessibility view's ↵: the Accessibility pane.
        case openAccessibilitySettings
        /// The no-answer view's ↵: reads the menus again.
        case tryAgain
    }

    /// Its nodes' ids. Each row's nodes are a block of `stride` from `firstItem`, in the order shown.
    enum Node {
        static let list = 1
        static let empty = 2
        static let emptyActions = 3
        static let openSettings = 4
        static let tryAgain = 5
        static let firstItem = 100
        static let stride = 4
        // Offsets inside a row's block.
        static let item = 0
        static let actions = 1
        static let run = 2
    }

    /// The List: one item per row, in menu order. Raycast's own filtering applies, so search matches the title and,
    /// as a keyword, the path with the title. When the read missed some menus, the bottom bar says so in place of
    /// the title.
    public static func view(rows: [Row], app: MenuTarget, complete: Bool) -> UINode {
        var children = rows.enumerated().map { index, row in item(row, index: index, app: app) }
        children.append(
            empty(
                title: "No Menu Items", description: "\(app.name) has no menu items to run right now.",
                icon: "app-window-list-16"))
        return list(navigationTitle: complete ? title : incomplete, children: children)
    }

    /// The List while the menus are being read.
    public static func loading() -> UINode {
        list(navigationTitle: title, isLoading: true, children: [])
    }

    /// Without Accessibility permission, the List is empty and says so, with Open Accessibility Settings on ↵.
    public static func accessibilityNeeded() -> UINode {
        let open = UINode(
            id: Node.openSettings, type: "Action",
            props: ["title": .string(AccessibilitySettingsAlert.openButton), "icon": .string("cog-16")])
        return list(
            navigationTitle: title,
            children: [
                empty(
                    title: AccessibilitySettingsAlert.title,
                    description:
                        "Search Menu Items needs Accessibility permission to read an app's menus. Turn Fudge on in "
                        + "System Settings → Privacy & Security → Accessibility.",
                    icon: "lock-16", actions: [open])
            ])
    }

    /// When Fudge itself was in front: there's no other app's menus to search.
    public static func noApp() -> UINode {
        list(
            navigationTitle: title,
            children: [
                empty(
                    title: "No App to Search",
                    description: "Open Search Menu Items from another app to search its menus.",
                    icon: "app-window-list-16")
            ])
    }

    /// When the app's menu bar didn't answer in time, with Try Again on ↵.
    public static func noAnswer(app: MenuTarget) -> UINode {
        let again = UINode(
            id: Node.tryAgain, type: "Action",
            props: ["title": .string("Try Again"), "icon": .string("arrow-clockwise-16")])
        return list(
            navigationTitle: title,
            children: [
                empty(
                    title: "\(app.name) Didn't Answer", description: "Its menus couldn't be read. Try again.",
                    icon: "warning-16", actions: [again])
            ])
    }

    /// What the action `node` does in a view of `rows` rows; nil for any other node.
    public static func target(of node: Int, rows: Int) -> Target? {
        if node == Node.openSettings { return .openAccessibilitySettings }
        if node == Node.tryAgain { return .tryAgain }
        guard node >= Node.firstItem else { return nil }
        let row = (node - Node.firstItem) / Node.stride
        guard row < rows, (node - Node.firstItem) % Node.stride == Node.run else { return nil }
        return .run(row: row)
    }

    /// The node id of the row at `index`, as the list selects it.
    public static func itemNode(_ index: Int) -> Int {
        Node.firstItem + index * Node.stride + Node.item
    }

    /// The place of the row at `index` in `old` among `new`, for keeping the selection on it when the menus are read
    /// again: the first row there that's the same, else nil.
    public static func place(of index: Int, in old: [Row], among new: [Row]) -> Int? {
        guard old.indices.contains(index) else { return nil }
        return new.firstIndex(of: old[index])
    }

    private static func list(navigationTitle: String, isLoading: Bool = false, children: [UINode]) -> UINode {
        UINode(
            id: Node.list, type: "List",
            props: [
                "navigationTitle": .string(navigationTitle), "searchBarPlaceholder": .string(placeholder),
                "isLoading": .bool(isLoading),
            ],
            children: children)
    }

    private static func empty(title: String, description: String, icon: String, actions: [UINode] = []) -> UINode {
        var props: [String: JSONValue] = [
            "title": .string(title), "description": .string(description), "icon": .string(icon),
        ]
        if !actions.isEmpty {
            props["actions"] = UINode(id: Node.emptyActions, type: "ActionPanel", children: actions).json
        }
        return UINode(id: Node.empty, type: "List.EmptyView", props: props)
    }

    private static func item(_ row: Row, index: Int, app: MenuTarget) -> UINode {
        let base = Node.firstItem + index * Node.stride
        let run = UINode(
            id: base + Node.run, type: "Action",
            props: ["title": .string("Run Menu Item"), "icon": .string("play-16")])
        var props: [String: JSONValue] = [
            // Its place, never its title: titles stay out of anything that identifies a row.
            "id": .string(String(index)),
            "title": .string(row.title), "subtitle": .string(row.subtitle),
            "keywords": .array([.string((row.path + [row.title]).joined(separator: " › "))]),
            "icon": app.path.map { .object(["fileIcon": .string($0)]) } ?? .string("app-window-list-16"),
            "actions": UINode(id: base + Node.actions, type: "ActionPanel", children: [run]).json,
        ]
        if !row.keycaps.isEmpty {
            props["accessories"] = .array([.object(["keycaps": .array(row.keycaps.map(JSONValue.string))])])
        }
        return UINode(id: base + Node.item, type: "List.Item", props: props)
    }
}

/// One read of an app's menus, as Search Menu Items lists it: the rows in menu order, and each row's item, found
/// again when it's run. It lives in memory only (the launcher's, and `MenuItemsCache`).
public final class MenuItemsListing: @unchecked Sendable {
    public let rows: [MenuItemsList.Row]
    /// False when the read stopped at its deadline or some menus didn't answer, so items may be missing.
    public let complete: Bool
    private let find: (Int, Int32) -> MenuItemFound

    init(rows: [MenuItemsList.Row], complete: Bool, find: @escaping (Int, Int32) -> MenuItemFound) {
        self.rows = rows
        self.complete = complete
        self.find = find
    }

    /// The menu item of the row at `row`, now, in the app running as `pid` (`MenuReader.current`): the one read, else
    /// found again by its whole path, once. Blocks: call it off the main thread.
    public func item(row: Int, in pid: Int32) -> MenuItemFound {
        guard rows.indices.contains(row) else { return .gone }
        return find(row, pid)
    }
}

/// A menu item found to run, or why it wasn't.
public enum MenuItemFound: Sendable {
    case found(MenuItemPress)
    /// It's there, but turned off now.
    case disabled
    case gone
    case noAnswer
}

/// Presses one menu item (`kAXPressAction`). Blocks: call it off the main thread.
public struct MenuItemPress: @unchecked Sendable {
    private let action: () -> MenuPress

    init(_ action: @escaping () -> MenuPress) {
        self.action = action
    }

    public func callAsFunction() -> MenuPress { action() }
}

/// Running a row's menu item: find it, then press it only if the list it was run from is still the one on screen.
/// Finding can wait on a busy app for seconds, and by then the user may have dismissed the panel and gone to another
/// app, where pressing would bring the old one back and run what they gave up on.
public enum MenuItemRun {
    /// What a run came to.
    public enum Outcome: Sendable, Equatable {
        /// The item was pressed; `MenuPress` says how the app answered.
        case pressed(MenuPress)
        /// The item is turned off now, so it wasn't pressed.
        case disabled
        /// The item isn't there anymore.
        case gone
        /// The app didn't answer while the item was being found.
        case noAnswer
        /// The list was dismissed, or replaced, while the item was being found: nothing was done.
        case dismissed
    }

    /// Finds the item (`find`, which waits on the app off the main thread), then, only while `isCurrent` still says
    /// the list is the one the run started from: hides the panel, makes the app active and presses the item.
    /// Otherwise nothing is hidden, activated or pressed, and nothing is said.
    @MainActor
    public static func run(
        find: () async -> MenuItemFound, isCurrent: () -> Bool, hide: () async -> Void, activate: () async -> Void,
        press: (MenuItemPress) async -> MenuPress
    ) async -> Outcome {
        let found = await find()
        guard isCurrent() else { return .dismissed }
        switch found {
        case .found(let item):
            await hide()
            await activate()
            return .pressed(await press(item))
        case .disabled:
            return .disabled
        case .gone:
            return .gone
        case .noAnswer:
            return .noAnswer
        }
    }
}

/// Counts the lifetimes of the list on screen: hiding the panel or leaving the list starts a new one, so a run begun
/// in an older one is no longer current (`MenuItemRun`).
public struct MenuItemsGeneration: Sendable, Equatable {
    public private(set) var value = 0

    public init() {}

    /// The panel hid, or the list went.
    public mutating func dismissed() { value += 1 }
}

/// What reading an app's menus for the list gave.
public enum MenuItemsRead: Sendable {
    case listing(MenuItemsListing)
    /// The app's menu bar didn't answer in time.
    case noAnswer
}

/// What Search Menu Items reads menus through: the system's, or a snapshot run's made-up ones.
public protocol MenuItemsSource: Sendable {
    /// Reads `target`'s menus, giving what was read by `deadline`. `cancel` stops it when its list goes. A read of the
    /// same app that was cancelled is waited for, up to `deadline`, rather than answered as busy. Blocks: call it off
    /// the main thread.
    func read(_ target: MenuTarget, deadline: Duration, cancel: MenuReadCancel) -> MenuItemsRead
}

/// Search Menu Items over a `MenuSystem`.
public struct MenuItemsSearch<System: MenuSystem>: MenuItemsSource {
    public let reader: MenuReader<System>

    public init(reader: MenuReader<System>) {
        self.reader = reader
    }

    public func read(
        _ target: MenuTarget, deadline: Duration = .milliseconds(1500), cancel: MenuReadCancel = MenuReadCancel()
    ) -> MenuItemsRead {
        let walk = reader.start(target.pid, cancel: cancel, waitingForCancelledUpTo: deadline)
        guard case .items(let items, let complete) = walk.finish(within: deadline) else { return .noAnswer }
        let reader = reader
        let listing = MenuItemsListing(
            rows: items.map { MenuItemsList.Row($0, appName: target.name) }, complete: complete
        ) { row, pid in
            switch reader.current(items[row], place: items[row].place, count: items[row].count, in: pid) {
            case .ready(let handle): .found(MenuItemPress { reader.system.press(handle) })
            case .disabled: .disabled
            case .gone: .gone
            case .noAnswer: .noAnswer
            }
        }
        return .listing(listing)
    }
}

extension BuiltInCommandGroup {
    /// Apps: commands about the app the user was in. Search Menu Items (`MenuItemsList`).
    public static let apps = BuiltInCommandGroup(
        name: ":apps", title: "Apps",
        commands: [
            BuiltInCommand(
                name: MenuItemsList.commandName, title: MenuItemsList.title,
                keywords: ["menu", "menus", "menu bar", "commands"], symbol: "filemenu.and.selection")
        ])
}
