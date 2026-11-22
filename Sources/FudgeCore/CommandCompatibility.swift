import Darwin
import Foundation

/// Which commands of an installed extension use something Fudge doesn't support at all (SPEC-109): Raycast AI or the
/// Raycast Browser Extension, each command traced from its own entry by `fudge scan`. `fudge build` keeps it in the
/// install as `compatibility.json`, `{ "commands": { "<command>": ["AI"] } }`, listing only the commands that reach
/// something; an install without it (built before, or the scan couldn't run) has every command enabled.
///
/// Fudge never writes `enabled` for these: such a command is off only while its `enabled` is unset
/// (`FudgeSettings.offByDefault`), so an update that drops the use turns it on again, and a user's own choice stays.
public struct CommandCompatibility: Sendable, Equatable {
    /// What a command can use that Fudge doesn't support: `fudge scan`'s categories (`unsupported` in the runtime's
    /// `src/api/stubs.ts`).
    public enum Unsupported: String, Sendable, CaseIterable, Comparable {
        case ai = "AI"
        case browserExtension = "Browser Extension"

        /// As the store and Settings name it.
        public var name: String {
            switch self {
            case .ai: "Raycast AI"
            case .browserExtension: "the Raycast Browser Extension"
            }
        }

        public static func < (lhs: Self, rhs: Self) -> Bool {
            allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
        }
    }

    /// The command names that use something Fudge doesn't support, and what.
    public var commands: [String: [Unsupported]]

    public init(commands: [String: [Unsupported]] = [:]) {
        self.commands = commands.filter { !$0.value.isEmpty }.mapValues { Array(Set($0)).sorted() }
    }

    public static let fileName = "compatibility.json"
    /// The file is the build's own and small; anything bigger isn't read.
    static let maxBytes = 1 << 20

    /// From `fudge scan <folder> --json`'s report: each command's `unsupported` categories. Nil for a report that
    /// isn't one, or has no per-command results; a category this Fudge doesn't know is left out.
    public init?(report data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let commands = object["commands"] as? [[String: Any]]
        else { return nil }
        var found: [String: [Unsupported]] = [:]
        for command in commands {
            guard let name = command["name"] as? String, let categories = command["unsupported"] as? [String] else {
                return nil
            }
            found[name] = categories.compactMap(Unsupported.init(rawValue:))
        }
        self.init(commands: found)
    }

    /// Reads `directory`'s `compatibility.json`: a regular file, never through a link, read tolerantly. A missing or
    /// broken one, a command name that isn't valid and a category this Fudge doesn't know read as nothing.
    public static func load(from directory: URL) -> CommandCompatibility {
        guard let data = readRegularFile(directory.appendingPathComponent(fileName), maxBytes: maxBytes),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let commands = object["commands"] as? [String: Any]
        else { return CommandCompatibility() }
        var found: [String: [Unsupported]] = [:]
        for (name, value) in commands where ExtensionManifest.isValidCommandName(name) {
            found[name] = ((value as? [Any]) ?? []).compactMap { ($0 as? String).flatMap(Unsupported.init(rawValue:)) }
        }
        return CommandCompatibility(commands: found)
    }

    /// Writes `compatibility.json` into `directory` (the build's staging folder).
    public func write(to directory: URL) throws {
        let object = ["commands": commands.mapValues { $0.map(\.rawValue) }]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
        try data.write(to: directory.appendingPathComponent(Self.fileName), options: .atomic)
    }

    /// Why a command is off until the user turns it on, as Settings → Commands says it; nil for one that uses
    /// nothing Fudge doesn't support.
    public func reason(for command: String) -> String? {
        guard let uses = commands[command], !uses.isEmpty else { return nil }
        let names = uses.map(\.name)
        let listed = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names.last!
        return "Uses \(listed), which Fudge doesn't support."
    }

    private static func readRegularFile(_ url: URL, maxBytes: Int) -> Data? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, Int(info.st_size) <= maxBytes else {
            return nil
        }
        return try? handle.readToEnd() ?? Data()
    }
}

extension InstalledExtension {
    /// The ids of the installed commands that are off until the user turns them on (`FudgeSettings.offByDefault`):
    /// those `compatibility.json` says use something Fudge doesn't support.
    public static func offByDefault(_ installed: [InstalledExtension]) -> Set<String> {
        var ids = Set<String>()
        for installed in installed {
            for command in installed.manifest.commands where installed.compatibility.commands[command.name] != nil {
                ids.insert(FudgeSettings.commandID(extension: installed.manifest.name, command: command.name))
            }
        }
        return ids
    }
}
