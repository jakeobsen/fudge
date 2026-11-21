import Foundation

/// Fudge's own Switch Windows view (FUD-120): a List built here as an extension's would arrive, so the launcher draws
/// it, filters it and takes its keys like any other. As with Search Snippets, it never reaches the extension host:
/// its session is Fudge's (`session`), and the launcher answers its actions itself. Its rows are known by their place
/// in the read they come from: an item's `id` prop and its nodes' ids are positions, never anything about a window.
public enum SwitchWindowsList {
    public static let session = "fudge:switch-windows"
    public static let title = "Switch Windows"
    /// Its name in the Window Management group (`:window-management/switch-windows`).
    public static let commandName = "switch-windows"
    /// A minimized window's accessory.
    public static let minimized = "Minimized"
    public static let placeholder = "Search windows"

    /// One window's row: the window's title, or its app's name when it has none; the app's name; and its accessory.
    public struct Row: Sendable, Equatable {
        public var title: String
        public var appName: String
        /// The app's bundle, whose icon the row shows.
        public var appPath: String?
        /// "Minimized", the screen's name when there are several, or nil.
        public var accessory: String?

        public init(title: String, appName: String, appPath: String? = nil, accessory: String? = nil) {
            self.title = title
            self.appName = appName
            self.appPath = appPath
            self.accessory = accessory
        }
    }

    /// What one of its actions does, by the row's place in the read.
    public enum Target: Sendable, Equatable {
        /// ↵: un-minimizes, raises and activates the window.
        case switchTo(row: Int)
        /// ⌃X: presses its close button.
        case close(row: Int)
        /// ⌃⌥X: quits its app, after asking.
        case quit(row: Int)
        /// The Accessibility view's ↵: the Accessibility pane.
        case openAccessibilitySettings
    }

    public static let closeShortcut = KeyShortcut(key: "x", modifiers: ["ctrl"])
    public static let quitShortcut = KeyShortcut(key: "x", modifiers: ["ctrl", "opt"])

    /// Its nodes' ids. Each row's nodes are a block of `stride` from `firstItem`, in the order shown.
    enum Node {
        static let list = 1
        static let empty = 2
        static let emptyActions = 3
        static let openSettings = 4
        static let firstItem = 100
        static let stride = 10
        // Offsets inside a row's block.
        static let item = 0
        static let actions = 1
        static let switchSection = 2
        static let switchTo = 3
        static let manageSection = 4
        static let close = 5
        static let quit = 6
    }

    /// The List: one item per row, in the read's order. Raycast's own filtering applies, so search matches the
    /// title and, as a keyword, the app's name. With apps that didn't answer, the bottom bar names them in place of
    /// the title (`footer`).
    public static func view(rows: [Row], silentApps: [String]) -> UINode {
        var children = rows.enumerated().map { index, row in item(row, index: index) }
        children.append(
            UINode(
                id: Node.empty, type: "List.EmptyView",
                props: [
                    "title": .string("No Windows"), "description": .string("Your apps' open windows show here."),
                    "icon": .string("app-window-16"),
                ]))
        return list(navigationTitle: footer(silentApps: silentApps) ?? title, children: children)
    }

    /// The List while the windows are being read.
    public static func loading() -> UINode {
        list(navigationTitle: title, isLoading: true, children: [])
    }

    /// Without Accessibility permission, the List is empty and says so, with Open Accessibility Settings on ↵.
    public static func accessibilityNeeded() -> UINode {
        let open = UINode(
            id: Node.openSettings, type: "Action",
            props: ["title": .string(AccessibilitySettingsAlert.openButton), "icon": .string("cog-16")])
        let empty = UINode(
            id: Node.empty, type: "List.EmptyView",
            props: [
                "title": .string(AccessibilitySettingsAlert.title),
                "description": .string(
                    "Switch Windows needs Accessibility permission to list your windows. Turn Fudge on in System "
                        + "Settings → Privacy & Security → Accessibility."),
                "icon": .string("lock-16"),
                "actions": UINode(id: Node.emptyActions, type: "ActionPanel", children: [open]).json,
            ])
        return list(navigationTitle: title, children: [empty])
    }

    /// The bottom bar's line naming the apps that didn't answer in time; nil when they all did.
    public static func footer(silentApps: [String]) -> String? {
        silentApps.isEmpty ? nil : "Some apps didn't answer: " + silentApps.joined(separator: ", ")
    }

    /// What the action `node` does in a view of `rows` rows; nil for any other node.
    public static func target(of node: Int, rows: Int) -> Target? {
        if node == Node.openSettings { return .openAccessibilitySettings }
        guard node >= Node.firstItem else { return nil }
        let row = (node - Node.firstItem) / Node.stride
        guard row < rows else { return nil }
        switch (node - Node.firstItem) % Node.stride {
        case Node.switchTo: return .switchTo(row: row)
        case Node.close: return .close(row: row)
        case Node.quit: return .quit(row: row)
        default: return nil
        }
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

    private static func item(_ row: Row, index: Int) -> UINode {
        let base = Node.firstItem + index * Node.stride
        let actions = UINode(
            id: base + Node.actions, type: "ActionPanel",
            children: [
                UINode(
                    id: base + Node.switchSection, type: "ActionPanel.Section",
                    children: [action(base + Node.switchTo, "Switch to Window", icon: "app-window-16", shortcut: nil)]),
                UINode(
                    id: base + Node.manageSection, type: "ActionPanel.Section",
                    children: [
                        action(base + Node.close, "Close Window", icon: "x-mark-circle-16", shortcut: closeShortcut),
                        action(
                            base + Node.quit, "Quit App", icon: "power-16", shortcut: quitShortcut, destructive: true),
                    ]),
            ])
        var props: [String: JSONValue] = [
            // Its place, never its title: titles stay out of anything that identifies a row.
            "id": .string(String(index)),
            "title": .string(row.title), "subtitle": .string(row.appName),
            "keywords": .array([.string(row.appName)]),
            "icon": row.appPath.map { .object(["fileIcon": .string($0)]) } ?? .string("app-window-16"),
            "actions": actions.json,
        ]
        if let accessory = row.accessory {
            props["accessories"] = .array([.object(["text": .string(accessory)])])
        }
        return UINode(id: base + Node.item, type: "List.Item", props: props)
    }

    private static func action(
        _ id: Int, _ title: String, icon: String, shortcut: KeyShortcut?, destructive: Bool = false
    ) -> UINode {
        var props: [String: JSONValue] = ["title": .string(title), "icon": .string(icon)]
        if let shortcut {
            props["shortcut"] = .object([
                "key": .string(shortcut.key), "modifiers": .array(shortcut.modifiers.sorted().map(JSONValue.string)),
            ])
        }
        if destructive { props["style"] = .string("destructive") }
        return UINode(id: id, type: "Action", props: props)
    }
}
