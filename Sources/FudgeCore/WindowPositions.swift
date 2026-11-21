import CoreGraphics
import Foundation

// The user's own window commands (SPEC-094): custom positions and saved layouts, kept in `window-layouts.json`.

/// A frame as fractions of a screen's visible frame: `x` and `y` from its top left, `width` and `height`, each 0–1.
/// "Left 70%" is (0, 0, 0.7, 1).
public struct WindowFractions: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Every value finite and within 0–1, a size above 0, and the frame inside the screen (`x + width` and
    /// `y + height` at most 1), to within rounding.
    public var isValid: Bool {
        let values = [x, y, width, height]
        guard values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }), width > 0, height > 0 else { return false }
        return x + width <= 1 + Self.tolerance && y + height <= 1 + Self.tolerance
    }

    static let tolerance = 1e-9

    /// The frame in `visible`, a screen's visible frame, with each edge rounded to a whole point as Fudge's own
    /// commands are (`WindowLayout`).
    public func frame(in visible: CGRect) -> CGRect {
        let left = (visible.minX + visible.width * x).rounded()
        let top = (visible.minY + visible.height * y).rounded()
        let right = (visible.minX + visible.width * min(x + width, 1)).rounded()
        let bottom = (visible.minY + visible.height * min(y + height, 1)).rounded()
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// `frame` as fractions of `visible`: the part of it inside `visible`, since a window can reach past the visible
    /// frame (under the menu bar or the Dock, or off the screen's edge). Nil when no part of it is inside.
    public init?(_ frame: CGRect, in visible: CGRect) {
        let inside = frame.intersection(visible)
        guard !inside.isNull, inside.width > 0, inside.height > 0, visible.width > 0, visible.height > 0 else {
            return nil
        }
        self.init(
            x: Double((inside.minX - visible.minX) / visible.width),
            y: Double((inside.minY - visible.minY) / visible.height),
            width: Double(inside.width / visible.width), height: Double(inside.height / visible.height))
        guard isValid else { return nil }
    }

    /// The fractions in an entry of `window-layouts.json`, its `x`, `y`, `width` and `height`; nil unless they're
    /// numbers that are `isValid`.
    init?(json object: [String: JSONValue]) {
        guard case .number(let x) = object["x"], case .number(let y) = object["y"],
            case .number(let width) = object["width"], case .number(let height) = object["height"]
        else { return nil }
        self.init(x: x, y: y, width: width, height: height)
        guard isValid else { return nil }
    }

    func write(into object: inout [String: JSONValue]) {
        object["x"] = .number(x)
        object["y"] = .number(y)
        object["width"] = .number(width)
        object["height"] = .number(height)
    }
}

/// A custom position (SPEC-094 §1): a name and a frame. It's a command in the Window Management group, which acts on
/// the frontmost window as Left Half does.
public struct CustomWindowPosition: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var frame: WindowFractions

    public static let nameLimit = 64

    public init(id: String = WindowLayoutStore.newID(), name: String, frame: WindowFractions) {
        self.id = id
        self.name = name
        self.frame = frame
    }

    /// Its command's name in the Window Management group.
    public var commandName: String { "position-\(id)" }

    /// A position from its `window-layouts.json` entry: a valid id and name, and valid fractions.
    init?(json: JSONValue) {
        guard case .object(let object) = json, case .string(let id) = object["id"], WindowLayoutStore.isValidID(id),
            case .string(let name) = object["name"], WindowLayoutStore.isValidName(name),
            let frame = WindowFractions(json: object)
        else { return nil }
        self.init(id: id, name: name, frame: frame)
    }

    /// Writes the position over its old entry, so keys Fudge doesn't know stay.
    func json(over existing: [String: JSONValue] = [:]) -> JSONValue {
        var object = existing
        object["id"] = .string(id)
        object["name"] = .string(name)
        frame.write(into: &object)
        return .object(object)
    }
}

/// Where a saved window's screen was: its display name, and its place in the screen list (the primary one first).
public struct SavedScreen: Sendable, Equatable {
    public var name: String
    public var index: Int

    public init(name: String, index: Int) {
        self.name = name
        self.index = index
    }

    /// The screen among `screens` (the primary one first) that a saved window goes on: the one with its name; of
    /// several with that name (two of one model), the one in its place, else the first; with none, the one in its
    /// place; else the primary one.
    public func match(in screens: [WindowScreen]) -> WindowScreen? {
        let named = screens.indices.filter { screens[$0].name == name && !name.isEmpty }
        if named.count == 1 { return screens[named[0]] }
        if !named.isEmpty { return named.contains(index) ? screens[index] : screens[named[0]] }
        return screens.indices.contains(index) ? screens[index] : screens.first
    }
}

/// One window of a saved layout: its app's bundle id, its place among that app's windows (front to back), its screen
/// and its frame there. Never its title, which can be private.
public struct SavedWindow: Sendable, Equatable {
    public var bundleId: String
    public var index: Int
    public var screen: SavedScreen
    public var frame: WindowFractions

    public init(bundleId: String, index: Int, screen: SavedScreen, frame: WindowFractions) {
        self.bundleId = bundleId
        self.index = index
        self.screen = screen
        self.frame = frame
    }

    /// The highest place a saved window can have, so a hand-edited file can't ask for an absurd one.
    static let indexLimit = 1_000

    init?(json: JSONValue) {
        guard case .object(let object) = json, case .string(let bundleId) = object["bundleId"],
            !bundleId.trimmingCharacters(in: .whitespaces).isEmpty,
            let index = Self.count(object["index"]),
            case .object(let screen) = object["screen"], case .string(let screenName) = screen["name"],
            let screenIndex = Self.count(screen["index"]),
            let frame = WindowFractions(json: object)
        else { return nil }
        self.init(
            bundleId: bundleId, index: index, screen: SavedScreen(name: screenName, index: screenIndex), frame: frame)
    }

    /// A whole number from 0 to `indexLimit`, read without a conversion that could trap.
    private static func count(_ value: JSONValue?) -> Int? {
        guard case .number(let number) = value, number >= 0, number <= Double(indexLimit),
            number == number.rounded()
        else { return nil }
        return Int(number)
    }

    /// The valid windows in a JSON array of `window-layouts.json`'s window entries, as a snapshot run's
    /// `--layout-windows` file holds them.
    public static func list(from json: JSONValue) -> [SavedWindow] {
        guard case .array(let entries) = json else { return [] }
        return entries.compactMap(SavedWindow.init(json:))
    }

    var json: JSONValue {
        var object: [String: JSONValue] = [
            "bundleId": .string(bundleId), "index": .number(Double(index)),
            "screen": .object(["name": .string(screen.name), "index": .number(Double(screen.index))]),
        ]
        frame.write(into: &object)
        return .object(object)
    }
}

/// A saved layout (SPEC-094 §2): where each app's windows were. It's the command "Apply <name>".
public struct SavedWindowLayout: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var windows: [SavedWindow]
    /// When it was saved, ISO 8601.
    public var createdAt: String?

    public init(id: String = WindowLayoutStore.newID(), name: String, windows: [SavedWindow], createdAt: String? = nil)
    {
        self.id = id
        self.name = name
        self.windows = windows
        self.createdAt = createdAt
    }

    /// Its command's name in the Window Management group.
    public var commandName: String { "layout-\(id)" }
    /// Its command's title.
    public var commandTitle: String { "Apply \(name)" }

    /// How many apps its windows belong to.
    public var appCount: Int { Set(windows.map(\.bundleId)).count }

    /// A layout from its `window-layouts.json` entry: a valid id and name, and its windows, of which those that
    /// aren't valid are left out. One with no valid window isn't a layout.
    init?(json: JSONValue) {
        guard case .object(let object) = json, case .string(let id) = object["id"], WindowLayoutStore.isValidID(id),
            case .string(let name) = object["name"], WindowLayoutStore.isValidName(name),
            case .array(let entries) = object["windows"]
        else { return nil }
        let windows = entries.compactMap(SavedWindow.init(json:))
        guard !windows.isEmpty else { return nil }
        var createdAt: String?
        if case .string(let date) = object["createdAt"] { createdAt = date }
        self.init(id: id, name: name, windows: windows, createdAt: createdAt)
    }

    /// A new layout's entry.
    var json: JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(id), "name": .string(name), "windows": .array(windows.map(\.json)),
        ]
        if let createdAt { object["createdAt"] = .string(createdAt) }
        return .object(object)
    }
}

/// The user's custom positions and saved layouts in `window-layouts.json`,
/// `{ "positions": [ { id, name, x, y, width, height } ], "layouts": [ { id, name, createdAt, windows: [ { bundleId,
/// index, screen: { name, index }, x, y, width, height } ] } ] }`, kept as `QuicklinkStore` keeps quicklinks
/// (`EntryFile`): read tolerantly, written atomically, keys Fudge doesn't know kept, and a file it can't read never
/// overwritten. Entries that aren't valid (a hand-edited fraction outside 0–1, a size of 0, a frame reaching past the
/// screen) are left out of the commands and the Settings page, and kept in the file as they are.
public struct WindowLayoutStore: Sendable, Equatable {
    private var positionEntries: [JSONValue]
    private var layoutEntries: [JSONValue]

    public init(positions: [CustomWindowPosition] = [], layouts: [SavedWindowLayout] = []) {
        positionEntries = positions.map { $0.json() }
        layoutEntries = layouts.map(\.json)
    }

    init(positionEntries: [JSONValue], layoutEntries: [JSONValue]) {
        self.positionEntries = positionEntries
        self.layoutEntries = layoutEntries
    }

    /// The valid positions, each `id` once.
    public var positions: [CustomWindowPosition] {
        EntryFile.valid(positionEntries, CustomWindowPosition.init(json:), id: \.id)
    }

    /// The valid layouts, each `id` once.
    public var layouts: [SavedWindowLayout] {
        EntryFile.valid(layoutEntries, SavedWindowLayout.init(json:), id: \.id)
    }

    public func position(id: String) -> CustomWindowPosition? { positions.first { $0.id == id } }

    public func layout(id: String) -> SavedWindowLayout? { layouts.first { $0.id == id } }

    public mutating func add(_ position: CustomWindowPosition) {
        positionEntries.append(position.json())
    }

    /// Writes `position` over the one with its id, keeping keys Fudge doesn't know; false when there's none.
    @discardableResult
    public mutating func replace(_ position: CustomWindowPosition) -> Bool {
        EntryFile.replace(
            in: &positionEntries, id: position.id, matching: { CustomWindowPosition(json: $0)?.id },
            with: { position.json(over: $0) })
    }

    @discardableResult
    public mutating func removePosition(id: String) -> Bool {
        let before = positionEntries.count
        positionEntries.removeAll { CustomWindowPosition(json: $0)?.id == id }
        return positionEntries.count != before
    }

    public mutating func add(_ layout: SavedWindowLayout) {
        layoutEntries.append(layout.json)
    }

    /// Renames the layout with `id`, leaving the rest of its entry as it is; false when there's none.
    @discardableResult
    public mutating func renameLayout(id: String, to name: String) -> Bool {
        EntryFile.replace(
            in: &layoutEntries, id: id, matching: { SavedWindowLayout(json: $0)?.id },
            with: { existing in
                var object = existing
                object["name"] = .string(name)
                return .object(object)
            })
    }

    @discardableResult
    public mutating func removeLayout(id: String) -> Bool {
        let before = layoutEntries.count
        layoutEntries.removeAll { SavedWindowLayout(json: $0)?.id == id }
        return layoutEntries.count != before
    }

    /// `window-layouts.json` exists but isn't such an object: Fudge never overwrites it.
    public struct Unreadable: Error, Equatable, CustomStringConvertible {
        public init() {}
        public var description: String {
            "Fudge can't read window-layouts.json, so it leaves the file as it is. Fix or remove it, then try again."
        }
    }

    static let positionsKey = "positions"
    static let layoutsKey = "layouts"
    static let fileKeys = [positionsKey, layoutsKey]

    public static func isWritable(_ file: URL) -> Bool {
        (try? EntryFile.object(at: file, keys: fileKeys)) != nil
    }

    /// The file's positions and layouts; none when it can't be read.
    public static func load(from file: URL) -> WindowLayoutStore {
        let lists = EntryFile.lists(at: file, keys: fileKeys)
        return WindowLayoutStore(
            positionEntries: lists[positionsKey] ?? [], layoutEntries: lists[layoutsKey] ?? [])
    }

    public func save(to file: URL) throws {
        do {
            try EntryFile.save([Self.positionsKey: positionEntries, Self.layoutsKey: layoutEntries], to: file)
        } catch is EntryFile.Unreadable {
            throw Unreadable()
        }
    }

    // MARK: - Rules

    /// A new id: a lowercase UUID, which makes a valid command name after `position-` or `layout-`.
    public static func newID() -> String { UUID().uuidString.lowercased() }

    /// An id makes a command's name, so it follows the name rule (`ExtensionManifest.isValidName`), up to 64
    /// characters.
    static func isValidID(_ id: String) -> Bool {
        id.count <= 64 && ExtensionManifest.isValidName(id)
    }

    /// 1–64 characters, not only whitespace, on one line.
    public static func isValidName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= CustomWindowPosition.nameLimit
            && !name.contains(where: \.isNewline)
    }

    /// Whether two names are the same one: ignoring case and spaces around them.
    static func sameName(_ one: String, _ other: String) -> Bool {
        one.trimmingCharacters(in: .whitespaces).lowercased() == other.trimmingCharacters(in: .whitespaces).lowercased()
    }
}
