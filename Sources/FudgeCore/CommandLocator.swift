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
    case notActiveInMenuBar(command: String)
    case missingArgument(argument: String, command: String)
    case missingPreferences(extensionTitle: String, names: [String])
    case notAllowed(extensionTitle: String)
    /// A background call can't ask "Allow A to open B?"; the question comes when the user opens the caller.
    case permissionNeeded(extensionTitle: String)
    case disabled(command: String)

    public var description: String {
        switch self {
        case .invalid(let problem): "launchCommand: \(problem)"
        case .extensionNotInstalled(let owner, let name): "Extension \"\(owner)/\(name)\" isn't installed"
        case .commandNotFound(let command, let name): "No command \"\(command)\" in extension \"\(name)\""
        case .notInBackground(let command): "\"\(command)\" can't be launched in the background"
        case .notActiveInMenuBar(let command): "\"\(command)\" isn't active in the menu bar"
        case .missingArgument(let argument, let command):
            "Missing required argument \"\(argument)\" for \"\(command)\""
        case .missingPreferences(let title, let names):
            "\"\(title)\" needs these preferences set: \(names.joined(separator: ", "))"
        case .notAllowed(let title): "Not allowed to launch commands of \"\(title)\""
        case .permissionNeeded(let title):
            "Not allowed to launch commands of \"\(title)\" yet: Fudge asks the user when they open this command"
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
    public var rootItemID: String { RootItem.commandID(owner: .extension(installed.id), command: command.name) }

    /// The first required argument without a value.
    public var missingArgument: ExtensionManifest.Argument? {
        command.arguments.first { $0.required == true && (launchProps.arguments[$0.name] ?? "").isEmpty }
    }
}

/// Finds the command a `launchCommand` call names, and decides whether it can run as asked.
public enum CommandLocator {
    /// What a `launchCommand` call opens: one command, or a choice the user makes between copies (SPEC-177).
    public enum Located: Sendable, Equatable {
        /// The command to launch.
        case target(LaunchTarget)
        /// Two or more installs can run the call: `copies`, those, sorted by repository label (`sorted(_:names:)`);
        /// `all`, every install with that name and owner, which a choice is recorded among (`LaunchPermissions`).
        case choose(copies: [InstalledExtension], all: [ExtensionID])
    }

    /// The command `request` names: in `caller`'s own extension, or in an installed extension with that `name` whose
    /// owner (or, without one, author) is `ownerOrAuthorName`. Of several such installs, the caller itself is the
    /// target if it's one of them; else those that can't run the call (no such command, or the extension or the
    /// command switched off) are left out, one left is the target, two or more are a choice, and none gives the
    /// refusal of the first by repository label, as a single install would.
    public static func locate(
        _ request: LaunchRequest, caller: InstalledExtension, in installed: [InstalledExtension],
        settings: FudgeSettings = FudgeSettings(), names: RepositoryNames = RepositoryNames(settings: FudgeSettings())
    ) throws -> Located {
        guard let extensionName = request.extensionName else {
            guard let match = installed.first(where: { $0.id == caller.id }) else {
                throw LaunchCommandError.extensionNotInstalled(owner: "", name: caller.manifest.name)
            }
            return .target(try target(request, in: match, caller: caller, settings: settings))
        }
        let owner = request.ownerOrAuthorName ?? ""
        let matches = sorted(
            installed.filter { $0.manifest.name == extensionName && $0.manifest.ownerOrAuthorName == owner },
            names: names)
        guard let first = matches.first else {
            throw LaunchCommandError.extensionNotInstalled(owner: owner, name: extensionName)
        }
        if let own = matches.first(where: { $0.id == caller.id }) {
            return .target(try target(request, in: own, caller: caller, settings: settings))
        }
        let copies = matches.filter { canRun(request, in: $0, settings: settings) }
        if copies.count > 1 { return .choose(copies: copies, all: matches.map(\.id)) }
        return .target(try target(request, in: copies.first ?? first, caller: caller, settings: settings))
    }

    /// Whether `found` can run the call: it has the command, and neither the extension nor the command is switched off.
    static func canRun(_ request: LaunchRequest, in found: InstalledExtension, settings: FudgeSettings) -> Bool {
        found.manifest.commands.contains { $0.name == request.name }
            && settings.isEnabled(owner: .extension(found.id), command: request.name)
    }

    /// Installs of one name and owner in the order the question and the Permissions page list them: by repository
    /// label, A to Z (`localizedStandardCompare`), then by id.
    public static func sorted(_ copies: [InstalledExtension], names: RepositoryNames) -> [InstalledExtension] {
        copies.map { (copy: $0, label: names.label(of: $0.repository)) }.sorted { first, second in
            switch first.label.localizedStandardCompare(second.label) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: first.copy.id.key < second.copy.id.key
            }
        }.map(\.copy)
    }

    /// The command `request` names in `found`, launched by `caller`, when it can be: it exists, and neither it nor its
    /// extension is switched off. `locate` uses it, and the app after the user chooses a copy.
    public static func target(
        _ request: LaunchRequest, in found: InstalledExtension, caller: InstalledExtension, settings: FudgeSettings
    ) throws -> LaunchTarget {
        guard let command = found.manifest.commands.first(where: { $0.name == request.name }) else {
            throw LaunchCommandError.commandNotFound(command: request.name, extension: found.manifest.name)
        }
        // A disabled command, or one of a disabled extension, can't be launched (as in Raycast).
        guard settings.isEnabled(owner: .extension(found.id), command: command.name) else {
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
            isOtherExtension: found.id != caller.id
        )
    }

    /// Whether the command's mode can be launched as `type`. A view command never runs in the background. A
    /// menu-bar command runs either way (`MenuBarController`): in the background only while it's active in the
    /// menu bar, where the launch refreshes it; a UserInitiated launch activates it first if needed.
    public static func checkMode(
        _ command: ExtensionManifest.Command, type: LaunchRequest.LaunchType, isActiveInMenuBar: Bool = false
    ) throws {
        if command.mode == "menu-bar" {
            if type == .background, !isActiveInMenuBar {
                throw LaunchCommandError.notActiveInMenuBar(command: command.name)
            }
            return
        }
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
    /// instead (false), and a background launch fails, naming the extension as `extensionTitle` (`ExtensionTitles`).
    public static func checkPreferences(
        _ missing: [ExtensionManifest.Preference], of target: LaunchTarget, extensionTitle: String,
        type: LaunchRequest.LaunchType
    ) throws -> Bool {
        guard !missing.isEmpty else { return true }
        guard type == .userInitiated else {
            throw LaunchCommandError.missingPreferences(
                extensionTitle: extensionTitle, names: missing.map { $0.title ?? $0.name })
        }
        return false
    }
}

/// The user's answers to "may this extension open that extension's commands?", by caller and target extension id.
/// Stored as JSON in `launch-permissions.json`, `{"<caller>": {"<target>": true}}`, as before ids.
public struct LaunchPermissions: Sendable, Equatable, Codable {
    public private(set) var answers: [ExtensionID: [ExtensionID: Bool]]
    /// The file's answers under a caller or target key that isn't an id (a hand edit, a newer Fudge's), by the keys as
    /// written: left out of `answers`, and written back unchanged.
    private var otherAnswers: [String: [String: Bool]] = [:]

    public init(answers: [ExtensionID: [ExtensionID: Bool]] = [:]) {
        self.answers = answers
    }

    /// Read as strings and split, never decoded by id in one piece, so one key that isn't an id costs only itself.
    public init(from decoder: Decoder) throws {
        let all = try decoder.singleValueContainer().decode([String: [String: Bool]].self)
        answers = [:]
        for (callerKey, targets) in all {
            guard let caller = ExtensionID(stored: callerKey) else {
                otherAnswers[callerKey] = targets
                continue
            }
            for (targetKey, allowed) in targets {
                if let target = ExtensionID(stored: targetKey) {
                    answers[caller, default: [:]][target] = allowed
                } else {
                    otherAnswers[callerKey, default: [:]][targetKey] = allowed
                }
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var all = otherAnswers
        for (caller, targets) in answers {
            for (target, allowed) in targets { all[caller.key, default: [:]][target.key] = allowed }
        }
        var container = encoder.singleValueContainer()
        try container.encode(all)
    }

    /// The stored answer, or nil when the user hasn't been asked.
    public func answer(caller: ExtensionID, target: ExtensionID) -> Bool? {
        answers[caller]?[target]
    }

    public mutating func record(_ allowed: Bool, caller: ExtensionID, target: ExtensionID) {
        answers[caller, default: [:]][target] = allowed
    }

    /// Removes an answer, so the user is asked again next time.
    public mutating func forget(caller: ExtensionID, target: ExtensionID) {
        answers[caller]?[target] = nil
        if answers[caller]?.isEmpty == true { answers[caller] = nil }
    }

    /// One stored answer: whether `caller` may open `target`'s commands.
    public struct Entry: Sendable, Hashable, Identifiable {
        public var caller: ExtensionID
        public var target: ExtensionID
        public var allowed: Bool

        /// The caller and target, not the answer, so changing an answer updates its row instead of replacing it.
        public var id: [String] { [caller.key, target.key] }
    }

    /// Every stored answer, sorted by caller, then target.
    public var entries: [Entry] {
        answers.keys.sorted { $0.key < $1.key }.flatMap { caller in
            (answers[caller] ?? [:]).sorted { $0.key.key < $1.key.key }.map {
                Entry(caller: caller, target: $0.key, allowed: $0.value)
            }
        }
    }

    /// A caller's choice among copies of one extension (SPEC-177): the copy it opens, none, or not made yet.
    public enum CopyChoice: Sendable, Hashable {
        case chosen(ExtensionID)
        case notAllowed
        case unanswered
    }

    /// The choice stored for `caller` among `copies`: exactly one copy answered `true` is chosen, whatever the others
    /// hold; every copy answered `false` is not allowed; anything else, two `true`s included, is unanswered.
    public func choice(caller: ExtensionID, among copies: [ExtensionID]) -> CopyChoice {
        let allowed = copies.filter { answer(caller: caller, target: $0) == true }
        if allowed.count == 1 { return .chosen(allowed[0]) }
        if !copies.isEmpty, copies.allSatisfy({ answer(caller: caller, target: $0) == false }) { return .notAllowed }
        return .unanswered
    }

    /// Records the user's choice among `copies`, every install of one name and owner: a copy stores `true` for it and
    /// forgets the others' answers for `caller`; nil ("Don't Allow") stores `false` for each.
    public mutating func recordChoice(_ chosen: ExtensionID?, caller: ExtensionID, among copies: [ExtensionID]) {
        guard let chosen else {
            for copy in copies { record(false, caller: caller, target: copy) }
            return
        }
        forget(caller: caller, among: copies)
        record(true, caller: caller, target: chosen)
    }

    /// Forgets `caller`'s answers for each of `copies`, so the user is asked again.
    public mutating func forget(caller: ExtensionID, among copies: [ExtensionID]) {
        for copy in copies { forget(caller: caller, target: copy) }
    }

    /// A row of the Permissions page's "Extensions that open other extensions".
    public enum Row: Sendable, Equatable, Identifiable {
        /// One stored answer, "Allowed" or "Not allowed".
        case answer(Entry)
        /// A caller's answers to an extension installed two or more times, as one choice among its copies.
        case choice(Choice)

        public var caller: ExtensionID {
            switch self {
            case .answer(let entry): entry.caller
            case .choice(let choice): choice.caller
            }
        }

        /// The caller and the target, or a choice's first copy, so a change updates the row instead of replacing it.
        public var id: [String] {
            switch self {
            case .answer(let entry): entry.id
            case .choice(let choice): [choice.caller.key, choice.copies.first?.id.key ?? ""]
            }
        }
    }

    /// A choice row: the caller, every install of the target's name and owner, switched off or not, sorted as
    /// `CommandLocator.sorted` sorts them, and what's stored (`choice(caller:among:)`).
    public struct Choice: Sendable, Equatable {
        public var caller: ExtensionID
        public var copies: [InstalledExtension]
        public var selection: CopyChoice
    }

    /// The page's rows: a stored answer whose target is installed beside other installs of its name and owner joins
    /// the one choice row of its caller and those installs; every other answer is a row as before. By caller, then
    /// target, a choice row by its first copy's id.
    public func rows(installed: [InstalledExtension], names: RepositoryNames) -> [Row] {
        let byID = InstalledExtension.index(installed)
        var rows: [(row: Row, target: String)] = []
        var choices: Set<[String]> = []
        for entry in entries {
            if let target = byID[entry.target] {
                let group = byID.values.filter {
                    $0.manifest.name == target.manifest.name
                        && $0.manifest.ownerOrAuthorName == target.manifest.ownerOrAuthorName
                }
                if group.count > 1 {
                    let copies = CommandLocator.sorted(group, names: names)
                    let ids = copies.map(\.id)
                    if choices.insert([entry.caller.key] + ids.map(\.key)).inserted {
                        let selection = choice(caller: entry.caller, among: ids)
                        let row = Row.choice(Choice(caller: entry.caller, copies: copies, selection: selection))
                        rows.append((row, ids[0].key))
                    }
                    continue
                }
            }
            rows.append((.answer(entry), entry.target.key))
        }
        return rows.sorted { first, second in
            let (one, other) = (first.row.caller.key, second.row.caller.key)
            return one != other ? one < other : first.target < second.target
        }.map(\.row)
    }

    /// The file holds something `load` can't read, so `save` won't overwrite it.
    public struct Unreadable: Error, Equatable, CustomStringConvertible {
        public init() {}
        public var description: String {
            "Fudge can't read launch-permissions.json, so it leaves the file as it is and can't change these answers. "
                + "Fix or remove it, then try again."
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
