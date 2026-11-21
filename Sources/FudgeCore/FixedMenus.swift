import Foundation

/// A made-up menu: a menu bar item with its items, or an item, with a submenu when it has `items`.
public struct FixedMenu: Sendable, Equatable, Decodable {
    public var title: String
    public var enabled: Bool
    public var shortcut: MenuShortcut?
    public var items: [FixedMenu]?

    public init(_ title: String, enabled: Bool = true, shortcut: MenuShortcut? = nil, items: [FixedMenu]? = nil) {
        self.title = title
        self.enabled = enabled
        self.shortcut = shortcut
        self.items = items
    }

    private enum CodingKeys: String, CodingKey {
        case title, enabled, key, modifiers, glyph, virtualKey, items
    }

    /// `{ "title", "enabled"?, "key"?, "modifiers"?, "glyph"?, "virtualKey"?, "items"? }`: `key` is the shortcut's
    /// character, and `modifiers` its `kAXMenuItemModifier…` bits.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        items = try container.decodeIfPresent([FixedMenu].self, forKey: .items)
        let key = try container.decodeIfPresent(String.self, forKey: .key)
        let glyph = try container.decodeIfPresent(Int.self, forKey: .glyph)
        let virtualKey = try container.decodeIfPresent(Int.self, forKey: .virtualKey)
        if key != nil || glyph != nil || virtualKey != nil {
            shortcut = MenuShortcut(
                character: key, modifiers: try container.decodeIfPresent(Int.self, forKey: .modifiers) ?? 0,
                glyph: glyph, virtualKey: virtualKey)
        }
    }
}

/// An element of `FixedMenuSystem`'s menus: which build of them it's from, and its place there.
public struct FixedMenuHandle: Sendable, Hashable {
    public var build: Int
    public var index: Int
}

/// Made-up menus, for tests and snapshot runs (`--menu-items`): an app's menu bar, with the Apple menu first as
/// every app has, then `menus`, the first being the app's own. Pressing an item only records it. `rebuild` gives the
/// app new menus, whose elements are new ones, as when an app rebuilds its menus.
public final class FixedMenuSystem: MenuSystem, @unchecked Sendable {
    public typealias Handle = FixedMenuHandle

    private struct Element {
        var node: MenuNode<FixedMenuHandle>
        var title: String
    }

    private let lock = NSLock()
    private var build = 0
    private var elements: [Element] = []
    private var bar: [FixedMenuHandle] = []
    private var pressedTitles: [String] = []
    private var pressedHandles: [FixedMenuHandle] = []
    private var silent = false
    private var asked = 0

    /// Called with each item's title as it's read, before it answers: a test can hold the read there.
    public var onRead: (@Sendable (String) -> Void)?

    public init(menus: [FixedMenu]) {
        load(menus)
    }

    /// The made-up app's menus as they now are, without the Apple menu.
    public func rebuild(_ menus: [FixedMenu]) {
        lock.withLock {
            build += 1
            elements = []
            load(menus)
        }
    }

    /// While true, nothing answers.
    public var answers: Bool {
        get { lock.withLock { !silent } }
        set { lock.withLock { silent = !newValue } }
    }

    /// The titles of the items pressed, in order.
    public var pressed: [String] { lock.withLock { pressedTitles } }

    /// The elements pressed, in order, to tell alike items apart.
    public var pressedElements: [FixedMenuHandle] { lock.withLock { pressedHandles } }

    /// The leaf items titled `title`, in menu order.
    public func items(titled title: String) -> [FixedMenuHandle] {
        lock.withLock {
            elements.indices.filter { elements[$0].title == title && elements[$0].node.children.isEmpty }
                .map { FixedMenuHandle(build: build, index: $0) }
        }
    }

    /// Turns the items titled `title` on or off, as an app does while its menus stay up.
    public func setEnabled(_ enabled: Bool, titled title: String) {
        lock.withLock {
            for index in elements.indices where elements[index].title == title {
                elements[index].node.enabled = enabled
            }
        }
    }

    /// How many times an element was read.
    public var reads: Int { lock.withLock { asked } }

    private func load(_ menus: [FixedMenu]) {
        let apple = FixedMenu("Apple", items: [FixedMenu("About This Mac"), FixedMenu("System Settings…")])
        bar = ([apple] + menus).map { add($0) }
    }

    /// Adds `menu` as an item, with its submenu, and gives its handle.
    private func add(_ menu: FixedMenu) -> FixedMenuHandle {
        var children: [FixedMenuHandle] = []
        if let items = menu.items {
            let list = items.map { add($0) }
            children = [append(MenuNode(role: .menu, title: "", children: list), title: menu.title)]
        }
        let item = MenuNode(
            role: .item, title: menu.title, enabled: menu.enabled, children: children, shortcut: menu.shortcut)
        return append(item, title: menu.title)
    }

    private func append(_ node: MenuNode<FixedMenuHandle>, title: String) -> FixedMenuHandle {
        elements.append(Element(node: node, title: title))
        return FixedMenuHandle(build: build, index: elements.count - 1)
    }

    public func menuBar(of pid: Int32) -> MenuAnswer<[FixedMenuHandle]> {
        lock.withLock { silent ? .noAnswer : .answered(bar) }
    }

    public func node(_ element: FixedMenuHandle) -> MenuAnswer<MenuNode<FixedMenuHandle>> {
        let title: String? = lock.withLock {
            guard element.build == build, elements.indices.contains(element.index),
                elements[element.index].node.role == .item
            else { return nil }
            return elements[element.index].title
        }
        if let title { onRead?(title) }
        return lock.withLock {
            asked += 1
            if silent { return .noAnswer }
            guard element.build == build, elements.indices.contains(element.index) else { return .gone }
            return .answered(elements[element.index].node)
        }
    }

    public func press(_ element: FixedMenuHandle) -> MenuPress {
        lock.withLock {
            if silent { return .noAnswer }
            guard element.build == build, elements.indices.contains(element.index) else { return .gone }
            pressedTitles.append(elements[element.index].title)
            pressedHandles.append(element)
            return .pressed
        }
    }
}

/// A snapshot run's made-up app and menus (`--menu-items <file>`): `{ "app": "<name>", "path"?: "<bundle>",
/// "menus": [<FixedMenu>…] }`, the app's own menu first.
public struct FixedMenuFile: Sendable, Decodable {
    public var app: String
    public var path: String?
    public var menus: [FixedMenu]

    public static func load(_ url: URL) -> FixedMenuFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(FixedMenuFile.self, from: data)
    }

    /// The made-up app, with a pid no app has.
    public var target: MenuTarget {
        MenuTarget(pid: -1, bundleID: "fudge.snapshot.menu-items", name: app, path: path)
    }
}
