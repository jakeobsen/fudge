import Foundation

// Define Word (SPEC-091), in the Tools group: a word's definition from the Mac's own dictionaries, offline. Every
// decision lives here; the app asks Dictionary Services (`DefinitionLookup`), and tests and snapshot runs use fakes.

/// Looks a word up in the Mac's dictionaries: the plain-text definition, or nil when there's none.
public protocol DefinitionLookup: Sendable {
    func definition(of word: String) async -> String?
}

/// Made-up definitions by word, ignoring case: tests and snapshot runs (`--definitions <file>`) use it, so neither
/// reads the Mac's dictionaries.
public struct FixedDefinitions: DefinitionLookup {
    public var definitions: [String: String]

    public init(_ definitions: [String: String]) {
        self.definitions = Dictionary(definitions.map { ($0.key.lowercased(), $0.value) }) { first, _ in first }
    }

    /// A JSON object of word to definition in `file`; none when it can't be read.
    public static func load(_ file: URL) -> FixedDefinitions {
        let object = (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
        return FixedDefinitions(object as? [String: String] ?? [:])
    }

    public func definition(of word: String) async -> String? {
        definitions[word.lowercased()]
    }
}

public enum DefineWord {
    /// Define Word's one argument, Word, which may be left empty.
    public static let argument = ExtensionManifest.Argument(
        name: "word", type: "text", placeholder: "Word", required: false, data: nil)
    /// The longest word or phrase it looks up, in characters: a selection can be a whole page.
    public static let wordLimit = 100

    /// What a run does: look a word up, or ask for one in its argument field.
    public enum Start: Sendable, Equatable {
        case lookUp(String)
        /// No word was typed and nothing is selected: root search shows the Word field, with the keyboard in it.
        case askForWord
    }

    /// The typed word, else the selected text's (`selection` is asked only when nothing was typed), else ask.
    public static func start(argument: String, selection: () async -> String?) async -> Start {
        if let word = word(from: argument) { return .lookUp(word) }
        if let word = word(from: await selection()) { return .lookUp(word) }
        return .askForWord
    }

    /// The word in `text`: its first line that isn't blank, trimmed and cut to `wordLimit` characters.
    public static func word(from text: String?) -> String? {
        guard let text else { return nil }
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard let line else { return nil }
        return String(line.prefix(wordLimit)).trimmingCharacters(in: .whitespaces)
    }

    /// Dictionary.app at `word`: `dict://` and the word, cut to `wordLimit` characters and percent-encoded so only
    /// unreserved ASCII is left as it is.
    public static func dictionaryURL(for word: String) -> URL? {
        var unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        unreserved.insert(charactersIn: "-._~")
        guard let encoded = String(word.prefix(wordLimit)).addingPercentEncoding(withAllowedCharacters: unreserved),
            !encoded.isEmpty
        else { return nil }
        return URL(string: "dict://\(encoded)")
    }
}

/// A plain-text definition, as Dictionary Services gives it, made into light Markdown: the headword as a heading,
/// then the pronunciation, the part of speech, each numbered sense, each `•` sub-sense and each section (ORIGIN,
/// PHRASES, …) on its own line. Everything from the dictionary is escaped, so nothing in it is read as Markdown.
public enum DefinitionText {
    /// The parts of speech put on a line of their own, in italics, where a definition or a run of senses starts.
    static let partsOfSpeech: Set<String> = [
        "noun", "verb", "adjective", "adverb", "pronoun", "preposition", "conjunction", "exclamation", "interjection",
        "determiner", "abbreviation", "prefix", "suffix", "symbol", "article", "numeral",
    ]
    /// The section labels Apple's English dictionaries use.
    static let sections: Set<String> = ["PHRASES", "PHRASAL VERBS", "DERIVATIVES", "ORIGIN", "USAGE", "NOTE"]

    /// The Markdown for `text`, `word`'s definition. The headword is the text before the first " | " (the
    /// pronunciation's), else `word`.
    public static func markdown(word: String, text: String) -> String {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var headword = word
        var lines: [String] = []
        if let bar = body.range(of: " | "), body.distance(from: body.startIndex, to: bar.lowerBound) <= 100,
            !body[..<bar.lowerBound].trimmingCharacters(in: .whitespaces).isEmpty
        {
            headword = String(body[..<bar.lowerBound]).trimmingCharacters(in: .whitespaces)
            body = String(body[bar.lowerBound...]).trimmingCharacters(in: .whitespaces)
            // The pronunciation, between two bars.
            if body.hasPrefix("|"), let close = body.dropFirst().firstIndex(of: "|") {
                lines.append(escaped(String(body[...close])))
                body = String(body[body.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        lines += paragraphs(body)
        return (["# " + escaped(headword)] + lines).joined(separator: "\n\n")
    }

    /// The body split where a part of speech, a sense number, a `•` or a section label starts.
    static func paragraphs(_ body: String) -> [String] {
        let tokens = body.split(whereSeparator: \.isWhitespace).map(String.init)
        var paragraphs: [String] = []
        var current: [String] = []
        var nextSense = 1
        func flush() {
            if !current.isEmpty { paragraphs.append(current.joined(separator: " ")) }
            current = []
        }
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            let hasMore = index + 1 < tokens.count
            let pair = hasMore ? token + " " + tokens[index + 1] : ""
            let startsRun = current.isEmpty || partsOfSpeech.contains(current.last ?? "")
            if sections.contains(pair) || (sections.contains(token) && hasMore) {
                // ORIGIN, PHRASES, …: their own paragraph, the label in bold; sense numbers start over after them.
                flush()
                let label = sections.contains(pair) ? pair : token
                current = ["**\(label)**"]
                index += sections.contains(pair) ? 2 : 1
                nextSense = 1
                continue
            } else if partsOfSpeech.contains(token), hasMore, current.isEmpty || isSenseNumber(tokens[index + 1], 1) {
                // A part of speech where the definition or a new run of senses starts: on its own line.
                flush()
                paragraphs.append("*\(token)*")
                nextSense = 1
                index += 1
                continue
            } else if hasMore, isSenseNumber(token, nextSense) || (startsRun && isSenseNumber(token, 1)) {
                flush()
                nextSense = Int(token)! + 1
                current = ["**\(token)**"]
                index += 1
                continue
            } else if token == "•", hasMore {
                flush()
                current = ["•"]
                index += 1
                continue
            }
            current.append(escaped(token))
            index += 1
        }
        flush()
        return paragraphs
    }

    private static func isSenseNumber(_ token: String, _ expected: Int) -> Bool {
        token == String(expected)
    }

    /// `text` with Markdown's punctuation escaped, so the dictionary's text is shown as it is.
    static func escaped(_ text: String) -> String {
        let special: Set<Character> = [
            "\\", "`", "*", "_", "{", "}", "[", "]", "(", ")", "#", "+", "-", ".", "!", "<", ">", "|", "~",
        ]
        var result = ""
        for character in text {
            if special.contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }
}

/// The Define Word view: a Detail with the definition, built here as an extension's would arrive, under its own
/// session, so nothing of it reaches the extension host.
public enum DefineWordView {
    public static let session = "fudge:define-word"
    public static let title = "Define Word"

    /// What one of its actions does.
    public enum Target: Sendable, Equatable {
        /// ↵ and ⌘D: Dictionary.app at the word.
        case lookUpInDictionary
        /// ⌘↵: the definition's text.
        case copyDefinition
    }

    public static let lookUpShortcut = KeyShortcut(key: "d", modifiers: ["cmd"])

    enum Node {
        static let detail = 1
        static let actions = 2
        static let lookUp = 3
        static let copy = 4
    }

    /// The Detail for `word`: its definition as `DefinitionText` formats it, with Look Up in Dictionary (↵, ⌘D) and
    /// Copy Definition (⌘↵); with no definition, "No definition for “word”" and Look Up in Dictionary only.
    public static func view(word: String, definition: String?) -> UINode {
        var actions = [
            action(Node.lookUp, "Look Up in Dictionary", icon: "book-16", shortcut: lookUpShortcut)
        ]
        let markdown: String
        if let definition {
            markdown = DefinitionText.markdown(word: word, text: definition)
            actions.append(action(Node.copy, "Copy Definition", icon: "copy-clipboard-16", shortcut: nil))
        } else {
            markdown = "## No definition for “\(DefinitionText.escaped(word))”"
        }
        return UINode(
            id: Node.detail, type: "Detail",
            props: [
                "navigationTitle": .string(title), "markdown": .string(markdown),
                "actions": UINode(id: Node.actions, type: "ActionPanel", children: actions).json,
            ])
    }

    /// What the action `node` does; nil for any other node.
    public static func target(of node: Int) -> Target? {
        switch node {
        case Node.lookUp: .lookUpInDictionary
        case Node.copy: .copyDefinition
        default: nil
        }
    }

    private static func action(_ id: Int, _ title: String, icon: String, shortcut: KeyShortcut?) -> UINode {
        var props: [String: JSONValue] = ["title": .string(title), "icon": .string(icon)]
        if let shortcut {
            props["shortcut"] = .object([
                "key": .string(shortcut.key), "modifiers": .array(shortcut.modifiers.sorted().map(JSONValue.string)),
            ])
        }
        return UINode(id: id, type: "Action", props: props)
    }
}
