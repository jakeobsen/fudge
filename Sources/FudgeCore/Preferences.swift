import CoreServices
import Foundation

/// The preference values the user has set for one extension, stored as JSON.
public struct StoredPreferences: Sendable, Equatable, Codable {
    /// Extension-wide preferences, by name.
    public var extensionValues: [String: JSONValue] = [:]
    /// Each command's own preferences: command name → preference name → value.
    public var commandValues: [String: [String: JSONValue]] = [:]

    public init(extensionValues: [String: JSONValue] = [:], commandValues: [String: [String: JSONValue]] = [:]) {
        self.extensionValues = extensionValues
        self.commandValues = commandValues
    }

    enum CodingKeys: String, CodingKey {
        case extensionValues = "extension"
        case commandValues = "commands"
    }
}

/// Reads and writes `preferences/<extension>.json` in fudge's support folder.
public struct PreferenceStore: Sendable {
    public var directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func load(_ extensionName: String) -> StoredPreferences {
        guard let data = try? Data(contentsOf: file(for: extensionName)) else { return StoredPreferences() }
        return (try? JSONDecoder().decode(StoredPreferences.self, from: data)) ?? StoredPreferences()
    }

    public func save(_ preferences: StoredPreferences, for extensionName: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(preferences).write(to: file(for: extensionName), options: .atomic)
    }

    private func file(for extensionName: String) -> URL {
        directory.appendingPathComponent("\(extensionName).json")
    }
}

/// The values a command gets from `getPreferenceValues()`.
public struct ResolvedPreferences: Sendable, Equatable {
    public var values: [String: JSONValue]
    /// Required preferences that have no value; the command can't run until they're set.
    public var missing: [ExtensionManifest.Preference]
}

public enum PreferenceResolver {
    /// Merges the extension's and the command's preferences: the stored value, else the manifest's
    /// default, else the type's own default (false for checkboxes, the first option for dropdowns).
    /// appPicker values (a path, bundle id or app name) become Raycast `Application` objects.
    public static func resolve(
        _ manifest: ExtensionManifest,
        command: ExtensionManifest.Command,
        stored: StoredPreferences,
        application: (String) -> JSONValue? = ApplicationResolver.resolve
    ) -> ResolvedPreferences {
        var values: [String: JSONValue] = [:]
        var missing: [ExtensionManifest.Preference] = []
        let scopes: [([ExtensionManifest.Preference], [String: JSONValue])] = [
            (manifest.preferences, stored.extensionValues),
            (command.preferences, stored.commandValues[command.name] ?? [:]),
        ]
        for (preferences, storedValues) in scopes {
            for preference in preferences {
                var value = storedValues[preference.name] ?? preference.default ?? typeDefault(preference)
                if preference.type == "appPicker", case .string(let reference) = value {
                    value = application(reference)
                }
                if let value, value != .null, value != .string("") || preference.type != "appPicker" {
                    values[preference.name] = value
                } else if preference.required == true {
                    missing.append(preference)
                }
            }
        }
        return ResolvedPreferences(values: values, missing: missing)
    }

    static func typeDefault(_ preference: ExtensionManifest.Preference) -> JSONValue? {
        switch preference.type {
        case "checkbox": .bool(false)
        case "dropdown": preference.data?.first.map { .string($0.value) }
        default: nil
        }
    }
}

/// Turns an appPicker reference into a Raycast `Application`: `{ name, path, bundleId? }`.
public enum ApplicationResolver {
    public static func resolve(_ reference: String) -> JSONValue? {
        let expanded = (reference as NSString).expandingTildeInPath
        if expanded.hasPrefix("/"), FileManager.default.fileExists(atPath: expanded) {
            return application(at: URL(fileURLWithPath: expanded))
        }
        if let url = applicationURL(bundleIdentifier: reference) {
            return application(at: url)
        }
        let name = reference.hasSuffix(".app") ? String(reference.dropLast(4)) : reference
        if let match = ApplicationIndex.scan().first(where: { $0.title.caseInsensitiveCompare(name) == .orderedSame }),
            case .application(let url) = match.kind
        {
            return application(at: url)
        }
        return nil
    }

    public static func application(at url: URL) -> JSONValue {
        let bundle = Bundle(url: url)
        let name = (FileManager.default.displayName(atPath: url.path) as NSString).deletingPathExtension
        var object: [String: JSONValue] = ["name": .string(name), "path": .string(url.path)]
        if let identifier = bundle?.bundleIdentifier { object["bundleId"] = .string(identifier) }
        return .object(object)
    }

    private static func applicationURL(bundleIdentifier: String) -> URL? {
        guard bundleIdentifier.contains(".") else { return nil }
        let urls = LSCopyApplicationURLsForBundleIdentifier(bundleIdentifier as CFString, nil)?.takeRetainedValue()
        return (urls as? [URL])?.first
    }
}
