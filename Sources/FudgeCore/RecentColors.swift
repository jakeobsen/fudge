import Foundation

/// A color the user picked, as Recent Colors keeps it.
public struct RecentColor: Sendable, Equatable, Identifiable {
    public var id: String
    public var color: PickedColor
    /// When it was picked, ISO 8601.
    public var pickedAt: String?

    public init(id: String = UUID().uuidString, color: PickedColor, pickedAt: String? = nil) {
        self.id = id
        self.color = color
        self.pickedAt = pickedAt
    }

    /// A color from its `colors.json` entry: an `id` and `red`, `green` and `blue` numbers, with `alpha` 1 unless
    /// it's a number. Components are clamped as `PickedColor` clamps them.
    init?(json: JSONValue) {
        guard case .object(let object) = json,
            case .string(let id) = object["id"], !id.trimmingCharacters(in: .whitespaces).isEmpty,
            case .number(let red) = object["red"], case .number(let green) = object["green"],
            case .number(let blue) = object["blue"]
        else { return nil }
        let alpha: Double = if case .number(let alpha) = object["alpha"] { alpha } else { 1 }
        let pickedAt: String? = if case .string(let date) = object["pickedAt"] { date } else { nil }
        self.init(id: id, color: PickedColor(red: red, green: green, blue: blue, alpha: alpha), pickedAt: pickedAt)
    }

    func json() -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(id), "red": .number(color.red), "green": .number(color.green), "blue": .number(color.blue),
            "alpha": .number(color.alpha),
        ]
        if let pickedAt { object["pickedAt"] = .string(pickedAt) }
        return .object(object)
    }
}

/// Recent Colors in `colors.json`, `{ "colors": [ { id, red, green, blue, alpha, pickedAt } ] }`, newest first, the
/// components in sRGB. Kept as `SnippetStore` keeps snippets (`EntryFile`): read tolerantly, written atomically, keys
/// Fudge doesn't know kept, and a file it can't read never overwritten.
public struct RecentColorStore: Sendable, Equatable {
    /// How many colors it keeps: the oldest go first.
    public static let limit = 32

    private var entries: [JSONValue]

    public init(_ colors: [RecentColor] = []) {
        entries = colors.map { $0.json() }
    }

    init(entries: [JSONValue]) {
        self.entries = entries
    }

    /// The valid colors, newest first, each `id` once.
    public var colors: [RecentColor] {
        EntryFile.valid(entries, RecentColor.init(json:), id: \.id)
    }

    public func color(id: String) -> RecentColor? {
        colors.first { $0.id == id }
    }

    /// Puts `color` first. The same color picked before (the same in every format, `isSame(as:)`) moves up rather
    /// than showing twice, and past `limit` valid colors the oldest go. Entries that aren't valid colors (a hand edit)
    /// don't count toward the limit and stay in the file.
    public mutating func add(_ color: PickedColor, id: String = UUID().uuidString, now: Date) {
        entries.removeAll { RecentColor(json: $0)?.color.isSame(as: color) == true }
        let pickedAt = ISO8601DateFormatter().string(from: now)
        entries.insert(RecentColor(id: id, color: color, pickedAt: pickedAt).json(), at: 0)
        var valid = 0
        entries.removeAll { entry in
            guard RecentColor(json: entry) != nil else { return false }
            valid += 1
            return valid > Self.limit
        }
    }

    @discardableResult
    public mutating func remove(id: String) -> Bool {
        let before = entries.count
        entries.removeAll { RecentColor(json: $0)?.id == id }
        return entries.count != before
    }

    /// Clear Recent Colors.
    public mutating func clear() {
        entries = []
    }

    /// `colors.json` exists but isn't a colors object: Fudge never overwrites it.
    public struct Unreadable: Error, Equatable, CustomStringConvertible {
        public init() {}
        public var description: String {
            "Fudge can't read colors.json, so it leaves the file as it is. Fix or remove it, then try again."
        }
    }

    static let fileKey = "colors"

    public static func isWritable(_ file: URL) -> Bool {
        (try? EntryFile.object(at: file, key: fileKey)) != nil
    }

    public static func load(from file: URL) -> RecentColorStore {
        RecentColorStore(entries: EntryFile.entries(at: file, key: fileKey))
    }

    public func save(to file: URL) throws {
        do {
            try EntryFile.save(entries, to: file, key: Self.fileKey)
        } catch is EntryFile.Unreadable {
            throw Unreadable()
        }
    }
}

/// Fudge's own Recent Colors view (SPEC-090): a Grid of color swatches built here as an extension's would arrive, so
/// the launcher draws it, filters it and takes its keys like any other. As with Search Snippets (`SnippetList`), it
/// never reaches the extension host: its session is Fudge's, and the launcher answers its actions itself.
public enum RecentColorsGrid {
    public static let session = "fudge:recent-colors"
    public static let title = "Recent Colors"
    static let columns = 8

    /// What one of its actions does.
    public enum Target: Sendable, Equatable {
        /// ↵ (the Copy Format), and each format in ⌘K.
        case copy(id: String, format: ColorFormat)
        /// ⌃X.
        case remove(id: String)
        /// ⌃⇧X: Clear Recent Colors…, after asking.
        case clear
        /// The empty view's action.
        case pick
    }

    public static let removeShortcut = KeyShortcut(key: "x", modifiers: ["ctrl"])
    public static let clearShortcut = KeyShortcut(key: "x", modifiers: ["ctrl", "shift"])

    /// Its nodes' ids. Each color's nodes are a block of `stride` from `firstItem`, in the order shown.
    enum Node {
        static let grid = 1
        static let empty = 2
        static let emptyActions = 3
        static let emptyPick = 4
        static let firstItem = 100
        static let stride = 20
        // Offsets inside a color's block.
        static let item = 0
        static let actions = 1
        static let copySection = 2
        /// Each format's Copy action, at `copy + its index in ColorFormat.allCases`.
        static let copy = 3
        static let manageSection = 10
        static let remove = 11
        static let clear = 12
    }

    /// The Grid: one swatch per color, newest first, titled with its HEX. ↵ copies it in `format`, ⌘K lists every
    /// format with `format` first, then Remove Color and Clear Recent Colors…. With no colors, the empty view offers
    /// Pick Color.
    public static func view(colors: [RecentColor], format: ColorFormat) -> UINode {
        var children = colors.enumerated().map { index, color in
            item(color, base: Node.firstItem + index * Node.stride, format: format)
        }
        let pick = action(Node.emptyPick, "Pick Color", icon: "eye-dropper-16", shortcut: nil)
        children.append(
            UINode(
                id: Node.empty, type: "Grid.EmptyView",
                props: [
                    "title": .string("No Recent Colors"),
                    "description": .string("Colors you pick with Pick Color show here."),
                    "icon": .string("swatch-16"),
                    "actions": UINode(id: Node.emptyActions, type: "ActionPanel", children: [pick]).json,
                ]))
        return UINode(
            id: Node.grid, type: "Grid",
            props: [
                "navigationTitle": .string(title), "searchBarPlaceholder": .string("Search colors"),
                "columns": .number(Double(columns)),
            ],
            children: children)
    }

    /// What the action `node` does, in the view built from `colors`; nil for any other node.
    public static func target(of node: Int, in colors: [RecentColor]) -> Target? {
        if node == Node.emptyPick { return .pick }
        guard node >= Node.firstItem else { return nil }
        let index = (node - Node.firstItem) / Node.stride
        guard index < colors.count else { return nil }
        let id = colors[index].id
        let offset = (node - Node.firstItem) % Node.stride
        let formats = ColorFormat.allCases
        if offset >= Node.copy, offset < Node.copy + formats.count {
            return .copy(id: id, format: formats[offset - Node.copy])
        }
        switch offset {
        case Node.remove: return .remove(id: id)
        case Node.clear: return .clear
        default: return nil
        }
    }

    private static func item(_ color: RecentColor, base: Int, format: ColorFormat) -> UINode {
        let ordered = [format] + ColorFormat.allCases.filter { $0 != format }
        let copies = ordered.map { each in
            action(
                base + Node.copy + ColorFormat.allCases.firstIndex(of: each)!, "Copy \(each.title)",
                icon: "copy-clipboard-16", shortcut: nil)
        }
        let actions = UINode(
            id: base + Node.actions, type: "ActionPanel",
            children: [
                UINode(id: base + Node.copySection, type: "ActionPanel.Section", children: copies),
                UINode(
                    id: base + Node.manageSection, type: "ActionPanel.Section",
                    children: [
                        action(
                            base + Node.remove, "Remove Color", icon: "trash-16", shortcut: removeShortcut,
                            destructive: true),
                        action(
                            base + Node.clear, "Clear Recent Colors…", icon: "trash-16", shortcut: clearShortcut,
                            destructive: true),
                    ]),
            ])
        let hex = ColorFormat.hex.string(for: color.color)
        return UINode(
            id: base + Node.item, type: "Grid.Item",
            props: [
                "id": .string(color.id), "title": .string(hex),
                "content": .object(["color": .string(hex)]),
                "keywords": .array(
                    [ColorFormat.rgb, .hsl].map { JSONValue.string($0.string(for: color.color)) }),
                "actions": actions.json,
            ])
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
