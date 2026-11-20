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

    /// The values of search bar dropdowns that ask for theirs to be kept (`storeValue`).
    public var dropdownValuesFile: URL {
        supportDirectory.appendingPathComponent("dropdown-values.json")
    }

    /// Which extensions the user allowed to open other extensions' commands (`launchCommand`).
    public var launchPermissionsFile: URL {
        supportDirectory.appendingPathComponent("launch-permissions.json")
    }

    /// What commands changed about themselves with `updateCommandMetadata` (`CommandMetadata`).
    public var commandMetadataFile: URL {
        supportDirectory.appendingPathComponent("command-metadata.json")
    }

    /// The menu-bar commands the user activated (`MenuBarStore`).
    public var menuBarFile: URL {
        supportDirectory.appendingPathComponent("menu-bar.json")
    }

    /// The preference values set for each extension.
    public var preferencesDirectory: URL {
        supportDirectory.appendingPathComponent("preferences", isDirectory: true)
    }

    /// An extension's own folder for files it keeps (`environment.supportPath`).
    public func supportDirectory(forExtension name: String) -> URL {
        supportDirectory.appendingPathComponent("extension-data/\(name)", isDirectory: true)
    }

    /// Where an extension's `Cache` lives.
    public func cacheDirectory(forExtension name: String) -> URL {
        supportDirectory.appendingPathComponent("cache/\(name)", isDirectory: true)
    }

    /// Where an extension's `LocalStorage` lives.
    public func localStorageFile(forExtension name: String) -> URL {
        supportDirectory.appendingPathComponent("local-storage/\(name).json")
    }

    /// Installed extensions, one folder each.
    public var extensionsDirectory: URL {
        supportDirectory.appendingPathComponent("extensions", isDirectory: true)
    }
}
