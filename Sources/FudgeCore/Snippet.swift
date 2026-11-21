import Foundation

/// A saved snippet (SPEC-078): text to paste or copy from Search Snippets, with an optional keyword that expands it
/// as you type.
public struct Snippet: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var text: String
    public var keyword: String?
    /// When it was made, ISO 8601.
    public var createdAt: String?

    public static let nameLimit = 64
    public static let textLimit = 100_000
    public static let keywordLimit = 32

    public init(
        id: String = UUID().uuidString, name: String, text: String, keyword: String? = nil, createdAt: String? = nil
    ) {
        self.id = id
        self.name = name
        self.text = text
        self.keyword = keyword
        self.createdAt = createdAt
    }

    /// A snippet from its `snippets.json` entry: an `id`, a valid name and some text. A keyword that isn't one
    /// (`isValidKeyword`) is left off.
    init?(json: JSONValue) {
        guard case .object(let object) = json,
            case .string(let id) = object["id"], !id.trimmingCharacters(in: .whitespaces).isEmpty,
            case .string(let name) = object["name"], Self.isValidName(name),
            case .string(let text) = object["text"], !text.isEmpty
        else { return nil }
        var keyword: String?
        if case .string(let word) = object["keyword"], Self.isValidKeyword(word) { keyword = word }
        var createdAt: String?
        if case .string(let date) = object["createdAt"] { createdAt = date }
        self.init(id: id, name: name, text: text, keyword: keyword, createdAt: createdAt)
    }

    /// 1–64 characters, not only whitespace.
    public static func isValidName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= nameLimit
    }

    /// 1–32 characters, with no whitespace.
    public static func isValidKeyword(_ keyword: String) -> Bool {
        !keyword.isEmpty && keyword.count <= keywordLimit && !keyword.contains(where: \.isWhitespace)
    }

    /// Whether two keywords can't both be used: one contains the other, ignoring case. Expansion matches the end of
    /// what's typed, so "dt" with "xdt" (a suffix) would be ambiguous, and with "adtb" (inside it) would fire before
    /// "adtb" could ever be typed; a prefix ("dt" and "dtx") is the same (SPEC-078, the reviewer's MUST 1).
    public static func keywordsClash(_ one: String, _ other: String) -> Bool {
        let a = one.lowercased()
        let b = other.lowercased()
        return a.contains(b) || b.contains(a)
    }

    /// Writes the snippet over its old entry, so keys Fudge doesn't know stay.
    func json(over existing: [String: JSONValue] = [:]) -> JSONValue {
        var object = existing
        object["id"] = .string(id)
        object["name"] = .string(name)
        object["text"] = .string(text)
        object["keyword"] = keyword.map(JSONValue.string)
        object["createdAt"] = createdAt.map(JSONValue.string)
        return .object(object.compactMapValues { $0 })
    }

    /// Its root search id, which its launches count under in `LaunchHistory`.
    public var rootItemID: String { "snippet:\(id)" }
}

/// The user's snippets in `snippets.json`, `{ "snippets": [ { id, name, text, keyword?, createdAt } ] }`, kept as
/// `QuicklinkStore` keeps quicklinks (`EntryFile`): read tolerantly, written atomically, keys Fudge doesn't know and
/// entries that aren't valid snippets kept, and a file it can't read never overwritten.
public struct SnippetStore: Sendable, Equatable {
    private var entries: [JSONValue]

    public init(_ snippets: [Snippet] = []) {
        entries = snippets.map { $0.json() }
    }

    init(entries: [JSONValue]) {
        self.entries = entries
    }

    /// The valid snippets, each `id` once.
    public var snippets: [Snippet] {
        EntryFile.valid(entries, Snippet.init(json:), id: \.id)
    }

    public func snippet(id: String) -> Snippet? {
        snippets.first { $0.id == id }
    }

    public mutating func add(_ snippet: Snippet) {
        entries.append(snippet.json())
    }

    @discardableResult
    public mutating func remove(id: String) -> Bool {
        let before = entries.count
        entries.removeAll { Snippet(json: $0)?.id == id }
        return entries.count != before
    }

    @discardableResult
    public mutating func replace(_ snippet: Snippet) -> Bool {
        EntryFile.replace(
            in: &entries, id: snippet.id, matching: { Snippet(json: $0)?.id }, with: { snippet.json(over: $0) })
    }

    /// `snippets.json` exists but isn't a snippets object: Fudge never overwrites it.
    public struct Unreadable: Error, Equatable, CustomStringConvertible {
        public init() {}
        public var description: String {
            "Fudge can't read snippets.json, so it leaves the file as it is. Fix or remove it, then try again."
        }
    }

    static let fileKey = "snippets"

    public static func isWritable(_ file: URL) -> Bool {
        (try? EntryFile.object(at: file, key: fileKey)) != nil
    }

    public static func load(from file: URL) -> SnippetStore {
        SnippetStore(entries: EntryFile.entries(at: file, key: fileKey))
    }

    public func save(to file: URL) throws {
        do {
            try EntryFile.save(entries, to: file, key: Self.fileKey)
        } catch is EntryFile.Unreadable {
            throw Unreadable()
        }
    }
}
