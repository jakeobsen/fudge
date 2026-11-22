import Foundation

/// What commands changed about themselves with `updateCommandMetadata`, by command id (`FudgeSettings.commandID`).
/// Stored in `command-metadata.json` as `{ "<extension>/<command>": { "subtitle": "…" } }`. The manifest is never
/// touched, so reinstalling an extension keeps its entries; entries of commands that aren't installed are pruned.
/// Keys of an entry that this version doesn't know are kept as they are.
public struct CommandMetadata: Sendable, Equatable {
    /// The subtitles commands set for root search, replacing the manifest's.
    public private(set) var subtitles: [String: String]
    /// Each entry's other keys, by command id: written back untouched.
    private var otherKeys: [String: [String: JSONValue]] = [:]

    public init(subtitles: [String: String] = [:]) {
        self.subtitles = subtitles
    }

    public func subtitle(extension id: ExtensionID, command: String) -> String? {
        subtitles[FudgeSettings.commandID(owner: .extension(id), command: command)]
    }

    /// Sets a command's subtitle, or with nil goes back to the manifest's.
    public mutating func setSubtitle(_ subtitle: String?, extension id: ExtensionID, command: String) {
        subtitles[FudgeSettings.commandID(owner: .extension(id), command: command)] = subtitle
    }

    /// Drops the entries of commands that aren't in `installed` (command ids). Returns whether any were dropped.
    /// An empty `installed` drops nothing: it more likely means the extensions folder couldn't be read than that
    /// every extension is gone, and a stale entry is harmless.
    @discardableResult
    public mutating func prune(keeping installed: Set<String>) -> Bool {
        guard !installed.isEmpty else { return false }
        let ids = Set(subtitles.keys).union(otherKeys.keys)
        let dropped = ids.subtracting(installed)
        guard !dropped.isEmpty else { return false }
        for id in dropped {
            subtitles[id] = nil
            otherKeys[id] = nil
        }
        return true
    }

    /// Reads the params of `command.updateMetadata`: `{ "subtitle": string | null }`, where a missing subtitle
    /// means null (back to the manifest's).
    public static func subtitle(fromParams params: JSONValue) throws -> String? {
        guard case .object(let values) = params else { throw InvalidMetadata("metadata must be an object") }
        switch values["subtitle"] {
        case .string(let subtitle): return subtitle
        case nil, .null: return nil
        default: throw InvalidMetadata("subtitle must be a string or null")
        }
    }

    public struct InvalidMetadata: Error, Equatable, CustomStringConvertible {
        public var reason: String
        public init(_ reason: String) { self.reason = reason }
        public var description: String { "updateCommandMetadata: \(reason)" }
    }

    /// Reads the file tolerantly: a missing or unreadable file is empty (and `save` then refuses to overwrite it), an
    /// entry that isn't an object is skipped, and a `subtitle` that isn't a string is ignored. An entry's other keys
    /// are kept for `save`.
    public static func load(from file: URL) -> CommandMetadata {
        guard let data = try? Data(contentsOf: file),
            let object = try? JSONDecoder().decode([String: JSONValue].self, from: data)
        else { return CommandMetadata() }
        var metadata = CommandMetadata()
        for (id, entry) in object {
            guard case .object(var fields) = entry else { continue }
            if case .string(let subtitle) = fields["subtitle"] { metadata.subtitles[id] = subtitle }
            fields["subtitle"] = nil
            if !fields.isEmpty { metadata.otherKeys[id] = fields }
        }
        return metadata
    }

    /// The file holds something Fudge can't read, so it leaves it as it is rather than overwrite it.
    public struct Unreadable: Error, Equatable, CustomStringConvertible {
        public init() {}
        public var description: String {
            "Fudge can't read command-metadata.json, so it leaves the file as it is. Fix or remove it, then try again."
        }
    }

    /// Whether `save(to:)` may write `file`: it's missing or blank, or a JSON object. Anything else, or a file that
    /// can't be read, would be lost by saving over it.
    public static func isWritable(_ file: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: file.path) else { return true }
        guard let data = try? Data(contentsOf: file) else { return false }
        if String(decoding: data, as: UTF8.self).allSatisfy(\.isWhitespace) { return true }
        return (try? JSONDecoder().decode([String: JSONValue].self, from: data)) != nil
    }

    /// Writes the file atomically, with each entry's other keys as they were read. An entry left with no keys is
    /// left out. Throws `Unreadable`, leaving the file as it is, when it holds something `load` couldn't read.
    public func save(to file: URL) throws {
        guard Self.isWritable(file) else { throw Unreadable() }
        var object: [String: JSONValue] = [:]
        for id in Set(subtitles.keys).union(otherKeys.keys) {
            var fields = otherKeys[id] ?? [:]
            if let subtitle = subtitles[id] { fields["subtitle"] = .string(subtitle) }
            if !fields.isEmpty { object[id] = .object(fields) }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(object).write(to: file, options: .atomic)
    }
}
