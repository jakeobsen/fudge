import Foundation

/// What commands changed about themselves with `updateCommandMetadata`, by command id (`FudgeSettings.commandID`).
/// Stored in `command-metadata.json` as `{ "<extension>/<command>": { "subtitle": "…" } }`. The manifest is never
/// touched, so reinstalling an extension keeps its entries; entries of commands that aren't installed are pruned.
public struct CommandMetadata: Sendable, Equatable {
    /// The subtitles commands set for root search, replacing the manifest's.
    public private(set) var subtitles: [String: String]

    public init(subtitles: [String: String] = [:]) {
        self.subtitles = subtitles
    }

    public func subtitle(extension extensionName: String, command: String) -> String? {
        subtitles[FudgeSettings.commandID(extension: extensionName, command: command)]
    }

    /// Sets a command's subtitle, or with nil goes back to the manifest's.
    public mutating func setSubtitle(_ subtitle: String?, extension extensionName: String, command: String) {
        subtitles[FudgeSettings.commandID(extension: extensionName, command: command)] = subtitle
    }

    /// Drops the entries of commands that aren't in `installed` (command ids). Returns whether any were dropped.
    @discardableResult
    public mutating func prune(keeping installed: Set<String>) -> Bool {
        let kept = subtitles.filter { installed.contains($0.key) }
        guard kept.count != subtitles.count else { return false }
        subtitles = kept
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

    /// Reads the file tolerantly: a missing or unreadable file is empty, and entries that aren't
    /// `{ "subtitle": string }` are skipped.
    public static func load(from file: URL) -> CommandMetadata {
        guard let data = try? Data(contentsOf: file),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return CommandMetadata() }
        var subtitles: [String: String] = [:]
        for (id, entry) in object {
            if let subtitle = (entry as? [String: Any])?["subtitle"] as? String { subtitles[id] = subtitle }
        }
        return CommandMetadata(subtitles: subtitles)
    }

    /// Writes the file atomically.
    public func save(to file: URL) throws {
        let object = subtitles.mapValues { ["subtitle": $0] }
        let data = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }
}
