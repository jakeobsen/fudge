import Foundation

/// How a Grid lays out a section's cells: the Grid's own props, with a section's overrides.
public struct GridSectionLayout: Sendable, Equatable {
    public enum Fit: String, Sendable {
        case contain, fill
    }

    /// The space between a cell's content and its border.
    public enum Inset: String, Sendable {
        case zero
        case small = "sm"
        case medium = "md"
        case large = "lg"
    }

    /// 1 to 8.
    public var columns: Int
    /// A cell's width divided by its height.
    public var aspectRatio: Double
    public var fit: Fit
    public var inset: Inset

    public static let defaultColumns = 5
    public static let columnRange = 1...8

    public init(columns: Int = defaultColumns, aspectRatio: Double = 1, fit: Fit = .contain, inset: Inset = .zero) {
        self.columns = min(max(columns, Self.columnRange.lowerBound), Self.columnRange.upperBound)
        self.aspectRatio = aspectRatio
        self.fit = fit
        self.inset = inset
    }

    /// A Grid's layout, from its props.
    public init(grid node: UINode) {
        self = GridSectionLayout().overridden(by: node)
    }

    /// This layout with what `node` (a Grid or a Grid.Section) sets itself.
    public func overridden(by node: UINode) -> GridSectionLayout {
        var layout = self
        if let columns = Self.columns(node) {
            layout = GridSectionLayout(columns: columns, aspectRatio: aspectRatio, fit: fit, inset: inset)
        }
        if let ratio = Self.aspectRatio(node.string("aspectRatio")) { layout.aspectRatio = ratio }
        if let fit = node.string("fit").flatMap(Fit.init) { layout.fit = fit }
        if let inset = node.string("inset").flatMap(Inset.init) { layout.inset = inset }
        return layout
    }

    /// `columns`, else the deprecated `itemSize`: small is 8 columns, medium 5, large 3. `columns` is clamped to
    /// 1–8 while it's still a `Double`, so a huge or infinite value can't trap in the conversion; `NaN` counts as
    /// not set.
    static func columns(_ node: UINode) -> Int? {
        if case .number(let columns) = node.props["columns"], !columns.isNaN {
            let range = Double(columnRange.lowerBound)...Double(columnRange.upperBound)
            return Int(min(max(columns, range.lowerBound), range.upperBound))
        }
        switch node.string("itemSize") {
        case "small": return 8
        case "medium": return 5
        case "large": return 3
        default: return nil
        }
    }

    /// `"16/9"` as 16 ÷ 9, for the ratios Raycast allows ("1", "3/2", "2/3", "4/3", "3/4", "16/9", "9/16").
    public static func aspectRatio(_ text: String?) -> Double? {
        switch text {
        case "1": 1
        case "3/2": 3.0 / 2
        case "2/3": 2.0 / 3
        case "4/3": 4.0 / 3
        case "3/4": 3.0 / 4
        case "16/9": 16.0 / 9
        case "9/16": 9.0 / 16
        default: nil
        }
    }

    /// The inset in points. Raycast scales it with the item size, so it's given for 5 columns and grows or shrinks
    /// with the cell's width: half as much at 8 columns as at 4.
    public var insetPoints: Double {
        let atFiveColumns: Double =
            switch inset {
            case .zero: 0
            case .small: 6
            case .medium: 12
            case .large: 20
            }
        return atFiveColumns * Double(Self.defaultColumns) / Double(columns)
    }
}

/// What a Grid.Item shows in its cell: an image or a color, with an optional tooltip.
public struct GridItemContent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// An `Image.ImageLike`, as the extension sent it.
        case image(JSONValue)
        /// A `Color.ColorLike`, filling the cell.
        case color(JSONValue)
    }

    public var kind: Kind
    public var tooltip: String?

    public init(kind: Kind, tooltip: String? = nil) {
        self.kind = kind
        self.tooltip = tooltip
    }

    /// Reads `content`: an `Image.ImageLike`, `{ color }`, or `{ value, tooltip }` around either.
    public init?(_ json: JSONValue?) {
        guard let json, json != .null else { return nil }
        if case .object(let object) = json, !Self.isImageObject(object), let value = object["value"] {
            guard let inner = GridItemContent(value) else { return nil }
            self = inner
            if case .string(let tooltip) = object["tooltip"], !tooltip.isEmpty { self.tooltip = tooltip }
            return
        }
        if case .object(let object) = json, !Self.isImageObject(object), let color = object["color"] {
            guard color != .null else { return nil }
            self.init(kind: .color(color))
            return
        }
        self.init(kind: .image(json))
    }

    /// `{ source }` and `{ fileIcon }` are images even with other keys beside them.
    private static func isImageObject(_ object: [String: JSONValue]) -> Bool {
        object["source"] != nil || object["fileIcon"] != nil
    }

    /// How a cell draws its content.
    public enum Drawing: Sendable, Equatable {
        /// An asset, a file path or an http(s) image: it follows the section's `fit`.
        case picture
        /// A file's or application's icon (`fileIcon`), one of Raycast's icons, or an emoji: always drawn whole,
        /// centred and fitted inside the inset, so `Grid.Fit.Fill` never crops it.
        case icon
        /// A color, filling the cell.
        case color
    }

    public var drawing: Drawing {
        switch kind {
        case .color: .color
        case .image(let json): Self.drawing(ofImage: json)
        }
    }

    /// Whether the content covers the whole space inside the inset: a color always, a picture when the section's
    /// `fit` is `.fill`, an icon never.
    public func fills(_ fit: GridSectionLayout.Fit) -> Bool {
        switch drawing {
        case .color: true
        case .picture: fit == .fill
        case .icon: false
        }
    }

    /// An `Image.ImageLike`: a `{ fileIcon }` is an icon, and `{ source }` (light first when themed) or its
    /// `fallback` is read as a plain source.
    static func drawing(ofImage json: JSONValue) -> Drawing {
        switch json {
        case .string(let source):
            return drawing(ofSource: source)
        case .object(let object):
            if object["fileIcon"] != nil { return .icon }
            switch object["source"] {
            case .string(let source):
                return drawing(ofSource: source)
            case .object(let themed):
                if case .string(let source) = themed["light"] ?? themed["dark"] { return drawing(ofSource: source) }
            default:
                break
            }
            if case .string(let fallback) = object["fallback"] { return drawing(ofSource: fallback) }
            return .picture
        default:
            return .picture
        }
    }

    /// An `Image.Source`, read in the order the app resolves it: a URL or a file path is a picture, a name ending
    /// in `-16` is one of Raycast's icons, one or two characters are an emoji, and anything else names an asset.
    static func drawing(ofSource source: String) -> Drawing {
        let isURL = source.hasPrefix("http://") || source.hasPrefix("https://")
        if isURL || source.hasPrefix("/") || source.hasPrefix("~") { return .picture }
        if source.hasSuffix("-16") || (!source.isEmpty && source.count <= 2) { return .icon }
        return .picture
    }
}

/// Moving the selection through a Grid with the arrow keys.
public enum GridNavigation {
    public enum Move: Sendable {
        case left, right, up, down
    }

    /// One section as laid out: its number of items and of columns.
    public struct Section: Sendable, Equatable {
        public var count: Int
        public var columns: Int

        public init(count: Int, columns: Int) {
            self.count = count
            self.columns = max(1, columns)
        }
    }

    /// The index, counting through all sections, to select after `move` from `index`.
    /// - ← and → step to the previous and next item, across row and section ends.
    /// - ↑ and ↓ go to the row above or below. From a section's first or last row they go to the next section's
    ///   first row or the previous one's last, in the column nearest the same position. A shorter row takes its last
    ///   item.
    /// - At the first or last item, a move that would leave the grid stays where it is.
    public static func target(from index: Int, move: Move, in sections: [Section]) -> Int {
        let sections = sections.filter { $0.count > 0 }
        let total = sections.reduce(0) { $0 + $1.count }
        guard total > 0 else { return index }
        guard (0..<total).contains(index) else { return 0 }
        switch move {
        case .left: return max(0, index - 1)
        case .right: return min(total - 1, index + 1)
        case .up, .down: break
        }

        var starts: [Int] = []
        var start = 0
        for section in sections {
            starts.append(start)
            start += section.count
        }
        let current = starts.lastIndex { $0 <= index } ?? 0
        let section = sections[current]
        let position = index - starts[current]
        let row = position / section.columns
        let column = position % section.columns
        let lastRow = (section.count - 1) / section.columns

        /// The item in `row` of section `target` nearest to where `column` is in the current section.
        func item(inRow row: Int, of target: Int) -> Int {
            let other = sections[target]
            let rowStart = row * other.columns
            let rowLength = min(other.columns, other.count - rowStart)
            let x = (Double(column) + 0.5) / Double(section.columns)
            let nearest = min(Int(x * Double(other.columns)), rowLength - 1)
            return starts[target] + rowStart + nearest
        }

        if move == .down {
            if row < lastRow { return item(inRow: row + 1, of: current) }
            return current + 1 < sections.count ? item(inRow: 0, of: current + 1) : index
        }
        if row > 0 { return item(inRow: row - 1, of: current) }
        guard current > 0 else { return index }
        let previous = sections[current - 1]
        return item(inRow: (previous.count - 1) / previous.columns, of: current - 1)
    }

    /// The modifiers that leave ← and → to the search field: ⇧ selects text, ⌥ moves by word, ⌘ to the line's ends,
    /// ⌃ as Emacs does. Named as `KeyShortcut` names them.
    public static let fieldModifiers: Set<String> = ["shift", "opt", "cmd", "ctrl"]

    /// Whether an arrow key moves the Grid's selection rather than the search field's cursor.
    /// - While an input method is composing (`composing`: the field has marked text), no arrow does: they pick a
    ///   candidate.
    /// - ↑ and ↓ always do otherwise.
    /// - ← and → don't with ⇧, ⌥, ⌘ or ⌃ (`fieldModifiers`). Other flags an event carries don't count: arrow keys
    ///   always come with `fn` and `numpad`. Without those four, they do when the search field is empty, or when its
    ///   cursor is at the end with nothing selected; otherwise they move the cursor.
    ///
    /// Lengths and the selection are in UTF-16 units, as `NSTextView` counts them; a nil selection means the field
    /// isn't being edited, and only the empty-field case applies.
    public static func arrowMovesSelection(
        _ move: Move, modifiers: Set<String> = [], composing: Bool = false, textLength: Int,
        selection: (location: Int, length: Int)?
    ) -> Bool {
        if composing { return false }
        switch move {
        case .up, .down:
            return true
        case .left, .right:
            guard modifiers.isDisjoint(with: fieldModifiers) else { return false }
            if textLength == 0 { return true }
            guard let selection else { return false }
            return selection.length == 0 && selection.location == textLength
        }
    }
}
