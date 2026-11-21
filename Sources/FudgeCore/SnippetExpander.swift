import Foundation

/// A key press as the keyboard tap sees it (SPEC-078 §6), reduced to what expansion needs.
public struct SnippetKeyEvent: Sendable, Equatable {
    /// The virtual key code (HIToolbox's Events.h).
    public var keyCode: UInt16
    /// What the key typed, with the modifiers held, as the event says. Empty for a dead key.
    public var characters: String
    public var command: Bool
    public var control: Bool
    public var option: Bool
    /// The event's `eventSourceUserData`. Fudge's own posted events carry `SnippetExpander.marker`.
    public var sourceUserData: Int64

    public init(
        keyCode: UInt16, characters: String, command: Bool = false, control: Bool = false, option: Bool = false,
        sourceUserData: Int64 = 0
    ) {
        self.keyCode = keyCode
        self.characters = characters
        self.command = command
        self.control = control
        self.option = option
        self.sourceUserData = sourceUserData
    }
}

/// Expands a snippet's keyword as it's typed (SPEC-078 §6): it keeps the last characters typed and says which
/// snippet to expand when they end with a keyword.
///
/// What's typed stays in here (the reviewer's MUST 2): the buffer is private, nothing reads it out, it isn't
/// printed, dumped or mirrored, and the only output is `Output.expand`, which names a snippet's id. It's cleared on
/// every reset: a click, an app switch, a key that moves the caret or leaves the field, a ⌘ or ⌃ combination, secure
/// input, Fudge's own windows, switching expansion off, and Input Monitoring being revoked.
public struct SnippetExpander: Sendable {
    /// `eventSourceUserData` on every event Fudge posts (⌫, ⌘V, ←), so the tap never reads its own keys as typing.
    public static let marker: Int64 = 0x6675_6467_6501  // "fudge" and a version

    /// Why turning expansion on needs Input Monitoring: the Snippets page's sheet and onboarding's step both say it.
    public static let inputMonitoringExplanation =
        "To notice a keyword as you type it, Fudge needs macOS's Input Monitoring permission. What you type isn't "
        + "saved or sent anywhere, and nothing is read in password fields."

    /// How many characters are kept: the longest keyword.
    public static let bufferLimit = Snippet.keywordLimit

    /// What the app is asked to do. Nothing else ever leaves the expander.
    public enum Output: Sendable, Equatable, CustomStringConvertible {
        /// Delete the snippet's keyword, just typed, and paste the snippet in its place.
        case expand(snippetID: String)

        public var description: String {
            switch self {
            case .expand(let id): "expand snippet \(id)"
            }
        }
    }

    /// Why the buffer was cleared, for the app's own reset calls.
    public enum Reset: Sendable, Equatable {
        case click
        case appSwitch
        case switchedOff
        case permissionRevoked
        case snippetsChanged
    }

    /// The keywords that can expand, each with its snippet's id. One that contains another, or is contained in one,
    /// ignoring case (only a hand-edited `snippets.json` can hold such a pair), expands neither, so typing is never
    /// ambiguous.
    private var keywords: [(keyword: [Character], id: String)] = []
    /// The last characters typed, at most `bufferLimit`. Never read out.
    private var typed: [Character] = []

    public init(snippets: [Snippet] = []) {
        setSnippets(snippets)
    }

    /// Takes the snippets' keywords, after a change to `snippets.json`, and starts the buffer over.
    public mutating func setSnippets(_ snippets: [Snippet]) {
        let withKeywords = snippets.compactMap { snippet in
            snippet.keyword.flatMap { Snippet.isValidKeyword($0) ? ($0, snippet.id) : nil }
        }
        keywords = withKeywords.enumerated().compactMap { index, entry in
            let clashes = withKeywords.indices.contains { other in
                other != index && Snippet.keywordsClash(entry.0, withKeywords[other].0)
            }
            return clashes ? nil : (Array(entry.0), entry.1)
        }
        typed = []
    }

    /// Whether any snippet can expand: the app doesn't need its keyboard tap otherwise.
    public var hasKeywords: Bool { !keywords.isEmpty }

    /// Clears what was typed.
    public mutating func reset(_ reason: Reset) {
        typed = []
    }

    /// A key press. With `secureInput` on (a password field, `IsSecureEventInputEnabled()`) or one of Fudge's own
    /// windows in front, nothing is kept or expanded, and the buffer is cleared. Fudge's own posted keys are ignored.
    public mutating func handle(_ event: SnippetKeyEvent, secureInput: Bool, fudgeInFront: Bool) -> Output? {
        if event.sourceUserData == Self.marker { return nil }
        guard !secureInput, !fudgeInFront else {
            typed = []
            return nil
        }
        if event.command || event.control {
            typed = []
            return nil
        }
        if event.keyCode == Self.deleteKey {
            // ⌥⌫ deletes a word, which the buffer can't follow.
            if event.option { typed = [] } else if !typed.isEmpty { typed.removeLast() }
            return nil
        }
        if Self.resettingKeys.contains(event.keyCode) {
            typed = []
            return nil
        }
        guard !event.characters.isEmpty else { return nil }  // a dead key, waiting for the next
        guard event.characters.unicodeScalars.allSatisfy(Self.isTypedText) else {
            typed = []
            return nil
        }
        typed.append(contentsOf: event.characters)
        if typed.count > Self.bufferLimit { typed.removeFirst(typed.count - Self.bufferLimit) }
        guard let match = keywords.first(where: { typed.ends(with: $0.keyword) }) else { return nil }
        typed = []
        return .expand(snippetID: match.id)
    }

    // Virtual key codes (HIToolbox's Events.h).
    static let deleteKey: UInt16 = 51
    /// Keys that move the caret or leave the text: Return, Enter, Tab, Esc, ⌦, the arrows, Home, End, Page Up and
    /// Page Down, and the function keys.
    static let resettingKeys: Set<UInt16> = [
        36, 76, 48, 53, 117, 123, 124, 125, 126, 115, 119, 116, 121,
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90,
    ]

    /// Typed text, not a control character or a function key's private-use character (U+F700…).
    static func isTypedText(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.generalCategory == .control { return false }
        return !(0xF700...0xF8FF).contains(scalar.value)
    }
}

extension SnippetExpander: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    // Neither printing nor `dump` shows what was typed.
    public var description: String { "SnippetExpander(\(keywords.count) keywords)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

extension Array where Element == Character {
    fileprivate func ends(with suffix: [Character]) -> Bool {
        count >= suffix.count && self[(count - suffix.count)...].elementsEqual(suffix)
    }
}
