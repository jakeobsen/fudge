import Foundation

/// The parts of a Raycast extension's `package.json` that fudge uses.
public struct ExtensionManifest: Sendable, Equatable, Decodable {
    public var name: String
    public var title: String
    public var description: String?
    public var icon: String?
    /// Raycast's `owner` (an organisation) or else `author`, for `environment.ownerOrAuthorName`.
    public var ownerOrAuthorName: String
    public var commands: [Command]
    public var preferences: [Preference]
    /// True when `dependencies` or `devDependencies` lists anything.
    public var hasDependencies: Bool
    /// `package.json`'s `version`, when it has one (Raycast's store extensions usually don't).
    public var version: String?

    public struct Command: Sendable, Equatable, Decodable {
        public var name: String
        public var title: String
        public var subtitle: String?
        public var description: String?
        /// `view`, `no-view` or `menu-bar`.
        public var mode: String
        public var icon: String?
        public var keywords: [String]
        public var arguments: [Argument]
        public var preferences: [Preference]
        /// How often a menu-bar command refreshes in the background, e.g. "10s" (`MenuBarInterval`).
        public var interval: String?

        enum CodingKeys: String, CodingKey {
            case name, title, subtitle, description, mode, icon, keywords, arguments, preferences, interval
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            title = try container.decode(String.self, forKey: .title)
            subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
            description = try container.decodeIfPresent(String.self, forKey: .description)
            mode = try container.decodeIfPresent(String.self, forKey: .mode) ?? "view"
            icon = try container.decodeIfPresent(String.self, forKey: .icon)
            keywords = try container.decodeIfPresent([String].self, forKey: .keywords) ?? []
            arguments = try container.decodeIfPresent([Argument].self, forKey: .arguments) ?? []
            preferences = try container.decodeIfPresent([Preference].self, forKey: .preferences) ?? []
            interval = try? container.decodeIfPresent(String.self, forKey: .interval)
        }
    }

    public struct Argument: Sendable, Equatable, Decodable {
        public var name: String
        /// `text`, `password` or `dropdown`.
        public var type: String
        public var placeholder: String?
        public var required: Bool?
        public var data: [Option]?
    }

    public struct Preference: Sendable, Equatable, Decodable {
        public var name: String
        /// `textfield`, `password`, `checkbox`, `dropdown`, `appPicker`, `file` or `directory`.
        public var type: String
        public var title: String?
        public var label: String?
        public var description: String?
        public var placeholder: String?
        public var required: Bool?
        public var `default`: JSONValue?
        public var data: [Option]?
    }

    public struct Option: Sendable, Equatable, Decodable {
        public var title: String
        public var value: String
    }

    enum CodingKeys: String, CodingKey {
        case name, title, description, icon, owner, author, commands, preferences, dependencies, devDependencies,
            version
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? name
        description = try container.decodeIfPresent(String.self, forKey: .description)
        icon = try container.decodeIfPresent(String.self, forKey: .icon)
        ownerOrAuthorName =
            (try? container.decodeIfPresent(String.self, forKey: .owner))
            ?? (try? container.decodeIfPresent(String.self, forKey: .author)) ?? ""
        commands = try container.decodeIfPresent([Command].self, forKey: .commands) ?? []
        preferences = try container.decodeIfPresent([Preference].self, forKey: .preferences) ?? []
        let dependencies = try container.decodeIfPresent([String: String].self, forKey: .dependencies) ?? [:]
        let devDependencies = try container.decodeIfPresent([String: String].self, forKey: .devDependencies) ?? [:]
        hasDependencies = !dependencies.isEmpty || !devDependencies.isEmpty
        version = try? container.decodeIfPresent(String.self, forKey: .version)
    }

    public static func load(from packageJSON: URL) throws -> ExtensionManifest {
        let data: Data
        do {
            data = try Data(contentsOf: packageJSON)
        } catch {
            throw ManifestError.unreadable(packageJSON.path)
        }
        do {
            return try JSONDecoder().decode(ExtensionManifest.self, from: data)
        } catch {
            throw ManifestError.invalid(packageJSON.path, String(describing: error))
        }
    }

    /// Extension names become folder and file names, so they're lowercase letters, digits, `-` and `_`, starting with
    /// a letter or a digit. Raycast allows `_` too (`notion_researcher`). This is the one extension name rule: every
    /// check of an extension's name uses it, and the runtime's `src/extension-id.ts` mirrors it, both pinned by
    /// `runtime/test/fixtures/extension-names.json`. Command names have their own rule (`isValidCommandName`).
    public static func isValidName(_ name: String) -> Bool {
        name.range(of: #"^[a-z0-9][a-z0-9_-]*$"#, options: .regularExpression) != nil
    }

    /// Command names are letters of either case, digits, `.`, `-` and `_`, starting with a letter or a digit, as
    /// Raycast accepts them (`caffeinateWhile`, `search-projects.command`). A name becomes `src/<name>.<ext>` and
    /// the built `<name>.cjs`, and with no `/`, `\`, `:`, space or leading `.` it can't reach outside `src/` or the
    /// install, or take a built-in group's key. The compatibility scan and the Extension Store mirror it
    /// (`isCommandName` in `runtime/scripts/compat/source-files.ts`), both pinned by
    /// `runtime/test/fixtures/command-names.json`.
    public static func isValidCommandName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil
    }
}

public enum ManifestError: Error, Equatable, CustomStringConvertible {
    case unreadable(String)
    case invalid(String, String)

    public var description: String {
        switch self {
        case .unreadable(let path): "can't read \(path)"
        case .invalid(let path, let reason): "\(path) isn't a valid extension manifest: \(reason)"
        }
    }
}
