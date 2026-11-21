import Foundation

/// Hyperkey (SPEC-093, FUD-125): while it's on, holding Caps Lock acts as ⌘⌥⌃⇧ (Hyper). Caps Lock is remapped to
/// F18, a key no keyboard has, with macOS's per-user key mapping (`hidutil`, `HyperkeyMapping`), and an event tap
/// adds the four modifiers to every key pressed while F18 is held (`HyperTap`). The logic is here; the app makes the
/// system calls, behind `KeyMappingSystem` and its own tap, so no test runs `hidutil` or creates a tap.
public enum Hyperkey {
    /// HID usages on the keyboard page (7), as `hidutil`'s `UserKeyMapping` names keys.
    public static let capsLockUsage: UInt64 = 0x7_0000_0039
    public static let f18Usage: UInt64 = 0x7_0000_006D
    /// F18's virtual key code (`kVK_F18`), which the remapped Caps Lock types.
    public static let f18KeyCode: UInt16 = 79
    /// A press of Caps Lock shorter than this, with no other key, toggles caps when **Quick press toggles Caps Lock**
    /// is on.
    public static let quickPress: UInt64 = 200_000_000

    /// Why it's off in password fields, shown under the switch.
    public static let explanation =
        "Hold Caps Lock to press ⌘⌥⌃⇧ at once, so shortcuts like Hyper+T don't clash with other apps. It doesn't work "
        + "in password fields."
}

/// One entry of `hidutil`'s `UserKeyMapping`: the key pressed and the key it types, as HID usages.
public struct KeyRemap: Sendable, Hashable {
    public var source: UInt64
    public var destination: UInt64

    public init(source: UInt64, destination: UInt64) {
        self.source = source
        self.destination = destination
    }
}

/// Reads and writes macOS's per-user key mapping. The app's runs `/usr/bin/hidutil`; tests use a fake.
public protocol KeyMappingSystem: Sendable {
    /// `hidutil property --get UserKeyMapping`: the mapping every keyboard gets.
    func readMapping() throws -> String
    /// `hidutil property --matching keyboard --get UserKeyMapping`: each keyboard's own, one row each.
    func readKeyboardMappings() throws -> String
    /// `hidutil property --matching keyboard --get HIDKeyboardModifierMappingPairs`: what System Settings → Keyboard →
    /// Modifier Keys set for each keyboard, one row each.
    func readModifierKeys() throws -> String
    /// `hidutil property --set <argument>`.
    func writeMapping(_ argument: String) throws
}

/// Fudge's entry in `UserKeyMapping`, Caps Lock → F18, added and removed without touching the others (SPEC-093).
public enum HyperkeyMapping {
    public static let entry = KeyRemap(source: Hyperkey.capsLockUsage, destination: Hyperkey.f18Usage)

    public enum Problem: Error, Equatable {
        /// Caps Lock is already mapped to another key, by the user or another app: Fudge doesn't take it.
        case capsLockTaken(destination: UInt64)
        /// The current mapping couldn't be read, so writing one could lose it.
        case unreadable
        /// `hidutil` failed.
        case failed(String)

        public var message: String {
            switch self {
            case .capsLockTaken(let destination):
                return "Caps Lock is already mapped to \(HyperkeyMapping.keyName(destination)) on this Mac (in System "
                    + "Settings → Keyboard → Modifier Keys, or by a tool such as Karabiner-Elements), so Fudge leaves it "
                    + "alone. Remove that mapping first."
            case .unreadable:
                return "Fudge couldn't read this Mac's key mapping, so it left it alone."
            case .failed(let reason):
                return "Fudge couldn't change the key mapping: \(reason)"
            }
        }
    }

    /// Adds Fudge's entry, keeping every other one. Refuses when Caps Lock is mapped elsewhere: in the mapping every
    /// keyboard gets, in a keyboard's own, or in System Settings → Keyboard → Modifier Keys
    /// (`HIDKeyboardModifierMappingPairs`), and when any of them can't be read.
    public static func apply(_ system: any KeyMappingSystem) throws(Problem) {
        let current = try read(system)
        let keyboards: [[KeyRemap]]
        do {
            keyboards =
                try keyboardMappings(system.readKeyboardMappings()) + keyboardMappings(system.readModifierKeys())
        } catch {
            throw .unreadable
        }
        let merged = try adding(to: current, keyboards: keyboards)
        guard merged != current else { return }
        try write(merged, to: system)
    }

    /// Removes Fudge's entry only, keeping every other one.
    public static func remove(_ system: any KeyMappingSystem) throws(Problem) {
        let current = try read(system)
        let kept = removing(from: current)
        guard kept != current else { return }
        try write(kept, to: system)
    }

    public static func adding(to current: [KeyRemap], keyboards: [[KeyRemap]] = []) throws(Problem) -> [KeyRemap] {
        // Caps Lock left as Caps Lock (Modifier Keys lists every key that way) isn't a mapping.
        for remap in current + keyboards.flatMap({ $0 })
        where remap.source == Hyperkey.capsLockUsage && remap.destination != remap.source {
            guard remap == entry else { throw .capsLockTaken(destination: remap.destination) }
        }
        return current.contains(entry) ? current : current + [entry]
    }

    public static func removing(from current: [KeyRemap]) -> [KeyRemap] {
        current.filter { $0 != entry }
    }

    /// The argument for `hidutil property --set`: the whole list, since setting it replaces it.
    public static func setArgument(_ remaps: [KeyRemap]) -> String {
        let entries = remaps.map {
            "{\"HIDKeyboardModifierMappingSrc\":\($0.source),\"HIDKeyboardModifierMappingDst\":\($0.destination)}"
        }
        return "{\"UserKeyMapping\":[\(entries.joined(separator: ","))]}"
    }

    /// `hidutil property --get UserKeyMapping`'s output: `(null)`, or the array as CoreFoundation describes it, an
    /// old-style property list whose numbers are strings.
    public static func parse(_ output: String) throws(Problem) -> [KeyRemap] {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text == "(null)" { return [] }
        guard let list = try? PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil) as? [Any]
        else { throw .unreadable }
        return try list.map { item throws(Problem) in
            guard let entry = item as? [String: Any], let source = number(entry["HIDKeyboardModifierMappingSrc"]),
                let destination = number(entry["HIDKeyboardModifierMappingDst"])
            else { throw .unreadable }
            return KeyRemap(source: source, destination: destination)
        }
    }

    /// `hidutil property --matching keyboard --get UserKeyMapping` (or `HIDKeyboardModifierMappingPairs`)'s output: a
    /// header line, then one row per keyboard, its registry id, the key and the value, which runs on over the
    /// following lines when it's a list.
    public static func keyboardMappings(_ output: String) throws(Problem) -> [[KeyRemap]] {
        var values: [String] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if let row = line.wholeMatch(
                of: /\s*[0-9A-Fa-fx]+\s+(?:UserKeyMapping|HIDKeyboardModifierMappingPairs)\s+(.*)/)
            {
                values.append(String(row.1))
            } else if line.hasPrefix("RegistryID") || (values.isEmpty && line.allSatisfy(\.isWhitespace)) {
                continue
            } else if values.isEmpty {
                throw .unreadable
            } else {
                values[values.count - 1] += "\n" + line
            }
        }
        return try values.map { value throws(Problem) in try parse(value) }
    }

    /// A key's name for the conflict message, for the usages Caps Lock is usually mapped to.
    public static func keyName(_ usage: UInt64) -> String {
        if usage == 0 { return "No Action" }
        guard usage >> 32 == 7 else { return "another key" }
        switch usage & 0xFFFF {
        case 0x29: return "Escape"
        case 0x2A: return "Delete"
        case 0x39: return "Caps Lock"
        case 0x68...0x73: return "F\((usage & 0xFFFF) - 0x68 + 13)"
        case 0xE0, 0xE4: return "Control"
        case 0xE1, 0xE5: return "Shift"
        case 0xE2, 0xE6: return "Option"
        case 0xE3, 0xE7: return "Command"
        default: return "another key"
        }
    }

    private static func read(_ system: any KeyMappingSystem) throws(Problem) -> [KeyRemap] {
        let output: String
        do {
            output = try system.readMapping()
        } catch {
            throw .unreadable
        }
        return try parse(output)
    }

    private static func write(_ remaps: [KeyRemap], to system: any KeyMappingSystem) throws(Problem) {
        do {
            try system.writeMapping(setArgument(remaps))
        } catch {
            throw .failed("\(error)")
        }
    }

    private static func number(_ value: Any?) -> UInt64? {
        if let number = value as? NSNumber { return number.uint64Value }
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespaces) else { return nil }
        if text.lowercased().hasPrefix("0x") { return UInt64(text.dropFirst(2), radix: 16) }
        return UInt64(text)
    }
}

/// What Hyperkey's event tap needs to know about one event: never which character a key types.
public struct HyperTapEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case keyDown, keyUp, flagsChanged
    }

    public var kind: Kind
    public var keyCode: UInt16
    public var isRepeat: Bool
    /// The event's timestamp, in nanoseconds.
    public var time: UInt64

    public init(kind: Kind, keyCode: UInt16, isRepeat: Bool = false, time: UInt64) {
        self.kind = kind
        self.keyCode = keyCode
        self.isRepeat = isRepeat
        self.time = time
    }
}

/// Hyperkey's event tap, as a state machine (SPEC-093). F18's own events are swallowed; any other key pressed while
/// F18 is down gets ⌘⌥⌃⇧ added. Whether F18 is down is the hardware's answer (`f18Down`, read for every event), never
/// only what the tap saw, so a lost key-up can't leave Hyper stuck. The only thing kept is when F18 went down and
/// whether another key came since, for the quick press: nothing about which keys were typed.
public struct HyperTap: Sendable, Equatable {
    public enum Decision: Sendable, Equatable {
        /// Leave the event as it is.
        case pass
        /// Add ⌘⌥⌃⇧ to its flags.
        case addHyper
        /// Drop it: it's F18's.
        case swallow
        /// Drop it, and toggle Caps Lock: a quick press with the option on.
        case swallowAndToggleCapsLock
    }

    /// Why the state starts over.
    public enum Reset: Sendable, Equatable {
        case tapDisabled, tapEnabled, secureInput, switchedOff
    }

    public var quickPressTogglesCapsLock: Bool
    private var pressedAt: UInt64?
    private var otherKeySincePress = false

    public init(quickPressTogglesCapsLock: Bool = false) {
        self.quickPressTogglesCapsLock = quickPressTogglesCapsLock
    }

    /// Whether a press of F18 is being tracked, for tests.
    public var isTrackingPress: Bool { pressedAt != nil }

    /// What to do with `event`. `f18Down` is F18's state in the HID system (`CGEventSource.keyState`), and
    /// `secureInput` whether a password field has the keyboard, where the tap does nothing.
    public mutating func handle(_ event: HyperTapEvent, f18Down: Bool, secureInput: Bool) -> Decision {
        guard !secureInput else {
            reset(.secureInput)
            return .pass
        }
        if event.keyCode == Hyperkey.f18KeyCode, event.kind != .flagsChanged {
            switch event.kind {
            case .keyDown:
                // A new press starts over, even when the last one's key-up never came (macOS delivers no keys to
                // the tap under secure input); a key repeat keeps the press.
                if !event.isRepeat {
                    pressedAt = event.time
                    otherKeySincePress = false
                }
            case .keyUp:
                defer { pressedAt = nil }
                if quickPressTogglesCapsLock, let start = pressedAt, !otherKeySincePress, event.time >= start,
                    event.time - start < Hyperkey.quickPress
                {
                    return .swallowAndToggleCapsLock
                }
            case .flagsChanged:
                break
            }
            return .swallow
        }
        guard f18Down else {
            // The hardware says F18 is up: a press the tap saw go down without its key-up is over.
            pressedAt = nil
            return .pass
        }
        otherKeySincePress = true
        return event.kind == .flagsChanged ? .pass : .addHyper
    }

    public mutating func reset(_ reason: Reset) {
        pressedAt = nil
        otherKeySincePress = false
    }
}

/// When Hyperkey's service starts and stops (SPEC-093, and #125's review), checked at launch, on every change of the
/// setting and every 2 s for Accessibility. It runs only while the setting is on and Accessibility is allowed.
/// Otherwise Fudge's mapping goes, once, even when this run never added it: a crash, a kill or a force-quit skips
/// the removal at quit, and a leftover Caps Lock → F18 with no tap leaves Caps Lock dead. A start that failed (the
/// tap refused, the mapping refused) isn't tried again until the setting or Accessibility changes.
public struct HyperkeyLifecycle: Sendable, Equatable {
    public enum Step: Sendable, Equatable {
        case nothing
        /// Start the tap, then add Fudge's entry.
        case start
        /// Stop the tap if it runs, and remove Fudge's entry (`HyperkeyMapping.remove` writes nothing when it isn't
        /// there).
        case stop
    }

    public private(set) var running = false
    private var removed = false
    private var gaveUp = false
    private var lastSetting: Bool?
    private var lastTrusted: Bool?

    public init() {}

    public mutating func next(settingOn: Bool, trusted: Bool) -> Step {
        if lastSetting != settingOn || lastTrusted != trusted { gaveUp = false }
        lastSetting = settingOn
        lastTrusted = trusted
        if settingOn && trusted {
            guard !running, !gaveUp else { return .nothing }
            running = true
            removed = false
            return .start
        }
        guard running || !removed else { return .nothing }
        running = false
        removed = true
        return .stop
    }

    /// The start failed: Hyperkey stops, its entry goes, and it waits for a change before trying again.
    public mutating func startFailed() -> Step {
        running = false
        removed = true
        gaveUp = true
        return .stop
    }
}
