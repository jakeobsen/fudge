import Foundation

/// An extension's `launchCommand(options)` call (the `command.launch` rpc), as the app reads it.
public struct LaunchRequest: Sendable, Equatable {
    /// Raycast's `LaunchType` values.
    public enum LaunchType: String, Sendable, Equatable {
        case userInitiated, background
    }

    public var name: String
    public var type: LaunchType
    /// The other extension's `name`, with its `owner` (or `author`); both nil for the caller's own extension.
    public var extensionName: String?
    public var ownerOrAuthorName: String?
    /// The given argument values, as strings. Arguments given as null are left out.
    public var arguments: [String: String]
    /// `context`, with Dates and Buffers as the runtime encoded them (`$date`, `$buffer`), passed on untouched.
    public var context: JSONValue?
    public var fallbackText: String?

    public init(
        name: String,
        type: LaunchType,
        extensionName: String? = nil,
        ownerOrAuthorName: String? = nil,
        arguments: [String: String] = [:],
        context: JSONValue? = nil,
        fallbackText: String? = nil
    ) {
        self.name = name
        self.type = type
        self.extensionName = extensionName
        self.ownerOrAuthorName = ownerOrAuthorName
        self.arguments = arguments
        self.context = context
        self.fallbackText = fallbackText
    }

    /// Reads the rpc's params. The worker has validated them already; this checks again, with the same messages.
    /// `null` means absent. Numbers and booleans among the arguments become strings, as `String(value)` makes them.
    public init(params: JSONValue) throws {
        guard case .object(let values) = params else { throw LaunchCommandError.invalid("name is required") }
        func string(_ key: String) throws -> String? {
            switch values[key] {
            case nil, .null: return nil
            case .string(let value): return value
            default: throw LaunchCommandError.invalid("\(key) must be a string")
            }
        }
        guard let name = try string("name"), !name.isEmpty else { throw LaunchCommandError.invalid("name is required") }
        guard case .string(let typeName) = values["type"], let type = LaunchType(rawValue: typeName) else {
            throw LaunchCommandError.invalid("type must be LaunchType.UserInitiated or LaunchType.Background")
        }
        let extensionName = try string("extensionName")
        let ownerOrAuthorName = try string("ownerOrAuthorName")
        if extensionName != nil, ownerOrAuthorName == nil {
            throw LaunchCommandError.invalid("ownerOrAuthorName is required with extensionName")
        }
        if ownerOrAuthorName != nil, extensionName == nil {
            throw LaunchCommandError.invalid("extensionName is required with ownerOrAuthorName")
        }
        var arguments: [String: String] = [:]
        switch values["arguments"] {
        case nil, .null:
            break
        case .object(let given):
            for (key, value) in given {
                switch value {
                case .null: continue
                case .string(let text): arguments[key] = text
                case .number(let number): arguments[key] = Self.string(number)
                case .bool(let flag): arguments[key] = flag ? "true" : "false"
                case .array, .object: throw LaunchCommandError.invalid("argument \"\(key)\" must be a string")
                }
            }
        default:
            throw LaunchCommandError.invalid("arguments must be an object")
        }
        let context: JSONValue?
        switch values["context"] {
        case nil, .null: context = nil
        case .object(let object): context = .object(object)
        default: throw LaunchCommandError.invalid("context must be an object")
        }
        self.init(
            name: name,
            type: type,
            extensionName: extensionName,
            ownerOrAuthorName: ownerOrAuthorName,
            arguments: arguments,
            context: context,
            fallbackText: try string("fallbackText")
        )
    }

    /// A number the way JavaScript's `String(value)` writes it, for the common cases: `1`, not `1.0`.
    static func string(_ number: Double) -> String {
        if number.rounded() == number, abs(number) < 1e15 { return String(Int64(number)) }
        return String(number)
    }
}

/// Why a `launchCommand` call was turned down. The description is the message the extension's promise rejects with.
public enum LaunchCommandError: Error, Equatable, CustomStringConvertible {
    /// The options don't make sense (the worker normally catches these first).
    case invalid(String)
    case extensionNotInstalled(owner: String, name: String)
    case commandNotFound(command: String, extension: String)
    case notInBackground(command: String)
    case menuBarNotSupported
    case missingArgument(argument: String, command: String)
    case missingPreferences(extensionTitle: String, names: [String])
    case notAllowed(extensionTitle: String)
    case disabled(command: String)

    public var description: String {
        switch self {
        case .invalid(let problem): "launchCommand: \(problem)"
        case .extensionNotInstalled(let owner, let name): "Extension \"\(owner)/\(name)\" isn't installed"
        case .commandNotFound(let command, let name): "No command \"\(command)\" in extension \"\(name)\""
        case .notInBackground(let command): "\"\(command)\" can't be launched in the background"
        case .menuBarNotSupported: "Menu bar commands aren't supported in fudge yet"
        case .missingArgument(let argument, let command):
            "Missing required argument \"\(argument)\" for \"\(command)\""
        case .missingPreferences(let title, let names):
            "\"\(title)\" needs these preferences set: \(names.joined(separator: ", "))"
        case .notAllowed(let title): "Not allowed to launch commands of \"\(title)\""
        case .disabled(let command): "Command \"\(command)\" is disabled"
        }
    }
}

/// The command a `launchCommand` call names, and what it gets launched with.
public struct LaunchTarget: Sendable, Equatable {
    public var installed: InstalledExtension
    public var command: ExtensionManifest.Command
    /// Every argument in the command's manifest (a given value, else an empty string), the context, the launch type
    /// and the fallback text.
    public var launchProps: LaunchProps
    /// The target is in another extension than the caller, so the user has to allow it.
    public var isOtherExtension: Bool

    /// The command's root search item.
    public var rootItemID: String { RootItem.commandID(extension: installed.manifest.name, command: command.name) }

    /// The first required argument without a value.
    public var missingArgument: ExtensionManifest.Argument? {
        command.arguments.first { $0.required == true && (launchProps.arguments[$0.name] ?? "").isEmpty }
    }
}

/// Finds the command a `launchCommand` call names, and decides whether it can run as asked.
public enum CommandLocator {
    /// The command `request` names: in `caller`'s own extension, or in the installed extension with that `name`
    /// whose owner (or, without one, author) is `ownerOrAuthorName`.
    public static func locate(
        _ request: LaunchRequest, caller: String, in installed: [InstalledExtension],
        settings: FudgeSettings = FudgeSettings()
    ) throws -> LaunchTarget {
        let found: InstalledExtension
        if let extensionName = request.extensionName {
            let owner = request.ownerOrAuthorName ?? ""
            guard
                let match = installed.first(where: {
                    $0.manifest.name == extensionName && $0.manifest.ownerOrAuthorName == owner
                })
            else { throw LaunchCommandError.extensionNotInstalled(owner: owner, name: extensionName) }
            found = match
        } else {
            guard let match = installed.first(where: { $0.manifest.name == caller }) else {
                throw LaunchCommandError.extensionNotInstalled(owner: "", name: caller)
            }
            found = match
        }
        guard let command = found.manifest.commands.first(where: { $0.name == request.name }) else {
            throw LaunchCommandError.commandNotFound(command: request.name, extension: found.manifest.name)
        }
        // A disabled command, or one of a disabled extension, can't be launched (as in Raycast).
        guard settings.isEnabled(extension: found.manifest.name, command: command.name) else {
            throw LaunchCommandError.disabled(command: request.name)
        }
        let arguments = Dictionary(
            command.arguments.map { ($0.name, request.arguments[$0.name] ?? "") },
            uniquingKeysWith: { first, _ in first })
        return LaunchTarget(
            installed: found,
            command: command,
            launchProps: LaunchProps(
                arguments: arguments,
                launchType: request.type.rawValue,
                fallbackText: request.fallbackText,
                launchContext: request.context
            ),
            isOtherExtension: found.manifest.name != caller
        )
    }

    /// Whether the command's mode can be launched as `type`: a view command never in the background, and menu-bar
    /// commands not at all yet. The one place menu-bar commands are turned away.
    public static func checkMode(_ command: ExtensionManifest.Command, type: LaunchRequest.LaunchType) throws {
        if command.mode == "menu-bar" { throw LaunchCommandError.menuBarNotSupported }
        if type == .background, command.mode != "no-view" {
            throw LaunchCommandError.notInBackground(command: command.name)
        }
    }

    /// True when every required argument has a value. Otherwise a user-initiated launch shows the command's argument
    /// fields instead (false), and a background launch fails.
    public static func checkArguments(_ target: LaunchTarget, type: LaunchRequest.LaunchType) throws -> Bool {
        guard let missing = target.missingArgument else { return true }
        guard type == .userInitiated else {
            throw LaunchCommandError.missingArgument(argument: missing.name, command: target.command.name)
        }
        return false
    }

    /// True when no required preference is missing. Otherwise a user-initiated launch opens Settings on the extension
    /// instead (false), and a background launch fails.
    public static func checkPreferences(
        _ missing: [ExtensionManifest.Preference], of target: LaunchTarget, type: LaunchRequest.LaunchType
    ) throws -> Bool {
        guard !missing.isEmpty else { return true }
        guard type == .userInitiated else {
            throw LaunchCommandError.missingPreferences(
                extensionTitle: target.installed.manifest.title, names: missing.map { $0.title ?? $0.name })
        }
        return false
    }
}

/// The user's answers to "may this extension open that extension's commands?", by caller and target extension name.
/// Stored as JSON in `launch-permissions.json`.
public struct LaunchPermissions: Sendable, Equatable, Codable {
    public private(set) var answers: [String: [String: Bool]]

    public init(answers: [String: [String: Bool]] = [:]) {
        self.answers = answers
    }

    public init(from decoder: Decoder) throws {
        answers = try decoder.singleValueContainer().decode([String: [String: Bool]].self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(answers)
    }

    /// The stored answer, or nil when the user hasn't been asked.
    public func answer(caller: String, target: String) -> Bool? {
        answers[caller]?[target]
    }

    public mutating func record(_ allowed: Bool, caller: String, target: String) {
        answers[caller, default: [:]][target] = allowed
    }

    /// Removes an answer, so the user is asked again next time.
    public mutating func forget(caller: String, target: String) {
        answers[caller]?[target] = nil
        if answers[caller]?.isEmpty == true { answers[caller] = nil }
    }

    /// One stored answer: whether `caller` may open `target`'s commands.
    public struct Entry: Sendable, Hashable {
        public var caller: String
        public var target: String
        public var allowed: Bool
    }

    /// Every stored answer, sorted by caller, then target.
    public var entries: [Entry] {
        answers.keys.sorted().flatMap { caller in
            (answers[caller] ?? [:]).sorted { $0.key < $1.key }.map {
                Entry(caller: caller, target: $0.key, allowed: $0.value)
            }
        }
    }

    /// The file holds something `load` can't read, so `save` won't overwrite it.
    public struct Unreadable: Error, Equatable, CustomStringConvertible {
        public init() {}
        public var description: String {
            "fudge can't read launch-permissions.json, so it leaves the file as it is and can't change these answers."
        }
    }

    /// Whether `file` exists with something other than whitespace or answers in it. `load` reads such a file as
    /// empty, so saving over it would lose what's there.
    public static func isUnreadable(_ file: URL) -> Bool {
        guard let data = try? Data(contentsOf: file) else { return false }
        if String(decoding: data, as: UTF8.self).allSatisfy(\.isWhitespace) { return false }
        return (try? JSONDecoder().decode(LaunchPermissions.self, from: data)) == nil
    }

    public static func load(from file: URL) -> LaunchPermissions {
        guard let data = try? Data(contentsOf: file) else { return LaunchPermissions() }
        return (try? JSONDecoder().decode(LaunchPermissions.self, from: data)) ?? LaunchPermissions()
    }

    /// Writes the file atomically. Throws `Unreadable`, leaving the file alone, when it holds something that
    /// isn't answers.
    public func save(to file: URL) throws {
        guard !Self.isUnreadable(file) else { throw Unreadable() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: file, options: .atomic)
    }
}
