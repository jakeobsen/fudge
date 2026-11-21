import CoreGraphics
import Foundation

// Saving and applying layouts (SPEC-094 §2), the user's own commands in the Window Management group, and what the
// Settings page and the Save Layout form edit.

/// What applying a saved layout did, for the HUD.
public struct LayoutPlacement: Sendable, Equatable {
    public var placed: Int
    public var skipped: Int

    public init(placed: Int, skipped: Int) {
        self.placed = placed
        self.skipped = skipped
    }

    /// "Placed 5 windows; skipped 2", or "Placed 1 window" when none was skipped.
    public var message: String {
        let placedText = "Placed \(placed) \(placed == 1 ? "window" : "windows")"
        return skipped == 0 ? placedText : "\(placedText); skipped \(skipped)"
    }
}

extension WindowManager {
    /// Save Layout… (SPEC-094 §2): every standard window of the regular apps on the screens now, front to back. Each
    /// is kept as its app's bundle id, its place among that app's standard windows (front to back), its screen (by
    /// name and place in the screen list) and its frame as fractions of that screen's visible frame; never its title.
    /// A full-screen window, or one with no part inside its screen's visible frame, isn't kept, but still counts in
    /// its app's places, so applying finds the others where they were.
    public func captureLayout() -> [SavedWindow] {
        let reading = Reading(self)
        var saved: [SavedWindow] = []
        for (bundleId, windows) in reading.standardWindowsByApp().sorted(by: { $0.key < $1.key }) {
            for (index, listed) in windows.enumerated() {
                guard let ax = reading.ax(for: listed), !ax.fullScreen,
                    let screen = reading.screen(of: listed), let place = reading.screens.firstIndex(of: screen),
                    let frame = WindowFractions(ax.frame ?? listed.bounds, in: screen.visibleBounds)
                else { continue }
                saved.append(
                    SavedWindow(
                        bundleId: bundleId, index: index, screen: SavedScreen(name: screen.name, index: place),
                        frame: frame))
            }
        }
        return saved
    }

    /// "Apply <name>": puts each saved window where it was, as a custom position would, on the screen it was on
    /// (`SavedScreen.match`). A window whose app isn't running, a place its app has no window in now, a full-screen
    /// window and one the app won't move are skipped; no app is launched. Each moved window's frame before is
    /// remembered for Restore.
    public func apply(_ layout: SavedWindowLayout, frames: inout WindowFrames) -> LayoutPlacement {
        let reading = Reading(self)
        frames.keep(only: Set(reading.windows.map(\.number)))
        let byApp = reading.standardWindowsByApp()
        var result = LayoutPlacement(placed: 0, skipped: 0)
        for saved in layout.windows {
            guard let windows = byApp[saved.bundleId], windows.indices.contains(saved.index),
                let ax = reading.ax(for: windows[saved.index]), !ax.fullScreen,
                let screen = saved.screen.match(in: reading.screens)
            else {
                result.skipped += 1
                continue
            }
            let listed = windows[saved.index]
            let current = ax.frame ?? listed.bounds
            let visible = screen.visibleBounds
            guard place(ax, at: saved.frame.frame(in: visible), current: current, in: visible) == .done else {
                result.skipped += 1
                continue
            }
            frames.remember(current, of: listed.number)
            result.placed += 1
        }
        return result
    }
}

extension WindowManager.Reading {
    /// Each app's windows that saved layouts take, by bundle id: its listed windows paired with a standard AX
    /// window, front to back. Every process of one bundle id counts as that app.
    func standardWindowsByApp() -> [String: [ListedWindow]] {
        var byApp: [String: [ListedWindow]] = [:]
        for listed in windows {
            guard case .object(let application) = application(listed.pid),
                case .string(let bundleId) = application["bundleId"], !bundleId.isEmpty,
                let ax = ax(for: listed), ax.standard
            else { continue }
            byApp[bundleId, default: []].append(listed)
        }
        return byApp
    }
}

// MARK: - The commands

/// One of the user's own commands in the Window Management group.
public enum UserWindowCommand: Sendable, Equatable {
    case saveLayout
    case position(CustomWindowPosition)
    case layout(SavedWindowLayout)
}

extension WindowLayoutStore {
    /// Save Layout…'s command name.
    public static let saveLayoutCommand = "save-layout"

    /// Save Layout…, then the custom positions and "Apply <name>" for each layout, each by name.
    public var commands: [BuiltInCommand] {
        let save = BuiltInCommand(
            name: Self.saveLayoutCommand, title: "Save Layout…", keywords: ["layout", "arrange", "save", "window"],
            symbol: "square.and.arrow.down.on.square")
        let positions = Self.byName(positions, \.name).map { position in
            BuiltInCommand(
                name: position.commandName, title: position.name, keywords: ["position", "custom", "window"],
                symbol: "square.on.square.dashed")
        }
        let layouts = Self.byName(layouts, \.name).map { layout in
            BuiltInCommand(
                name: layout.commandName, title: layout.commandTitle, keywords: ["layout", "arrange", "window"],
                symbol: "rectangle.3.group")
        }
        return [save] + positions + layouts
    }

    /// The command `name` names, if it's one of these.
    public func command(named name: String) -> UserWindowCommand? {
        if name == Self.saveLayoutCommand { return .saveLayout }
        if let position = positions.first(where: { $0.commandName == name }) { return .position(position) }
        if let layout = layouts.first(where: { $0.commandName == name }) { return .layout(layout) }
        return nil
    }

    /// As the Settings page and the commands list them: by name, as Finder sorts.
    public static func byName<Entry>(_ entries: [Entry], _ name: (Entry) -> String) -> [Entry] {
        entries.sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
    }
}

extension BuiltInCommandGroup {
    /// Fudge's groups, with the user's own commands (`WindowLayoutStore.commands`) after Window Management's.
    public static func all(with layouts: WindowLayoutStore) -> [BuiltInCommandGroup] {
        all.map { group in
            guard group.name == windowManagement.name else { return group }
            var group = group
            group.commands += layouts.commands
            return group
        }
    }
}

// MARK: - Editing them

extension String {
    fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// A custom position in the Settings page's sheet: its name, and x, y, width and height as percentages, as typed.
public struct PositionDraft: Sendable, Equatable {
    /// The position being edited; nil for a new one.
    public var id: String?
    public var name: String
    public var x: String
    public var y: String
    public var width: String
    public var height: String

    /// A new position: the left half, to start from.
    public init(name: String = "", x: String = "0", y: String = "0", width: String = "50", height: String = "100") {
        self.name = name
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(editing position: CustomWindowPosition) {
        self.init(
            name: position.name, x: Self.percent(position.frame.x), y: Self.percent(position.frame.y),
            width: Self.percent(position.frame.width), height: Self.percent(position.frame.height))
        id = position.id
    }

    public struct Problems: Sendable, Equatable {
        public var name: String?
        /// One for the four values together.
        public var frame: String?

        public init(name: String? = nil, frame: String? = nil) {
            self.name = name
            self.frame = frame
        }

        public var isEmpty: Bool { name == nil && frame == nil }
    }

    /// The four values as fractions, when each is a number (a `%` after it, and a decimal comma, are fine);
    /// whether they make a valid frame is `problems`' to say.
    public var fractions: WindowFractions? {
        guard let x = Self.number(x), let y = Self.number(y), let width = Self.number(width),
            let height = Self.number(height)
        else { return nil }
        return WindowFractions(x: x / 100, y: y / 100, width: width / 100, height: height / 100)
    }

    /// What's wrong with it among the positions already saved (the edited one left out): a name of 1–64
    /// characters on one line that no other position has, ignoring case and spaces around it; each value a
    /// percentage from 0 to 100; a width and height above 0; and the frame inside the screen.
    public func problems(among existing: [CustomWindowPosition]) -> Problems {
        var problems = Problems()
        let name = name.trimmed
        if name.isEmpty {
            problems.name = "Enter a name."
        } else if name.count > CustomWindowPosition.nameLimit || name.contains(where: \.isNewline) {
            problems.name = "Use at most \(CustomWindowPosition.nameLimit) characters, on one line."
        } else if existing.contains(where: { $0.id != id && WindowLayoutStore.sameName($0.name, name) }) {
            problems.name = "Another position is called “\(name)”."
        }
        if let frame = fractions {
            let values = [frame.x, frame.y, frame.width, frame.height]
            if !values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) {
                problems.frame = "Each value is a percentage from 0 to 100."
            } else if frame.width <= 0 || frame.height <= 0 {
                problems.frame = "Width and height must be more than 0%."
            } else if !frame.isValid {
                problems.frame = "It must fit on the screen: X + Width and Y + Height at most 100%."
            }
        } else {
            problems.frame = "Each value is a percentage from 0 to 100."
        }
        return problems
    }

    /// Saves it, once `problems` is empty: a new position, or over the edited one by `id`. The name is trimmed.
    @discardableResult
    public func save(into store: inout WindowLayoutStore) -> CustomWindowPosition? {
        guard let frame = fractions, frame.isValid else { return nil }
        let position = CustomWindowPosition(id: id ?? WindowLayoutStore.newID(), name: name.trimmed, frame: frame)
        if !store.replace(position) { store.add(position) }
        return position
    }

    /// A fraction as a percentage to edit: at most two decimals, without trailing zeros ("70", "33.33").
    static func percent(_ fraction: Double) -> String {
        var text = String(format: "%.2f", fraction * 100)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text == "-0" ? "0" : text
    }

    static func number(_ text: String) -> Double? {
        var text = text.trimmed
        if text.hasSuffix("%") { text = String(text.dropLast()).trimmed }
        text = text.replacingOccurrences(of: ",", with: ".")
        guard !text.isEmpty, let value = Double(text), value.isFinite else { return nil }
        return value
    }
}

/// A layout's name: in the Save Layout form, with the windows it saves, or in the Settings page's Rename sheet.
public struct LayoutDraft: Sendable, Equatable {
    /// The layout being renamed; nil for a new one.
    public var id: String?
    public var name: String
    /// The windows a new layout saves.
    public var windows: [SavedWindow]

    public init(name: String = "", windows: [SavedWindow]) {
        self.name = name
        self.windows = windows
    }

    public init(renaming layout: SavedWindowLayout) {
        self.init(name: layout.name, windows: layout.windows)
        id = layout.id
    }

    /// The name's problem among the layouts already saved (the renamed one left out): 1–64 characters on one line
    /// that no other layout has, ignoring case and spaces around it.
    public func problem(among existing: [SavedWindowLayout]) -> String? {
        let name = name.trimmed
        if name.isEmpty { return "Enter a name." }
        if name.count > CustomWindowPosition.nameLimit || name.contains(where: \.isNewline) {
            return "Use at most \(CustomWindowPosition.nameLimit) characters, on one line."
        }
        if existing.contains(where: { $0.id != id && WindowLayoutStore.sameName($0.name, name) }) {
            return "Another layout is called “\(name)”."
        }
        return nil
    }

    /// Saves it, once `problem` is nil: a new layout with its windows, or the renamed one's new name.
    public func save(into store: inout WindowLayoutStore, now: Date = Date()) {
        if let id {
            store.renameLayout(id: id, to: name.trimmed)
        } else {
            store.add(SavedWindowLayout(name: name.trimmed, windows: windows, createdAt: now.formatted(.iso8601)))
        }
    }

    /// "5 windows of 3 apps".
    public var summary: String {
        let apps = Set(windows.map(\.bundleId)).count
        return "\(windows.count) \(windows.count == 1 ? "window" : "windows") of \(apps) \(apps == 1 ? "app" : "apps")"
    }
}

/// The Save Layout form, built here and shown by the app like an extension's Form, as `SnippetForm` is: a Name field
/// with a fixed node id, what it saves, and Save Layout. Nothing of it reaches the host.
public enum LayoutForm {
    public static let session = "fudge:layout-form"
    public static let title = "Save Layout"

    public enum Node {
        public static let form = 1
        public static let name = 2
        public static let windows = 3
        public static let actions = 4
        public static let save = 5
    }

    public enum Field {
        public static let name = "name"
    }

    public static func view(draft: LayoutDraft, problem: String? = nil) -> UINode {
        var name: [String: JSONValue] = [
            "id": .string(Field.name), "title": .string("Name"), "placeholder": .string("Layout name"),
            "defaultValue": .string(draft.name),
            "info": .string("Apply it with “Apply <name>”: each app's windows go back where they are now."),
        ]
        if let problem { name["error"] = .string(problem) }
        let save = UINode(
            id: Node.save, type: "Action", props: ["title": .string("Save Layout"), "icon": .string("checkmark-16")])
        let actions = UINode(id: Node.actions, type: "ActionPanel", children: [save])
        return UINode(
            id: Node.form, type: "Form",
            props: ["navigationTitle": .string(title), "actions": actions.json],
            children: [
                UINode(id: Node.name, type: "Form.TextField", props: name),
                UINode(
                    id: Node.windows, type: "Form.Description",
                    props: ["title": .string("Saves"), "text": .string(draft.summary)]),
            ])
    }

    /// `draft` with the name the form's field holds.
    public static func draft(_ draft: LayoutDraft, with values: [String: JSONValue]) -> LayoutDraft {
        var draft = draft
        if case .string(let name) = values[Field.name] { draft.name = name }
        return draft
    }
}
