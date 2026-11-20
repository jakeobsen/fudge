import Foundation

/// What the user enters into a command's `arguments` in root search: one field per argument after the query,
/// Tab and ⇧Tab to move between them, and a check that the required ones are filled before the command launches.
public struct ArgumentInput: Sendable, Equatable {
    public typealias Argument = ExtensionManifest.Argument

    public private(set) var arguments: [Argument]
    /// What the user entered, by argument name.
    public private(set) var values: [String: String] = [:]
    /// The argument that has the keyboard; nil for the search field.
    public var focus: Int?
    /// The required argument that was empty when the user tried to launch, until it gets a value.
    public private(set) var missing: Int?

    public init(arguments: [Argument] = []) {
        self.arguments = arguments
    }

    public var isEmpty: Bool { arguments.isEmpty }

    public func value(at index: Int) -> String {
        guard arguments.indices.contains(index) else { return "" }
        return values[arguments[index].name] ?? ""
    }

    public mutating func set(_ value: String, at index: Int) {
        guard arguments.indices.contains(index) else { return }
        values[arguments[index].name] = value
        if missing == index, !value.isEmpty { missing = nil }
    }

    /// Tab: from the search field to the first argument, on to each next one, then back to the search field.
    public mutating func focusNext() {
        guard !arguments.isEmpty else { return }
        focus = focus.map { $0 + 1 < arguments.count ? $0 + 1 : nil } ?? 0
    }

    /// ⇧Tab: the same, the other way round.
    public mutating func focusPrevious() {
        guard !arguments.isEmpty else { return }
        focus = focus.map { $0 > 0 ? $0 - 1 : nil } ?? arguments.count - 1
    }

    /// ↑ and ↓ on a dropdown argument: the previous or next of its values. With no value yet, ↓ picks the first
    /// and ↑ the last.
    public mutating func step(dropdown index: Int, by offset: Int) {
        guard arguments.indices.contains(index), let options = arguments[index].data, !options.isEmpty else { return }
        let next: Int
        if let current = options.firstIndex(where: { $0.value == value(at: index) }) {
            next = max(0, min(options.count - 1, current + offset))
        } else {
            next = offset > 0 ? 0 : options.count - 1
        }
        set(options[next].value, at: index)
    }

    /// Before a launch: true when every required argument has a value. Otherwise moves the keyboard to the first
    /// empty one and marks it as missing.
    public mutating func checkRequired() -> Bool {
        let empty = arguments.indices.first { arguments[$0].required == true && value(at: $0).isEmpty }
        guard let empty else { return true }
        focus = empty
        missing = empty
        return false
    }

    /// `launchProps.arguments`: every argument by name, with an empty string for those left empty.
    public var launchArguments: [String: String] {
        Dictionary(arguments.map { ($0.name, values[$0.name] ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    public enum KeyResult: Sendable, Equatable {
        /// Not an argument key; it goes on to the focused field.
        case ignored
        case handled
        /// Launch the command (↵ or keypad Enter on a dropdown argument; text fields submit on their own).
        case submit
    }

    /// The keys root search gives the arguments: Tab and ⇧Tab move between the fields, even with no arguments, so
    /// the keyboard never leaves the search bar. In an argument, Esc goes back to the search field, ⌫ in an empty
    /// one goes back a field, and ↑↓ change a dropdown's value instead of moving the selection.
    public mutating func handle(_ pressed: KeyShortcut) -> KeyResult {
        switch pressed {
        case KeyShortcut(key: "tab", modifiers: []):
            focusNext()
            return .handled
        case KeyShortcut(key: "tab", modifiers: ["shift"]):
            focusPrevious()
            return .handled
        default:
            break
        }
        guard let index = focus, arguments.indices.contains(index) else { return .ignored }
        let isDropdown = arguments[index].type == "dropdown"
        switch pressed {
        case KeyShortcut(key: "escape", modifiers: []):
            focus = nil
            return .handled
        case KeyShortcut(key: "arrowUp", modifiers: []):
            if isDropdown { step(dropdown: index, by: -1) }
            return .handled
        case KeyShortcut(key: "arrowDown", modifiers: []):
            if isDropdown { step(dropdown: index, by: 1) }
            return .handled
        case KeyShortcut(key: "delete", modifiers: []):
            guard value(at: index).isEmpty else {
                // A dropdown has no text to delete: ⌫ clears its value.
                if isDropdown { set("", at: index) }
                return isDropdown ? .handled : .ignored
            }
            focusPrevious()
            return .handled
        case KeyShortcut(key: "return", modifiers: []), KeyShortcut(key: "enter", modifiers: []):
            return isDropdown ? .submit : .ignored
        default:
            return .ignored
        }
    }
}
