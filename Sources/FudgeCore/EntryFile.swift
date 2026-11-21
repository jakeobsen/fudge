import Foundation

/// A support file that holds a list of entries under one key, such as `quicklinks.json` (`{ "quicklinks": [ … ] }`)
/// and `snippets.json`. It's read tolerantly and written atomically, keeping the file's other keys and every entry as
/// it was read, invalid ones too, so a hand edit or a newer Fudge's keys survive. A file that isn't such an object
/// can't be read (`Unreadable`), and is never overwritten; a missing or blank one counts as empty.
enum EntryFile {
    struct Unreadable: Error {}

    /// The file's object, or `[:]` when it's missing or blank. Throws `Unreadable` for anything else that isn't an
    /// object whose `key` is a list.
    static func object(at file: URL, key: String) throws -> [String: JSONValue] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        guard let data = try? Data(contentsOf: file) else { throw Unreadable() }
        if String(decoding: data, as: UTF8.self).allSatisfy(\.isWhitespace) { return [:] }
        guard case .object(let object) = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw Unreadable()
        }
        switch object[key] {
        case nil, .array: return object
        default: throw Unreadable()
        }
    }

    /// The file's entries, raw; none when it can't be read.
    static func entries(at file: URL, key: String) -> [JSONValue] {
        guard let object = try? object(at: file, key: key), case .array(let entries) = object[key] else { return [] }
        return entries
    }

    /// Writes `entries` under `key`, over the file's other keys, read again first. Throws `Unreadable` rather than
    /// overwrite a file it can't read.
    static func save(_ entries: [JSONValue], to file: URL, key: String) throws {
        var object = try Self.object(at: file, key: key)
        object[key] = .array(entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(JSONValue.object(object))
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }

    /// The valid entries, each id once, the first one winning.
    static func valid<Entry>(_ entries: [JSONValue], _ read: (JSONValue) -> Entry?, id: (Entry) -> String) -> [Entry] {
        var seen = Set<String>()
        return entries.compactMap(read).filter { seen.insert(id($0)).inserted }
    }

    /// Replaces the entry with `id` by `json(existing)`, which writes over the old entry so its unknown keys stay.
    static func replace(
        in entries: inout [JSONValue], id: String, matching: (JSONValue) -> String?,
        with json: ([String: JSONValue]) -> JSONValue
    ) -> Bool {
        guard let index = entries.firstIndex(where: { matching($0) == id }) else { return false }
        var existing: [String: JSONValue] = [:]
        if case .object(let object) = entries[index] { existing = object }
        entries[index] = json(existing)
        return true
    }
}
