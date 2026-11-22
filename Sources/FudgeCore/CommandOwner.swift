import Foundation

/// Fudge's own command groups (FUD-183), a closed list: their commands' ids are `<group>/<command>` in `settings.json`'s
/// `commands`, and a group's Enabled is under its key in `extensions`, beside the extensions'. A new group adds a case.
public enum BuiltInGroup: String, CaseIterable, Hashable, Sendable {
    case apps = ":apps"
    case calendar = ":calendar"
    case system = ":system"
    case tools = ":tools"
    case windowManagement = ":window-management"
    case quicklinks = ":quicklinks"
}

/// Who a command belongs to (FUD-183): one of Fudge's groups, or an extension, bundled ones included. Its key is the
/// part of a command id before the first `/` (`:system`, `github`, `someone+tools+github`).
///
/// A group's key starts with `:`, which the id rule never accepts, and an id never starts with `:`, so the two kinds
/// never meet in one key space.
public enum CommandOwner: Hashable, Sendable, CustomStringConvertible {
    case group(BuiltInGroup)
    case `extension`(ExtensionID)

    /// The key it's written under.
    public var key: String {
        switch self {
        case .group(let group): group.rawValue
        case .extension(let id): id.key
        }
    }

    public var description: String { key }

    /// A key read back from a file: a `:` key is a group by its name, anything else an extension id. Nil when neither
    /// accepts it.
    public init?(stored key: String) {
        if key.hasPrefix(":") {
            guard let group = BuiltInGroup(rawValue: key) else { return nil }
            self = .group(group)
        } else {
            guard let id = ExtensionID(stored: key) else { return nil }
            self = .extension(id)
        }
    }
}

extension CommandOwner: Codable {
    /// Decoded from its string, read as `init?(stored:)` reads it.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let key = try container.decode(String.self)
        guard let owner = CommandOwner(stored: key) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Not a command owner: \(key.debugDescription)")
        }
        self = owner
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(key)
    }
}

/// A dictionary keyed by a `CommandOwner` encodes as a JSON object, as `ExtensionID`'s does.
extension CommandOwner: CodingKeyRepresentable {
    public var codingKey: any CodingKey { StringCodingKey(key) }

    public init?<T: CodingKey>(codingKey: T) {
        self.init(stored: codingKey.stringValue)
    }
}
