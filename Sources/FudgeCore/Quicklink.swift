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
        EntryFile.valid(entries, Quicklink.init(json:), id: \.id)
    }

    public func quicklink(id: String) -> Quicklink? {
        quicklinks.first { $0.id == id }
    }

    public mutating func add(_ quicklink: Quicklink) {
        entries.append(quicklink.json())
    }

    /// Removes the quicklink with `id`; false when there's none.
    @discardableResult
    public mutating func remove(id: String) -> Bool {
        let before = entries.count
        entries.removeAll { Quicklink(json: $0)?.id == id }
        return entries.count != before
    }

    /// Replaces the quicklink with the same `id`, keeping keys Fudge doesn't know on its entry; false when there's
    /// none.
    @discardableResult
    public mutating func replace(_ quicklink: Quicklink) -> Bool {
        EntryFile.replace(
            in: &entries, id: quicklink.id, matching: { Quicklink(json: $0)?.id }, with: { quicklink.json(over: $0) })
    }

    /// `quicklinks.json` exists but isn't a quicklinks object: Fudge never overwrites it.
    public struct Unreadable: Error, Equatable, CustomStringConvertible {
        public init() {}
        public var description: String {
            "Fudge can't read quicklinks.json, so it leaves the file as it is. Fix or remove it, then try again."
        }
    }

    static let fileKey = "quicklinks"

    /// Whether `file` can be saved over: missing, blank, or a quicklinks object.
    public static func isWritable(_ file: URL) -> Bool {
        (try? EntryFile.object(at: file, key: fileKey)) != nil
    }

    /// The quicklinks in `file`; none when it's missing or can't be read.
    public static func load(from file: URL) -> QuicklinkStore {
        QuicklinkStore(entries: EntryFile.entries(at: file, key: fileKey))
    }

    /// Writes the quicklinks over the file's other keys. Throws `Unreadable` rather than overwrite a file it can't
    /// read.
    public func save(to file: URL) throws {
        do {
            try EntryFile.save(entries, to: file, key: Self.fileKey)
        } catch is EntryFile.Unreadable {
            throw Unreadable()
        }
    }
}
