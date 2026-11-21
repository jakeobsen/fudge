import Foundation

/// A saved link that opens from root search (FUD-86): a name, a link with optional placeholders
/// (`QuicklinkTemplate`), and the app that opens it.
public struct Quicklink: Sendable, Equatable, Identifiable {
    public var id: String
    /// 1–64 characters, unique among quicklinks ignoring case.
    public var name: String
    /// A URL with a scheme, or a file path (absolute or starting with `~`), with optional placeholders.
    public var link: String
    /// The bundle id of the app that opens it; nil for the default app.
    public var application: String?
    /// When it was made, as ISO 8601.
    public var createdAt: String?

    public static let nameLimit = 64

    public init(
        id: String = UUID().uuidString, name: String, link: String, application: String? = nil,
        createdAt: String? = nil
    ) {
        self.id = id
        self.name = name
        self.link = link
        self.application = application
        self.createdAt = createdAt
    }

    /// Reads one entry of `quicklinks.json`: nil without a valid `id`, `name` or `link`.
    init?(json: JSONValue) {
        guard case .object(let object) = json,
            case .string(let id) = object["id"], !id.trimmingCharacters(in: .whitespaces).isEmpty,
            case .string(let name) = object["name"], Self.isValidName(name),
            case .string(let link) = object["link"], !link.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        var application: String?
        if case .string(let app) = object["application"], !app.isEmpty { application = app }
        var createdAt: String?
        if case .string(let date) = object["createdAt"] { createdAt = date }
        self.init(id: id, name: name, link: link, application: application, createdAt: createdAt)
    }

    /// A name has 1–64 characters, not all of them spaces.
    public static func isValidName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= nameLimit
    }

    /// The entry as `quicklinks.json` holds it, over `existing` so the keys Fudge doesn't know stay.
    func json(over existing: [String: JSONValue] = [:]) -> JSONValue {
        var object = existing
        object["id"] = .string(id)
        object["name"] = .string(name)
        object["link"] = .string(link)
        object["application"] = application.map(JSONValue.string)
        object["createdAt"] = createdAt.map(JSONValue.string)
        return .object(object.compactMapValues { $0 })
    }

    /// The id of its root search item, which its launches count under in `LaunchHistory`.
    public var rootItemID: String { "quicklink:\(id)" }
}

/// The user's quicklinks, kept in `quicklinks.json` as `{ "quicklinks": [ … ] }`. It reads tolerantly, writes
/// atomically, keeps the keys it doesn't know (on the file and on each entry), and never overwrites a file it can't
/// read (`Unreadable`). An entry with no valid `id`, `name` or `link` isn't a quicklink, but stays in the file.
public struct QuicklinkStore: Sendable, Equatable {
    /// Every entry as read, the ones that aren't quicklinks included, so saving keeps them.
    private var entries: [JSONValue]

    public init(_ quicklinks: [Quicklink] = []) {
        entries = quicklinks.map { $0.json() }
    }

    init(entries: [JSONValue]) {
        self.entries = entries
    }

    /// The quicklinks, in the file's order. Of two with the same id, the first counts.
    public var quicklinks: [Quicklink] {
        var seen = Set<String>()
        return entries.compactMap(Quicklink.init(json:)).filter { seen.insert($0.id).inserted }
    }

    public func quicklink(id: String) -> Quicklink? {
        quicklinks.first { $0.id == id }
    }

    /// Adds one at the end.
    public mutating func add(_ quicklink: Quicklink) {
        entries.append(quicklink.json())
    }

    /// Removes the quicklink with `id`. Returns whether there was one.
    @discardableResult
    public mutating func remove(id: String) -> Bool {
        let before = entries.count
        entries.removeAll { Quicklink(json: $0)?.id == id }
        return entries.count != before
    }

    /// Replaces the quicklink with the same id, keeping the keys Fudge doesn't know on it. Returns whether there
    /// was one.
    @discardableResult
    public mutating func replace(_ quicklink: Quicklink) -> Bool {
        guard let index = entries.firstIndex(where: { Quicklink(json: $0)?.id == quicklink.id }) else { return false }
        var existing: [String: JSONValue] = [:]
        if case .object(let object) = entries[index] { existing = object }
        entries[index] = quicklink.json(over: existing)
        return true
    }

    /// The file holds something Fudge can't read, so it leaves it as it is rather than overwrite it.
    public struct Unreadable: Error, Equatable, CustomStringConvertible {
        public init() {}
        public var description: String {
            "Fudge can't read quicklinks.json, so it leaves the file as it is. Fix or remove it, then try again."
        }
    }

    /// Whether `save(to:)` may write `file`: it's missing or blank, or a JSON object whose `quicklinks`, if any, is
    /// a list.
    public static func isWritable(_ file: URL) -> Bool {
        (try? existingObject(at: file)) != nil
    }

    /// The JSON object in `file`; empty when the file is missing or blank. Throws `Unreadable` for anything else.
    private static func existingObject(at file: URL) throws -> [String: JSONValue] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        guard let data = try? Data(contentsOf: file) else { throw Unreadable() }
        if String(decoding: data, as: UTF8.self).allSatisfy(\.isWhitespace) { return [:] }
        guard case .object(let object) = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw Unreadable()
        }
        switch object["quicklinks"] {
        case nil, .array: return object
        default: throw Unreadable()
        }
    }

    /// Reads the file tolerantly: one that's missing or can't be read has no quicklinks.
    public static func load(from file: URL) -> QuicklinkStore {
        guard let object = try? existingObject(at: file), case .array(let entries) = object["quicklinks"] else {
            return QuicklinkStore()
        }
        return QuicklinkStore(entries: entries)
    }

    /// Writes the file atomically, keeping keys it doesn't know. Throws `Unreadable`, leaving the file as it is,
    /// when it holds something `load` couldn't read.
    public func save(to file: URL) throws {
        var object = try Self.existingObject(at: file)
        object["quicklinks"] = .array(entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(JSONValue.object(object))
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }
}
