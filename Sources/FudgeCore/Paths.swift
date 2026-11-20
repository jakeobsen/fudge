import Foundation

/// Where fudge keeps its files.
public struct FudgePaths: Sendable, Equatable {
    /// The root folder for everything fudge stores.
    public let supportDirectory: URL

    public init(supportDirectory: URL) {
        self.supportDirectory = supportDirectory
    }

    /// `~/Library/Application Support/fudge`, or `$FUDGE_SUPPORT_DIR` when it is set.
    public static func standard(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> FudgePaths {
        if let override = environment["FUDGE_SUPPORT_DIR"], !override.isEmpty {
            return FudgePaths(supportDirectory: URL(fileURLWithPath: override, isDirectory: true))
        }
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return FudgePaths(supportDirectory: applicationSupport.appendingPathComponent("fudge", isDirectory: true))
    }

    /// fudge's own settings.
    public var settingsFile: URL {
        supportDirectory.appendingPathComponent("settings.json")
    }

    /// How often and how recently root items were opened.
    public var historyFile: URL {
        supportDirectory.appendingPathComponent("history.json")
    }

    /// The preference values set for each extension.
    public var preferencesDirectory: URL {
        supportDirectory.appendingPathComponent("preferences", isDirectory: true)
    }

    /// Installed extensions, one folder each.
    public var extensionsDirectory: URL {
        supportDirectory.appendingPathComponent("extensions", isDirectory: true)
    }
}
