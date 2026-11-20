import Foundation

/// fudge's own settings, read from `settings.json` in the support folder.
public struct FudgeSettings: Sendable, Equatable, Codable {
    /// The global shortcut that shows the launcher, e.g. "option+space" or "cmd+shift+k".
    public var hotkey: String?

    public init(hotkey: String? = nil) {
        self.hotkey = hotkey
    }

    public static func load(from file: URL) -> FudgeSettings {
        guard let data = try? Data(contentsOf: file) else { return FudgeSettings() }
        return (try? JSONDecoder().decode(FudgeSettings.self, from: data)) ?? FudgeSettings()
    }
}

/// A keyboard shortcut: one key plus modifiers, using macOS virtual key codes.
public struct HotKeySpec: Sendable, Equatable, CustomStringConvertible {
    public var keyCode: UInt32
    public var key: String
    public var command = false
    public var option = false
    public var control = false
    public var shift = false

    public static let `default` = HotKeySpec.parse("option+space")!

    /// Parses "cmd+shift+space" style text. Modifiers: cmd/command, opt/option/alt, ctrl/control, shift.
    /// Needs at least one modifier, so a plain key can't be grabbed system-wide.
    public static func parse(_ text: String) -> HotKeySpec? {
        let parts = text.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let key = parts.last, let code = keyCodes[key] else { return nil }
        var spec = HotKeySpec(keyCode: code, key: key)
        for modifier in parts.dropLast() {
            switch modifier {
            case "cmd", "command": spec.command = true
            case "opt", "option", "alt": spec.option = true
            case "ctrl", "control": spec.control = true
            case "shift": spec.shift = true
            default: return nil
            }
        }
        guard spec.command || spec.option || spec.control else { return nil }
        return spec
    }

    /// "⌥Space", "⌘⇧K": how macOS menus show shortcuts.
    public var description: String {
        var text = ""
        if control { text += "⌃" }
        if option { text += "⌥" }
        if shift { text += "⇧" }
        if command { text += "⌘" }
        return text + (key.count == 1 ? key.uppercased() : key.capitalized)
    }

    // Virtual key codes from HIToolbox's Events.h (ANSI layout).
    static let keyCodes: [String: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40,
        "n": 45, "m": 46, "return": 36, "tab": 48, "space": 49, "escape": 53, ";": 41, ",": 43, ".": 47,
        "/": 44, "'": 39, "`": 50, "-": 27, "=": 24, "[": 33, "]": 30, "\\": 42,
    ]
}
