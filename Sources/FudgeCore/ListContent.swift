import Foundation

/// A List view as fudge draws it: its sections after Raycast's own filtering, the empty view when one shows,
/// and the search bar's dropdown.
public struct ListContent: Sendable, Equatable {
    public struct Item: Sendable, Equatable, Identifiable {
        /// The node id, which the app uses for selection and events.
        public var id: Int
        /// The item's own `id` prop, which `selectedItemId` and `onSelectionChange` use.
        public var itemId: String?
        public var title: String
        public var titleTooltip: String?
        public var subtitle: String?
        public var subtitleTooltip: String?
        /// An `Image.ImageLike`, as the extension sent it.
        public var icon: JSONValue?
        public var iconTooltip: String?
        public var keywords: [String]
        public var accessories: [Accessory]
        public var actions: UINode?
        public var detail: UINode?
    }

    /// One accessory on the right of an item: text, a date or a tag, with an optional icon.
    public struct Accessory: Sendable, Equatable {
        /// What it shows; dates are already written relative to now ("2h", "1d").
        public var text: String?
        public var isTag: Bool
        /// A `Color.ColorLike` for the text (and a tag's background).
        public var color: JSONValue?
        public var icon: JSONValue?
        public var tooltip: String?
    }

    public struct Section: Sendable, Equatable, Identifiable {
        /// The section node's id. Items outside a section are grouped into one without a title,
        /// whose id is the negated id of its first item.
        public var id: Int
        public var title: String?
        public var subtitle: String?
        public var items: [Item]
    }

    public struct EmptyView: Sendable, Equatable {
        public var title: String
        public var description: String?
        public var icon: JSONValue?
        public var actions: UINode?
    }

    /// The sections that have items to show, in the order to show them.
    public var sections: [Section]
    /// What to show instead of items, when the list has none to show.
    public var emptyView: EmptyView?
    public var isLoading: Bool
    public var isShowingDetail: Bool
    public var dropdown: SearchBarDropdown?
    /// Set when the list loads in pages (`pagination`).
    public var pagination: Pagination?

    public struct Pagination: Sendable, Equatable {
        public var pageSize: Int
        public var hasMore: Bool
    }

    /// Whether to ask for the next page now that `index` is on screen or selected: the list has more, isn't
    /// already loading, and `index` is within `threshold` items of the end.
    public func wantsMore(near index: Int, threshold: Int = 5) -> Bool {
        guard let pagination, pagination.hasMore, !isLoading else { return false }
        return index >= items.count - threshold
    }

    public var items: [Item] { sections.flatMap(\.items) }

    /// Reads a `List` node, filtering it by `searchText` when Raycast would filter it itself.
    public init(_ view: UINode, searchText: String, now: Date = Date()) {
        var sections: [Section] = []
        var loose: [Item] = []
        var emptyNode: UINode?
        func flushLoose() {
            if let first = loose.first { sections.append(Section(id: -first.id, items: loose)) }
            loose = []
        }
        for child in view.children {
            switch child.type {
            case "List.Section":
                flushLoose()
                let items = child.children.filter { $0.type == "List.Item" }.map { Self.item($0, now: now) }
                sections.append(
                    Section(
                        id: child.id, title: child.string("title"), subtitle: child.string("subtitle"), items: items)
                )
            case "List.Item":
                loose.append(Self.item(child, now: now))
            case "List.EmptyView":
                emptyNode = child
            default:
                break
            }
        }
        flushLoose()

        let query = searchText.trimmingCharacters(in: .whitespaces)
        if Self.filtersLocally(view), !query.isEmpty {
            sections = Self.filter(sections, query: query, keepSectionOrder: Self.keepsSectionOrder(view))
        } else {
            sections.removeAll { $0.items.isEmpty }
        }

        self.sections = sections
        isLoading = view.bool("isLoading") == true
        isShowingDetail = view.bool("isShowingDetail") == true
        dropdown = view.node("searchBarAccessory").flatMap(SearchBarDropdown.init)
        if case .object(let options) = view.props["pagination"],
            case .object(let loadMore) = options["onLoadMore"], loadMore["$fn"] != nil
        {
            let pageSize: Int = if case .number(let size) = options["pageSize"] { max(1, Int(size)) } else { 10 }
            pagination = Pagination(pageSize: pageSize, hasMore: options["hasMore"] == .bool(true))
        } else {
            pagination = nil
        }

        // Raycast never shows the empty view while the list loads with an empty search bar.
        if sections.isEmpty, !(isLoading && searchText.isEmpty) {
            emptyView = EmptyView(
                title: emptyNode?.string("title") ?? (emptyNode == nil ? "No Results" : ""),
                description: emptyNode?.string("description"),
                icon: emptyNode?.props["icon"].flatMap(Self.present),
                actions: emptyNode?.node("actions") ?? view.node("actions")
            )
        } else {
            emptyView = nil
        }
    }

    /// Raycast filters a List itself unless the command handles search (`onSearchTextChange`) or says not to.
    public static func filtersLocally(_ view: UINode) -> Bool {
        switch view.props["filtering"] {
        case .bool(let filtering): return filtering
        case .object: return true
        default: break
        }
        if let enabled = view.bool("enableFiltering") { return enabled }
        return !view.hasCallback("onSearchTextChange")
    }

    static func keepsSectionOrder(_ view: UINode) -> Bool {
        if case .object(let options) = view.props["filtering"] { return options["keepSectionOrder"] == .bool(true) }
        return false
    }

    /// Keeps the items whose title or keywords match, best first, and drops sections left empty.
    /// Sections are ordered by their best item unless the list asks to keep their order.
    static func filter(_ sections: [Section], query: String, keepSectionOrder: Bool) -> [Section] {
        var ranked: [(section: Section, best: Int)] = []
        for var section in sections {
            let scored = section.items.enumerated().compactMap { index, item -> (item: Item, score: Int, index: Int)? in
                let scores = ([item.title] + item.keywords).compactMap { Fuzzy.match(query, in: $0)?.score }
                return scores.max().map { (item, $0, index) }
            }
            guard let best = scored.map(\.score).max() else { continue }
            section.items = scored.sorted { ($0.score, -$0.index) > ($1.score, -$1.index) }.map(\.item)
            ranked.append((section, best))
        }
        if !keepSectionOrder {
            ranked = ranked.enumerated()
                .sorted { ($0.element.best, -$0.offset) > ($1.element.best, -$1.offset) }
                .map(\.element)
        }
        return ranked.map(\.section)
    }

    /// The item to select after the list changed: the same node if it's still there, else an item with the
    /// same `id` prop, else the first item.
    public func reselect(node: Int?, itemId: String?) -> Int? {
        let items = items
        if let node, items.contains(where: { $0.id == node }) { return node }
        if let itemId, let match = items.first(where: { $0.itemId == itemId }) { return match.id }
        return items.first?.id
    }

    static func item(_ node: UINode, now: Date) -> Item {
        let title = textWithTooltip(node.props["title"])
        let subtitle = textWithTooltip(node.props["subtitle"])
        var icon = node.props["icon"].flatMap(present)
        var iconTooltip: String?
        if case .object(let wrapper) = icon, wrapper["source"] == nil, wrapper["fileIcon"] == nil,
            case .string(let tooltip) = wrapper["tooltip"]
        {
            icon = wrapper["value"].flatMap(present)
            iconTooltip = tooltip
        }
        var accessories: [Accessory] = []
        if case .array(let values) = node.props["accessories"] {
            accessories = values.compactMap { accessory($0, now: now) }
        }
        // Raycast's old accessory props.
        let oldTitle = node.string("accessoryTitle")
        let oldIcon = node.props["accessoryIcon"].flatMap(present)
        if oldTitle != nil || oldIcon != nil {
            accessories.append(Accessory(text: oldTitle, isTag: false, color: nil, icon: oldIcon, tooltip: nil))
        }
        return Item(
            id: node.id,
            itemId: node.string("id"),
            title: title.text ?? "",
            titleTooltip: title.tooltip,
            subtitle: subtitle.text.flatMap { $0.isEmpty ? nil : $0 },
            subtitleTooltip: subtitle.tooltip,
            icon: icon,
            iconTooltip: iconTooltip,
            keywords: strings(node.props["keywords"]),
            accessories: accessories,
            actions: node.node("actions"),
            detail: node.node("detail")
        )
    }

    static func accessory(_ json: JSONValue, now: Date) -> Accessory? {
        guard case .object(let object) = json else { return nil }
        let icon = object["icon"].flatMap(present)
        let tooltip: String? = if case .string(let tooltip) = object["tooltip"] { tooltip } else { nil }
        var text: String?
        var color: JSONValue?
        var isTag = false
        for key in ["tag", "date", "text"] {
            guard let value = object[key].flatMap(present) else { continue }
            isTag = key == "tag"
            var content = value
            if case .object(let wrapper) = value, wrapper["$date"] == nil {
                content = wrapper["value"] ?? .null
                color = wrapper["color"].flatMap(present)
            }
            switch content {
            case .string(let string): text = string
            case .number(let number): text = number.formatted()
            default: text = date(content).map { relative($0, now: now) }
            }
            break
        }
        if text?.isEmpty == true { text = nil }
        guard text != nil || icon != nil else { return nil }
        return Accessory(text: text, isTag: isTag && text != nil, color: color, icon: icon, tooltip: tooltip)
    }

    /// A date the way Raycast's accessories show one: "now", "5m", "2h", "1d", "3w", "2mo", "1y".
    public static func relative(_ date: Date, now: Date) -> String {
        let seconds = abs(now.timeIntervalSince(date))
        let minutes = Int(seconds / 60)
        let hours = minutes / 60
        let days = hours / 24
        if minutes < 1 { return "now" }
        if hours < 1 { return "\(minutes)m" }
        if days < 1 { return "\(hours)h" }
        if days < 7 { return "\(days)d" }
        if days < 30 { return "\(days / 7)w" }
        if days < 365 { return "\(days / 30)mo" }
        return "\(days / 365)y"
    }

    /// Reads `{ "$date": iso }`, as the host sends dates.
    public static func date(_ json: JSONValue?) -> Date? {
        guard case .object(let object) = json, case .string(let iso) = object["$date"] else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: iso) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)
    }

    /// `"text"` or `{ value, tooltip }`.
    static func textWithTooltip(_ json: JSONValue?) -> (text: String?, tooltip: String?) {
        switch json {
        case .string(let text):
            return (text, nil)
        case .object(let object):
            let text: String? = if case .string(let value) = object["value"] { value } else { nil }
            let tooltip: String? = if case .string(let tooltip) = object["tooltip"] { tooltip } else { nil }
            return (text, tooltip)
        default:
            return (nil, nil)
        }
    }

    static func strings(_ json: JSONValue?) -> [String] {
        guard case .array(let values) = json else { return [] }
        return values.compactMap { if case .string(let string) = $0 { string } else { nil } }
    }

    /// Nil for JSON null, so "no value" has one spelling.
    static func present(_ json: JSONValue) -> JSONValue? {
        json == .null ? nil : json
    }
}

/// The dropdown at the right of a List's or Grid's search bar.
public struct SearchBarDropdown: Sendable, Equatable {
    public struct Item: Sendable, Equatable, Identifiable {
        public var title: String
        public var value: String
        public var icon: JSONValue?
        public var keywords: [String]
        public var id: String { value }
    }

    public struct Section: Sendable, Equatable {
        public var title: String?
        public var items: [Item]
    }

    /// The node id, which `onChange` events go to.
    public var id: Int
    /// The dropdown's own `id` prop.
    public var name: String?
    public var tooltip: String?
    /// Set when the extension controls the value.
    public var value: String?
    public var defaultValue: String?
    public var storesValue: Bool
    public var hasOnChange: Bool
    /// The placeholder of the dropdown's own search field.
    public var placeholder: String?
    /// Whether fudge filters the items by the dropdown's search text, or the extension does
    /// (`onSearchTextChange`), as with a List.
    public var filtersLocally: Bool
    /// Whether the extension wants to hear the dropdown's search text (`onSearchTextChange`).
    public var handlesSearch: Bool
    public var throttle: Bool
    public var isLoading: Bool
    public var sections: [Section]

    public var items: [Item] { sections.flatMap(\.items) }

    public init?(_ node: UINode) {
        guard node.type.hasSuffix(".Dropdown") else { return nil }
        id = node.id
        name = node.string("id")
        tooltip = node.string("tooltip")
        value = node.string("value")
        defaultValue = node.string("defaultValue")
        storesValue = node.bool("storeValue") == true
        hasOnChange = node.hasCallback("onChange")
        placeholder = node.string("placeholder")
        filtersLocally = ListContent.filtersLocally(node)
        handlesSearch = node.hasCallback("onSearchTextChange")
        throttle = node.bool("throttle") == true
        isLoading = node.bool("isLoading") == true
        var sections: [Section] = []
        var loose: [Item] = []
        for child in node.children {
            if child.type.hasSuffix(".Dropdown.Section") {
                if !loose.isEmpty { sections.append(Section(title: nil, items: loose)) }
                loose = []
                let title = child.string("title")
                // An item's keywords default to its section's title.
                let items = child.children.compactMap(Self.item).map { item in
                    var item = item
                    if item.keywords.isEmpty, let title { item.keywords = [title] }
                    return item
                }
                sections.append(Section(title: title, items: items))
            } else if let item = Self.item(child) {
                loose.append(item)
            }
        }
        if !loose.isEmpty { sections.append(Section(title: nil, items: loose)) }
        self.sections = sections
    }

    static func item(_ node: UINode) -> Item? {
        guard node.type.hasSuffix(".Dropdown.Item"), let value = node.string("value") else { return nil }
        return Item(
            title: node.string("title") ?? value,
            value: value,
            icon: node.props["icon"].flatMap(ListContent.present),
            keywords: ListContent.strings(node.props["keywords"])
        )
    }

    /// The sections to show for the dropdown's search text: filtered by title and keywords when fudge filters,
    /// all of them when the extension does. Sections left empty are dropped.
    public func sections(matching query: String) -> [Section] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard filtersLocally, !trimmed.isEmpty else { return sections.filter { !$0.items.isEmpty } }
        return sections.compactMap { section in
            let items = section.items.filter { item in
                ([item.title] + item.keywords).contains { Fuzzy.match(trimmed, in: $0) != nil }
            }
            return items.isEmpty ? nil : Section(title: section.title, items: items)
        }
    }

    /// The value a newly shown dropdown starts with: the controlled value, else the stored one if it's still
    /// an item, else the default, else the first item's.
    public func initialValue(stored: String?) -> String? {
        if let value { return value }
        if storesValue, let stored, items.contains(where: { $0.value == stored }) { return stored }
        return defaultValue ?? items.first?.value
    }

    /// The values of dropdowns with `storeValue`, kept across launches in one JSON file.
    public struct Store: Sendable {
        public let file: URL

        public init(file: URL) {
            self.file = file
        }

        public static func key(extension name: String, command: String, dropdown: String?) -> String {
            [name, command, dropdown].compactMap { $0 }.joined(separator: "/")
        }

        public func value(for key: String) -> String? {
            load()[key]
        }

        public func set(_ value: String, for key: String) throws {
            var values = load()
            values[key] = value
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(values).write(to: file, options: .atomic)
        }

        private func load() -> [String: String] {
            guard let data = try? Data(contentsOf: file) else { return [:] }
            return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        }
    }
}
