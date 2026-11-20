import Foundation

/// Where an item sits in a `MenuBarExtra`: its index among its parent's children at each level, through sections
/// and submenus, and whether it's an item's ⌥ alternate. A pick made in an old tree is matched to a new one by this
/// and the item's title.
public struct MenuBarPath: Sendable, Hashable, CustomStringConvertible {
    public var indexes: [Int]
    public var alternate: Bool

    public init(_ indexes: [Int], alternate: Bool = false) {
        self.indexes = indexes
        self.alternate = alternate
    }

    public var description: String {
        indexes.map(String.init).joined(separator: ".") + (alternate ? " (alternate)" : "")
    }
}

/// A `MenuBarExtra.Item`.
public struct MenuBarItem: Sendable, Equatable {
    public var node: Int
    public var path: MenuBarPath
    public var title: String
    /// Drawn after the title, in a secondary colour.
    public var subtitle: String?
    public var icon: JSONValue?
    public var tooltip: String?
    public var shortcut: KeyShortcut?
    /// Whether it has an `onAction`. One without is drawn disabled: Raycast uses those as headings.
    public var isEnabled: Bool
    /// Held in an array, since a struct can't hold an optional of itself.
    private var alternates: [MenuBarItem]

    /// The item shown in its place while ⌥ is held.
    public var alternate: MenuBarItem? { alternates.first }

    public init(
        node: Int, path: MenuBarPath, title: String, subtitle: String? = nil, icon: JSONValue? = nil,
        tooltip: String? = nil, shortcut: KeyShortcut? = nil, isEnabled: Bool, alternate: MenuBarItem? = nil
    ) {
        self.node = node
        self.path = path
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.tooltip = tooltip
        self.shortcut = shortcut
        self.isEnabled = isEnabled
        self.alternates = alternate.map { [$0] } ?? []
    }
}

/// A `MenuBarExtra.Submenu`.
public struct MenuBarSubmenu: Sendable, Equatable {
    public var path: MenuBarPath
    public var title: String
    public var icon: JSONValue?
    public var entries: [MenuBarEntry]
}

/// One line of a menu-bar command's menu. Sections become their title as a heading, with separators around them.
public enum MenuBarEntry: Sendable, Equatable {
    case item(MenuBarItem)
    case submenu(MenuBarSubmenu)
    /// A section's title, drawn as a disabled line.
    case heading(String)
    case separator
}

/// A menu-bar command's `MenuBarExtra`, read for its status item and menu.
public struct MenuBarContent: Sendable, Equatable {
    public var title: String?
    public var icon: JSONValue?
    public var tooltip: String?
    public var isLoading: Bool
    public var entries: [MenuBarEntry]

    /// Reads a rendered view. A command that rendered `null`, or something other than a `MenuBarExtra`, has none.
    public init?(_ view: UINode?) {
        guard let view, view.type == "MenuBarExtra" else { return nil }
        title = view.string("title").flatMap { $0.isEmpty ? nil : $0 }
        icon = view.props["icon"].flatMap { $0 == .null ? nil : $0 }
        tooltip = view.string("tooltip")
        isLoading = view.bool("isLoading") == true
        entries = Self.entries(of: view.children, at: [])
    }

    /// With no children, no title and no icon, the command shows no item.
    public var isEmpty: Bool { entries.isEmpty && title == nil && icon == nil }

    /// The enabled item at a pick's path, if it still has the title it had when it was picked.
    public func item(matching path: MenuBarPath, title: String) -> MenuBarItem? {
        guard let item = item(at: path, in: entries), item.title == title, item.isEnabled else { return nil }
        return item
    }

    private func item(at path: MenuBarPath, in entries: [MenuBarEntry]) -> MenuBarItem? {
        for entry in entries {
            switch entry {
            case .item(let item):
                if item.path == path { return item }
                if let alternate = item.alternate, alternate.path == path { return alternate }
            case .submenu(let submenu):
                if let found = self.item(at: path, in: submenu.entries) { return found }
            case .heading, .separator:
                break
            }
        }
        return nil
    }

    static func entries(of children: [UINode], at prefix: [Int]) -> [MenuBarEntry] {
        var entries: [MenuBarEntry] = []
        for (index, child) in children.enumerated() {
            let path = prefix + [index]
            switch child.type {
            case "MenuBarExtra.Item":
                entries.append(.item(item(child, path: MenuBarPath(path))))
            case "MenuBarExtra.Submenu":
                entries.append(
                    .submenu(
                        MenuBarSubmenu(
                            path: MenuBarPath(path), title: child.string("title") ?? "",
                            icon: child.props["icon"].flatMap { $0 == .null ? nil : $0 },
                            entries: Self.entries(of: child.children, at: path))))
            case "MenuBarExtra.Separator":
                entries.append(.separator)
            case "MenuBarExtra.Section":
                // A section is separated from its neighbours, with its title as a heading.
                let inner = Self.entries(of: child.children, at: path)
                let heading = child.string("title").flatMap { $0.isEmpty ? nil : $0 }
                guard !inner.isEmpty || heading != nil else { continue }
                entries.append(.separator)
                if let heading { entries.append(.heading(heading)) }
                entries += inner
                entries.append(.separator)
            default:
                break
            }
        }
        return tidy(entries)
    }

    /// No separator first, last, or twice in a row.
    static func tidy(_ entries: [MenuBarEntry]) -> [MenuBarEntry] {
        var result: [MenuBarEntry] = []
        for entry in entries {
            if entry == .separator, result.isEmpty || result.last == .separator { continue }
            result.append(entry)
        }
        if result.last == .separator { result.removeLast() }
        return result
    }

    static func item(_ node: UINode, path: MenuBarPath) -> MenuBarItem {
        var alternate: MenuBarItem?
        if let node = node.node("alternate"), node.type == "MenuBarExtra.Item" {
            alternate = item(node, path: MenuBarPath(path.indexes, alternate: true))
        }
        return MenuBarItem(
            node: node.id, path: path, title: node.string("title") ?? "", subtitle: node.string("subtitle"),
            icon: node.props["icon"].flatMap { $0 == .null ? nil : $0 }, tooltip: node.string("tooltip"),
            shortcut: KeyShortcut(json: node.props["shortcut"]), isEnabled: node.hasCallback("onAction"),
            alternate: alternate)
    }
}
