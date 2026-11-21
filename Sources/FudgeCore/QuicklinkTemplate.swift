import Foundation

/// A quicklink's `link`, read into text and placeholders, and filled in when it opens (SPEC-052 A2).
///
/// - Arguments: `{argument}`, `{argument name="ticket"}`, `{argument name="q" default="news"}`,
///   `{argument name="kind" options="bug, task, story"}` (a dropdown), and Raycast's older bare `{Query}`. The same
///   name twice is one field, and a link has at most 3.
/// - Dynamic values: `{clipboard}`, `{uuid}`, `{date}`, `{time}`, `{datetime}`.
/// - Modifiers after `|`: `raw`, `percent-encode`, `uppercase`, `lowercase`, `trim`.
///
/// In a URL, every value is percent-encoded as JavaScript's `encodeURIComponent` does, unless it's marked `raw`; in a
/// file path, values go in as they are. A link that is exactly one placeholder is taken raw. Anything else in braces
/// is a `problem`.
public struct QuicklinkTemplate: Sendable, Equatable {
    public enum Dynamic: String, Sendable, Equatable, CaseIterable {
        case clipboard, uuid, date, time, datetime
        /// The day of the week ("Monday"), and where the caret goes: snippets only (`SnippetTemplate`).
        case day, cursor
    }

    /// What's being read: a quicklink's link, or a snippet's text (`SnippetTemplate`), which share one parser.
    enum Mode: Sendable {
        case link, snippet

        /// The thing the problem messages name.
        var thing: String { self == .link ? "a quicklink" : "a snippet" }
        var whole: String { self == .link ? "the link" : "the snippet" }

        /// Raycast's dynamic names this mode refuses: a bare word with one of these names is a problem, never an
        /// argument.
        var unsupported: Set<String> {
            self == .link
                ? ["selection", "day", "cursor", "browser-tab", "snippet"] : ["selection", "browser-tab", "snippet"]
        }
    }

    public enum Modifier: String, Sendable, Equatable, CaseIterable {
        case raw
        case percentEncode = "percent-encode"
        case uppercase, lowercase, trim
    }

    /// A field the user fills in before it opens.
    public struct Argument: Sendable, Equatable {
        public var name: String
        /// Shown in the empty field, and used when it's left empty. Without one, the field is required.
        public var defaultValue: String?
        /// A dropdown's values; empty for a text field.
        public var options: [String]
    }

    public enum Value: Sendable, Equatable {
        /// An argument, by name.
        case argument(String)
        case dynamic(Dynamic)
    }

    public struct Placeholder: Sendable, Equatable {
        public var value: Value
        public var modifiers: [Modifier]
    }

    public enum Segment: Sendable, Equatable {
        case text(String)
        case placeholder(Placeholder)
    }

    public static let argumentLimit = 3

    public let link: String
    public let segments: [Segment]
    /// The arguments, each once, in the order they first appear.
    public let arguments: [Argument]
    /// What's wrong with the link, naming the placeholder; nil when it's fine.
    public let problem: String?

    public init(_ link: String) {
        self.init(link, mode: .link)
    }

    init(_ link: String, mode: Mode) {
        self.link = link
        var parser = Parser(mode: mode)
        parser.parse(link)
        segments = parser.segments
        arguments = parser.arguments
        problem =
            parser.problem
            ?? (parser.arguments.count > Self.argumentLimit
                ? "A quicklink can have at most \(Self.argumentLimit) fields." : nil)
    }

    /// Whether it's a file path, absolute or starting with `~`, rather than a URL.
    public var isPath: Bool {
        let trimmed = link.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("/") || trimmed.hasPrefix("~")
    }

    /// The link's scheme as written (`https`, `slack`), when it's a URL whose scheme isn't a placeholder.
    public var scheme: String? {
        guard !isPath, case .text(let first) = segments.first,
            let match = first.prefixMatch(of: /([A-Za-z][A-Za-z0-9+.\-]*):/)
        else { return nil }
        return String(match.1).lowercased()
    }

    /// Its arguments as root search's fields after the query (`ArgumentInput`): a dropdown for `options`, the
    /// default as the placeholder text, and required unless there's a default. None when the link has a problem,
    /// so ↵ shows the problem rather than asking for fields first.
    public var fields: [ExtensionManifest.Argument] {
        guard problem == nil else { return [] }
        return arguments.map { argument in
            ExtensionManifest.Argument(
                name: argument.name,
                type: argument.options.isEmpty ? "text" : "dropdown",
                placeholder: argument.defaultValue ?? argument.name,
                required: argument.defaultValue == nil,
                data: argument.options.isEmpty
                    ? nil : argument.options.map { ExtensionManifest.Option(title: $0, value: $0) }
            )
        }
    }

    /// The link without its placeholders, for root search to match: typing "argument" shouldn't find every
    /// quicklink with a field.
    public var searchableText: String {
        link.replacing(/\{[^{}]*\}/, with: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Whether it uses `{clipboard}`, so opening it reads the clipboard only then.
    public var usesClipboard: Bool {
        segments.contains { segment in
            if case .placeholder(let placeholder) = segment { return placeholder.value == .dynamic(.clipboard) }
            return false
        }
    }

    /// What the dynamic placeholders read. Tests fix every part.
    public struct Context: Sendable {
        /// The clipboard's text, or nil when there's none or it's concealed or transient.
        public var clipboard: String?
        public var now: Date
        public var locale: Locale
        public var timeZone: TimeZone
        /// The Mac's calendar, which `{date}` and `{datetime}` are written in.
        public var calendar: Calendar
        public var makeUUID: @Sendable () -> String

        public init(
            clipboard: String?, now: Date = Date(), locale: Locale = .current, timeZone: TimeZone = .current,
            calendar: Calendar = .current, makeUUID: @escaping @Sendable () -> String = { UUID().uuidString }
        ) {
            self.clipboard = clipboard
            self.now = now
            self.locale = locale
            self.timeZone = timeZone
            self.calendar = calendar
            self.makeUUID = makeUUID
        }
    }

    /// The link with every placeholder filled in: an argument left empty takes its default, or stays empty.
    public func fill(arguments values: [String: String], context: Context) -> String {
        let alone = segments.count == 1
        var result = ""
        for segment in segments {
            switch segment {
            case .text(let text):
                result += text
            case .placeholder(let placeholder):
                var value = raw(placeholder.value, values: values, context: context)
                var encode = !isPath && !alone
                for modifier in placeholder.modifiers {
                    switch modifier {
                    case .raw: encode = false
                    case .percentEncode: encode = true
                    case .uppercase: value = value.uppercased()
                    case .lowercase: value = value.lowercased()
                    case .trim: value = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                result += encode ? Self.encodeURIComponent(value) : value
            }
        }
        return result
    }

    /// A placeholder's value before its modifiers, shared with `SnippetTemplate`.
    func raw(_ value: Value, values: [String: String], context: Context) -> String {
        switch value {
        case .argument(let name):
            if let entered = values[name], !entered.isEmpty { return entered }
            return arguments.first { $0.name == name }?.defaultValue ?? ""
        case .dynamic(.clipboard):
            return context.clipboard ?? ""
        case .dynamic(.uuid):
            return context.makeUUID()
        case .dynamic(.cursor):
            return ""
        case .dynamic(.day):
            return context.now.formatted(
                Date.FormatStyle(locale: context.locale, calendar: context.calendar, timeZone: context.timeZone)
                    .weekday(.wide))
        case .dynamic(let dynamic):
            var calendar = context.calendar
            calendar.locale = context.locale
            calendar.timeZone = context.timeZone
            let date: Date.FormatStyle.DateStyle = dynamic == .time ? .omitted : .abbreviated
            let time: Date.FormatStyle.TimeStyle = dynamic == .date ? .omitted : .shortened
            return context.now.formatted(
                Date.FormatStyle(
                    date: date, time: time, locale: context.locale, calendar: calendar, timeZone: context.timeZone))
        }
    }

    /// What `{clipboard}` reads: the clipboard's text, unless a password manager marked it concealed or another app
    /// marked it transient (nspasteboard.org); then nothing, so a copied password never ends up in a link.
    public static func clipboardText(_ text: String?, types: [String]) -> String? {
        let skipped = [PasteboardContents.concealedType, PasteboardContents.transientType]
        guard !types.contains(where: skipped.contains) else { return nil }
        return text
    }

    /// The characters `encodeURIComponent` leaves alone.
    static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")

    /// JavaScript's `encodeURIComponent`: every UTF-8 byte but the unreserved characters, percent-encoded.
    public static func encodeURIComponent(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
    }

    /// Reads a link or a snippet's text, one character at a time.
    private struct Parser {
        let mode: Mode
        var segments: [Segment] = []
        var arguments: [Argument] = []
        var problem: String?

        mutating func parse(_ link: String) {
            var text = ""
            var rest = Substring(link)
            while let character = rest.first {
                if character == "}" {
                    fail("A “}” in \(mode.whole) has no “{” before it.")
                    return
                }
                guard character == "{" else {
                    text.append(character)
                    rest = rest.dropFirst()
                    continue
                }
                let inside = rest.dropFirst()
                guard let close = inside.firstIndex(of: "}") else {
                    fail("A “{” in \(mode.whole) has no “}” after it.")
                    return
                }
                let body = inside[..<close]
                if body.contains("{") {
                    fail("A “{” in \(mode.whole) has no “}” after it.")
                    return
                }
                if !text.isEmpty { segments.append(.text(text)) }
                text = ""
                guard let placeholder = placeholder(String(body)) else { return }
                segments.append(.placeholder(placeholder))
                rest = inside[inside.index(after: close)...]
            }
            if !text.isEmpty { segments.append(.text(text)) }
        }

        mutating func fail(_ message: String) {
            if problem == nil { problem = message }
        }

        /// One placeholder's inside, between the braces.
        mutating func placeholder(_ body: String) -> Placeholder? {
            let written = "{\(body)}"
            var parts = Self.splitModifiers(body).map { $0.trimmingCharacters(in: .whitespaces) }
            let head = parts.removeFirst()
            var modifiers: [Modifier] = []
            for part in parts {
                guard let modifier = Modifier(rawValue: part) else {
                    fail("Fudge doesn't know the modifier “\(part)” in “\(written)”.")
                    return nil
                }
                modifiers.append(modifier)
            }
            guard let match = head.wholeMatch(of: /([A-Za-z0-9_\-]+)((?:\s+[A-Za-z]+="[^"]*")*)\s*/) else {
                fail("Fudge doesn't support “\(written)” in \(mode.thing).")
                return nil
            }
            let word = String(match.1)
            var attributes: [String: String] = [:]
            for attribute in String(match.2).matches(of: /([A-Za-z]+)="([^"]*)"/) {
                attributes[String(attribute.1)] = String(attribute.2)
            }
            if word == "argument", mode == .link {
                guard Set(attributes.keys).isSubset(of: ["name", "default", "options"]) else {
                    fail("Fudge doesn't support “\(written)” in \(mode.thing).")
                    return nil
                }
                let name = attributes["name"].map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                let options = (attributes["options"] ?? "").split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }.filter { !$0.isEmpty }
                return Placeholder(
                    value: .argument(
                        add(
                            Argument(
                                name: name.isEmpty ? "argument" : name, defaultValue: attributes["default"],
                                options: options))),
                    modifiers: modifiers)
            }
            guard attributes.isEmpty, !mode.unsupported.contains(word.lowercased()) else {
                fail("Fudge doesn't support “\(written)” in \(mode.thing).")
                return nil
            }
            if let dynamic = Dynamic(rawValue: word.lowercased()) {
                return Placeholder(value: .dynamic(dynamic), modifiers: modifiers)
            }
            // A snippet has no fields: any other word is a problem.
            guard mode == .link else {
                fail("Fudge doesn't support “\(written)” in \(mode.thing).")
                return nil
            }
            // Raycast's older form: a bare word is an argument with that name.
            return Placeholder(
                value: .argument(add(Argument(name: word, defaultValue: nil, options: []))), modifiers: modifiers)
        }

        /// Splits a placeholder at each `|` outside quotes, so `default="a|b"` stays one attribute.
        static func splitModifiers(_ body: String) -> [String] {
            var parts = [""]
            var quoted = false
            for character in body {
                if character == "\"" { quoted.toggle() }
                if character == "|", !quoted {
                    parts.append("")
                } else {
                    parts[parts.count - 1].append(character)
                }
            }
            return parts
        }

        /// Adds an argument, or merges it into the one with the same name: the first default and options win.
        mutating func add(_ argument: Argument) -> String {
            if let index = arguments.firstIndex(where: { $0.name == argument.name }) {
                if arguments[index].defaultValue == nil { arguments[index].defaultValue = argument.defaultValue }
                if arguments[index].options.isEmpty { arguments[index].options = argument.options }
            } else {
                arguments.append(argument)
            }
            return argument.name
        }
    }
}

/// What a filled-in quicklink opens: a URL with a scheme, or a path that exists, `~` expanded.
public enum QuicklinkOpening {
    public enum Target: Sendable, Equatable {
        case url(URL)
        case path(String)

        /// The text `SystemCalls`' `open` takes.
        public var openText: String {
            switch self {
            case .url(let url): url.absoluteString
            case .path(let path): path
            }
        }
    }

    public struct Failure: Error, Sendable, Equatable, CustomStringConvertible {
        public var description: String
    }

    /// The template's problem, if it has one; else what the filled link opens, or why it can't be opened.
    public static func target(
        for template: QuicklinkTemplate, filled: String, home: String = NSHomeDirectory(),
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Result<Target, Failure> {
        if let problem = template.problem { return .failure(Failure(description: problem)) }
        let trimmed = filled.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            let path = trimmed.hasPrefix("~") ? home + trimmed.dropFirst() : trimmed
            guard trimmed == "~" || trimmed.hasPrefix("~/") || trimmed.hasPrefix("/") else {
                return .failure(Failure(description: "“\(trimmed)” isn't a path Fudge can open."))
            }
            guard exists(path) else { return .failure(Failure(description: "“\(trimmed)” doesn't exist.")) }
            return .success(.path(path))
        }
        guard let url = URL(string: trimmed), let scheme = url.scheme, !scheme.isEmpty,
            trimmed.range(of: #"^[A-Za-z][A-Za-z0-9+.\-]*:"#, options: .regularExpression) != nil
        else {
            return .failure(Failure(description: "“\(trimmed)” isn't a link Fudge can open."))
        }
        return .success(.url(url))
    }
}
