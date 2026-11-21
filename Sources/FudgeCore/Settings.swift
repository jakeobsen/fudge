import Foundation

/// fudge's own settings, in `settings.json` in the support folder: the launcher's hotkey, and each command's
/// hotkey, alias and enabled state. Users may edit the file by hand, so reading tolerates anything, and writing
/// keeps keys fudge doesn't know.
public struct FudgeSettings: Sendable, Equatable {
    /// The global shortcut that shows the launcher, e.g. "option+space" or "cmd+shift+k".
    public var hotkey: String?
    /// By command id (`FudgeSettings.commandID`).
    public var commands: [String: CommandSettings]
    /// By extension name.
    public var extensions: [String: ExtensionSettings]
    /// Download exchange rates from the European Central Bank for the calculator. Off unless set.
    public var currencyRates: Bool
    /// How the calculator reads and shows numbers: the Mac's format unless set. An unknown value reads as the Mac's.
    public var numberFormat: NumberFormatSetting
    /// The Extension Store's switch (`extensionStore`); it counts only with the consent date beside it.
    public var extensionStore = false
    /// When the user confirmed the Extension Store's consent sheet (`extensionStoreConsentAt`, ISO 8601).
    public var extensionStoreConsentAt: String?
    /// The sign-in server (`signInServer`): `"fudge"` or a URL; it counts only with the consent date beside it
    /// (`signIn`).
    public var signInServer: String?
    /// When the user confirmed the sign-in server's consent sheet (`signInServerConsentAt`, ISO 8601).
    public var signInServerConsentAt: String?
    /// **Expand Snippets as You Type** (`expandSnippets`, SPEC-078 §5), off by default.
    public var expandSnippets = false
    /// Clipboard history's switch (`clipboardHistory`); it counts only with the consent date beside it.
    public var clipboardHistory = false
    /// When the user confirmed clipboard history's consent sheet (`clipboardHistoryConsentAt`, ISO 8601).
    public var clipboardHistoryConsentAt: String?
    /// **Keep For** (`clipboardHistoryKeepDays`): one of `ClipboardHistory.keepForChoices`; anything else reads as the
    /// default.
    public var clipboardHistoryKeepDays = ClipboardHistory.defaultKeepFor
    /// **Ignore Apps** (`clipboardHistoryIgnoredApps`): bundle ids whose copies aren't kept.
    public var clipboardHistoryIgnoredApps: [String] = []

    /// Whether clipboard history is on: switched on through the consent sheet, which records the date.
    public var isClipboardHistoryOn: Bool {
        clipboardHistory && clipboardHistoryConsentAt.flatMap(ISO8601DateFormatter().date(from:)) != nil
    }

    /// Clipboard history's switch: on records the consent date, off removes both keys.
    public mutating func setClipboardHistory(_ on: Bool, now: Date) {
        clipboardHistory = on
        clipboardHistoryConsentAt = on ? ISO8601DateFormatter().string(from: now) : nil
    }

    /// Whether the Extension Store is on: switched on through the consent sheet, which records the date.
    public var isExtensionStoreOn: Bool {
        extensionStore && extensionStoreConsentAt.flatMap(ISO8601DateFormatter().date(from:)) != nil
    }
    /// How long the panel stays hidden before it opens on root search again (`resetAfterSeconds`).
    public var resetAfter: PanelResetSetting = .default
    /// Which screen the panel opens on (`showOnScreen`).
    public var showOnScreen: ShowOnScreen = .default
    /// What Esc does in the panel (`escapeBehavior`).
    public var escapeBehavior: EscapeBehavior = .default
    /// How often Fudge checks for a new release (`updateCheck`); nil until the user chooses, and nothing is checked
    /// until then. An unknown value reads as unset.
    public var updateCheck: UpdateCheckSetting?
    /// The Color Picker's **Copy Format** (`colorFormat`): HEX unless set. An unknown value reads as HEX.
    public var colorFormat: ColorFormat = .default

    public struct CommandSettings: Sendable, Equatable {
        /// In `HotKeySpec` text form.
        public var hotkey: String?
        public var alias: String?
        /// nil means enabled.
        public var enabled: Bool?

        public init(hotkey: String? = nil, alias: String? = nil, enabled: Bool? = nil) {
            self.hotkey = hotkey
            self.alias = alias
            self.enabled = enabled
        }

        var isDefault: Bool { hotkey == nil && alias == nil && enabled != false }
    }

    public struct ExtensionSettings: Sendable, Equatable {
        /// nil means the default: enabled, except for the Extension Store (`isEnabled(extension:)`).
        public var enabled: Bool?

        public init(enabled: Bool? = nil) {
            self.enabled = enabled
        }
    }

    public init(
        hotkey: String? = nil, commands: [String: CommandSettings] = [:], extensions: [String: ExtensionSettings] = [:],
        currencyRates: Bool = false, numberFormat: NumberFormatSetting = .system
    ) {
        self.hotkey = hotkey
        self.commands = commands
        self.extensions = extensions
        self.currencyRates = currencyRates
        self.numberFormat = numberFormat
    }

    /// A command's key in `commands`: "<extension name>/<command name>".
    public static func commandID(extension extensionName: String, command: String) -> String {
        "\(extensionName)/\(command)"
    }

    /// Whether a command is enabled: neither it nor its extension is disabled.
    public func isEnabled(extension extensionName: String, command: String) -> Bool {
        isEnabled(extension: extensionName)
            && commands[Self.commandID(extension: extensionName, command: command)]?.enabled != false
    }

    /// `isEnabled` for a command id ("<extension name>/<command name>"), split at its first "/".
    public func isEnabled(commandID id: String) -> Bool {
        guard let slash = id.firstIndex(of: "/") else { return true }
        return isEnabled(extension: String(id[..<slash]), command: String(id[id.index(after: slash)...]))
    }

    /// Whether an extension is enabled on the Commands page. Every extension is until it's disabled, except the
    /// bundled Extension Store, which is off until it's enabled. An install from before that, with the store
    /// switched on, counts as enabled until either is changed.
    public func isEnabled(extension name: String) -> Bool {
        if let enabled = extensions[name]?.enabled { return enabled }
        return name == ExtensionStore.extensionName ? isExtensionStoreOn : true
    }

    /// Enables or disables an extension. The store's state is always written, since its default isn't on.
    public mutating func setEnabled(_ enabled: Bool, extension name: String) {
        extensions[name, default: .init()].enabled = enabled && name != ExtensionStore.extensionName ? nil : enabled
    }

    /// The Extension Store's switch: on records the consent date, off removes both keys. The store's Enabled is
    /// written down first, so the switch never changes it, even for an install from before, which takes it from
    /// the switch.
    public mutating func setExtensionStore(_ on: Bool, now: Date) {
        setEnabled(isEnabled(extension: ExtensionStore.extensionName), extension: ExtensionStore.extensionName)
        extensionStore = on
        extensionStoreConsentAt = on ? ISO8601DateFormatter().string(from: now) : nil
    }

    /// Onboarding's Turn On Extension Store, its consent words having been shown: what the switch and its consent
    /// sheet write, and the store's Enabled on the Commands page too, so the store is in root search straight away.
    public mutating func turnOnExtensionStore(now: Date) {
        setExtensionStore(true, now: now)
        setEnabled(true, extension: ExtensionStore.extensionName)
    }

    /// The hotkeys to register: those of the commands in `installed` (command ids) that are enabled. Entries for
    /// commands that aren't installed are kept in the file but aren't available.
    public func availableHotkeys(installed: Set<String>) -> [String: HotKeySpec] {
        commandHotkeys.filter { id, _ in
            guard installed.contains(id), let slash = id.firstIndex(of: "/") else { return false }
            return isEnabled(extension: String(id[..<slash]), command: String(id[id.index(after: slash)...]))
        }
    }

    /// The launcher's hotkey: `hotkey` parsed, else ⌥Space. Setting ⌥Space removes the key, as for other defaults.
    public var launcherHotkey: HotKeySpec {
        get { hotkey.flatMap(HotKeySpec.parse) ?? .default }
        set { hotkey = newValue.sameKeys(as: .default) ? nil : newValue.text }
    }

    /// The hotkeys commands have, parsed; entries that don't parse are left out.
    public var commandHotkeys: [String: HotKeySpec] {
        commands.compactMapValues { $0.hotkey.flatMap(HotKeySpec.parse) }
    }

    /// Reads `file`. A missing or broken file, or a value of the wrong type, reads as the default.
    /// `settings.json` exists but isn't a JSON object (a typo in a hand edit, say), so fudge won't write to it.
    public struct Unreadable: Error, Equatable {}

    /// Whether `save(to:)` may write `file`: it's missing, empty, or a JSON object.
    public static func isWritable(_ file: URL) -> Bool {
        (try? existingObject(at: file)) != nil
    }

    /// The JSON object in `file`; empty when the file is missing or blank. Throws `Unreadable` for anything else.
    private static func existingObject(at file: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        guard let data = try? Data(contentsOf: file) else { throw Unreadable() }
        if String(decoding: data, as: UTF8.self).allSatisfy(\.isWhitespace) { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Unreadable() }
        return object
    }

    /// Reads `file`. A missing or unreadable file reads as the defaults.
    public static func load(from file: URL) -> FudgeSettings {
        guard let object = try? existingObject(at: file) else { return FudgeSettings() }
        var settings = FudgeSettings(
            hotkey: object["hotkey"] as? String, currencyRates: object["currencyRates"] as? Bool ?? false,
            numberFormat: (object["numberFormat"] as? String).flatMap(NumberFormatSetting.init(rawValue:)) ?? .system)
        settings.extensionStore = object["extensionStore"] as? Bool ?? false
        settings.extensionStoreConsentAt = object["extensionStoreConsentAt"] as? String
        settings.signInServer = object["signInServer"] as? String
        settings.signInServerConsentAt = object["signInServerConsentAt"] as? String
        settings.expandSnippets = object["expandSnippets"] as? Bool ?? false
        settings.clipboardHistory = object["clipboardHistory"] as? Bool ?? false
        settings.clipboardHistoryConsentAt = object["clipboardHistoryConsentAt"] as? String
        if let days = object["clipboardHistoryKeepDays"] as? Int, ClipboardHistory.keepForChoices.contains(days) {
            settings.clipboardHistoryKeepDays = days
        }
        settings.clipboardHistoryIgnoredApps = (object["clipboardHistoryIgnoredApps"] as? [Any] ?? [])
            .compactMap { $0 as? String }
        settings.resetAfter = PanelResetSetting(settingsValue: object["resetAfterSeconds"])
        settings.showOnScreen = ShowOnScreen(settingsValue: object["showOnScreen"])
        settings.escapeBehavior = EscapeBehavior(settingsValue: object["escapeBehavior"])
        settings.updateCheck = UpdateCheckSetting(settingsValue: object["updateCheck"])
        settings.colorFormat = (object["colorFormat"] as? String).flatMap(ColorFormat.init(rawValue:)) ?? .default
        for case (let id, let entry as [String: Any]) in object["commands"] as? [String: Any] ?? [:] {
            settings.commands[id] = CommandSettings(
                hotkey: entry["hotkey"] as? String, alias: entry["alias"] as? String, enabled: entry["enabled"] as? Bool
            )
        }
        for case (let name, let entry as [String: Any]) in object["extensions"] as? [String: Any] ?? [:] {
            settings.extensions[name] = ExtensionSettings(enabled: entry["enabled"] as? Bool)
        }
        return settings
    }

    /// Writes to `file` atomically. Keys fudge doesn't know, at any level, are kept; only non-default values are
    /// written, and entries left empty are removed. A file that isn't a JSON object is left alone: this throws
    /// `Unreadable` rather than replace the user's text with fudge's keys.
    public func save(to file: URL) throws {
        var object = try Self.existingObject(at: file)
        object["hotkey"] = hotkey
        object["currencyRates"] = currencyRates ? true : nil
        object["numberFormat"] = numberFormat == .system ? nil : numberFormat.rawValue
        object["extensionStore"] = extensionStore ? true : nil
        object["extensionStoreConsentAt"] = extensionStoreConsentAt
        object["signInServer"] = signInServer
        object["signInServerConsentAt"] = signInServerConsentAt
        object["expandSnippets"] = expandSnippets ? true : nil
        object["clipboardHistory"] = clipboardHistory ? true : nil
        object["clipboardHistoryConsentAt"] = clipboardHistoryConsentAt
        object["clipboardHistoryKeepDays"] =
            clipboardHistoryKeepDays == ClipboardHistory.defaultKeepFor ? nil : clipboardHistoryKeepDays
        object["clipboardHistoryIgnoredApps"] = clipboardHistoryIgnoredApps.isEmpty ? nil : clipboardHistoryIgnoredApps
        object["resetAfterSeconds"] = resetAfter.settingsValue
        object["showOnScreen"] = showOnScreen.settingsValue
        object["escapeBehavior"] = escapeBehavior.settingsValue
        object["updateCheck"] = updateCheck?.rawValue
        object["colorFormat"] = colorFormat == .default ? nil : colorFormat.rawValue

        var commandObjects = object["commands"] as? [String: Any] ?? [:]
        let commandIDs = Set(commandObjects.keys).union(commands.keys)
        for id in commandIDs {
            var entry = commandObjects[id] as? [String: Any] ?? [:]
            let settings = commands[id] ?? CommandSettings()
            entry["hotkey"] = settings.hotkey
            entry["alias"] = settings.alias
            entry["enabled"] = settings.enabled == false ? false : nil
            commandObjects[id] = entry.isEmpty ? nil : entry
        }
        object["commands"] = commandObjects.isEmpty ? nil : commandObjects

        var extensionObjects = object["extensions"] as? [String: Any] ?? [:]
        for name in Set(extensionObjects.keys).union(extensions.keys) {
            var entry = extensionObjects[name] as? [String: Any] ?? [:]
            let enabled = extensions[name]?.enabled
            entry["enabled"] = name == ExtensionStore.extensionName ? enabled : (enabled == false ? false : nil)
            extensionObjects[name] = entry.isEmpty ? nil : entry
        }
        object["extensions"] = extensionObjects.isEmpty ? nil : extensionObjects

        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }
}

/// A keyboard shortcut: one physical key (a macOS virtual key code) plus modifiers. Its text form is
/// "option+s", "cmd+shift+k" or "f5"; a key with no name is "keycode:<n>", so any recorded key survives a reload.
public struct HotKeySpec: Sendable, Hashable, CustomStringConvertible {
    public var keyCode: UInt32
    /// The key's name in the text form: "s", "space", "f5", "left", "keypad5", "keycode:93".
    public var key: String
    public var command = false
    public var option = false
    public var control = false
    public var shift = false

    public static let `default` = HotKeySpec.parse("option+space")!

    public init(
        keyCode: UInt32, command: Bool = false, option: Bool = false, control: Bool = false, shift: Bool = false
    ) {
        self.keyCode = keyCode
        self.key = Self.names[keyCode] ?? "keycode:\(keyCode)"
        self.command = command
        self.option = option
        self.control = control
        self.shift = shift
    }

    /// Parses the text form. Modifiers: cmd/command, opt/option/alt, ctrl/control, shift. It needs one of ⌘ ⌥ ⌃,
    /// so a plain key can't be grabbed system-wide, except F1–F20, which may stand alone.
    public static func parse(_ text: String) -> HotKeySpec? {
        let parts = text.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let key = parts.last, let code = keyCodes[key] ?? unnamedKeyCode(key) else { return nil }
        var spec = HotKeySpec(keyCode: code)
        for modifier in parts.dropLast() {
            switch modifier {
            case "cmd", "command": spec.command = true
            case "opt", "option", "alt": spec.option = true
            case "ctrl", "control": spec.control = true
            case "shift": spec.shift = true
            default: return nil
            }
        }
        return spec.isAllowed ? spec : nil
    }

    private static func unnamedKeyCode(_ key: String) -> UInt32? {
        guard key.hasPrefix("keycode:"), let code = UInt32(key.dropFirst("keycode:".count)), code < 128 else {
            return nil
        }
        return code
    }

    /// Whether it may be a global hotkey: with one of ⌘ ⌥ ⌃, or an F-key alone.
    public var isAllowed: Bool { command || option || control || isFunctionKey }

    public var isFunctionKey: Bool { Self.functionKeys.values.contains(keyCode) }

    /// The text form, modifiers in macOS's order: "ctrl+option+shift+cmd+k".
    public var text: String {
        var parts: [String] = []
        if control { parts.append("ctrl") }
        if option { parts.append("option") }
        if shift { parts.append("shift") }
        if command { parts.append("cmd") }
        return (parts + [key]).joined(separator: "+")
    }

    /// The modifiers as macOS shows them, in its order: ⌃ ⌥ ⇧ ⌘.
    public var modifierSymbols: [String] {
        [(control, "⌃"), (option, "⌥"), (shift, "⇧"), (command, "⌘")].filter(\.0).map(\.1)
    }

    /// The key as shown without a keyboard layout: "S", "Space", "F5", "←", "Keypad 5", "Key 93". The app shows
    /// character keys as the current layout types them instead.
    public var keyLabel: String {
        if let symbol = Self.symbols[key] { return symbol }
        if key.hasPrefix("keycode:") { return "Key \(key.dropFirst("keycode:".count))" }
        if key.hasPrefix("keypad") { return "Keypad \(key.dropFirst("keypad".count).capitalized)" }
        if key.count == 1 { return key.uppercased() }
        return key.capitalized
    }

    /// "⌥Space", "⇧⌘K": how macOS menus show shortcuts.
    public var description: String { modifierSymbols.joined() + keyLabel }

    /// Whether `other` is the same keys, whatever the names.
    public func sameKeys(as other: HotKeySpec) -> Bool {
        keyCode == other.keyCode && command == other.command && option == other.option && control == other.control
            && shift == other.shift
    }

    // Virtual key codes from HIToolbox's Events.h, named as on an ANSI layout.
    static let functionKeys: [String: UInt32] = [
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109,
        "f11": 103, "f12": 111, "f13": 105, "f14": 107, "f15": 113, "f16": 106, "f17": 64, "f18": 79, "f19": 80,
        "f20": 90,
    ]

    static let keyCodes: [String: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40,
        "n": 45, "m": 46, "return": 36, "tab": 48, "space": 49, "escape": 53, ";": 41, ",": 43, ".": 47,
        "/": 44, "'": 39, "`": 50, "-": 27, "=": 24, "[": 33, "]": 30, "\\": 42,
        // The ISO key left of 1 (§ on Danish and other ISO keyboards).
        "§": 10,
        "left": 123, "right": 124, "down": 125, "up": 126, "delete": 51, "forwarddelete": 117, "home": 115,
        "end": 119, "pageup": 116, "pagedown": 121, "enter": 76, "clear": 71,
        "keypad0": 82, "keypad1": 83, "keypad2": 84, "keypad3": 85, "keypad4": 86, "keypad5": 87, "keypad6": 88,
        "keypad7": 89, "keypad8": 91, "keypad9": 92, "keypaddecimal": 65, "keypadmultiply": 67, "keypadplus": 69,
        "keypaddivide": 75, "keypadminus": 78, "keypadequals": 81,
    ].merging(functionKeys) { first, _ in first }

    static let names: [UInt32: String] = Dictionary(keyCodes.map { ($1, $0) }, uniquingKeysWith: { first, _ in first })

    static let symbols: [String: String] = [
        "left": "←", "right": "→", "down": "↓", "up": "↑", "delete": "⌫", "forwarddelete": "⌦", "home": "↖",
        "end": "↘", "pageup": "⇞", "pagedown": "⇟", "return": "↩", "enter": "⌤", "tab": "⇥", "escape": "⎋",
        "space": "Space", "clear": "Clear", "keypaddecimal": "Keypad .", "keypadmultiply": "Keypad *",
        "keypadplus": "Keypad +", "keypaddivide": "Keypad /", "keypadminus": "Keypad -", "keypadequals": "Keypad =",
    ].merging(functionKeys.keys.map { ($0, $0.uppercased()) }) { first, _ in first }
}
