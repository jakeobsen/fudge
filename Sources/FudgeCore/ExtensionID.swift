import Foundation

/// An installed extension's key (FUD-183): what its settings, data, sign-ins, logs and command ids are kept under.
///
/// Raycast's extensions keep their manifest name as their key, and so do the bundled ones. An extension from any other
/// repository, the development folder included, has a qualified id: its repository folder's segments, then its name,
/// joined with `+` (`someone+tools+github`, `fudgeapp+development+github`). `+` is in no extension name, no folder
/// segment and no command name, so an id splits back into its parts one way only, and no qualified id equals a name.
///
/// An id comes only from where an install is (`init?(name:repositoryFolder:)`, the loader), from the bundled extensions'
/// constants (`bundled(_:)`), or from a key read back from disk, settings or a message (`init?(stored:)`, checked).
/// There's no init from a `String` that skips the rule and no conversion from a manifest, so a place still keyed by
/// `manifest.name` doesn't compile once it takes an `ExtensionID`.
public struct ExtensionID: Hashable, Sendable, CustomStringConvertible {
    /// The id as it's written in files, settings and messages.
    public let key: String

    private init(unchecked key: String) { self.key = key }

    /// A key read back from disk, settings, a backup, the host or the store, when it passes the id rule.
    public init?(stored key: String) {
        guard Self.isValid(key) else { return nil }
        self.init(unchecked: key)
    }

    /// The id of the extension `name` installed in the repository folder `folder`: the bare name in Raycast's folder,
    /// else the folder's segments and the name joined with `+`. Nil when the name isn't a valid extension name or the
    /// result fails the id rule.
    public init?(name: String, repositoryFolder folder: String) {
        guard ExtensionManifest.isValidName(name) else { return nil }
        if folder == ExtensionRepositoryFolder.raycast {
            self.init(stored: name)
        } else {
            self.init(
                stored: (folder.split(separator: "/", omittingEmptySubsequences: false) + [Substring(name)])
                    .joined(separator: Self.separator))
        }
    }

    /// A bundled extension's id: its manifest name, for the constants `ExtensionStore.id`, `ClipboardHistory.id`,
    /// `FileSearch.id` and `BundledExtensions.emojiID` only.
    static func bundled(_ name: String) -> ExtensionID {
        precondition(ExtensionManifest.isValidName(name), "A bundled extension's name must be valid: \(name)")
        return ExtensionID(unchecked: name)
    }

    public var description: String { key }

    /// What joins a qualified id's parts.
    public static let separator = "+"
    /// The longest id, in bytes, so `Extensions/<id>.old.log` stays under the 255 bytes a file name may have.
    public static let maxBytes = 200

    /// The id rule, at most 200 bytes, one of:
    /// - a valid extension name (Raycast's extensions, and the bundled ones);
    /// - a GitHub owner, a repository and a valid name: exactly three parts;
    /// - a server's name, one to six path segments and a valid name: three to eight parts.
    ///
    /// The parts before the name are a repository folder that `ExtensionRepositoryFolder.isValid` accepts, so they're
    /// lowercase. `raycast+extensions+<name>` is refused, since Raycast's installs keep their bare names.
    /// `runtime/test/fixtures/extension-ids.json` pins this and the runtime's `isValidExtensionId` to the same cases.
    public static func isValid(_ key: String) -> Bool {
        guard key.utf8.count <= maxBytes else { return false }
        let parts = key.split(separator: Character(separator), omittingEmptySubsequences: false).map(String.init)
        guard let name = parts.last, ExtensionManifest.isValidName(name) else { return false }
        if parts.count == 1 { return true }
        let folder = parts.dropLast().joined(separator: "/")
        return folder != ExtensionRepositoryFolder.raycast && ExtensionRepositoryFolder.isValid(folder)
    }
}

extension ExtensionID: Codable {
    /// Decoded from its string, checked with the id rule, so a decoded id is never an unchecked one.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let key = try container.decode(String.self)
        guard let id = ExtensionID(stored: key) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Not an extension id: \(key.debugDescription)")
        }
        self = id
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(key)
    }
}

/// A dictionary keyed by an `ExtensionID` encodes as a JSON object, as one keyed by a `String` does, so the files keep
/// today's shape. Decoding one in one piece fails on the first key the id rule refuses, so a store reads its keys as
/// strings and keeps those `init?(stored:)` accepts.
extension ExtensionID: CodingKeyRepresentable {
    public var codingKey: any CodingKey { StringCodingKey(key) }

    public init?<T: CodingKey>(codingKey: T) {
        self.init(stored: codingKey.stringValue)
    }
}

/// A coding key that's just its string.
struct StringCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
