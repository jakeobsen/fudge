import Foundation

/// A keyboard shortcut as extensions write them: Raycast's key names ("c", "arrowUp", "return")
/// and modifiers ("cmd", "ctrl", "opt", "shift"; "alt" means "opt").
public struct KeyShortcut: Sendable, Hashable, CustomStringConvertible {
    public var key: String
    public var modifiers: Set<String>

    public init(key: String, modifiers: Set<String>) {
        self.key = key.count == 1 ? key.lowercased() : key
        self.modifiers = Set(modifiers.map { $0 == "alt" ? "opt" : $0 })
    }

    /// Reads `{ modifiers, key }`, or the macOS half of `{ macOS: {…}, Windows: {…} }`.
    public init?(json: JSONValue?) {
        guard case .object(var object) = json else { return nil }
        if case .object(let macOS) = object["macOS"] { object = macOS }
        guard case .string(let key) = object["key"] else { return nil }
        var modifiers: Set<String> = []
        if case .array(let values) = object["modifiers"] {
            for case .string(let modifier) in values { modifiers.insert(modifier) }
        }
        self.init(key: key, modifiers: modifiers)
    }

    /// How macOS menus show it: ⌃⌥⇧⌘ then the key, e.g. "⇧⌘C", "⌘↵", "⌃X".
    public var description: String {
        var text = ""
        for (modifier, symbol) in [("ctrl", "⌃"), ("opt", "⌥"), ("shift", "⇧"), ("cmd", "⌘")]
        where modifiers.contains(modifier) {
            text += symbol
        }
        return text + (Self.symbols[key] ?? key.uppercased())
    }

    static let symbols: [String: String] = [
        "return": "↵", "enter": "⌅", "delete": "⌫", "backspace": "⌫", "deleteForward": "⌦", "tab": "⇥",
        "escape": "⎋", "space": "Space", "arrowUp": "↑", "arrowDown": "↓", "arrowLeft": "←", "arrowRight": "→",
        "pageUp": "⇞", "pageDown": "⇟", "home": "↖", "end": "↘",
    ]

    /// The Raycast key name for a key press: special keys by virtual key code, others by their character.
    /// `characters` must be what the key types with no modifier at all, ⇧ included (AppKit's
    /// `characters(byApplyingModifiers: [])`). `charactersIgnoringModifiers` still applies ⇧, so ⌘⇧, would arrive
    /// as "<" on a US keyboard and ";" on a Danish one, and never match a shortcut written as `,`.
    public static func key(forKeyCode keyCode: UInt16, characters: String?) -> String? {
        if let special = specialKeys[keyCode] { return special }
        guard let character = characters?.lowercased(), character.count == 1 else { return nil }
        return character
    }

    /// A key press as a shortcut: the key named as in `key(forKeyCode:characters:)`, with the modifiers held.
    public init?(keyCode: UInt16, characters: String?, modifiers: Set<String>) {
        guard let key = Self.key(forKeyCode: keyCode, characters: characters) else { return nil }
        self.init(key: key, modifiers: modifiers)
    }

    // Virtual key codes from HIToolbox's Events.h.
    static let specialKeys: [UInt16: String] = [
        36: "return", 76: "enter", 48: "tab", 49: "space", 51: "delete", 117: "deleteForward", 53: "escape",
        126: "arrowUp", 125: "arrowDown", 123: "arrowLeft", 124: "arrowRight",
        116: "pageUp", 121: "pageDown", 115: "home", 119: "end",
    ]
}

/// One entry of an action panel: an action, or a submenu holding more.
public struct ActionEntry: Sendable, Equatable, Identifiable {
    public var id: Int
    public var title: String
    public var icon: JSONValue?
    public var shortcut: KeyShortcut?
    public var destructive: Bool
    /// Set for submenus (possibly empty while it loads).
    public var submenu: [ActionSection]?
    public var isLoading: Bool
    /// What running it does.
    public var target: ActionTarget

    public var isSubmenu: Bool { submenu != nil }
}

/// What an action panel entry runs: an extension's `Action` node, or one of fudge's own actions in root search.
public enum ActionTarget: Sendable, Equatable {
    /// The node's `onAction`, in the running command.
    case node(Int)
    case root(RootAction)
}

/// fudge's own actions on a root search item.
public enum RootAction: Sendable, Equatable {
    /// What ↵ does: run the command, open the application, or open the Settings window.
    case open
    /// Opens the Settings window on an extension's preferences.
    case configureExtension(String)
    /// Shows an application in Finder.
    case showInFinder(URL)
    /// Copies the Calculator card's answer.
    case copyAnswer
    /// Copies the Calculator card's question and answer, as `question = answer`.
    case copyQuestionAndAnswer
}

/// The action panel of a root search item, and fudge's keys for the Settings window.
public enum RootActions {
    /// ⌘, opens the Settings window on its default page.
    public static let settingsShortcut = KeyShortcut(key: ",", modifiers: ["cmd"])
    /// ⌘⇧, opens it on the extension of the command that's selected or running.
    public static let configureExtensionShortcut = KeyShortcut(key: ",", modifiers: ["cmd", "shift"])
    public static let showInFinderShortcut = KeyShortcut(key: "f", modifiers: ["cmd", "shift"])
    public static let copyQuestionAndAnswerShortcut = KeyShortcut(key: "c", modifiers: ["cmd", "shift"])
    static let enter = KeyShortcut(key: "return", modifiers: [])

    /// The entries for the Calculator card, the first one being what ↵ does.
    public static func calculatorSections() -> [ActionSection] {
        section([
            ("Copy Answer", enter, .copyAnswer),
            ("Copy Question and Answer", copyQuestionAndAnswerShortcut, .copyQuestionAndAnswer),
        ])
    }

    /// The entries for `item`, the first one being what ↵ does.
    public static func sections(for item: RootItem?) -> [ActionSection] {
        guard let item else { return [] }
        let entries: [(String, KeyShortcut, RootAction)] =
            switch item.kind {
            case .command(let extensionName, _, _, _):
                [
                    ("Open Command", enter, .open),
                    ("Configure Extension", configureExtensionShortcut, .configureExtension(extensionName)),
                ]
            case .application(let url):
                [("Open Application", enter, .open), ("Show in Finder", showInFinderShortcut, .showInFinder(url))]
            case .settings:
                [("Open Settings", enter, .open)]
            }
        return section(entries)
    }

    private static func section(_ entries: [(String, KeyShortcut, RootAction)]) -> [ActionSection] {
        [
            ActionSection(
                title: nil,
                entries: entries.enumerated().map { index, entry in
                    ActionEntry(
                        id: index + 1, title: entry.0, icon: nil, shortcut: entry.1, destructive: false, submenu: nil,
                        isLoading: false, target: .root(entry.2))
                }
            )
        ]
    }
}

public struct ActionSection: Sendable, Equatable {
    public var title: String?
    public var entries: [ActionEntry]
}

/// The actions of an ActionPanel node, as sections.
public enum ActionPanelReader {
    public static func sections(of panel: UINode?) -> [ActionSection] {
        guard let panel else { return [] }
        return sections(in: panel.children)
    }

    static func sections(in children: [UINode]) -> [ActionSection] {
        var sections: [ActionSection] = []
        var loose: [ActionEntry] = []
        func flushLoose() {
            if !loose.isEmpty { sections.append(ActionSection(title: nil, entries: loose)) }
            loose = []
        }
        for child in children {
            if child.type == "ActionPanel.Section" {
                flushLoose()
                let entries = child.children.compactMap(entry)
                if !entries.isEmpty { sections.append(ActionSection(title: child.string("title"), entries: entries)) }
            } else if let entry = entry(child) {
                loose.append(entry)
            }
        }
        flushLoose()
        return sections
    }

    static func entry(_ node: UINode) -> ActionEntry? {
        switch node.type {
        case "Action":
            return ActionEntry(
                id: node.id,
                title: node.string("title") ?? "",
                icon: node.props["icon"],
                shortcut: KeyShortcut(json: node.props["shortcut"]),
                destructive: node.string("style") == "destructive",
                submenu: nil,
                isLoading: false,
                target: .node(node.id)
            )
        case "ActionPanel.Submenu":
            return ActionEntry(
                id: node.id,
                title: node.string("title") ?? "",
                icon: node.props["icon"],
                shortcut: KeyShortcut(json: node.props["shortcut"]),
                destructive: false,
                submenu: sections(in: node.children),
                isLoading: node.bool("isLoading") == true,
                target: .node(node.id)
            )
        default:
            return nil
        }
    }

    /// Every entry in order, sections flattened, submenus not opened.
    public static func flat(_ sections: [ActionSection]) -> [ActionEntry] {
        sections.flatMap(\.entries)
    }

    /// ↵ runs the first entry and ⌘↵ the second.
    public static func primary(_ sections: [ActionSection]) -> ActionEntry? { flat(sections).first }

    public static func secondary(_ sections: [ActionSection]) -> ActionEntry? { flat(sections).dropFirst().first }

    /// The action whose shortcut is `pressed`, searching submenus too.
    public static func action(for pressed: KeyShortcut, in sections: [ActionSection]) -> ActionEntry? {
        for entry in flat(sections) {
            if entry.shortcut == pressed, !entry.isSubmenu { return entry }
            if let submenu = entry.submenu, let found = action(for: pressed, in: submenu) { return found }
        }
        return nil
    }

    /// Sections filtered to entries whose title matches `query`, keeping section titles.
    public static func filter(_ sections: [ActionSection], query: String) -> [ActionSection] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return sections }
        return sections.compactMap { section in
            let entries = section.entries.filter { Fuzzy.match(trimmed, in: $0.title) != nil }
            return entries.isEmpty ? nil : ActionSection(title: section.title, entries: entries)
        }
    }
}
